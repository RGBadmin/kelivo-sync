import 'package:drift/drift.dart';

import '../../database/app_database.dart';
import '../../database/business_data.dart';
import '../../database/business_settings_router.dart';
import 'sync_object_codec.dart';
import 'sync_state_store.dart';

/// Result of applying one round of remote tombstones.
final class SyncTombstoneApplyResult {
  SyncTombstoneApplyResult({
    required this.deletedConversationIds,
    required this.changedConversationIds,
    required this.businessChanged,
  });

  final Set<String> deletedConversationIds;
  final Set<String> changedConversationIds;
  final bool businessChanged;
}

/// Row-level LWW merge of remote sync objects into the local database.
///
/// The merger writes raw SQL directly (bypassing the repositories), so
/// nothing it does is echo-marked dirty. When LOCAL data wins a comparison
/// the affected object is explicitly marked dirty so the next push uploads
/// the surviving local state.
final class SyncMerger {
  SyncMerger(this._db);

  final AppDatabase _db;

  // Temporary offsets used for the two-phase message_order rewrite; far above
  // any realistic conversation length.
  static const _orderShift = 1000000;
  static const _orderInsertBase = 2000000;

  /// Merges a remote conversation object. [hashToPath] localizes portable
  /// asset tokens. Tombstone maps are keyed by tombstone entity id.
  /// Returns true when local data survived somewhere (a push is needed).
  Future<bool> mergeConversationObject(
    Map<String, dynamic> object, {
    required Map<String, String> hashToPath,
    required Map<String, int> conversationTombstones,
    required Map<String, int> messageTombstones,
  }) async {
    final conversation = object['conversation'] as Map<String, dynamic>;
    final conversationId = conversation['id'] as String;
    final remoteMessages = (object['messages'] as List)
        .cast<Map<String, dynamic>>();
    final remoteMcp = (object['mcpServers'] as List? ?? const [])
        .cast<Map<String, dynamic>>();

    return _db.transaction(() async {
      final localConvRows = await _db
          .customSelect(
            'SELECT * FROM conversation_rows WHERE id = ?;',
            variables: [Variable.withString(conversationId)],
          )
          .get();

      String localize(String value) =>
          SyncObjectCodec.localizeContent(value, hashToPath);

      if (localConvRows.isEmpty) {
        final tombstoneAt = conversationTombstones[conversationId];
        var remoteMaxUpdatedAt =
            (conversation['updatedAt'] as num?)?.toInt() ?? 0;
        for (final message in remoteMessages) {
          final updatedAt = (message['updatedAt'] as num?)?.toInt() ?? 0;
          if (updatedAt > remoteMaxUpdatedAt) remoteMaxUpdatedAt = updatedAt;
        }
        if (tombstoneAt != null && tombstoneAt >= remoteMaxUpdatedAt) {
          // Deleted locally after the remote last touched it; stays deleted.
          return false;
        }
        await _insertConversationRow(conversation);
        await _replaceMcpRows(conversationId, remoteMcp);
        final sorted = _sortedByCanonicalOrder(remoteMessages);
        var order = 0;
        for (final message in sorted) {
          final tombstoneKey =
              '$conversationId/${message['id'] as String}';
          final tombstoneTime = messageTombstones[tombstoneKey];
          final messageUpdatedAt = (message['updatedAt'] as num?)?.toInt() ?? 0;
          if (tombstoneTime != null && tombstoneTime >= messageUpdatedAt) {
            continue;
          }
          await _insertMessage(conversationId, message, order, localize);
          order += 1;
        }
        await _queueAssetBackfill(conversationId);
        return false;
      }

      // ===== Existing conversation: row-level LWW =====
      final localConv = localConvRows.single.data;
      final localMessages = await _db
          .customSelect(
            'SELECT id, updated_at, group_id, version, timestamp '
            'FROM message_rows WHERE conversation_id = ?;',
            variables: [Variable.withString(conversationId)],
          )
          .get();
      final localById = {
        for (final row in localMessages) row.data['id'] as String: row.data,
      };
      final remoteIds = <String>{};
      final inserts = <Map<String, dynamic>>[];
      final replaces = <Map<String, dynamic>>[];
      var localWins = false;

      for (final message in remoteMessages) {
        final messageId = message['id'] as String;
        remoteIds.add(messageId);
        final remoteUpdatedAt = (message['updatedAt'] as num?)?.toInt() ?? 0;
        final local = localById[messageId];
        if (local == null) {
          final tombstoneTime =
              messageTombstones['$conversationId/$messageId'];
          if (tombstoneTime != null && tombstoneTime >= remoteUpdatedAt) {
            continue;
          }
          inserts.add(message);
        } else {
          final localUpdatedAt = (local['updated_at'] as num?)?.toInt() ?? 0;
          if (remoteUpdatedAt > localUpdatedAt) {
            replaces.add(message);
          } else if (remoteUpdatedAt < localUpdatedAt) {
            localWins = true;
          }
          // Equal timestamps: assume identical, touch nothing.
        }
      }
      for (final id in localById.keys) {
        if (!remoteIds.contains(id)) localWins = true;
      }

      final remoteConvUpdatedAt =
          (conversation['updatedAt'] as num?)?.toInt() ?? 0;
      final localConvUpdatedAt =
          (localConv['updated_at'] as num?)?.toInt() ?? 0;
      final replaceConvRow = remoteConvUpdatedAt > localConvUpdatedAt;
      if (remoteConvUpdatedAt < localConvUpdatedAt) localWins = true;

      if (inserts.isEmpty && replaces.isEmpty && !replaceConvRow) {
        if (localWins) await _markConversationDirty(conversationId);
        return localWins;
      }

      if (replaceConvRow) {
        await _updateConversationRow(conversation);
        await _replaceMcpRows(conversationId, remoteMcp);
      }

      // Two-phase order rewrite: shift local rows out of the way, apply row
      // changes at temporary orders, then renumber canonically.
      await _db.customStatement(
        'UPDATE message_rows SET message_order = message_order + $_orderShift '
        'WHERE conversation_id = ?;',
        [conversationId],
      );
      var temporaryOrder = _orderInsertBase;
      for (final message in replaces) {
        await _replaceMessage(
          conversationId,
          message,
          temporaryOrder++,
          localize,
        );
      }
      for (final message in inserts) {
        final resolvedVersion = await _resolveVersionCollision(
          conversationId,
          message,
        );
        await _insertMessage(
          conversationId,
          message,
          temporaryOrder++,
          localize,
          versionOverride: resolvedVersion,
        );
      }
      await _renumberCanonically(conversationId);
      await _queueAssetBackfill(conversationId);
      if (localWins) await _markConversationDirty(conversationId);
      return localWins;
    });
  }

