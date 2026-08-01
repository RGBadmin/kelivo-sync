// ignore_for_file: prefer_initializing_formals

import 'dart:convert';

import 'package:crypto/crypto.dart';
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
    this.changedConversationIds = const {},
    this.deletedConversationIds = const {},
    this.businessChanged = false,
    this.deferredActiveConversations = false,
  });

  final bool remoteChanged;
  final Set<String> changedConversationIds;
  final Set<String> deletedConversationIds;
  final bool businessChanged;

  /// True when at least one changed conversation was skipped because it has
  /// an active generation run; the next pull retries it.
  final bool deferredActiveConversations;

  bool get uiRefreshNeeded =>
      changedConversationIds.isNotEmpty ||
      deletedConversationIds.isNotEmpty ||
      businessChanged;

  SyncPullReport merge(SyncPullReport other) => SyncPullReport(
    remoteChanged: remoteChanged || other.remoteChanged,
    changedConversationIds: {
      ...changedConversationIds,
      ...other.changedConversationIds,
    },
    deletedConversationIds: {
      ...deletedConversationIds,
      ...other.deletedConversationIds,
    },
    businessChanged: businessChanged || other.businessChanged,
    deferredActiveConversations:
        deferredActiveConversations || other.deferredActiveConversations,
  );
}

final class SyncPushReport {
  const SyncPushReport({
    this.uploadedObjects = 0,
    this.pulled = const SyncPullReport(),
  });

  final int uploadedObjects;

  /// Pull work performed inside the push loop (conflict recovery).
  final SyncPullReport pulled;
}

