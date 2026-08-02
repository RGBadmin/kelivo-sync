// ignore_for_file: prefer_initializing_formals

import 'dart:convert';

import 'package:drift/drift.dart';

import '../../database/app_database.dart';
import '../../database/business_data.dart';
import 'sync_asset_transfer.dart';
import 'sync_clock.dart';
import 'sync_manifest.dart';
import 'sync_merger.dart';
import 'sync_object_codec.dart';
import 'sync_remote_store.dart';
import 'sync_state_store.dart';

/// The remote was written by an app with a newer database schema; syncing
/// must stop until this device updates.
final class SyncSchemaTooNewException implements Exception {
  const SyncSchemaTooNewException(this.remoteSchemaVersion);

  final int remoteSchemaVersion;
}

/// Conditional manifest writes kept failing; another device is pushing
/// continuously. The caller backs off and retries later.
final class SyncConflictRetriesExhaustedException implements Exception {
  const SyncConflictRetriesExhaustedException();
}

final class SyncPullReport {
  const SyncPullReport({
    this.remoteChanged = false,
    this.uploadedObjects = 0,
    this.changedConversationIds = const {},
    this.deletedConversationIds = const {},
    this.businessChanged = false,
    this.deferredActiveConversations = false,
  });

  final bool remoteChanged;
  final int uploadedObjects;
  final Set<String> changedConversationIds;
  final Set<String> deletedConversationIds;
  final bool businessChanged;

  /// True when a changed conversation was skipped because it has an active
  /// generation run; the next round retries it.
  final bool deferredActiveConversations;

  bool get uiRefreshNeeded =>
      changedConversationIds.isNotEmpty ||
      deletedConversationIds.isNotEmpty ||
      businessChanged;
}

/// Mirror-mode differential sync over a [SyncRemoteStore].
///
/// The remote always holds the single newest version of the data. Each
/// round compares who is newer:
/// - remote newer → the changed remote objects overwrite local state
///   (object-level diff by sha; local extras are deleted);
/// - local newer → the changed local objects overwrite the remote
///   (sha-diff uploads; remote extras are removed from the manifest).
/// There is no row merging: the losing side's concurrent edits are
/// discarded by design. The manifest is replaced with a conditional write,
/// so concurrent pushers serialize; the loser re-decides and retries.
final class SyncEngine {
  SyncEngine({
    required AppDatabase database,
    required SyncStateStore stateStore,
    required SyncObjectCodec codec,
    required SyncMerger merger,
    required SyncAssetTransfer assetTransfer,
    required String deviceId,
  }) : _db = database,
       _stateStore = stateStore,
       _codec = codec,
       _merger = merger,
       _assets = assetTransfer,
       _deviceId = deviceId;

  static const _maxConflictRetries = 5;

  final AppDatabase _db;
  final SyncStateStore _stateStore;
  final SyncObjectCodec _codec;
  final SyncMerger _merger;
  final SyncAssetTransfer _assets;
  final String _deviceId;

  /// Live activity feed for the status UI ("uploading X", "attempt 2/5").
  void Function(String message)? onActivity;

  void _act(String message) {
    try {
      onActivity?.call(message);
    } catch (_) {}
  }

  /// First-run / restored-database detection: when the database was not
  /// previously synced by THIS installation, remote application state is
  /// discarded, everything local is queued (quietly) for a sha reconcile,
  /// and the next sync treats the cloud as authoritative when it has data.
  Future<void> ensureConsistentIdentity() async {
    final stored = await _stateStore.readMeta(SyncStateStore.metaDeviceId);
    if (stored == _deviceId) return;
    await _stateStore.removeMeta(SyncStateStore.metaLastManifestJson);
    await _stateStore.removeMeta(SyncStateStore.metaLastManifestEtag);
    await _stateStore.removeMeta(SyncStateStore.metaLastRemoteRevision);
    await _stateStore.removeMeta(SyncStateStore.metaInitialSyncDone);
    await _markEverythingDirty();
    await _stateStore.writeMeta(SyncStateStore.metaDeviceId, _deviceId);
  }

  /// True when the dirty queue or tombstones await a push.
  Future<bool> hasPendingLocalChanges() async {
    final dirty = await _stateStore.snapshotDirty();
    if (dirty.isNotEmpty) return true;
    return (await _stateStore.allTombstones()).isNotEmpty;
  }

