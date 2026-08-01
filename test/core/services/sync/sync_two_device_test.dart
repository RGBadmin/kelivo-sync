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
    return rows.isEmpty
        ? null
        : jsonDecode(rows.single.data['value'] as String);
  }

  Future<List<String>> assistantIds() async {
    final rows = await database
        .customSelect('SELECT id FROM assistant_rows ORDER BY id;')
        .get();
    return [for (final row in rows) row.data['id'] as String];
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

  test('push then initial pull replicates the conversation', () async {
    await seedConversation(deviceA, 'conv-1');
    await deviceA.engine.syncOnce(remote);
    expect(remote.objects.containsKey('manifest.json'), isTrue);
    expect(remote.objects.containsKey('conversations/conv-1.json'), isTrue);

    await deviceB.engine.syncOnce(remote);
    expect(await deviceB.conversationIds(), ['conv-1']);
    expect(await deviceB.conversationTitle('conv-1'), 'hello');
    expect(await deviceB.messages('conv-1'), hasLength(2));

    final exportA = await deviceA.codec.exportConversation('conv-1');
    final exportB = await deviceB.codec.exportConversation('conv-1');
    expect(exportB!.sha256Hex, exportA!.sha256Hex);
  });

  test('diverged edits: the side with the newest change wins wholesale',
      () async {
    await seedConversation(deviceA, 'conv-1');
    await deviceA.engine.syncOnce(remote);
    await deviceB.engine.syncOnce(remote);

    // A renames first, then B appends a message (newer change).
    await deviceA.chat.putConversation(
      Conversation(id: 'conv-1', title: 'renamed by A'),
    );
    await deviceB.chat.putMessage(
      ChatMessage(
        id: 'conv-1-m9',
        role: 'user',
        content: 'added on B',
        conversationId: 'conv-1',
        timestamp: DateTime.fromMillisecondsSinceEpoch(2000000),
      ),
    );

    // B pushes its (newer) state; A's older pending rename is then
    // discarded when the cloud wins on A.
    await deviceB.engine.syncOnce(remote);
    await deviceA.engine.syncOnce(remote);

    expect(await deviceA.conversationTitle('conv-1'), 'hello');
    expect(await deviceB.conversationTitle('conv-1'), 'hello');
    expect(await deviceA.messages('conv-1'), hasLength(3));
    expect(await deviceB.messages('conv-1'), hasLength(3));

    final exportA = await deviceA.codec.exportConversation('conv-1');
    final exportB = await deviceB.codec.exportConversation('conv-1');
    expect(exportB!.sha256Hex, exportA!.sha256Hex);
  });

  test('offline edits newer than the cloud overwrite the cloud', () async {
    await seedConversation(deviceA, 'conv-1');
    await deviceA.engine.syncOnce(remote);
    await deviceB.engine.syncOnce(remote);

    // A pushes a rename; afterwards B (offline until now) makes a NEWER
    // edit and only then syncs: B's state must win.
    await deviceA.chat.putConversation(
      Conversation(id: 'conv-1', title: 'renamed by A'),
    );
    await deviceA.engine.syncOnce(remote);

    await deviceB.chat.putConversation(
      Conversation(id: 'conv-1', title: 'renamed by B later'),
    );
    await deviceB.engine.syncOnce(remote);
    await deviceA.engine.syncOnce(remote);

    expect(await deviceA.conversationTitle('conv-1'), 'renamed by B later');
    expect(await deviceB.conversationTitle('conv-1'), 'renamed by B later');
  });

  test('conversation deletion propagates', () async {
    await seedConversation(deviceA, 'conv-1');
    await deviceA.engine.syncOnce(remote);
    await deviceB.engine.syncOnce(remote);
    expect(await deviceB.conversationIds(), ['conv-1']);

    await deviceA.chat.deleteConversation('conv-1');
    await deviceA.engine.syncOnce(remote);
    expect(remote.objects.containsKey('conversations/conv-1.json'), isFalse);

    await deviceB.engine.syncOnce(remote);
    expect(await deviceB.conversationIds(), isEmpty);
  });

  test('message deletion propagates and reorders the survivors', () async {
    await seedConversation(deviceA, 'conv-1', messageCount: 3);
    await deviceA.engine.syncOnce(remote);
    await deviceB.engine.syncOnce(remote);

    await deviceA.chat.deleteMessage('conv-1-m1');
    await deviceA.engine.syncOnce(remote);
    await deviceB.engine.syncOnce(remote);

    final messages = await deviceB.messages('conv-1');
    expect(messages, hasLength(2));
    expect(messages.map((m) => m['content']), ['message 0', 'message 2']);
    expect(messages.map((m) => m['message_order']), [0, 1]);
  });

  test('a fresh device with seeded defaults never pollutes the cloud',
      () async {
    // Device A is the established install with real data.
    await seedConversation(deviceA, 'conv-1');
    await deviceA.business.upsertEntity(
      BusinessEntityKind.assistant,
      const BusinessEntityValue(
        id: 'real-assistant',
        sortOrder: 0,
        payload: '{"id":"real-assistant","name":"Real"}',
      ),
    );
    await deviceA.engine.syncOnce(remote);

    // Device B is a fresh install that seeded defaults BEFORE enabling
    // sync (this is what every new install does on first launch).
    await deviceB.business.upsertEntity(
      BusinessEntityKind.assistant,
      const BusinessEntityValue(
        id: 'default-assistant',
        sortOrder: 0,
        payload: '{"id":"default-assistant","name":"Default"}',
      ),
    );
    await seedConversation(deviceB, 'default-conv');

    // First sync: the populated cloud is authoritative regardless of the
    // fresh device's newer timestamps.
    await deviceB.engine.syncOnce(remote);
    expect(await deviceB.assistantIds(), ['real-assistant']);
    expect(await deviceB.conversationIds(), ['conv-1']);

    // And the defaults never reached the cloud.
    await deviceA.engine.syncOnce(remote);
    expect(await deviceA.assistantIds(), ['real-assistant']);
    expect(await deviceA.conversationIds(), ['conv-1']);
  });

  test('settings changes flow to the other device', () async {
    await deviceA.business.setPreference('theme_mode_v1', 'dark');
    await deviceA.engine.syncOnce(remote);
    await deviceB.engine.syncOnce(remote);
    expect(await deviceB.preference('theme_mode_v1'), 'dark');

    await deviceB.business.setPreference('theme_mode_v1', 'light');
    await deviceB.engine.syncOnce(remote);
    await deviceA.engine.syncOnce(remote);
    expect(await deviceA.preference('theme_mode_v1'), 'light');
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
    await deviceA.engine.syncOnce(remote);
    expect(
      remote.objects.keys.where((key) => key.startsWith('assets/')),
      hasLength(1),
    );

    await deviceB.engine.syncOnce(remote);
    final messages = await deviceB.messages('conv-1');
    final content = messages.single['content'] as String;
    final match = RegExp(r'\[image:([^\]]+)\]').firstMatch(content)!;
    final localPath = match.group(1)!;
    expect(localPath.contains('kelivo-asset://'), isFalse);
    expect(localPath, contains(deviceB.directory.path));
    expect(await File(localPath).readAsBytes(), [1, 2, 3, 4, 5]);
  });

  test('conditional manifest write conflicts retry and recover', () async {
    await deviceB.business.setPreference('seed_v1', 'x');
    await deviceB.engine.syncOnce(remote);
    await deviceA.engine.syncOnce(remote);

    await seedConversation(deviceA, 'conv-1');
    var hijacked = false;
    remote.onBeforePut = (path) {
      if (path == 'manifest.json' && !hijacked) {
        hijacked = true;
        remote.etags['manifest.json'] = 'hijacked';
      }
    };
    await deviceA.engine.syncOnce(remote);
    expect(hijacked, isTrue);
    expect(remote.objects.containsKey('conversations/conv-1.json'), isTrue);

    remote.onBeforePut = null;
    await deviceB.engine.syncOnce(remote);
    expect(await deviceB.conversationIds(), ['conv-1']);
  });

  test('applying remote state leaves no pending queue (no echo)', () async {
    await seedConversation(deviceA, 'conv-1');
    await deviceA.engine.syncOnce(remote);
    expect(await deviceA.stateStore.snapshotDirty(), isEmpty);

    await deviceB.engine.syncOnce(remote);
    expect(await deviceB.stateStore.snapshotDirty(), isEmpty);
    expect(await deviceB.stateStore.allTombstones(), isEmpty);

    // A no-op follow-up round transfers nothing (304 shortcut path).
    final putsBefore = remote.putCount;
    await deviceB.engine.syncOnce(remote);
    expect(remote.putCount, putsBefore);
  });

  test('repository writes queue loud change events for the push', () async {
    await seedConversation(deviceA, 'conv-1');
    final dirty = await deviceA.stateStore.snapshotDirty();
    expect(dirty, isNotEmpty);
    expect(dirty.any((entry) => !entry.quiet), isTrue);

    await deviceA.business.setPreference('theme_mode_v1', 'dark');
    final withSettings = await deviceA.stateStore.snapshotDirty();
    expect(
      withSettings.any((entry) => entry.scope == SyncScope.settings),
      isTrue,
    );
  });
}