  /// Merges one entities object. Returns true when local data won anywhere.
  Future<bool> mergeEntities(
    BusinessEntityKind kind,
    Map<String, dynamic> object, {
    required Map<String, String> hashToPath,
    required Map<String, int> entityTombstones,
  }) async {
    final remoteRows = (object['rows'] as List).cast<Map<String, dynamic>>();
    return _db.transaction(() async {
      final localRows = await _db
          .customSelect(
            'SELECT ${kind.idColumn} AS entity_id, payload, updated_at '
            'FROM ${kind.tableName};',
          )
          .get();
      final localById = {
        for (final row in localRows) row.data['entity_id'] as String: row.data,
      };
      final remoteIds = <String>{};
      var localWins = false;
      var changed = false;

      for (final remote in remoteRows) {
        final id = remote['id'] as String;
        remoteIds.add(id);
        final remoteUpdatedAt = (remote['updatedAt'] as num?)?.toInt() ?? 0;
        final tombstoneTime = entityTombstones[id];
        final local = localById[id];
        if (local == null) {
          if (tombstoneTime != null && tombstoneTime >= remoteUpdatedAt) {
            continue;
          }
          await _upsertEntityRow(kind, remote, hashToPath);
          changed = true;
        } else {
          final localUpdatedAt = (local['updated_at'] as num?)?.toInt() ?? 0;
          if (remoteUpdatedAt > localUpdatedAt) {
            await _upsertEntityRow(kind, remote, hashToPath);
            changed = true;
          } else if (remoteUpdatedAt < localUpdatedAt) {
            localWins = true;
          }
        }
      }
      for (final id in localById.keys) {
        if (!remoteIds.contains(id)) localWins = true;
      }
      if (localWins || changed) {
        await SyncStateStore.markDirtyInTransaction(
          _db,
          SyncScope.entities,
          kind.name,
          quiet: !localWins,
        );
      }
      return localWins;
    });
  }

