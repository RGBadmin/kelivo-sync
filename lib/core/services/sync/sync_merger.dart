import 'package:drift/drift.dart';

import '../../database/app_database.dart';
import '../../database/business_data.dart';
import '../../database/business_settings_router.dart';
import 'sync_object_codec.dart';

/// Mirror-mode applier: the winning side's state replaces the losing side's
/// wholesale. No row-level merging — the sync engine has already decided
/// which side is newest, this class just makes the local database identical
/// to the remote objects it is given.
///
/// All writes bypass the repositories, so nothing here is echo-marked dirty.
final class SyncMerger {
  SyncMerger(this._db);

  final AppDatabase _db;

  /// Replaces the local conversation with the remote object, wholesale.
  Future<void> replaceConversationObject(
    Map<String, dynamic> object, {
    required Map<String, String> hashToPath,
  }) async {
    final conversation = object['conversation'] as Map<String, dynamic>;
    final conversationId = conversation['id'] as String;
    final remoteMessages = (object['messages'] as List)
        .cast<Map<String, dynamic>>();
    final remoteMcp = (object['mcpServers'] as List? ?? const [])
        .cast<Map<String, dynamic>>();

    String localize(String value) =>
        SyncObjectCodec.localizeContent(value, hashToPath);

    await _db.transaction(() async {
      // Cascades take parts/artifacts/asset links with the old rows.
      await _db.customStatement(
        'DELETE FROM conversation_rows WHERE id = ?;',
        [conversationId],
      );
      await _insertConversationRow(conversation);
      await _replaceMcpRows(conversationId, remoteMcp);
      final sorted = _sortedByCanonicalOrder(remoteMessages);
      for (final (index, message) in sorted.indexed) {
        await _insertMessage(conversationId, message, index, localize);
      }
      await _queueAssetBackfill(conversationId);
    });
  }

  /// Deletes local conversations that no longer exist on the winning side.
  Future<Set<String>> deleteConversations(Iterable<String> ids) async {
    final deleted = <String>{};
    await _db.transaction(() async {
      for (final id in ids) {
        final count = await _db.customUpdate(
          'DELETE FROM conversation_rows WHERE id = ?;',
          variables: [Variable.withString(id)],
          updateKind: UpdateKind.delete,
        );
        if (count > 0) deleted.add(id);
      }
    });
    return deleted;
  }

  Future<Set<String>> localConversationIds() async {
    final rows = await _db
        .customSelect('SELECT id FROM conversation_rows;')
        .get();
    return {for (final row in rows) row.data['id'] as String};
  }

  /// Replaces one entity table with the remote object's rows.
  Future<void> replaceEntities(
    BusinessEntityKind kind,
    Map<String, dynamic>? object, {
    required Map<String, String> hashToPath,
  }) async {
    final remoteRows = (object?['rows'] as List? ?? const [])
        .cast<Map<String, dynamic>>();
    await _db.transaction(() async {
      await _db.customStatement('DELETE FROM ${kind.tableName};');
      for (final remote in remoteRows) {
        await _insertEntityRow(kind, remote, hashToPath);
      }
    });
  }

  /// Replaces the synced preference rows with the remote object's entries.
  /// Local-only and discarded keys never live in `preference_rows`, so a
  /// full replace is safe.
  Future<void> replaceSettings(
    Map<String, dynamic>? object, {
    required Map<String, String> hashToPath,
  }) async {
    final remotePrefs =
        (object?['prefs'] as Map<String, dynamic>?) ?? const {};
    await _db.transaction(() async {
      await _db.customStatement('DELETE FROM preference_rows;');
      for (final entry in remotePrefs.entries) {
        final key = entry.key;
        if (BusinessKeyRegistry.localOnlyKeys.contains(key) ||
            BusinessKeyRegistry.discardedKeys.contains(key) ||
            key.startsWith('restore_')) {
          continue;
        }
        final remote = entry.value as Map<String, dynamic>;
        await _db.customStatement(
          'INSERT INTO preference_rows (key, value, updated_at) '
          'VALUES (?, ?, ?);',
          [
            key,
            SyncObjectCodec.localizeJsonString(
              remote['value'] as String? ?? 'null',
              hashToPath,
            ),
            (remote['updatedAt'] as num?)?.toInt() ?? 0,
          ],
        );
      }
    });
  }

  /// Drops every pending dirty marker and tombstone — called after the
  /// local state has been made identical to the remote (nothing left to
  /// push) or after a push consumed them.
  Future<void> clearSyncQueues() async {
    await _db.transaction(() async {
      await _db.customStatement('DELETE FROM sync_dirty_rows;');
      await _db.customStatement('DELETE FROM sync_tombstone_rows;');
    });
  }

  // ===== Row writers =====

  List<Map<String, dynamic>> _sortedByCanonicalOrder(
    List<Map<String, dynamic>> messages,
  ) {
    final sorted = [...messages];
    sorted.sort((a, b) {
      final byTimestamp = ((a['timestamp'] as num?)?.toInt() ?? 0).compareTo(
        (b['timestamp'] as num?)?.toInt() ?? 0,
      );
      if (byTimestamp != 0) return byTimestamp;
      return (a['id'] as String).compareTo(b['id'] as String);
    });
    return sorted;
  }

