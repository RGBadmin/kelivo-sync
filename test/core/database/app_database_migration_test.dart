import 'dart:io';

import 'package:Kelivo/core/database/app_database.dart';
import 'package:Kelivo/core/database/chat_database_repository.dart';
import 'package:Kelivo/core/database/database_installation_gate.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' as sqlite;

import 'generated_schema/schema_v1.dart' as v1;

void main() {
  test(
    'installation gate creates and validates only the current schema',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'kelivo_current_schema_',
      );
      addTearDown(() async {
        if (await directory.exists()) await directory.delete(recursive: true);
      });

      await DatabaseInstallationGate.ensureReady(appDataDirectory: directory);

      final file = File(p.join(directory.path, AppDatabase.databaseFileName));
      final installed = ChatDatabaseRepository.inspectInstalledDatabase(file);
      expect(installed.schemaVersion, AppDatabase.currentSchemaVersion);
      expect(installed.databaseId, isNotEmpty);
    },
  );

  test(
    'installation gate upgrades a real schema-1 database preserving data',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'kelivo_upgrade_schema_1_',
      );
      addTearDown(() async {
        if (await directory.exists()) await directory.delete(recursive: true);
      });
      final file = File(p.join(directory.path, AppDatabase.databaseFileName));

      // Build a genuine schema-1 database file from the frozen v1 schema.
      final v1Database = v1.DatabaseAtV1(NativeDatabase(file));
      await v1Database.customStatement(
        'INSERT INTO conversation_rows '
        '(id, title, created_at, updated_at) VALUES (?, ?, ?, ?);',
        ['conv-1', 'hello', 1000, 2000],
      );
      await v1Database.customStatement(
        'INSERT INTO message_rows '
        '(id, conversation_id, role, content, timestamp, message_order) '
        'VALUES (?, ?, ?, ?, ?, ?);',
        ['msg-1', 'conv-1', 'user', 'hi', 12345, 0],
      );
      await v1Database.customStatement(
        'INSERT INTO chat_storage_meta_rows (key, value) VALUES (?, ?);',
        ['hive_migration_complete_v1', 'true'],
      );
      await v1Database.close();

      await DatabaseInstallationGate.ensureReady(appDataDirectory: directory);

      final upgraded = sqlite.sqlite3.open(
        file.path,
        mode: sqlite.OpenMode.readOnly,
      );
      try {
        expect(upgraded.userVersion, AppDatabase.currentSchemaVersion);
        final message = upgraded
            .select('SELECT content, updated_at FROM message_rows;')
            .single;
        expect(message['content'], 'hi');
        // updated_at is backfilled from the message timestamp.
        expect(message['updated_at'], 12345);
        final conversation = upgraded
            .select('SELECT title FROM conversation_rows;')
            .single;
        expect(conversation['title'], 'hello');
        final syncTables = upgraded.select(
          "SELECT name FROM sqlite_master WHERE type = 'table' "
          "AND name IN ('sync_dirty_rows', 'sync_tombstone_rows', "
          "'sync_meta_rows');",
        );
        expect(syncTables, hasLength(3));
      } finally {
        upgraded.close();
      }
    },
  );

  test(
    'installation gate rejects every unpublished SQLite schema without mutation',
    () async {
      for (final schemaVersion in <int>[3, 4, 5, 6, 7, 8, 9, 10, 11, 42]) {
        final directory = await Directory.systemTemp.createTemp(
          'kelivo_reject_schema_${schemaVersion}_',
        );
        addTearDown(() async {
          if (await directory.exists()) {
            await directory.delete(recursive: true);
          }
        });
        final file = File(p.join(directory.path, AppDatabase.databaseFileName));
        final database = sqlite.sqlite3.open(file.path);
        database.execute('CREATE TABLE intermediate_only (value TEXT);');
        database.userVersion = schemaVersion;
        database.close();

        await expectLater(
          DatabaseInstallationGate.ensureReady(appDataDirectory: directory),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'message',
              'database_schema_too_new',
            ),
          ),
        );

        final after = sqlite.sqlite3.open(
          file.path,
          mode: sqlite.OpenMode.readOnly,
        );
        try {
          expect(after.userVersion, schemaVersion);
          expect(
            after.select(
              "SELECT name FROM sqlite_master WHERE type='table' AND name=?;",
              ['intermediate_only'],
            ),
            hasLength(1),
          );
        } finally {
          after.close();
        }
      }
    },
  );

  test(
    'installed schema 1 is rejected when a business table is missing',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'kelivo_missing_business_table_',
      );
      addTearDown(() async {
        if (await directory.exists()) await directory.delete(recursive: true);
      });
      final file = File(p.join(directory.path, AppDatabase.databaseFileName));
      final database = AppDatabase.open(file: file);
      await database.customSelect('SELECT 1;').getSingle();
      await database.close();

      final raw = sqlite.sqlite3.open(file.path);
      raw.execute('DROP TABLE preference_rows;');
      raw.close();

      expect(
        () => ChatDatabaseRepository.inspectInstalledDatabase(file),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            'required_tables',
          ),
        ),
      );
    },
  );
}
