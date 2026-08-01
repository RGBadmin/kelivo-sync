import 'package:Kelivo/core/database/app_database.dart';
import 'package:Kelivo/core/services/sync/sync_clock.dart';
import 'package:Kelivo/core/services/sync/sync_state_store.dart';
import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late AppDatabase database;
  late SyncStateStore store;

  setUp(() async {
    SyncClock.resetForTest();
    database = AppDatabase(NativeDatabase.memory());
    await database.customSelect('SELECT 1;').getSingle();
    store = SyncStateStore(database);
  });

  tearDown(() async {
    await database.close();
  });

  test('clock issues strictly monotonic timestamps', () {
    final first = SyncClock.nowMicros();
    final second = SyncClock.nowMicros();
    expect(second, greaterThan(first));
    SyncClock.observe(second + 1000000);
    expect(SyncClock.nowMicros(), greaterThan(second + 1000000));
  });

  test('markDirty upserts and quiet only escalates to loud', () async {
    await SyncStateStore.markDirtyInTransaction(
      database,
      SyncScope.conversation,
      'conv-1',
      quiet: true,
    );
    var entries = await store.snapshotDirty();
    expect(entries.single.quiet, isTrue);

    await SyncStateStore.markDirtyInTransaction(
      database,
      SyncScope.conversation,
      'conv-1',
    );
    entries = await store.snapshotDirty();
    expect(entries.single.quiet, isFalse);

    // A later quiet mark cannot demote the loud flag.
    await SyncStateStore.markDirtyInTransaction(
      database,
      SyncScope.conversation,
      'conv-1',
      quiet: true,
    );
    entries = await store.snapshotDirty();
    expect(entries.single.quiet, isFalse);
  });

  test('clearDirty is exact: concurrent re-dirty survives', () async {
    await SyncStateStore.markDirtyInTransaction(
      database,
      SyncScope.conversation,
      'conv-1',
    );
    final snapshot = await store.snapshotDirty();

    // A write lands after the snapshot was taken.
    await SyncStateStore.markDirtyInTransaction(
      database,
      SyncScope.conversation,
      'conv-1',
    );
    await store.clearDirty(snapshot);
    expect(await store.snapshotDirty(), hasLength(1));

    final fresh = await store.snapshotDirty();
    await store.clearDirty(fresh);
    expect(await store.snapshotDirty(), isEmpty);
  });

  test('tombstones keep the newest deletion and prune when uploaded', () async {
    await SyncStateStore.writeTombstoneInTransaction(
      database,
      kind: SyncTombstoneKind.conversation,
      entityId: 'conv-1',
      deviceId: 'a',
      deletedAt: 100,
    );
    await SyncStateStore.writeTombstoneInTransaction(
      database,
      kind: SyncTombstoneKind.conversation,
      entityId: 'conv-1',
      deviceId: 'b',
      deletedAt: 50,
    );
    var tombstones = await store.allTombstones();
    expect(tombstones.single.deletedAt, 100);
    expect(tombstones.single.deviceId, 'a');

    await store.markTombstonesUploaded(tombstones);
    tombstones = await store.allTombstones();
    expect(tombstones.single.uploaded, isTrue);

    await store.pruneTombstones(olderThanMicros: 200);
    expect(await store.allTombstones(), isEmpty);
  });

  test('conversation tombstone clears its dirty row and message tombstones',
      () async {
    await SyncStateStore.markDirtyInTransaction(
      database,
      SyncScope.conversation,
      'conv-1',
    );
    await SyncStateStore.writeTombstoneInTransaction(
      database,
      kind: SyncTombstoneKind.message,
      entityId: 'conv-1/msg-1',
      deviceId: 'a',
    );
    await SyncStateStore.writeTombstoneInTransaction(
      database,
      kind: SyncTombstoneKind.conversation,
      entityId: 'conv-1',
      deviceId: 'a',
    );
    expect(await store.snapshotDirty(), isEmpty);
    final tombstones = await store.allTombstones();
    expect(tombstones, hasLength(1));
    expect(tombstones.single.kind, SyncTombstoneKind.conversation);
  });

  test('meta round-trips', () async {
    expect(await store.readMeta('k'), isNull);
    await store.writeMeta('k', 'v1');
    expect(await store.readMeta('k'), 'v1');
    await store.writeMeta('k', 'v2');
    expect(await store.readMeta('k'), 'v2');
    await store.removeMeta('k');
    expect(await store.readMeta('k'), isNull);
  });
}
