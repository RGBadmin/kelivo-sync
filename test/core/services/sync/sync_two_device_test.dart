import 'dart:convert';
import 'dart:io';

import 'package:Kelivo/core/database/app_database.dart';
import 'package:Kelivo/core/database/business_data.dart';
import 'package:Kelivo/core/database/business_repository.dart';
import 'package:Kelivo/core/database/chat_database_repository.dart';
import 'package:Kelivo/core/models/chat_message.dart';
import 'package:Kelivo/core/models/conversation.dart';
import 'package:Kelivo/core/services/sync/sync_asset_transfer.dart';
import 'package:Kelivo/core/services/sync/sync_clock.dart';
import 'package:Kelivo/core/services/sync/sync_engine.dart';
import 'package:Kelivo/core/services/sync/sync_merger.dart';
import 'package:Kelivo/core/services/sync/sync_object_codec.dart';
import 'package:Kelivo/core/services/sync/sync_state_store.dart';
import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_sync_remote_store.dart';

final class _Device {
  _Device({
    required this.name,
    required this.directory,
    required this.database,
    required this.chat,
    required this.business,
    required this.stateStore,
    required this.codec,
    required this.engine,
  });

  final String name;
  final Directory directory;
  final AppDatabase database;
  final ChatDatabaseRepository chat;
  final BusinessRepository business;
  final SyncStateStore stateStore;
  final SyncObjectCodec codec;
  final SyncEngine engine;

  Future<void> close() async {
    await database.close();
    if (await directory.exists()) {
      await directory.delete(recursive: true);
    }
  }

  Future<List<String>> conversationIds() async {
    final rows = await database
        .customSelect('SELECT id FROM conversation_rows ORDER BY id;')
        .get();
    return [for (final row in rows) row.data['id'] as String];
  }

  Future<List<Map<String, Object?>>> messages(String conversationId) async {
    final rows = await database
        .customSelect(
          'SELECT id, content, message_order FROM message_rows '
          'WHERE conversation_id = ? ORDER BY message_order;',
          variables: [Variable.withString(conversationId)],
        )
        .get();
    return [for (final row in rows) row.data];
  }

  Future<String?> conversationTitle(String id) async {
    final rows = await database
        .customSelect(
          'SELECT title FROM conversation_rows WHERE id = ?;',
          variables: [Variable.withString(id)],
        )
        .get();
    return rows.isEmpty ? null : rows.single.data['title'] as String;
  }

  Future<Object?> preference(String key) async {
    final rows = await database
        .customSelect(
          'SELECT value FROM preference_rows WHERE key = ?;',
          variables: [Variable.withString(key)],
        )
        .get();
    return rows.isEmpty ? null : jsonDecode(rows.single.data['value'] as String);
  }
}