  /// One complete sync round: fetch the manifest, decide the winner, then
  /// mirror in whichever direction is needed.
  Future<SyncPullReport> syncOnce(SyncRemoteStore store) async {
    for (var attempt = 0; attempt < _maxConflictRetries; attempt++) {
      final dirty = await _stateStore.snapshotDirty();
      final tombstones = await _stateStore.allTombstones();
      final hasPending = dirty.isNotEmpty || tombstones.isNotEmpty;

      _act(attempt == 0 ? '检查云端索引…' : '索引提交冲突，重试 ${attempt + 1}/$_maxConflictRetries…');
      final knownEtag = hasPending
          ? null
          : await _stateStore.readMeta(SyncStateStore.metaLastManifestEtag);
      final manifestResult = await store.getObject(
        SyncManifest.path,
        ifNoneMatch: knownEtag,
      );

      SyncManifest remote;
      String? remoteEtag;
      switch (manifestResult) {
        case RemoteObjectUnchanged():
          // Nothing pending locally (etag only sent then) and nothing new
          // remotely.
          return const SyncPullReport();
        case RemoteObjectMissing():
          if (!hasPending) return const SyncPullReport();
          await store.ensureReady();
          remote = SyncManifest.empty(AppDatabase.currentSchemaVersion);
          remoteEtag = null;
        case RemoteObjectData(:final bytes, :final etag):
          remote = SyncManifest.decode(bytes);
          remoteEtag = etag;
      }
      if (remote.schemaVersion > AppDatabase.currentSchemaVersion) {
        throw SyncSchemaTooNewException(remote.schemaVersion);
      }
      SyncClock.observe(remote.writtenAt);

      final lastApplied = await _readLastAppliedManifest();
      final remoteAdvanced =
          remote.revision > 0 &&
          remote.revision != (lastApplied?.revision ?? -1);
      final initialSyncDone =
          await _stateStore.readMeta(SyncStateStore.metaInitialSyncDone) ==
          'true';

      final bool cloudWins;
      if (!initialSyncDone && remote.objects.isNotEmpty) {
        // First sync against a populated cloud: the cloud is authoritative,
        // so a fresh install's seeded defaults never overwrite real data.
        cloudWins = true;
      } else if (remoteAdvanced && hasPending) {
        // Diverged: the side with the newest change wins wholesale.
        cloudWins = remote.writtenAt >= _maxPendingTimestamp(
          dirty,
          tombstones,
        );
      } else if (remoteAdvanced) {
        cloudWins = true;
      } else {
        cloudWins = false;
      }

      if (cloudWins) {
        return _applyMirror(
          store,
          remote,
          remoteEtag,
          lastApplied: lastApplied,
          discardedDirty: dirty,
          discardedTombstones: tombstones,
        );
      }
      if (hasPending) {
        final report = await _mirrorPush(
          store,
          remote,
          remoteEtag,
          dirty,
          tombstones,
          // Two straight conditional-write conflicts usually mean the server
          // mishandles If-Match; degrade to an unconditional write rather
          // than burning quota in an endless retry loop.
          allowUnconditional: attempt >= 2,
        );
        if (report == null) continue; // Conditional write lost; re-decide.
        return report;
      }
      // Same revision, nothing pending: just remember the ETag for cheap
      // 304 polling.
      if (remoteEtag != null) {
        await _stateStore.writeMeta(
          SyncStateStore.metaLastManifestEtag,
          remoteEtag,
        );
      }
      return const SyncPullReport();
    }
    throw const SyncConflictRetriesExhaustedException();
  }

  /// Incremental push: uploads pending local changes (creations, edits AND
  /// deletions since the last push) without ever pulling remote data.
  /// No-op when nothing is pending. This is the ONLY operation the runtime
  /// triggers (message sent / generation finished / interval tick).
  Future<SyncPullReport> pushPending(SyncRemoteStore store) async {
    for (var attempt = 0; attempt < _maxConflictRetries; attempt++) {
      final dirty = await _stateStore.snapshotDirty();
      final tombstones = await _stateStore.allTombstones();
      if (dirty.isEmpty && tombstones.isEmpty) return const SyncPullReport();

      _act(attempt == 0
          ? '准备上传变更…'
          : '索引提交冲突，重试 ${attempt + 1}/$_maxConflictRetries…');
      SyncManifest remote;
      String? remoteEtag;
      switch (await store.getObject(SyncManifest.path)) {
        case RemoteObjectMissing():
          await store.ensureReady();
          remote = SyncManifest.empty(AppDatabase.currentSchemaVersion);
          remoteEtag = null;
        case RemoteObjectData(:final bytes, :final etag):
          remote = SyncManifest.decode(bytes);
          remoteEtag = etag;
        case RemoteObjectUnchanged():
          throw StateError('sync_manifest_unchanged_without_etag');
      }
      if (remote.schemaVersion > AppDatabase.currentSchemaVersion) {
        throw SyncSchemaTooNewException(remote.schemaVersion);
      }
      SyncClock.observe(remote.writtenAt);
      final report = await _mirrorPush(
        store,
        remote,
        remoteEtag,
        dirty,
        tombstones,
        allowUnconditional: attempt >= 2,
      );
      if (report != null) return report;
    }
    throw const SyncConflictRetriesExhaustedException();
  }