/// Differential push/pull engine over a [SyncRemoteStore].
///
/// The remote manifest is the linearization point: content objects are
/// written unconditionally (their paths are id-keyed and their bytes
/// content-derived), but the manifest itself is replaced with a conditional
/// write. A concurrent writer surfaces as a precondition failure, after
/// which this engine re-pulls, re-merges and retries.
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
  static const tombstoneRetentionDays = 30;

  final AppDatabase _db;
  final SyncStateStore _stateStore;
  final SyncObjectCodec _codec;
  final SyncMerger _merger;
  final SyncAssetTransfer _assets;
  final String _deviceId;

  /// First-run / restored-database detection: when the database was not
  /// previously synced by THIS installation, all remote application state is
  /// discarded and everything local is queued (quietly) so the next push
  /// reconciles by content hash instead of trusting stale bookkeeping.
  Future<void> ensureConsistentIdentity() async {
    final stored = await _stateStore.readMeta(SyncStateStore.metaDeviceId);
    if (stored == _deviceId) return;
    await _stateStore.removeMeta(SyncStateStore.metaLastManifestJson);
    await _stateStore.removeMeta(SyncStateStore.metaLastManifestEtag);
    await _stateStore.removeMeta(SyncStateStore.metaLastRemoteRevision);
    await _markEverythingDirty();
    await _stateStore.writeMeta(SyncStateStore.metaDeviceId, _deviceId);
  }

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

  Future<SyncPullReport> pullOnce(SyncRemoteStore store) async {
    final knownEtag = await _stateStore.readMeta(
      SyncStateStore.metaLastManifestEtag,
    );
    final result = await store.getObject(
      SyncManifest.path,
      ifNoneMatch: knownEtag,
    );
    switch (result) {
      case RemoteObjectMissing():
      case RemoteObjectUnchanged():
        return const SyncPullReport();
      case RemoteObjectData(:final bytes, :final etag):
        final manifest = SyncManifest.decode(bytes);
        return _applyRemoteManifest(store, manifest, etag);
    }
  }

  Future<SyncPushReport> pushOnce(SyncRemoteStore store) async {
    var pulled = const SyncPullReport();
    for (var attempt = 0; attempt < _maxConflictRetries; attempt++) {
      await _dropResurrectedTombstones();
      final dirty = await _stateStore.snapshotDirty();
      final tombstones = await _stateStore.allTombstones();
      final pendingTombstones = tombstones
          .where((tombstone) => !tombstone.uploaded)
          .toList(growable: false);
      if (dirty.isEmpty && pendingTombstones.isEmpty) {
        return SyncPushReport(pulled: pulled);
      }

      // Current remote state; unapplied remote changes merge first so the
      // exports below already contain the LWW outcome.
      String? remoteEtag;
      SyncManifest remote;
      final manifestResult = await store.getObject(SyncManifest.path);
      switch (manifestResult) {
        case RemoteObjectMissing():
          await store.ensureReady();
          remote = SyncManifest.empty(AppDatabase.currentSchemaVersion);
          remoteEtag = null;
        case RemoteObjectUnchanged():
          throw StateError('sync_manifest_unchanged_without_etag');
        case RemoteObjectData(:final bytes, :final etag):
          remote = SyncManifest.decode(bytes);
          remoteEtag = etag;
      }
      if (remote.revision > 0) {
        pulled = pulled.merge(
          await _applyRemoteManifest(store, remote, remoteEtag),
        );
      }

      final freshDirty = await _stateStore.snapshotDirty();
      final freshTombstones = await _stateStore.allTombstones();
      final active = await _activeConversationIds();
      final conversationTombstones = _tombstoneMap(
        freshTombstones,
        SyncTombstoneKind.conversation,
      );

      final objects = Map<String, SyncObjectEntry>.of(remote.objects);
      final assetMap = Map<String, int>.of(remote.assets);
      final consumed = <SyncDirtyEntry>[];
      var uploadedObjects = 0;

      for (final entry in freshDirty) {
        switch (entry.scope) {
          case SyncScope.conversation:
            final conversationId = entry.entityId;
            if (active.contains(conversationId)) continue;
            final path = 'conversations/$conversationId.json';
            if (conversationTombstones.containsKey(conversationId)) {
              objects.remove(path);
              consumed.add(entry);
              continue;
            }
            final export = await _codec.exportConversation(conversationId);
            if (export == null) {
              objects.remove(path);
              consumed.add(entry);
              continue;
            }
            final uploaded = await _uploadIfChanged(
              store,
              path,
              export,
              objects,
              assetMap,
            );
            if (uploaded) uploadedObjects++;
            consumed.add(entry);
          case SyncScope.entities:
            BusinessEntityKind? kind;
            for (final value in BusinessEntityKind.values) {
              if (value.name == entry.entityId) {
                kind = value;
                break;
              }
            }
            if (kind == null) {
              consumed.add(entry);
              continue;
            }
            final export = await _codec.exportEntities(kind);
            final uploaded = await _uploadIfChanged(
              store,
              'entities/${kind.name}.json',
              export,
              objects,
              assetMap,
            );
            if (uploaded) uploadedObjects++;
            consumed.add(entry);
          case SyncScope.settings:
            final export = await _codec.exportSettings();
            final uploaded = await _uploadIfChanged(
              store,
              SyncManifest.settingsPath,
              export,
              objects,
              assetMap,
            );
            if (uploaded) uploadedObjects++;
            consumed.add(entry);
        }
      }

      // Deleted conversations leave the manifest (and their blob is cleaned
      // up best-effort); the tombstone below is what other devices act on.
      for (final tombstone in freshTombstones) {
        if (tombstone.kind != SyncTombstoneKind.conversation) continue;
        final path = 'conversations/${tombstone.entityId}.json';
        if (objects.remove(path) != null) {
          try {
            await store.deleteObject(path);
          } catch (_) {}
        }
      }

      // Canonical tombstones object.
      final tombstoneBytes = _encodeTombstones(freshTombstones);
      final tombstoneSha = _sha256Hex(tombstoneBytes);
      if (freshTombstones.isEmpty) {
        objects.remove(SyncManifest.tombstonesPath);
      } else if (objects[SyncManifest.tombstonesPath]?.sha256 !=
          tombstoneSha) {
        await store.putObject(
          SyncManifest.tombstonesPath,
          tombstoneBytes,
        );
        var maxDeletedAt = 0;
        for (final tombstone in freshTombstones) {
          if (tombstone.deletedAt > maxDeletedAt) {
            maxDeletedAt = tombstone.deletedAt;
          }
        }
        objects[SyncManifest.tombstonesPath] = SyncObjectEntry(
          sha256: tombstoneSha,
          updatedAt: maxDeletedAt,
          size: tombstoneBytes.length,
        );
        uploadedObjects++;
      }

      final manifestUnchanged =
          uploadedObjects == 0 &&
          _sameObjectMaps(objects, remote.objects) &&
          _sameAssetMaps(assetMap, remote.assets);
      if (manifestUnchanged) {
        await _stateStore.clearDirty(consumed);
        await _stateStore.markTombstonesUploaded(pendingTombstones);
        await _finishSuccessfulSync();
        return SyncPushReport(pulled: pulled);
      }

      final next = remote.next(
        writer: _deviceId,
        writtenAt: SyncClock.nowMicros(),
        schemaVersion: AppDatabase.currentSchemaVersion,
        objects: objects,
        assets: assetMap,
      );
      final encoded = next.encode();
      final String? newEtag;
      try {
        newEtag = await store.putObject(
          SyncManifest.path,
          Uint8List.fromList(encoded),
          ifMatch: remoteEtag,
          ifAbsent: remoteEtag == null && remote.revision == 0,
        );
      } on RemotePreconditionFailedException {
        continue;
      }

      await _stateStore.clearDirty(consumed);
      await _stateStore.markTombstonesUploaded(pendingTombstones);
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
      await _stateStore.pruneTombstones(
        olderThanMicros:
            SyncClock.nowMicros() -
            Duration(days: tombstoneRetentionDays).inMicroseconds,
      );
      await _finishSuccessfulSync();
      return SyncPushReport(uploadedObjects: uploadedObjects, pulled: pulled);
    }
    throw const SyncConflictRetriesExhaustedException();
  }

  Future<SyncPullReport> fullSync(SyncRemoteStore store) async {
    final pullReport = await pullOnce(store);
    final pushReport = await pushOnce(store);
    return pullReport.merge(pushReport.pulled);
  }

  /// True when the dirty queue or un-uploaded tombstones await a push.
  Future<bool> hasPendingLocalChanges() async {
    final dirty = await _stateStore.snapshotDirty();
    if (dirty.isNotEmpty) return true;
    final tombstones = await _stateStore.allTombstones();
    return tombstones.any((tombstone) => !tombstone.uploaded);
  }

  // ===== Internals =====

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

  Future<SyncPullReport> _applyRemoteManifest(
    SyncRemoteStore store,
    SyncManifest manifest,
    String? manifestEtag,
  ) async {
    if (manifest.schemaVersion > AppDatabase.currentSchemaVersion) {
      throw SyncSchemaTooNewException(manifest.schemaVersion);
    }
    SyncClock.observe(manifest.writtenAt);

    SyncManifest? lastApplied;
    final lastAppliedJson = await _stateStore.readMeta(
      SyncStateStore.metaLastManifestJson,
    );
    if (lastAppliedJson != null) {
      try {
        lastApplied = SyncManifest.decode(utf8.encode(lastAppliedJson));
      } on FormatException {
        lastApplied = null;
      }
    }
    if (lastApplied != null && lastApplied.revision == manifest.revision) {
      return const SyncPullReport();
    }

    final changed = manifest.changedSince(lastApplied);
    final changedConversations = <String>{};
    var businessChanged = false;
    var deferred = false;

    // Tombstones first so newly arriving objects merge against them.
    SyncTombstoneApplyResult? tombstoneResult;
    if (changed.contains(SyncManifest.tombstonesPath)) {
      final result = await store.getObject(SyncManifest.tombstonesPath);
      if (result is RemoteObjectData) {
        final remoteTombstones = _decodeTombstones(result.bytes);
        await _stateStore.recordRemoteTombstones(remoteTombstones);
        tombstoneResult = await _merger.applyTombstones(remoteTombstones);
        businessChanged |= tombstoneResult.businessChanged;
      }
    }

    final tombstones = await _stateStore.allTombstones();
    final conversationTombstones = _tombstoneMap(
      tombstones,
      SyncTombstoneKind.conversation,
    );
    final messageTombstones = _tombstoneMap(
      tombstones,
      SyncTombstoneKind.message,
    );
    final preferenceTombstones = _tombstoneMap(
      tombstones,
      SyncTombstoneKind.preference,
    );
    final active = await _activeConversationIds();
    final appliedObjects = Map<String, SyncObjectEntry>.of(manifest.objects);

    for (final path in changed) {
      if (path == SyncManifest.tombstonesPath) continue;
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
      }
      final result = await store.getObject(path);
      if (result is! RemoteObjectData) continue;
      final object = SyncObjectCodec.parseObject(result.bytes);
      final tokens = SyncObjectCodec.collectAssetTokens(
        utf8.decode(result.bytes),
      );
      final hashToPath = await _assets.ensureLocalAssets(store, tokens);

      if (path == SyncManifest.settingsPath) {
        await _merger.mergeSettings(
          object,
          hashToPath: hashToPath,
          preferenceTombstones: preferenceTombstones,
        );
        businessChanged = true;
      } else if (path.startsWith('entities/')) {
        final kindName = _idFromPath(path, 'entities/');
        BusinessEntityKind? kind;
        for (final value in BusinessEntityKind.values) {
          if (value.name == kindName) {
            kind = value;
            break;
          }
        }
        if (kind == null) continue;
        await _merger.mergeEntities(
          kind,
          object,
          hashToPath: hashToPath,
          entityTombstones: _entityTombstoneMap(tombstones, kind),
        );
        businessChanged = true;
      } else if (path.startsWith('conversations/')) {
        final conversationId = _idFromPath(path, 'conversations/')!;
        await _merger.mergeConversationObject(
          object,
          hashToPath: hashToPath,
          conversationTombstones: conversationTombstones,
          messageTombstones: messageTombstones,
        );
        changedConversations.add(conversationId);
      }
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
    // A deferred conversation must be re-examined next round: drop the ETag
    // so the next pull cannot short-circuit on 304.
    if (manifestEtag != null && !deferred) {
      await _stateStore.writeMeta(
        SyncStateStore.metaLastManifestEtag,
        manifestEtag,
      );
    } else {
      await _stateStore.removeMeta(SyncStateStore.metaLastManifestEtag);
    }
    await _stateStore.writeMeta(
      SyncStateStore.metaLastRemoteRevision,
      '${manifest.revision}',
    );
    await _finishSuccessfulSync();

    return SyncPullReport(
      remoteChanged: true,
      changedConversationIds: {
        ...changedConversations,
        ...?tombstoneResult?.changedConversationIds,
      },
      deletedConversationIds:
          tombstoneResult?.deletedConversationIds ?? const {},
      businessChanged: businessChanged,
      deferredActiveConversations: deferred,
    );
  }

  Future<void> _finishSuccessfulSync() async {
    await _stateStore.writeMeta(
      SyncStateStore.metaLastSyncAt,
      '${SyncClock.nowMicros()}',
    );
    await _stateStore.persistClockFloor();
  }

  /// Drops tombstones whose row has been edited back to life (edits win).
  Future<void> _dropResurrectedTombstones() async {
    final tombstones = await _stateStore.allTombstones();
    for (final tombstone in tombstones) {
      final bool alive;
      if (tombstone.kind == SyncTombstoneKind.conversation) {
        alive = await _rowExists(
          'SELECT 1 FROM conversation_rows WHERE id = ? AND (updated_at >= ? '
          'OR EXISTS (SELECT 1 FROM message_rows WHERE conversation_id = ? '
          'AND updated_at >= ?));',
          [
            tombstone.entityId,
            tombstone.deletedAt,
            tombstone.entityId,
            tombstone.deletedAt,
          ],
        );
      } else if (tombstone.kind == SyncTombstoneKind.message) {
        final separator = tombstone.entityId.indexOf('/');
        if (separator <= 0) continue;
        alive = await _rowExists(
          'SELECT 1 FROM message_rows WHERE id = ? AND updated_at >= ?;',
          [tombstone.entityId.substring(separator + 1), tombstone.deletedAt],
        );
      } else if (tombstone.kind == SyncTombstoneKind.preference) {
        alive = await _rowExists(
          'SELECT 1 FROM preference_rows WHERE key = ? AND updated_at >= ?;',
          [tombstone.entityId, tombstone.deletedAt],
        );
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
        alive = await _rowExists(
          'SELECT 1 FROM ${kind.tableName} WHERE ${kind.idColumn} = ? '
          'AND updated_at >= ?;',
          [tombstone.entityId, tombstone.deletedAt],
        );
      } else {
        continue;
      }
      if (alive) {
        await _stateStore.removeTombstone(tombstone.kind, tombstone.entityId);
      }
    }
  }

  Future<bool> _rowExists(String sql, List<Object?> args) async {
    final rows = await _db
        .customSelect(
          sql,
          variables: [
            for (final arg in args)
              arg is int ? Variable.withInt(arg) : Variable(arg),
          ],
        )
        .get();
    return rows.isNotEmpty;
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

  static Map<String, int> _tombstoneMap(
    List<SyncTombstone> tombstones,
    String kind,
  ) => {
    for (final tombstone in tombstones)
      if (tombstone.kind == kind) tombstone.entityId: tombstone.deletedAt,
  };

  static Map<String, int> _entityTombstoneMap(
    List<SyncTombstone> tombstones,
    BusinessEntityKind kind,
  ) {
    final kindKey = SyncTombstoneKind.entity(kind.name);
    return {
      for (final tombstone in tombstones)
        if (tombstone.kind == kindKey) tombstone.entityId: tombstone.deletedAt,
    };
  }

  static Uint8List _encodeTombstones(List<SyncTombstone> tombstones) {
    final sorted = [...tombstones]
      ..sort((a, b) {
        final byKind = a.kind.compareTo(b.kind);
        if (byKind != 0) return byKind;
        return a.entityId.compareTo(b.entityId);
      });
    return Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          'formatVersion': 1,
          'tombstones': [
            for (final tombstone in sorted)
              {
                'kind': tombstone.kind,
                'id': tombstone.entityId,
                'deletedAt': tombstone.deletedAt,
                'deviceId': tombstone.deviceId,
              },
          ],
        }),
      ),
    );
  }

  static List<SyncTombstone> _decodeTombstones(List<int> bytes) {
    final decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is! Map<String, dynamic>) return const [];
    final raw = decoded['tombstones'];
    if (raw is! List) return const [];
    return [
      for (final item in raw)
        if (item is Map<String, dynamic> &&
            item['kind'] is String &&
            item['id'] is String &&
            item['deletedAt'] is num)
          (
            kind: item['kind'] as String,
            entityId: item['id'] as String,
            deletedAt: (item['deletedAt'] as num).toInt(),
            deviceId: item['deviceId'] as String? ?? '',
            uploaded: true,
          ),
    ];
  }

  static String _sha256Hex(List<int> bytes) => sha256.convert(bytes).toString();

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
