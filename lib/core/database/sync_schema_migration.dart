import 'package:sqlite3/common.dart' as sqlite;

/// Stepwise SQL migration from schema 1 to schema 2.
///
/// Schema 2 adds multi-device sync support: the `updated_at` LWW timestamp
/// on `message_rows` plus the `sync_dirty_rows`, `sync_tombstone_rows` and
/// `sync_meta_rows` bookkeeping tables. The statements are shared by the two
/// upgrade entry points — drift's `onUpgrade` (databases opened through
/// [AppDatabase]) and the raw sqlite3 path used by the startup gate and
/// backup snapshot preparation — so both produce the same structure as a
/// fresh schema-2 install.
abstract final class SyncSchemaMigration {
  static const fromVersion = 1;
  static const toVersion = 2;

  static List<String> statementsV1ToV2() => const [
    'ALTER TABLE "message_rows" '
        'ADD COLUMN "updated_at" INTEGER NOT NULL DEFAULT 0;',
    'UPDATE "message_rows" SET "updated_at" = "timestamp";',
    'CREATE INDEX IF NOT EXISTS "idx_messages_updated_at" '
        'ON "message_rows" ("updated_at");',
    'CREATE TABLE IF NOT EXISTS "sync_dirty_rows" ('
        '"scope" TEXT NOT NULL CHECK ("scope" IN (\'conversation\', '
        '\'entities\', \'settings\')), '
        '"entity_id" TEXT NOT NULL, '
        '"first_dirty_at" INTEGER NOT NULL, '
        '"last_dirty_at" INTEGER NOT NULL, '
        '"quiet" INTEGER NOT NULL DEFAULT 1 CHECK ("quiet" IN (0, 1)), '
        'PRIMARY KEY ("scope", "entity_id"));',
    'CREATE TABLE IF NOT EXISTS "sync_tombstone_rows" ('
        '"kind" TEXT NOT NULL CHECK ("kind" IS NOT \'\'), '
        '"entity_id" TEXT NOT NULL, '
        '"deleted_at" INTEGER NOT NULL, '
        '"device_id" TEXT NOT NULL, '
        '"uploaded" INTEGER NOT NULL DEFAULT 0 CHECK ("uploaded" IN (0, 1)), '
        'PRIMARY KEY ("kind", "entity_id"));',
    'CREATE TABLE IF NOT EXISTS "sync_meta_rows" ('
        '"key" TEXT NOT NULL, '
        '"value" TEXT NOT NULL, '
        'PRIMARY KEY ("key"));',
  ];

  /// Upgrades a raw sqlite3 handle from schema 1 to schema 2 in a single
  /// transaction, including the `user_version` bump. Throws
  /// `StateError('database_schema_version')` when the handle is not at
  /// schema 1.
  static void migrateRaw(sqlite.CommonDatabase database) {
    if (database.userVersion != fromVersion) {
      throw StateError('database_schema_version');
    }
    database.execute('BEGIN IMMEDIATE;');
    try {
      for (final statement in statementsV1ToV2()) {
        database.execute(statement);
      }
      database.execute('PRAGMA user_version = $toVersion;');
      database.execute('COMMIT;');
    } catch (_) {
      database.execute('ROLLBACK;');
      rethrow;
    }
  }
}
