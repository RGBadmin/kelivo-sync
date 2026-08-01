import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';

import '../../../utils/sandbox_path_resolver.dart';
import '../../database/app_database.dart';
import '../../database/business_data.dart';
import '../../database/business_settings_router.dart';

/// A local file referenced by exported content, keyed by content hash.
typedef SyncAssetRef = ({String hash, String name, String subdir, File file});

/// Result of exporting one sync object: stable JSON bytes plus every local
/// asset the object references.
final class SyncExportedObject {
  SyncExportedObject({
    required this.bytes,
    required this.maxUpdatedAt,
    required this.assetRefs,
  });

  final Uint8List bytes;
  final int maxUpdatedAt;
  final List<SyncAssetRef> assetRefs;

  String get sha256Hex => sha256.convert(bytes).toString();
}

/// Serializes local rows into portable remote JSON objects and back.
///
/// Portability: absolute local file paths never travel. Content markers
/// (`[image:<path>]`, `[file:<path>|name|mime]`) and path-valued JSON strings
/// in payloads become `kelivo-asset://<hash>/<subdir>/<name>` tokens on
/// export; on import the engine downloads the assets and the codec rewrites
/// tokens back into this device's absolute paths.
final class SyncObjectCodec {
  SyncObjectCodec({
    required AppDatabase database,
    required Directory appDataDirectory,
  }) : _db = database,
       // ignore: prefer_initializing_formals
       _appDataDirectory = appDataDirectory;

  static const objectFormatVersion = 1;
  static const assetScheme = 'kelivo-asset://';

  final AppDatabase _db;
  final Directory _appDataDirectory;

  static const _knownSubdirs = {'upload', 'images', 'avatars', 'fonts'};

  // ===== Conversation export =====

