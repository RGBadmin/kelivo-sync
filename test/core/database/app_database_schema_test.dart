import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:drift_dev/api/migrations_native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:Kelivo/core/database/app_database.dart';

import 'generated_schema/schema.dart';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late SchemaVerifier verifier;

  setUpAll(() {
    verifier = SchemaVerifier(GeneratedHelper());
  });

  test('frozen schema includes and matches current schema 2', () async {
    expect(AppDatabase.currentSchemaVersion, 2);
    expect(GeneratedHelper.versions, [1, AppDatabase.currentSchemaVersion]);
    final database = AppDatabase(NativeDatabase.memory());
    try {
      await database.customSelect('SELECT 1;').getSingle();
      await verifier.migrateAndValidate(
        database,
        AppDatabase.currentSchemaVersion,
        options: const ValidationOptions(validateDropped: true),
      );
    } finally {
      await database.close();
    }
  });

  test('schema 1 upgrades in place to a structurally exact schema 2', () async {
    final connection = await verifier.startAt(1);
    final database = AppDatabase(connection);
    try {
      await verifier.migrateAndValidate(
        database,
        AppDatabase.currentSchemaVersion,
        options: const ValidationOptions(validateDropped: true),
      );
    } finally {
      await database.close();
    }
  });

  test('schema 2 creates every business, asset and sync table', () async {
    final database = AppDatabase(NativeDatabase.memory());
    try {
      final rows = await database
          .customSelect("SELECT name FROM sqlite_master WHERE type = 'table';")
          .get();
      final tables = rows.map((row) => row.read<String>('name')).toSet();

      expect(
        tables,
        containsAll(const {
          'assistant_rows',
          'provider_rows',
          'provider_group_rows',
          'mcp_server_rows',
          'world_book_rows',
          'assistant_memory_rows',
          'quick_phrase_rows',
          'search_service_rows',
          'tts_service_rows',
          'instruction_injection_rows',
          'assistant_tag_rows',
          'preference_rows',
          'asset_rows',
          'message_asset_rows',
          'asset_gc_rows',
          'gc_audit_rows',
          'asset_reference_dirty_rows',
          'sync_dirty_rows',
          'sync_tombstone_rows',
          'sync_meta_rows',
        }),
      );
    } finally {
      await database.close();
    }
  });

  test('unpublished schema is rejected instead of migrated', () async {
    final database = AppDatabase(
      NativeDatabase.memory(
        setup: (rawDatabase) {
          rawDatabase.userVersion = 3;
        },
      ),
    );
    try {
      await expectLater(
        database.customSelect('SELECT 1;').getSingle(),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            'database_schema_version',
          ),
        ),
      );
    } finally {
      await database.close();
    }
  });
}