  /// Manual "upload to cloud": makes the remote identical to local state,
  /// regardless of which side is newer.
  Future<SyncPullReport> forceUpload(SyncRemoteStore store) async {
    await _markEverythingDirty();
    for (var attempt = 0; attempt < _maxConflictRetries; attempt++) {
      final dirty = await _stateStore.snapshotDirty();
      final tombstones = await _stateStore.allTombstones();
      SyncManifest remote;
      String? remoteEtag;
      switch (await store.getObject(SyncManifest.path)) {
        case RemoteObjectMissing():
          await store.ensureReady();
          remote = SyncManifest.empty(AppDatabase.currentSchemaVersion);
          remoteEtag = null;
        case RemoteObjectData(:final bytes, :final etag):
          remote = SyncManifest.decode(bytes);
          remoteEtag = etag;
        case RemoteObjectUnchanged():
          throw StateError('sync_manifest_unchanged_without_etag');
      }
      if (remote.schemaVersion > AppDatabase.currentSchemaVersion) {
        throw SyncSchemaTooNewException(remote.schemaVersion);
      }
      SyncClock.observe(remote.writtenAt);
      final report = await _mirrorPush(
        store,
        remote,
        remoteEtag,
        dirty,
        tombstones,
        allowUnconditional: attempt >= 2,
      );
      if (report != null) return report;
    }
    throw const SyncConflictRetriesExhaustedException();
  }

  /// Manual "download from cloud": makes local state identical to the
  /// remote, discarding pending local changes. No-op when the cloud holds
  /// no manifest yet.
  Future<SyncPullReport> forceDownload(SyncRemoteStore store) async {
    final result = await store.getObject(SyncManifest.path);
    if (result is! RemoteObjectData) return const SyncPullReport();
    final manifest = SyncManifest.decode(result.bytes);
    if (manifest.schemaVersion > AppDatabase.currentSchemaVersion) {
      throw SyncSchemaTooNewException(manifest.schemaVersion);
    }
    SyncClock.observe(manifest.writtenAt);
    return _applyMirror(
      store,
      manifest,
      result.etag,
      lastApplied: null,
      discardedDirty: await _stateStore.snapshotDirty(),
      discardedTombstones: await _stateStore.allTombstones(),
      forceFull: true,
    );
  }

  // ===== Cloud → local =====