  Future<SyncExportedObject?> exportConversation(String conversationId) async {
    final conversationRows = await _db
        .customSelect(
          'SELECT * FROM conversation_rows WHERE id = ?;',
          variables: [Variable.withString(conversationId)],
        )
        .get();
    if (conversationRows.isEmpty) return null;
    final conversation = conversationRows.single.data;

    final mcpRows = await _db
        .customSelect(
          'SELECT server_id, ordinal FROM conversation_mcp_server_rows '
          'WHERE conversation_id = ? ORDER BY ordinal;',
          variables: [Variable.withString(conversationId)],
        )
        .get();
    // Canonical order (timestamp, id) rather than local message_order: both
    // devices export a merged conversation as byte-identical JSON, so the
    // manifest sha comparison converges instead of ping-ponging.
    final messageRows = await _db
        .customSelect(
          'SELECT * FROM message_rows WHERE conversation_id = ? '
          'ORDER BY timestamp, id;',
          variables: [Variable.withString(conversationId)],
        )
        .get();
    final partRows = await _db
        .customSelect(
          'SELECT * FROM message_part_rows WHERE conversation_id = ? '
          'ORDER BY revision_id, ordinal;',
          variables: [Variable.withString(conversationId)],
        )
        .get();
    final artifactRows = await _db
        .customSelect(
          'SELECT * FROM provider_artifact_rows WHERE conversation_id = ? '
          'ORDER BY revision_id, kind;',
          variables: [Variable.withString(conversationId)],
        )
        .get();

    final partsByRevision = <String, List<Map<String, Object?>>>{};
    for (final row in partRows) {
      partsByRevision
          .putIfAbsent(row.data['revision_id'] as String, () => [])
          .add({
            'ordinal': row.data['ordinal'],
            'kind': row.data['kind'],
            'payload': row.data['payload'],
            'createdAt': row.data['created_at'],
            'updatedAt': row.data['updated_at'],
          });
    }
    final artifactsByRevision = <String, List<Map<String, Object?>>>{};
    for (final row in artifactRows) {
      artifactsByRevision
          .putIfAbsent(row.data['revision_id'] as String, () => [])
          .add({
            'kind': row.data['kind'],
            'payload': row.data['payload'],
            'createdAt': row.data['created_at'],
            'updatedAt': row.data['updated_at'],
          });
    }

    final assetRefs = <String, SyncAssetRef>{};
    var maxUpdatedAt = (conversation['updated_at'] as num?)?.toInt() ?? 0;

    final messages = <Map<String, Object?>>[];
    for (final (index, row) in messageRows.indexed) {
      final data = row.data;
      final messageId = data['id'] as String;
      final updatedAt = (data['updated_at'] as num?)?.toInt() ?? 0;
      if (updatedAt > maxUpdatedAt) maxUpdatedAt = updatedAt;
      final portableContent = _portableContent(
        data['content'] as String? ?? '',
        assetRefs,
      );
      messages.add({
        'id': messageId,
        'role': data['role'],
        'content': portableContent,
        'timestamp': data['timestamp'],
        'modelId': data['model_id'],
        'providerId': data['provider_id'],
        'totalTokens': data['total_tokens'],
        // Normalized: a synced message is never mid-stream on another device.
        'isStreaming': false,
        'reasoningText': data['reasoning_text'],
        'reasoningStartAt': data['reasoning_start_at'],
        'reasoningFinishedAt': data['reasoning_finished_at'],
        'translation': data['translation'],
        'reasoningSegmentsJson': data['reasoning_segments_json'],
        'groupId': data['group_id'],
        'version': data['version'],
        'promptTokens': data['prompt_tokens'],
        'completionTokens': data['completion_tokens'],
        'cachedTokens': data['cached_tokens'],
        'durationMs': data['duration_ms'],
        'messageOrder': index,
        'updatedAt': updatedAt,
        'parts': [
          for (final part in partsByRevision[messageId] ?? const [])
            {
              ...part,
              'payload': _portableContent(
                part['payload'] as String? ?? '',
                assetRefs,
              ),
            },
        ],
        'artifacts': artifactsByRevision[messageId] ?? const [],
      });
    }

    final object = {
      'formatVersion': objectFormatVersion,
      'conversation': {
        'id': conversation['id'],
        'title': conversation['title'],
        'createdAt': conversation['created_at'],
        'updatedAt': conversation['updated_at'],
        'isPinned': conversation['is_pinned'],
        'assistantId': conversation['assistant_id'],
        'truncateIndex': conversation['truncate_index'],
        'versionSelectionsJson': conversation['version_selections_json'],
        'summary': conversation['summary'],
        'lastSummarizedMessageCount':
            conversation['last_summarized_message_count'],
        'chatSuggestionsJson': conversation['chat_suggestions_json'],
      },
      'mcpServers': [
        for (final row in mcpRows)
          {'serverId': row.data['server_id'], 'ordinal': row.data['ordinal']},
      ],
      'messages': messages,
    };
    return SyncExportedObject(
      bytes: utf8.encode(jsonEncode(object)),
      maxUpdatedAt: maxUpdatedAt,
      assetRefs: assetRefs.values.toList(growable: false),
    );
  }

  // ===== Entities export =====

  Future<SyncExportedObject> exportEntities(BusinessEntityKind kind) async {
    final isMemory = kind == BusinessEntityKind.assistantMemory;
    final rows = await _db
        .customSelect(
          'SELECT ${kind.idColumn} AS entity_id, sort_order, payload, '
          'updated_at${isMemory ? ', assistant_id' : ''} '
          'FROM ${kind.tableName} ORDER BY ${kind.idColumn};',
        )
        .get();
    final assetRefs = <String, SyncAssetRef>{};
    var maxUpdatedAt = 0;
    final encoded = <Map<String, Object?>>[];
    for (final row in rows) {
      final updatedAt = (row.data['updated_at'] as num?)?.toInt() ?? 0;
      if (updatedAt > maxUpdatedAt) maxUpdatedAt = updatedAt;
      encoded.add({
        'id': row.data['entity_id'],
        'sortOrder': row.data['sort_order'],
        'payload': _portableJsonString(
          row.data['payload'] as String? ?? '{}',
          assetRefs,
        ),
        if (isMemory) 'assistantId': row.data['assistant_id'],
        'updatedAt': updatedAt,
      });
    }
    return SyncExportedObject(
      bytes: utf8.encode(
        jsonEncode({
          'formatVersion': objectFormatVersion,
          'kind': kind.name,
          'rows': encoded,
        }),
      ),
      maxUpdatedAt: maxUpdatedAt,
      assetRefs: assetRefs.values.toList(growable: false),
    );
  }

  // ===== Settings export =====