  Future<void> _insertConversationRow(Map<String, dynamic> c) async {
    await _db.customStatement(
      'INSERT INTO conversation_rows '
      '(id, title, created_at, updated_at, is_pinned, assistant_id, '
      'truncate_index, version_selections_json, summary, '
      'last_summarized_message_count, chat_suggestions_json) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);',
      [
        c['id'],
        c['title'] ?? '',
        (c['createdAt'] as num?)?.toInt() ?? 0,
        (c['updatedAt'] as num?)?.toInt() ?? 0,
        (c['isPinned'] == true || c['isPinned'] == 1) ? 1 : 0,
        c['assistantId'],
        (c['truncateIndex'] as num?)?.toInt() ?? -1,
        c['versionSelectionsJson'] ?? '{}',
        c['summary'],
        (c['lastSummarizedMessageCount'] as num?)?.toInt() ?? 0,
        c['chatSuggestionsJson'] ?? '[]',
      ],
    );
  }

  Future<void> _replaceMcpRows(
    String conversationId,
    List<Map<String, dynamic>> rows,
  ) async {
    await _db.customStatement(
      'DELETE FROM conversation_mcp_server_rows WHERE conversation_id = ?;',
      [conversationId],
    );
    for (final row in rows) {
      await _db.customStatement(
        'INSERT OR IGNORE INTO conversation_mcp_server_rows '
        '(conversation_id, server_id, ordinal) VALUES (?, ?, ?);',
        [conversationId, row['serverId'], (row['ordinal'] as num).toInt()],
      );
    }
  }

  Future<void> _insertMessage(
    String conversationId,
    Map<String, dynamic> message,
    int order,
    String Function(String) localize,
  ) async {
    final messageId = message['id'] as String;
    await _db.customStatement(
      'INSERT INTO message_rows '
      '(id, conversation_id, role, content, timestamp, model_id, '
      'provider_id, total_tokens, is_streaming, reasoning_text, '
      'reasoning_start_at, reasoning_finished_at, translation, '
      'reasoning_segments_json, group_id, version, prompt_tokens, '
      'completion_tokens, cached_tokens, duration_ms, message_order, '
      'updated_at) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, '
      '?, ?);',
      [
        messageId,
        conversationId,
        message['role'],
        localize(message['content'] as String? ?? ''),
        (message['timestamp'] as num?)?.toInt() ?? 0,
        message['modelId'],
        message['providerId'],
        (message['totalTokens'] as num?)?.toInt(),
        message['reasoningText'],
        (message['reasoningStartAt'] as num?)?.toInt(),
        (message['reasoningFinishedAt'] as num?)?.toInt(),
        message['translation'],
        message['reasoningSegmentsJson'],
        message['groupId'],
        (message['version'] as num?)?.toInt() ?? 0,
        (message['promptTokens'] as num?)?.toInt(),
        (message['completionTokens'] as num?)?.toInt(),
        (message['cachedTokens'] as num?)?.toInt(),
        (message['durationMs'] as num?)?.toInt(),
        order,
        (message['updatedAt'] as num?)?.toInt() ?? 0,
      ],
    );
    for (final part
        in (message['parts'] as List? ?? const [])
            .cast<Map<String, dynamic>>()) {
      await _db.customStatement(
        'INSERT INTO message_part_rows '
        '(conversation_id, revision_id, ordinal, kind, payload, created_at, '
        'updated_at) VALUES (?, ?, ?, ?, ?, ?, ?);',
        [
          conversationId,
          messageId,
          (part['ordinal'] as num).toInt(),
          part['kind'],
          localize(part['payload'] as String? ?? ''),
          (part['createdAt'] as num?)?.toInt() ?? 0,
          (part['updatedAt'] as num?)?.toInt() ?? 0,
        ],
      );
    }
    for (final artifact
        in (message['artifacts'] as List? ?? const [])
            .cast<Map<String, dynamic>>()) {
      await _db.customStatement(
        'INSERT OR REPLACE INTO provider_artifact_rows '
        '(conversation_id, revision_id, kind, payload, created_at, '
        'updated_at) VALUES (?, ?, ?, ?, ?, ?);',
        [
          conversationId,
          messageId,
          artifact['kind'],
          artifact['payload'],
          (artifact['createdAt'] as num?)?.toInt() ?? 0,
          (artifact['updatedAt'] as num?)?.toInt() ?? 0,
        ],
      );
    }
  }

  Future<void> _insertEntityRow(
    BusinessEntityKind kind,
    Map<String, dynamic> remote,
    Map<String, String> hashToPath,
  ) async {
    final payload = SyncObjectCodec.localizeJsonString(
      remote['payload'] as String? ?? '{}',
      hashToPath,
    );
    final updatedAt = (remote['updatedAt'] as num?)?.toInt() ?? 0;
    final sortOrder = (remote['sortOrder'] as num?)?.toInt() ?? 0;
    if (kind == BusinessEntityKind.assistantMemory) {
      await _db.customStatement(
        'INSERT OR REPLACE INTO assistant_memory_rows '
        '(id, sort_order, assistant_id, payload, updated_at) '
        'VALUES (?, ?, ?, ?, ?);',
        [
          remote['id'],
          sortOrder,
          remote['assistantId'] ?? '',
          payload,
          updatedAt,
        ],
      );
      return;
    }
    await _db.customStatement(
      'INSERT OR REPLACE INTO ${kind.tableName} '
      '(${kind.idColumn}, sort_order, payload, updated_at) '
      'VALUES (?, ?, ?, ?);',
      [remote['id'], sortOrder, payload, updatedAt],
    );
  }

  Future<void> _queueAssetBackfill(String conversationId) async {
    await _db.customStatement(
      'INSERT OR IGNORE INTO asset_reference_dirty_rows(revision_id) '
      'SELECT id FROM message_rows WHERE conversation_id = ? '
      "AND (content LIKE '%[image:%' OR content LIKE '%[file:%');",
      [conversationId],
    );
  }
}