  /// Merges the settings object. Returns true when local data won anywhere.
  Future<bool> mergeSettings(
    Map<String, dynamic> object, {
    required Map<String, String> hashToPath,
    required Map<String, int> preferenceTombstones,
  }) async {
    final remotePrefs = (object['prefs'] as Map<String, dynamic>);
    return _db.transaction(() async {
      final localRows = await _db
          .customSelect('SELECT key, value, updated_at FROM preference_rows;')
          .get();
      final localByKey = {
        for (final row in localRows) row.data['key'] as String: row.data,
      };
      var localWins = false;
      var changed = false;

      for (final entry in remotePrefs.entries) {
        final key = entry.key;
        if (BusinessKeyRegistry.localOnlyKeys.contains(key) ||
            BusinessKeyRegistry.discardedKeys.contains(key) ||
            key.startsWith('restore_')) {
          continue;
        }
        final remote = entry.value as Map<String, dynamic>;
        final remoteUpdatedAt = (remote['updatedAt'] as num?)?.toInt() ?? 0;
        final remoteValue = SyncObjectCodec.localizeJsonString(
          remote['value'] as String? ?? 'null',
          hashToPath,
        );
        final tombstoneTime = preferenceTombstones[key];
        final local = localByKey[key];
        if (local == null) {
          if (tombstoneTime != null && tombstoneTime >= remoteUpdatedAt) {
            continue;
          }
          await _writePreference(key, remoteValue, remoteUpdatedAt);
          changed = true;
        } else {
          final localUpdatedAt = (local['updated_at'] as num?)?.toInt() ?? 0;
          if (remoteUpdatedAt > localUpdatedAt) {
            await _writePreference(key, remoteValue, remoteUpdatedAt);
            changed = true;
          } else if (remoteUpdatedAt < localUpdatedAt) {
            localWins = true;
          }
        }
      }
      for (final key in localByKey.keys) {
        if (!remotePrefs.containsKey(key)) localWins = true;
      }
      if (localWins || changed) {
        await SyncStateStore.markDirtyInTransaction(
          _db,
          SyncScope.settings,
          '',
          quiet: !localWins,
        );
      }
      return localWins;
    });
  }