Future<_Device> _createDevice(String name) async {
  final directory = await Directory.systemTemp.createTemp('kelivo_sync_$name');
  final database = AppDatabase(NativeDatabase.memory());
  await database.customSelect('SELECT 1;').getSingle();
  final chat = ChatDatabaseRepository(database);
  final business = BusinessRepository(database);
  chat.syncDeviceId = name;
  business.syncDeviceId = name;
  final stateStore = SyncStateStore(database);
  final codec = SyncObjectCodec(
    database: database,
    appDataDirectory: directory,
  );
  final engine = SyncEngine(
    database: database,
    stateStore: stateStore,
    codec: codec,
    merger: SyncMerger(database),
    assetTransfer: SyncAssetTransfer(
      database: database,
      appDataDirectory: directory,
    ),
    deviceId: name,
  );
  await engine.ensureConsistentIdentity();
  return _Device(
    name: name,
    directory: directory,
    database: database,
    chat: chat,
    business: business,
    stateStore: stateStore,
    codec: codec,
    engine: engine,
  );
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late FakeSyncRemoteStore remote;
  late _Device deviceA;
  late _Device deviceB;

  setUp(() async {
    SyncClock.resetForTest();
    remote = FakeSyncRemoteStore();
    deviceA = await _createDevice('device-a');
    deviceB = await _createDevice('device-b');
  });

  tearDown(() async {
    await deviceA.close();
    await deviceB.close();
  });

  Future<void> seedConversation(
    _Device device,
    String conversationId, {
    int messageCount = 2,
  }) async {
    await device.chat.putConversation(
      Conversation(id: conversationId, title: 'hello'),
    );
    for (var i = 0; i < messageCount; i++) {
      await device.chat.putMessage(
        ChatMessage(
          id: '$conversationId-m$i',
          role: i.isEven ? 'user' : 'assistant',
          content: 'message $i',
          conversationId: conversationId,
          timestamp: DateTime.fromMillisecondsSinceEpoch(1000000 + i * 1000),
        ),
      );
    }
  }

  test('basic push then pull replicates a conversation', () async {
    await seedConversation(deviceA, 'conv-1');
    await deviceA.engine.fullSync(remote);
    expect(remote.objects.containsKey('manifest.json'), isTrue);
    expect(remote.objects.containsKey('conversations/conv-1.json'), isTrue);

    await deviceB.engine.fullSync(remote);
    expect(await deviceB.conversationIds(), ['conv-1']);
    expect(await deviceB.conversationTitle('conv-1'), 'hello');
    final messages = await deviceB.messages('conv-1');
    expect(messages, hasLength(2));
    expect(messages.first['content'], 'message 0');

    // Convergence: both devices export byte-identical portable objects.
    final exportA = await deviceA.codec.exportConversation('conv-1');
    final exportB = await deviceB.codec.exportConversation('conv-1');
    expect(exportB!.sha256Hex, exportA!.sha256Hex);
  });

  test('diverged edits merge without losing either side', () async {
    await seedConversation(deviceA, 'conv-1');
    await deviceA.engine.fullSync(remote);
    await deviceB.engine.fullSync(remote);

    // A renames; B appends a message. Both offline edits.
    final conversation = Conversation(id: 'conv-1', title: 'renamed by A');
    await deviceA.chat.putConversation(conversation);
    await deviceB.chat.putMessage(
      ChatMessage(
        id: 'conv-1-m9',
        role: 'user',
        content: 'added on B',
        conversationId: 'conv-1',
        timestamp: DateTime.fromMillisecondsSinceEpoch(2000000),
      ),
    );

    await deviceA.engine.fullSync(remote);
    await deviceB.engine.fullSync(remote);
    await deviceA.engine.fullSync(remote);

    expect(await deviceA.conversationTitle('conv-1'), 'renamed by A');
    expect(await deviceB.conversationTitle('conv-1'), 'renamed by A');
    expect(await deviceA.messages('conv-1'), hasLength(3));
    expect(await deviceB.messages('conv-1'), hasLength(3));

    final exportA = await deviceA.codec.exportConversation('conv-1');
    final exportB = await deviceB.codec.exportConversation('conv-1');
    expect(exportB!.sha256Hex, exportA!.sha256Hex);
  });

  test('conversation deletion propagates through tombstones', () async {
    await seedConversation(deviceA, 'conv-1');
    await deviceA.engine.fullSync(remote);
    await deviceB.engine.fullSync(remote);
    expect(await deviceB.conversationIds(), ['conv-1']);

    await deviceA.chat.deleteConversation('conv-1');
    await deviceA.engine.fullSync(remote);
    expect(remote.objects.containsKey('conversations/conv-1.json'), isFalse);

    await deviceB.engine.fullSync(remote);
    expect(await deviceB.conversationIds(), isEmpty);
  });

  test('message deletion propagates and reorders the survivors', () async {
    await seedConversation(deviceA, 'conv-1', messageCount: 3);
    await deviceA.engine.fullSync(remote);
    await deviceB.engine.fullSync(remote);

    await deviceA.chat.deleteMessage('conv-1-m1');
    await deviceA.engine.fullSync(remote);
    await deviceB.engine.fullSync(remote);

    final messages = await deviceB.messages('conv-1');
    expect(messages, hasLength(2));
    expect(messages.map((m) => m['content']), ['message 0', 'message 2']);
    expect(messages.map((m) => m['message_order']), [0, 1]);
  });

  test('a later edit wins over a concurrent deletion', () async {
    await seedConversation(deviceA, 'conv-1');
    await deviceA.engine.fullSync(remote);
    await deviceB.engine.fullSync(remote);

    await deviceA.chat.deleteConversation('conv-1');
    // B edits AFTER the deletion instant.
    await deviceB.chat.updateMessageFields(
      'conv-1-m0',
      content: 'edited on B after deletion',
    );

    await deviceA.engine.fullSync(remote);
    await deviceB.engine.fullSync(remote);
    // B keeps its conversation (edit wins) and pushes it back.
    expect(await deviceB.conversationIds(), ['conv-1']);
    await deviceA.engine.fullSync(remote);
    expect(await deviceA.conversationIds(), ['conv-1']);
    final messages = await deviceA.messages('conv-1');
    expect(
      messages.map((m) => m['content']),
      contains('edited on B after deletion'),
    );
  });

  test('settings sync with per-key LWW', () async {
    await deviceA.business.setPreference('theme_mode_v1', 'dark');
    await deviceA.engine.fullSync(remote);
    await deviceB.engine.fullSync(remote);
    expect(await deviceB.preference('theme_mode_v1'), 'dark');

    await deviceB.business.setPreference('theme_mode_v1', 'light');
    await deviceB.engine.fullSync(remote);
    await deviceA.engine.fullSync(remote);
    expect(await deviceA.preference('theme_mode_v1'), 'light');
  });

  test('entity deletion propagates through tombstones', () async {
    await deviceA.business.upsertEntity(
      BusinessEntityKind.assistant,
      const BusinessEntityValue(
        id: 'assistant-1',
        sortOrder: 0,
        payload: '{"id":"assistant-1","name":"Test"}',
      ),
    );
    await deviceA.engine.fullSync(remote);
    await deviceB.engine.fullSync(remote);
    final rowsOnB = await deviceB.database
        .customSelect('SELECT id FROM assistant_rows;')
        .get();
    expect(rowsOnB, hasLength(1));

    await deviceB.business.deleteEntity(
      BusinessEntityKind.assistant,
      'assistant-1',
    );
    await deviceB.engine.fullSync(remote);
    await deviceA.engine.fullSync(remote);
    final rowsOnA = await deviceA.database
        .customSelect('SELECT id FROM assistant_rows;')
        .get();
    expect(rowsOnA, isEmpty);
  });

  test('attachments travel by content hash and are localized', () async {
    final upload = Directory('${deviceA.directory.path}/upload');
    await upload.create(recursive: true);
    final picture = File('${upload.path}/pic.png');
    await picture.writeAsBytes(const [1, 2, 3, 4, 5]);

    await deviceA.chat.putConversation(
      Conversation(id: 'conv-1', title: 'with image'),
    );
    await deviceA.chat.putMessage(
      ChatMessage(
        id: 'conv-1-m0',
        role: 'user',
        content: 'look [image:${picture.path}]',
        conversationId: 'conv-1',
        timestamp: DateTime.fromMillisecondsSinceEpoch(1000000),
      ),
    );
    await deviceA.engine.fullSync(remote);
    expect(
      remote.objects.keys.where((key) => key.startsWith('assets/')),
      hasLength(1),
    );

    await deviceB.engine.fullSync(remote);
    final messages = await deviceB.messages('conv-1');
    final content = messages.single['content'] as String;
    final match = RegExp(r'\[image:([^\]]+)\]').firstMatch(content)!;
    final localPath = match.group(1)!;
    expect(localPath.contains('kelivo-asset://'), isFalse);
    expect(localPath, contains(deviceB.directory.path));
    expect(await File(localPath).readAsBytes(), [1, 2, 3, 4, 5]);
  });

  test('conditional manifest write conflicts retry and recover', () async {
    await seedConversation(deviceA, 'conv-1');
    var hijacked = false;
    remote.onBeforePut = (path) {
      if (path == 'manifest.json' && !hijacked) {
        hijacked = true;
        // Simulate a concurrent writer bumping the manifest ETag.
        remote.etags['manifest.json'] = 'hijacked';
        remote.objects.putIfAbsent(
          'manifest.json',
          () => remote.objects['manifest.json'] ??
              // A minimal valid empty manifest so the retry can decode it.
              (throw StateError('manifest missing during hijack')),
        );
      }
    };

    // First push: manifest does not exist yet; ifAbsent write hits the
    // hijacked etag only when a manifest exists, so seed one via a full sync
    // from another device first.
    remote.onBeforePut = null;
    await deviceB.business.setPreference('seed_v1', 'x');
    await deviceB.engine.fullSync(remote);
    await deviceA.engine.pullOnce(remote);

    hijacked = false;
    remote.onBeforePut = (path) {
      if (path == 'manifest.json' && !hijacked) {
        hijacked = true;
        remote.etags['manifest.json'] = 'hijacked';
      }
    };
    await deviceA.engine.pushOnce(remote);
    expect(hijacked, isTrue);
    expect(remote.objects.containsKey('conversations/conv-1.json'), isTrue);

    remote.onBeforePut = null;
    await deviceB.engine.fullSync(remote);
    expect(await deviceB.conversationIds(), ['conv-1']);
  });

  test('suppressed writes never mark dirty (no echo loops)', () async {
    await seedConversation(deviceA, 'conv-1');
    await deviceA.engine.fullSync(remote);
    expect(await deviceA.stateStore.snapshotDirty(), isEmpty);

    // Pulling on B applies remote data without creating loud dirty entries
    // that would echo the same bytes back.
    await deviceB.engine.fullSync(remote);
    final dirtyOnB = await deviceB.stateStore.snapshotDirty();
    expect(dirtyOnB.where((entry) => !entry.quiet), isEmpty);
  });
}