  Future<SyncExportedObject> exportSettings() async {
    final rows = await _db
        .customSelect(
          'SELECT key, value, updated_at FROM preference_rows ORDER BY key;',
        )
        .get();
    final assetRefs = <String, SyncAssetRef>{};
    var maxUpdatedAt = 0;
    final prefs = <String, Object?>{};
    for (final row in rows) {
      final key = row.data['key'] as String;
      if (BusinessKeyRegistry.localOnlyKeys.contains(key) ||
          BusinessKeyRegistry.discardedKeys.contains(key) ||
          key.startsWith('restore_')) {
        continue;
      }
      final updatedAt = (row.data['updated_at'] as num?)?.toInt() ?? 0;
      if (updatedAt > maxUpdatedAt) maxUpdatedAt = updatedAt;
      prefs[key] = {
        'value': _portableJsonString(
          row.data['value'] as String? ?? 'null',
          assetRefs,
        ),
        'updatedAt': updatedAt,
      };
    }
    return SyncExportedObject(
      bytes: utf8.encode(
        jsonEncode({'formatVersion': objectFormatVersion, 'prefs': prefs}),
      ),
      maxUpdatedAt: maxUpdatedAt,
      assetRefs: assetRefs.values.toList(growable: false),
    );
  }

  // ===== Parsing =====

