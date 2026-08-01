import 'dart:convert';

/// One synced object's fingerprint in the remote manifest.
final class SyncObjectEntry {
  const SyncObjectEntry({
    required this.sha256,
    required this.updatedAt,
    required this.size,
  });

  /// Hex SHA-256 of the object's JSON bytes.
  final String sha256;

  /// Largest row-level HLC timestamp contained in the object (micros).
  final int updatedAt;

  final int size;

  Map<String, Object> toJson() => {
    'sha256': sha256,
    'updatedAt': updatedAt,
    'size': size,
  };

  static SyncObjectEntry fromJson(Map<String, dynamic> json) => SyncObjectEntry(
    sha256: json['sha256'] as String,
    updatedAt: (json['updatedAt'] as num).toInt(),
    size: (json['size'] as num).toInt(),
  );

  @override
  bool operator ==(Object other) =>
      other is SyncObjectEntry &&
      other.sha256 == sha256 &&
      other.updatedAt == updatedAt &&
      other.size == size;

  @override
  int get hashCode => Object.hash(sha256, updatedAt, size);
}

/// The remote sync index. One small JSON object at `manifest.json` under the
/// sync root; every successful push replaces it with `revision + 1` under a
/// conditional write, making it the linearization point for concurrent
/// writers.
final class SyncManifest {
  SyncManifest({
    required this.schemaVersion,
    required this.revision,
    required this.lastWriter,
    required this.writtenAt,
    required Map<String, SyncObjectEntry> objects,
    required Map<String, int> assets,
  }) : objects = Map.unmodifiable(objects),
       assets = Map.unmodifiable(assets);

  static const formatVersion = 1;
  static const path = 'manifest.json';
  static const tombstonesPath = 'tombstones.json';
  static const settingsPath = 'settings.json';

  /// Writer's database schema version. A reader on an older schema must stop
  /// syncing and ask the user to update the app.
  final int schemaVersion;

  /// Monotonically increasing write counter.
  final int revision;

  /// Installation id of the device that produced this revision.
  final String lastWriter;

  /// HLC micros at write time.
  final int writtenAt;

  /// Object path (e.g. `conversations/<id>.json`) → fingerprint. Includes
  /// `settings.json`, `entities/<kind>.json` and `tombstones.json`.
  final Map<String, SyncObjectEntry> objects;

  /// Asset content hash → byte size.
  final Map<String, int> assets;

  static SyncManifest empty(int schemaVersion) => SyncManifest(
    schemaVersion: schemaVersion,
    revision: 0,
    lastWriter: '',
    writtenAt: 0,
    objects: const {},
    assets: const {},
  );

  SyncManifest next({
    required String writer,
    required int writtenAt,
    required int schemaVersion,
    required Map<String, SyncObjectEntry> objects,
    required Map<String, int> assets,
  }) => SyncManifest(
    schemaVersion: schemaVersion,
    revision: revision + 1,
    lastWriter: writer,
    writtenAt: writtenAt,
    objects: objects,
    assets: assets,
  );

  List<int> encode() {
    final sortedObjects = Map.fromEntries(
      objects.entries.toList()..sort((a, b) => a.key.compareTo(b.key)),
    );
    final sortedAssets = Map.fromEntries(
      assets.entries.toList()..sort((a, b) => a.key.compareTo(b.key)),
    );
    return utf8.encode(
      jsonEncode({
        'formatVersion': formatVersion,
        'schemaVersion': schemaVersion,
        'revision': revision,
        'lastWriter': lastWriter,
        'writtenAt': writtenAt,
        'objects': {
          for (final entry in sortedObjects.entries)
            entry.key: entry.value.toJson(),
        },
        'assets': sortedAssets,
      }),
    );
  }

  static SyncManifest decode(List<int> bytes) {
    final decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('sync_manifest');
    }
    final format = decoded['formatVersion'];
    if (format is! int || format > formatVersion) {
      throw const FormatException('sync_manifest_format');
    }
    final rawObjects = decoded['objects'];
    final rawAssets = decoded['assets'];
    if (rawObjects is! Map<String, dynamic> ||
        rawAssets is! Map<String, dynamic>) {
      throw const FormatException('sync_manifest');
    }
    return SyncManifest(
      schemaVersion: (decoded['schemaVersion'] as num).toInt(),
      revision: (decoded['revision'] as num).toInt(),
      lastWriter: decoded['lastWriter'] as String? ?? '',
      writtenAt: (decoded['writtenAt'] as num?)?.toInt() ?? 0,
      objects: {
        for (final entry in rawObjects.entries)
          entry.key: SyncObjectEntry.fromJson(
            entry.value as Map<String, dynamic>,
          ),
      },
      assets: {
        for (final entry in rawAssets.entries)
          entry.key: (entry.value as num).toInt(),
      },
    );
  }

  /// Paths whose fingerprint differs from [previous] (added or changed).
  List<String> changedSince(SyncManifest? previous) => [
    for (final entry in objects.entries)
      if (previous == null || previous.objects[entry.key] != entry.value)
        entry.key,
  ];

  /// Paths present in [previous] but no longer in this manifest.
  List<String> removedSince(SyncManifest? previous) => [
    if (previous != null)
      for (final path in previous.objects.keys)
        if (!objects.containsKey(path)) path,
  ];
}