  Future<SyncPullReport> _applyMirror(
    SyncRemoteStore store,
    SyncManifest manifest,
    String? manifestEtag, {
    required SyncManifest? lastApplied,
    required List<SyncDirtyEntry> discardedDirty,
    required List<SyncTombstone> discardedTombstones,
    bool forceFull = false,
  }) async {
    final discardPending =
        forceFull ||
        discardedDirty.isNotEmpty ||
        discardedTombstones.isNotEmpty;
    final active = await _activeConversationIds();
    final changedConversations = <String>{};
    var businessChanged = false;
    var deferred = false;

    // With pending local changes being discarded, every remote object must
    // be re-applied — the local rows behind them may differ from what
    // lastApplied recorded.
    final paths = discardPending
        ? manifest.objects.keys.toList(growable: false)
        : manifest.changedSince(lastApplied);

    final appliedObjects = Map<String, SyncObjectEntry>.of(manifest.objects);

    for (final path in paths) {
      if (path == SyncManifest.tombstonesPath) continue; // Legacy layout.
      if (path.startsWith('conversations/')) {
        final conversationId = _idFromPath(path, 'conversations/');
        if (conversationId == null) continue;
        if (active.contains(conversationId)) {
          final previous = lastApplied?.objects[path];
          if (previous != null) {
            appliedObjects[path] = previous;
          } else {
            appliedObjects.remove(path);
          }
          deferred = true;
          continue;
        }
        _act('下载会话 $conversationId…');
        final result = await store.getObject(path);
        if (result is! RemoteObjectData) continue;
        final object = SyncObjectCodec.parseObject(result.bytes);
        final hashToPath = await _ensureAssetsFor(store, result.bytes);
        await _merger.replaceConversationObject(
          object,
          hashToPath: hashToPath,
        );
        changedConversations.add(conversationId);
      } else if (path == SyncManifest.settingsPath) {
        final result = await store.getObject(path);
        if (result is! RemoteObjectData) continue;
        await _merger.replaceSettings(
          SyncObjectCodec.parseObject(result.bytes),
          hashToPath: await _ensureAssetsFor(store, result.bytes),
        );
        businessChanged = true;
      } else if (path.startsWith('entities/')) {
        final kind = _entityKindFromPath(path);
        if (kind == null) continue;
        final result = await store.getObject(path);
        if (result is! RemoteObjectData) continue;
        await _merger.replaceEntities(
          kind,
          SyncObjectCodec.parseObject(result.bytes),
          hashToPath: await _ensureAssetsFor(store, result.bytes),
        );
        businessChanged = true;
      }
    }

    // Mirror semantics also cover absence: scoped objects the manifest does
    // not list must be empty locally.
    if (discardPending) {
      for (final kind in BusinessEntityKind.values) {
        if (!manifest.objects.containsKey('entities/${kind.name}.json')) {
          await _merger.replaceEntities(kind, null, hashToPath: const {});
          businessChanged = true;
        }
      }
      if (!manifest.objects.containsKey(SyncManifest.settingsPath)) {
        await _merger.replaceSettings(null, hashToPath: const {});
        businessChanged = true;
      }
    }

    // Local conversations the winning side does not have are deleted
    // (deferred for active generation runs).
    final remoteConversationIds = <String>{
      for (final path in manifest.objects.keys)
        if (path.startsWith('conversations/'))
          _idFromPath(path, 'conversations/')!,
    };
    final localIds = await _merger.localConversationIds();
    final extras = localIds
        .difference(remoteConversationIds)
        .where((id) => !active.contains(id))
        .toList(growable: false);
    final deletedIds = extras.isEmpty
        ? const <String>{}
        : await _merger.deleteConversations(extras);
    if (localIds.difference(remoteConversationIds).length != extras.length) {
      deferred = true;
    }

    // Precisely drop the pending entries that lost the decision; anything
    // queued by user writes DURING this apply survives for the next push.
    await _stateStore.clearDirty(discardedDirty);
    for (final tombstone in discardedTombstones) {
      await _stateStore.removeTombstone(tombstone.kind, tombstone.entityId);
    }

    final applied = SyncManifest(
      schemaVersion: manifest.schemaVersion,
      revision: manifest.revision,
      lastWriter: manifest.lastWriter,
      writtenAt: manifest.writtenAt,
      objects: appliedObjects,
      assets: manifest.assets,
    );
    await _stateStore.writeMeta(
      SyncStateStore.metaLastManifestJson,
      utf8.decode(applied.encode()),
    );
    if (manifestEtag != null && !deferred) {
      await _stateStore.writeMeta(
        SyncStateStore.metaLastManifestEtag,
        manifestEtag,
      );
    } else {
      // Deferred objects must be re-examined next round; a 304 shortcut
      // would skip them.
      await _stateStore.removeMeta(SyncStateStore.metaLastManifestEtag);
    }
    await _stateStore.writeMeta(
      SyncStateStore.metaLastRemoteRevision,
      '${manifest.revision}',
    );
    await _finishSuccessfulSync();

    return SyncPullReport(
      remoteChanged: true,
      changedConversationIds: changedConversations,
      deletedConversationIds: deletedIds,
      businessChanged: businessChanged,
      deferredActiveConversations: deferred,
    );
  }

  // ===== Local → cloud =====