  /// Applies remote tombstones: a row dies only when the tombstone is newer
  /// than the row's own updated_at (edits win over deletions).
  Future<SyncTombstoneApplyResult> applyTombstones(
    List<SyncTombstone> tombstones,
  ) async {
    final deletedConversations = <String>{};
    final changedConversations = <String>{};
    var businessChanged = false;
    await _db.transaction(() async {
      for (final tombstone in tombstones) {
        if (tombstone.kind == SyncTombstoneKind.conversation) {
          // A conversation survives its tombstone when the row itself OR any
          // of its messages was edited after the deletion (edits win).
          final deleted = await _db.customUpdate(
            'DELETE FROM conversation_rows WHERE id = ? AND updated_at < ? '
            'AND NOT EXISTS (SELECT 1 FROM message_rows '
            'WHERE conversation_id = ? AND updated_at >= ?);',
            variables: [
              Variable.withString(tombstone.entityId),
              Variable.withInt(tombstone.deletedAt),
              Variable.withString(tombstone.entityId),
              Variable.withInt(tombstone.deletedAt),
            ],
            updateKind: UpdateKind.delete,
          );
          if (deleted > 0) {
            deletedConversations.add(tombstone.entityId);
            await _db.customStatement(
              "DELETE FROM sync_dirty_rows WHERE scope = 'conversation' "
              'AND entity_id = ?;',
              [tombstone.entityId],
            );
          }
        } else if (tombstone.kind == SyncTombstoneKind.message) {
          final separator = tombstone.entityId.indexOf('/');
          if (separator <= 0) continue;
          final conversationId = tombstone.entityId.substring(0, separator);
          final messageId = tombstone.entityId.substring(separator + 1);
          final deleted = await _db.customUpdate(
            'DELETE FROM message_rows WHERE id = ? AND conversation_id = ? '
            'AND updated_at < ?;',
            variables: [
              Variable.withString(messageId),
              Variable.withString(conversationId),
              Variable.withInt(tombstone.deletedAt),
            ],
            updateKind: UpdateKind.delete,
          );
          if (deleted > 0) {
            await _renumberCanonically(conversationId);
            changedConversations.add(conversationId);
            await _markConversationDirty(conversationId);
          }
        } else if (tombstone.kind == SyncTombstoneKind.preference) {
          final deleted = await _db.customUpdate(
            'DELETE FROM preference_rows WHERE key = ? AND updated_at < ?;',
            variables: [
              Variable.withString(tombstone.entityId),
              Variable.withInt(tombstone.deletedAt),
            ],
            updateKind: UpdateKind.delete,
          );
          if (deleted > 0) {
            businessChanged = true;
            await SyncStateStore.markDirtyInTransaction(
              _db,
              SyncScope.settings,
              '',
            );
          }
        } else if (tombstone.kind.startsWith(SyncTombstoneKind.entityPrefix)) {
          final kindName = tombstone.kind.substring(
            SyncTombstoneKind.entityPrefix.length,
          );
          BusinessEntityKind? kind;
          for (final value in BusinessEntityKind.values) {
            if (value.name == kindName) {
              kind = value;
              break;
            }
          }
          if (kind == null) continue;
          final deleted = await _db.customUpdate(
            'DELETE FROM ${kind.tableName} WHERE ${kind.idColumn} = ? '
            'AND updated_at < ?;',
            variables: [
              Variable.withString(tombstone.entityId),
              Variable.withInt(tombstone.deletedAt),
            ],
            updateKind: UpdateKind.delete,
          );
          if (deleted > 0) {
            businessChanged = true;
            await SyncStateStore.markDirtyInTransaction(
              _db,
              SyncScope.entities,
              kind.name,
            );
          }
        }
      }
    });
    return SyncTombstoneApplyResult(
      deletedConversationIds: deletedConversations,
      changedConversationIds: changedConversations,
      businessChanged: businessChanged,
    );
  }

  // ===== Helpers =====