  static Map<String, dynamic> parseObject(List<int> bytes) {
    final decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('sync_object');
    }
    final format = decoded['formatVersion'];
    if (format is! int || format > objectFormatVersion) {
      throw const FormatException('sync_object_format');
    }
    return decoded;
  }

  // ===== Content portability =====

  static final _imageMarker = RegExp(r'\[image:([^\]]+)\]');
  static final _fileMarker = RegExp(r'\[file:([^|\]]+)\|([^|\]]*)\|([^\]]*)\]');
  static final _assetToken = RegExp(
    r'kelivo-asset://([0-9a-f]{16,64})/([^/|\]]+)/([^|\]]+)',
  );

  /// Rewrites local absolute paths in message content to portable asset
  /// tokens, collecting the referenced files into [assetRefs].
  String _portableContent(String content, Map<String, SyncAssetRef> assetRefs) {
    var result = content.replaceAllMapped(_imageMarker, (match) {
      final target = match.group(1)!.trim();
      final token = _tokenForLocalPath(target, assetRefs);
      return token == null ? match.group(0)! : '[image:$token]';
    });
    result = result.replaceAllMapped(_fileMarker, (match) {
      final target = match.group(1)!.trim();
      final token = _tokenForLocalPath(target, assetRefs);
      return token == null
          ? match.group(0)!
          : '[file:$token|${match.group(2)}|${match.group(3)}]';
    });
    return result;
  }

  /// Rewrites portable asset tokens back to this device's absolute paths.
  /// Tokens whose hash is not in [hashToPath] are left untouched so a later
  /// repair pass can still resolve them.
  static String localizeContent(String content, Map<String, String> hashToPath) {
    return content.replaceAllMapped(_assetToken, (match) {
      final local = hashToPath[match.group(1)!];
      return local ?? match.group(0)!;
    });
  }

  /// Collects every asset hash referenced by portable tokens in [content].
  static Set<String> referencedHashes(String content) => {
    for (final match in _assetToken.allMatches(content)) match.group(1)!,
  };

  /// Walks a JSON string and converts path-valued strings into portable
  /// tokens (assistant avatars/backgrounds, imported fonts, ...).
  String _portableJsonString(
    String jsonString,
    Map<String, SyncAssetRef> assetRefs,
  ) {
    final Object? decoded;
    try {
      decoded = jsonDecode(jsonString);
    } on FormatException {
      return jsonString;
    }
    final rewritten = _portableJsonValue(decoded, assetRefs);
    return jsonEncode(rewritten);
  }

  Object? _portableJsonValue(
    Object? value,
    Map<String, SyncAssetRef> assetRefs,
  ) {
    if (value is Map) {
      return {
        for (final entry in value.entries)
          entry.key: _portableJsonValue(entry.value, assetRefs),
      };
    }
    if (value is List) {
      return [for (final item in value) _portableJsonValue(item, assetRefs)];
    }
    if (value is String) {
      // Message-marker style content can appear inside payloads too.
      if (value.contains('[image:') || value.contains('[file:')) {
        return _portableContent(value, assetRefs);
      }
      final token = _tokenForLocalPath(value, assetRefs);
      return token ?? value;
    }
    return value;
  }

  static String localizeJsonString(
    String jsonString,
    Map<String, String> hashToPath,
  ) {
    final Object? decoded;
    try {
      decoded = jsonDecode(jsonString);
    } on FormatException {
      return jsonString;
    }
    return jsonEncode(_localizeJsonValue(decoded, hashToPath));
  }

  static Object? _localizeJsonValue(
    Object? value,
    Map<String, String> hashToPath,
  ) {
    if (value is Map) {
      return {
        for (final entry in value.entries)
          entry.key: _localizeJsonValue(entry.value, hashToPath),
      };
    }
    if (value is List) {
      return [for (final item in value) _localizeJsonValue(item, hashToPath)];
    }
    if (value is String) return localizeContent(value, hashToPath);
    return value;
  }

  static Set<String> referencedHashesInJsonString(String jsonString) =>
      referencedHashes(jsonString);

  static bool _looksLikeAbsolutePath(String value) {
    if (value.length < 4 || value.length > 1024) return false;
    if (value.contains('\n')) return false;
    return value.startsWith('/') ||
        RegExp(r'^[A-Za-z]:[\\/]').hasMatch(value) ||
        value.startsWith('file://');
  }

  /// Returns a portable token for [rawPath] when it points at an existing
  /// local file, registering the file in [assetRefs]; null otherwise.
  String? _tokenForLocalPath(
    String rawPath,
    Map<String, SyncAssetRef> assetRefs,
  ) {
    if (rawPath.startsWith(assetScheme)) return null;
    if (rawPath.startsWith('http://') ||
        rawPath.startsWith('https://') ||
        rawPath.startsWith('data:')) {
      return null;
    }
    if (!_looksLikeAbsolutePath(rawPath)) return null;
    var fixed = rawPath;
    try {
      fixed = SandboxPathResolver.fix(rawPath);
    } catch (_) {}
    final file = File(fixed);
    if (!file.existsSync()) return null;
    final hash = _hashFileSync(file);
    final name = _basename(fixed);
    final subdir = _subdirFor(fixed);
    assetRefs.putIfAbsent(
      hash,
      () => (hash: hash, name: name, subdir: subdir, file: file),
    );
    return '$assetScheme$hash/$subdir/${Uri.encodeComponent(name)}';
  }

  String _subdirFor(String path) {
    final normalized = path.replaceAll('\\', '/');
    final segments = normalized.split('/');
    if (segments.length >= 2) {
      final parent = segments[segments.length - 2];
      if (_knownSubdirs.contains(parent)) return parent;
    }
    return 'upload';
  }

  static String _basename(String path) {
    final normalized = path.replaceAll('\\', '/');
    final index = normalized.lastIndexOf('/');
    return index < 0 ? normalized : normalized.substring(index + 1);
  }

  final Map<String, ({int size, int mtime, String hash})> _hashCache = {};

  String _hashFileSync(File file) {
    final stat = file.statSync();
    final cached = _hashCache[file.path];
    if (cached != null &&
        cached.size == stat.size &&
        cached.mtime == stat.modified.microsecondsSinceEpoch) {
      return cached.hash;
    }
    final digest = sha256.convert(file.readAsBytesSync()).toString();
    _hashCache[file.path] = (
      size: stat.size,
      mtime: stat.modified.microsecondsSinceEpoch,
      hash: digest,
    );
    return digest;
  }

  /// Decodes a portable token into its parts, or null.
  static ({String hash, String subdir, String name})? parseAssetToken(
    String token,
  ) {
    final match = _assetToken.firstMatch(token);
    if (match == null) return null;
    return (
      hash: match.group(1)!,
      subdir: match.group(2)!,
      name: Uri.decodeComponent(match.group(3)!),
    );
  }

  /// Every portable asset token appearing anywhere in [content] (typically
  /// the raw JSON text of a fetched sync object).
  static List<({String hash, String subdir, String name})> collectAssetTokens(
    String content,
  ) => [
    for (final match in _assetToken.allMatches(content))
      (
        hash: match.group(1)!,
        subdir: match.group(2)!,
        name: Uri.decodeComponent(match.group(3)!),
      ),
  ];

  Directory get appDataDirectory => _appDataDirectory;
}