  /// Returns null when the conditional manifest write lost the race.
  Future<SyncPullReport?> _mirrorPush(
    SyncRemoteStore store,
    SyncManifest remote,
    String? remoteEtag,
    List<SyncDirtyEntry> dirty,
    List<SyncTombstone> tombstones, {
    bool allowUnconditional = false,
  }) async {
    final active = await _activeConversationIds();
    final objects = Map<String, SyncObjectEntry>.of(remote.objects)
      ..remove(SyncManifest.tombstonesPath); // Legacy layout cleanup.
    final assetMap = Map<String, int>.of(remote.assets);
    final consumed = <SyncDirtyEntry>[];
    var uploadedObjects = 0;
    var deferred = false;

    for (final entry in dirty) {
      switch (entry.scope) {
        case SyncScope.conversation:
          final conversationId = entry.entityId;
          if (active.contains(conversationId)) {
            deferred = true;
            continue;
          }
          final path = 'conversations/$conversationId.json';
          _act('上传会话 $conversationId…');
          final export = await _codec.exportConversation(conversationId);
          if (export == null) {
            objects.remove(path);
            consumed.add(entry);
            continue;
          }
          if (await _uploadIfChanged(store, path, export, objects, assetMap)) {
            uploadedObjects++;
          }
          consumed.add(entry);
        case SyncScope.entities:
          final kind = _entityKindByName(entry.entityId);
          if (kind == null) {
            consumed.add(entry);
            continue;
          }
          final export = await _codec.exportEntities(kind);
          if (await _uploadIfChanged(
            store,
            'entities/${kind.name}.json',
            export,
            objects,
            assetMap,
          )) {
            uploadedObjects++;
          }
          consumed.add(entry);
        case SyncScope.settings:
          final export = await _codec.exportSettings();
          if (await _uploadIfChanged(
            store,
            SyncManifest.settingsPath,
            export,
            objects,
            assetMap,
          )) {
            uploadedObjects++;
          }
          consumed.add(entry);
      }
    }

    // Deleted conversations leave the manifest; their blobs are cleaned up
    // best-effort. A full reconcile against the local id set also drops any
    // stray remote conversations (mirror semantics).
    final localIds = await _merger.localConversationIds();
    final staleRemote = <String>[
      for (final path in objects.keys)
        if (path.startsWith('conversations/') &&
            !localIds.contains(_idFromPath(path, 'conversations/')))
          path,
    ];
    for (final path in staleRemote) {
      objects.remove(path);
      try {
        await store.deleteObject(path);
      } catch (_) {}
    }

    final manifestUnchanged =
        uploadedObjects == 0 &&
        _sameObjectMaps(objects, remote.objects) &&
        _sameAssetMaps(assetMap, remote.assets);
    if (manifestUnchanged) {
      await _stateStore.clearDirty(consumed);
      for (final tombstone in tombstones) {
        await _stateStore.removeTombstone(tombstone.kind, tombstone.entityId);
      }
      if (remoteEtag != null) {
        await _stateStore.writeMeta(
          SyncStateStore.metaLastManifestEtag,
          remoteEtag,
        );
      }
      await _finishSuccessfulSync();
      return SyncPullReport(deferredActiveConversations: deferred);
    }

    final next = remote.next(
      writer: _deviceId,
      writtenAt: SyncClock.nowMicros(),
      schemaVersion: AppDatabase.currentSchemaVersion,
      objects: objects,
      assets: assetMap,
    );
    final encoded = next.encode();
    _act('提交云端索引…');
    final String? newEtag;
    try {
      newEtag = await store.putObject(
        SyncManifest.path,
        Uint8List.fromList(encoded),
        ifMatch: allowUnconditional ? null : remoteEtag,
        ifAbsent:
            !allowUnconditional && remoteEtag == null && remote.revision == 0,
      );
    } on RemotePreconditionFailedException {
      return null;
    }

    await _stateStore.clearDirty(consumed);
    for (final tombstone in tombstones) {
      await _stateStore.removeTombstone(tombstone.kind, tombstone.entityId);
    }
    await _stateStore.writeMeta(
      SyncStateStore.metaLastManifestJson,
      utf8.decode(encoded),
    );
    if (newEtag != null) {
      await _stateStore.writeMeta(
        SyncStateStore.metaLastManifestEtag,
        newEtag,
      );
    } else {
      await _stateStore.removeMeta(SyncStateStore.metaLastManifestEtag);
    }
    await _stateStore.writeMeta(
      SyncStateStore.metaLastRemoteRevision,
      '${next.revision}',
    );
    await _finishSuccessfulSync();
    return SyncPullReport(
      uploadedObjects: uploadedObjects,
      deferredActiveConversations: deferred,
    );
  }

  // ===== Internals =====

