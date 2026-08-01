import 'package:drift/drift.dart';

import '../../database/app_database.dart';
import 'sync_clock.dart';

/// The three kinds of remote sync objects a local change can invalidate.
enum SyncScope { conversation, entities, settings }

extension SyncScopeName on SyncScope {
  String get dbValue => switch (this) {
    SyncScope.conversation => 'conversation',
    SyncScope.entities => 'entities',
    SyncScope.settings => 'settings',
  };

  static SyncScope parse(String value) => switch (value) {
    'conversation' => SyncScope.conversation,
    'entities' => SyncScope.entities,
    'settings' => SyncScope.settings,
    _ => throw ArgumentError.value(value, 'value', 'unknown sync scope'),
  };
}

typedef SyncDirtyEntry = ({
  SyncScope scope,
  String entityId,
  int firstDirtyAt,
  int lastDirtyAt,
  bool quiet,
});

typedef SyncTombstone = ({
  String kind,
  String entityId,
  int deletedAt,
  String deviceId,
  bool uploaded,
});

/// Tombstone kinds. Message tombstones use
/// `<conversationId>/<messageId>` as entity id; entity tombstones use
/// `entity:<BusinessEntityKind.name>` as kind.
abstract final class SyncTombstoneKind {
  static const conversation = 'conversation';
  static const message = 'message';
  static const preference = 'preference';
  static const entityPrefix = 'entity:';

  static String entity(String kindName) => '$entityPrefix$kindName';

  static String messageId(String conversationId, String messageId) =>
      '$conversationId/$messageId';
}

/// Persistence for the sync engine's local bookkeeping: the dirty queue,
/// tombstones and engine metadata. The `inTransaction` statics are called by
/// the repositories inside their own write transactions so a data change and
/// its dirty marker commit atomically.
final class SyncStateStore {
  SyncStateStore(this._db);

  final AppDatabase _db;

  static const metaHlcMax = 'hlc_max';
  static const metaDeviceId = 'device_id';
  static const metaLastManifestJson = 'last_manifest_json';
  static const metaLastManifestEtag = 'last_manifest_etag';
  static const metaLastRemoteRevision = 'last_remote_revision';
  static const metaConditionalPutSupported = 'cond_put_supported';
  static const metaInitialSyncDone = 'initial_sync_done';
  static const metaLastSyncAt = 'last_sync_at';

  /// Seeds [SyncClock] so timestamps issued after a restart stay above
  /// everything already persisted locally.
  Future<void> initializeClock() async {
    final row = await _db
        .customSelect(
          'SELECT MAX(v) AS floor FROM ('
          'SELECT MAX(updated_at) AS v FROM conversation_rows '
          'UNION ALL SELECT MAX(updated_at) FROM message_rows '
          'UNION ALL SELECT MAX(updated_at) FROM preference_rows '
          'UNION ALL SELECT MAX(updated_at) FROM assistant_rows '
          'UNION ALL SELECT MAX(updated_at) FROM provider_rows '
          'UNION ALL SELECT MAX(deleted_at) FROM sync_tombstone_rows '
          'UNION ALL SELECT MAX(last_dirty_at) FROM sync_dirty_rows '
          "UNION ALL SELECT CAST(value AS INTEGER) FROM sync_meta_rows "
          "WHERE key = '$metaHlcMax'"
          ');',
        )
        .getSingle();
    final floor = row.data['floor'];
    if (floor is int) SyncClock.observe(floor);
  }

  Future<void> persistClockFloor() =>
      writeMeta(metaHlcMax, '${SyncClock.nowMicros()}');

  static Future<void> markDirtyInTransaction(
    GeneratedDatabase db,
    SyncScope scope,
    String entityId, {
    bool quiet = false,
  }) async {
    final now = SyncClock.nowMicros();
    await db.customStatement(
      'INSERT INTO sync_dirty_rows '
      '(scope, entity_id, first_dirty_at, last_dirty_at, quiet) '
      'VALUES (?, ?, ?, ?, ?) '
      'ON CONFLICT(scope, entity_id) DO UPDATE SET '
      'last_dirty_at = excluded.last_dirty_at, '
      'quiet = CASE WHEN sync_dirty_rows.quiet = 0 '
      'OR excluded.quiet = 0 THEN 0 ELSE 1 END;',
      [scope.dbValue, entityId, now, now, quiet ? 1 : 0],
    );
  }

  static Future<void> writeTombstoneInTransaction(
    GeneratedDatabase db, {
    required String kind,
    required String entityId,
    required String deviceId,
    int? deletedAt,
  }) async {
    final at = deletedAt ?? SyncClock.nowMicros();
    await db.customStatement(
      'INSERT INTO sync_tombstone_rows '
      '(kind, entity_id, deleted_at, device_id, uploaded) '
      'VALUES (?, ?, ?, ?, 0) '
      'ON CONFLICT(kind, entity_id) DO UPDATE SET '
      'deleted_at = MAX(sync_tombstone_rows.deleted_at, excluded.deleted_at), '
      'device_id = CASE WHEN excluded.deleted_at > '
      'sync_tombstone_rows.deleted_at THEN excluded.device_id '
      'ELSE sync_tombstone_rows.device_id END, '
      'uploaded = CASE WHEN excluded.deleted_at > '
      'sync_tombstone_rows.deleted_at THEN 0 '
      'ELSE sync_tombstone_rows.uploaded END;',
      [kind, entityId, at, deviceId],
    );
    if (kind == SyncTombstoneKind.conversation) {
      // A deleted conversation can no longer be exported; drop its pending
      // dirty marker and any message tombstones it subsumes.
      await db.customStatement(
        "DELETE FROM sync_dirty_rows WHERE scope = 'conversation' "
        'AND entity_id = ?;',
        [entityId],
      );
      await db.customStatement(
        'DELETE FROM sync_tombstone_rows WHERE kind = ? '
        'AND entity_id LIKE ?;',
        [SyncTombstoneKind.message, '$entityId/%'],
      );
    }
  }