  Future<void> _markConversationDirty(String conversationId) =>
      SyncStateStore.markDirtyInTransaction(
        _db,
        SyncScope.conversation,
        conversationId,
      );

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
      'INSERT OR REPLACE INTO conversation_rows '
      '(id, title, created_at, updated_at, is_pinned, assistant_id, '
      'truncate_index, version_selections_json, summary, '
      'last_summarized_message_count, chat_suggestions_json) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);',
      _conversationValues(c),
    );
  }

  Future<void> _updateConversationRow(Map<String, dynamic> c) async {
    final values = _conversationValues(c);
    await _db.customStatement(
      'UPDATE conversation_rows SET title = ?, created_at = ?, '
      'updated_at = ?, is_pinned = ?, assistant_id = ?, truncate_index = ?, '
      'version_selections_json = ?, summary = ?, '
      'last_summarized_message_count = ?, chat_suggestions_json = ? '
      'WHERE id = ?;',
      [...values.sublist(1), values.first],
    );
  }

  List<Object?> _conversationValues(Map<String, dynamic> c) => [
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
  ];

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

  /// When an inserted remote revision collides with a different local
  /// revision on (conversation, group, version), give it the next free
  /// version instead of failing the unique constraint.
  Future<int?> _resolveVersionCollision(
    String conversationId,
    Map<String, dynamic> message,
  ) async {
    final groupId = message['groupId'] as String?;
    final version = (message['version'] as num?)?.toInt() ?? 0;
    final id = message['id'] as String;
    final collision = await _db
        .customSelect(
          'SELECT id FROM message_rows WHERE conversation_id = ? '
          'AND group_id IS ? AND version = ? AND id != ?;',
          variables: [
            Variable.withString(conversationId),
            Variable(groupId),
            Variable.withInt(version),
            Variable.withString(id),
          ],
        )
        .get();
    if (collision.isEmpty) return null;
    final maxRow = await _db
        .customSelect(
          'SELECT MAX(version) AS v FROM message_rows '
          'WHERE conversation_id = ? AND '
          '(group_id IS ? OR (group_id IS NULL AND id IS ?));',
          variables: [
            Variable.withString(conversationId),
            Variable(groupId),
            Variable(groupId),
          ],
        )
        .getSingle();
    return ((maxRow.data['v'] as num?)?.toInt() ?? version) + 1;
  }

  Future<void> _insertMessage(
    String conversationId,
    Map<String, dynamic> message,
    int order,
    String Function(String) localize, {
    int? versionOverride,
  }) async {
    await _writeMessageRow(
      conversationId,
      message,
      order,
      localize,
      orReplace: false,
      versionOverride: versionOverride,
    );
  }

  Future<void> _replaceMessage(
    String conversationId,
    Map<String, dynamic> message,
    int order,
    String Function(String) localize,
  ) async {
    await _writeMessageRow(
      conversationId,
      message,
      order,
      localize,
      orReplace: true,
    );
  }

  Future<void> _writeMessageRow(
    String conversationId,
    Map<String, dynamic> message,
    int order,
    String Function(String) localize, {
    required bool orReplace,
    int? versionOverride,
  }) async {
    final messageId = message['id'] as String;
    await _db.customStatement(
      'INSERT ${orReplace ? 'OR REPLACE ' : ''}INTO message_rows '
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
        versionOverride ?? (message['version'] as num?)?.toInt() ?? 0,
        (message['promptTokens'] as num?)?.toInt(),
        (message['completionTokens'] as num?)?.toInt(),
        (message['cachedTokens'] as num?)?.toInt(),
        (message['durationMs'] as num?)?.toInt(),
        order,
        (message['updatedAt'] as num?)?.toInt() ?? 0,
      ],
    );
    // OR REPLACE cascades the old parts/artifacts away; a plain insert has
    // none. Either way, write the remote ones fresh.
    if (!orReplace) {
      await _db.customStatement(
        'DELETE FROM message_part_rows WHERE revision_id = ?;',
        [messageId],
      );
      await _db.customStatement(
        'DELETE FROM provider_artifact_rows WHERE revision_id = ?;',
        [messageId],
      );
    }
    for (final part
        in (message['parts'] as List? ?? const []).cast<Map<String, dynamic>>()) {
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

  Future<void> _renumberCanonically(String conversationId) async {
    final rows = await _db
        .customSelect(
          'SELECT id FROM message_rows WHERE conversation_id = ? '
          'ORDER BY timestamp, id;',
          variables: [Variable.withString(conversationId)],
        )
        .get();
    await _db.customStatement(
      'UPDATE message_rows SET message_order = message_order + $_orderShift '
      'WHERE conversation_id = ? AND message_order < $_orderShift;',
      [conversationId],
    );
    for (final (index, row) in rows.indexed) {
      await _db.customStatement(
        'UPDATE message_rows SET message_order = ? WHERE id = ?;',
        [index, row.data['id']],
      );
    }
  }

  Future<void> _queueAssetBackfill(String conversationId) async {
    await _db.customStatement(
      'INSERT OR IGNORE INTO asset_reference_dirty_rows(revision_id) '
      'SELECT id FROM message_rows WHERE conversation_id = ? '
      "AND (content LIKE '%[image:%' OR content LIKE '%[file:%');",
      [conversationId],
    );
  }

  Future<void> _upsertEntityRow(
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

  Future<void> _writePreference(String key, String value, int updatedAt) async {
    await _db.customStatement(
      'INSERT INTO preference_rows (key, value, updated_at) '
      'VALUES (?, ?, ?) '
      'ON CONFLICT(key) DO UPDATE SET value = excluded.value, '
      'updated_at = excluded.updated_at;',
      [key, value, updatedAt],
    );
  }
}