  Future<void> _markEverythingDirty() async {
    await _db.transaction(() async {
      final rows = await _db
          .customSelect('SELECT id FROM conversation_rows;')
          .get();
      for (final row in rows) {
        await SyncStateStore.markDirtyInTransaction(
          _db,
          SyncScope.conversation,
          row.data['id'] as String,
          quiet: true,
        );
      }
      for (final kind in BusinessEntityKind.values) {
        await SyncStateStore.markDirtyInTransaction(
          _db,
          SyncScope.entities,
          kind.name,
          quiet: true,
        );
      }
      await SyncStateStore.markDirtyInTransaction(
        _db,
        SyncScope.settings,
        '',
        quiet: true,
      );
    });
  }

  Future<bool> _uploadIfChanged(
    SyncRemoteStore store,
    String path,
    SyncExportedObject export,
    Map<String, SyncObjectEntry> objects,
    Map<String, int> assetMap,
  ) async {
    final sha = export.sha256Hex;
    final entry = SyncObjectEntry(
      sha256: sha,
      updatedAt: export.maxUpdatedAt,
      size: export.bytes.length,
    );
    if (objects[path]?.sha256 == sha) {
      objects[path] = entry;
      return false;
    }
    final uploadedAssets = await _assets.uploadMissingAssets(
      export.assetRefs,
      assetMap,
      store,
    );
    assetMap.addAll(uploadedAssets);
    await store.putObject(path, export.bytes);
    objects[path] = entry;
    return true;
  }

  Future<Map<String, String>> _ensureAssetsFor(
    SyncRemoteStore store,
    List<int> objectBytes,
  ) => _assets.ensureLocalAssets(
    store,
    SyncObjectCodec.collectAssetTokens(utf8.decode(objectBytes)),
  );

  Future<SyncManifest?> _readLastAppliedManifest() async {
    final raw = await _stateStore.readMeta(
      SyncStateStore.metaLastManifestJson,
    );
    if (raw == null) return null;
    try {
      return SyncManifest.decode(utf8.encode(raw));
    } on FormatException {
      return null;
    }
  }

  static int _maxPendingTimestamp(
    List<SyncDirtyEntry> dirty,
    List<SyncTombstone> tombstones,
  ) {
    var max = 0;
    for (final entry in dirty) {
      if (entry.lastDirtyAt > max) max = entry.lastDirtyAt;
    }
    for (final tombstone in tombstones) {
      if (tombstone.deletedAt > max) max = tombstone.deletedAt;
    }
    return max;
  }

  Future<void> _finishSuccessfulSync() async {
    await _stateStore.writeMeta(
      SyncStateStore.metaInitialSyncDone,
      'true',
    );
    await _stateStore.writeMeta(
      SyncStateStore.metaLastSyncAt,
      '${SyncClock.nowMicros()}',
    );
    await _stateStore.persistClockFloor();
  }

  Future<Set<String>> _activeConversationIds() async {
    final rows = await _db
        .customSelect(
          'SELECT DISTINCT conversation_id FROM generation_run_rows '
          "WHERE state IN ('preparing', 'requesting', 'streaming', "
          "'waiting_tool');",
        )
        .get();
    return {for (final row in rows) row.data['conversation_id'] as String};
  }

  static String? _idFromPath(String path, String prefix) {
    if (!path.startsWith(prefix)) return null;
    var id = path.substring(prefix.length);
    if (id.endsWith('.json')) id = id.substring(0, id.length - 5);
    return id.isEmpty ? null : id;
  }

  static BusinessEntityKind? _entityKindByName(String name) {
    for (final value in BusinessEntityKind.values) {
      if (value.name == name) return value;
    }
    return null;
  }

  static BusinessEntityKind? _entityKindFromPath(String path) {
    final name = _idFromPath(path, 'entities/');
    return name == null ? null : _entityKindByName(name);
  }

  static bool _sameObjectMaps(
    Map<String, SyncObjectEntry> a,
    Map<String, SyncObjectEntry> b,
  ) {
    if (a.length != b.length) return false;
    for (final entry in a.entries) {
      if (b[entry.key] != entry.value) return false;
    }
    return true;
  }

  static bool _sameAssetMaps(Map<String, int> a, Map<String, int> b) {
    if (a.length != b.length) return false;
    for (final entry in a.entries) {
      if (b[entry.key] != entry.value) return false;
    }
    return true;
  }
}