  Future<List<SyncDirtyEntry>> snapshotDirty() async {
    final rows = await _db
        .customSelect(
          'SELECT scope, entity_id, first_dirty_at, last_dirty_at, quiet '
          'FROM sync_dirty_rows ORDER BY first_dirty_at;',
        )
        .get();
    return rows
        .map(
          (row) => (
            scope: SyncScopeName.parse(row.read<String>('scope')),
            entityId: row.read<String>('entity_id'),
            firstDirtyAt: row.read<int>('first_dirty_at'),
            lastDirtyAt: row.read<int>('last_dirty_at'),
            quiet: row.read<int>('quiet') != 0,
          ),
        )
        .toList(growable: false);
  }

  /// True when at least one non-quiet dirty row is pending.
  Future<bool> hasLoudDirty() async {
    final row = await _db
        .customSelect(
          'SELECT COUNT(*) AS c FROM sync_dirty_rows WHERE quiet = 0;',
        )
        .getSingle();
    return row.read<int>('c') > 0;
  }

  /// Clears exactly the captured dirty entries. A row re-dirtied after the
  /// snapshot has a later `last_dirty_at` (the clock is strictly monotonic)
  /// and survives, so no concurrent change is ever lost.
  Future<void> clearDirty(List<SyncDirtyEntry> entries) async {
    if (entries.isEmpty) return;
    await _db.transaction(() async {
      for (final entry in entries) {
        await _db.customStatement(
          'DELETE FROM sync_dirty_rows WHERE scope = ? AND entity_id = ? '
          'AND last_dirty_at <= ?;',
          [entry.scope.dbValue, entry.entityId, entry.lastDirtyAt],
        );
      }
    });
  }

  Future<List<SyncTombstone>> allTombstones() async {
    final rows = await _db
        .customSelect(
          'SELECT kind, entity_id, deleted_at, device_id, uploaded '
          'FROM sync_tombstone_rows;',
        )
        .get();
    return rows
        .map(
          (row) => (
            kind: row.read<String>('kind'),
            entityId: row.read<String>('entity_id'),
            deletedAt: row.read<int>('deleted_at'),
            deviceId: row.read<String>('device_id'),
            uploaded: row.read<int>('uploaded') != 0,
          ),
        )
        .toList(growable: false);
  }

  Future<void> markTombstonesUploaded(List<SyncTombstone> tombstones) async {
    if (tombstones.isEmpty) return;
    await _db.transaction(() async {
      for (final tombstone in tombstones) {
        await _db.customStatement(
          'UPDATE sync_tombstone_rows SET uploaded = 1 '
          'WHERE kind = ? AND entity_id = ? AND deleted_at <= ?;',
          [tombstone.kind, tombstone.entityId, tombstone.deletedAt],
        );
      }
    });
  }

  /// Records tombstones learned from the remote as already uploaded, keeping
  /// the newest deletion time per key.
  Future<void> recordRemoteTombstones(List<SyncTombstone> tombstones) async {
    if (tombstones.isEmpty) return;
    await _db.transaction(() async {
      for (final tombstone in tombstones) {
        await _db.customStatement(
          'INSERT INTO sync_tombstone_rows '
          '(kind, entity_id, deleted_at, device_id, uploaded) '
          'VALUES (?, ?, ?, ?, 1) '
          'ON CONFLICT(kind, entity_id) DO UPDATE SET '
          'deleted_at = '
          'MAX(sync_tombstone_rows.deleted_at, excluded.deleted_at), '
          'uploaded = CASE WHEN excluded.deleted_at >= '
          'sync_tombstone_rows.deleted_at THEN 1 '
          'ELSE sync_tombstone_rows.uploaded END;',
          [
            tombstone.kind,
            tombstone.entityId,
            tombstone.deletedAt,
            tombstone.deviceId,
          ],
        );
      }
    });
  }

  /// Removes a tombstone whose row was resurrected by a newer edit.
  Future<void> removeTombstone(String kind, String entityId) async {
    await _db.customStatement(
      'DELETE FROM sync_tombstone_rows WHERE kind = ? AND entity_id = ?;',
      [kind, entityId],
    );
  }

  /// Prunes uploaded tombstones older than [olderThanMicros].
  Future<void> pruneTombstones({required int olderThanMicros}) async {
    await _db.customStatement(
      'DELETE FROM sync_tombstone_rows WHERE uploaded = 1 '
      'AND deleted_at < ?;',
      [olderThanMicros],
    );
  }

  Future<String?> readMeta(String key) async {
    final rows = await _db.customSelect(
      'SELECT value FROM sync_meta_rows WHERE key = ?;',
      variables: [Variable.withString(key)],
    ).get();
    if (rows.isEmpty) return null;
    return rows.single.read<String>('value');
  }

  Future<void> writeMeta(String key, String value) async {
    await _db.customStatement(
      'INSERT INTO sync_meta_rows (key, value) VALUES (?, ?) '
      'ON CONFLICT(key) DO UPDATE SET value = excluded.value;',
      [key, value],
    );
  }

  Future<void> removeMeta(String key) async {
    await _db.customStatement('DELETE FROM sync_meta_rows WHERE key = ?;', [
      key,
    ]);
  }
}
