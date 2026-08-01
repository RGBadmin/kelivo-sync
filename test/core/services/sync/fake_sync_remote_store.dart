import 'dart:io';
import 'dart:typed_data';

import 'package:Kelivo/core/services/sync/sync_remote_store.dart';

/// In-memory [SyncRemoteStore] shared between simulated devices in tests.
/// Honors If-None-Match on reads and If-Match / If-None-Match:* on the
/// conditional writes, like a well-behaved S3 backend.
final class FakeSyncRemoteStore implements SyncRemoteStore {
  final Map<String, Uint8List> objects = {};
  final Map<String, String> etags = {};
  int _etagCounter = 0;
  int putCount = 0;

  /// Test hook invoked before every putObject; lets a test simulate a
  /// concurrent writer to force a precondition failure.
  void Function(String path)? onBeforePut;

  @override
  Future<void> ensureReady() async {}

  @override
  Future<RemoteGetResult> getObject(String path, {String? ifNoneMatch}) async {
    final bytes = objects[path];
    if (bytes == null) return const RemoteObjectMissing();
    final etag = etags[path];
    if (ifNoneMatch != null && etag != null && etag == ifNoneMatch) {
      return const RemoteObjectUnchanged();
    }
    return RemoteObjectData(Uint8List.fromList(bytes), etag);
  }

  @override
  Future<String?> putObject(
    String path,
    Uint8List bytes, {
    String? ifMatch,
    bool ifAbsent = false,
    String contentType = 'application/json; charset=utf-8',
  }) async {
    onBeforePut?.call(path);
    final current = etags[path];
    if (ifAbsent && current != null) {
      throw RemotePreconditionFailedException(path);
    }
    if (ifMatch != null && current != ifMatch) {
      throw RemotePreconditionFailedException(path);
    }
    objects[path] = Uint8List.fromList(bytes);
    final etag = 'etag-${++_etagCounter}';
    etags[path] = etag;
    putCount++;
    return etag;
  }

  @override
  Future<void> putFile(String path, File file, {String? contentType}) async {
    objects[path] = Uint8List.fromList(await file.readAsBytes());
    etags[path] = 'etag-${++_etagCounter}';
    putCount++;
  }

  @override
  Future<bool> getToFile(String path, File destination) async {
    final bytes = objects[path];
    if (bytes == null) return false;
    await destination.parent.create(recursive: true);
    await destination.writeAsBytes(bytes);
    return true;
  }

  @override
  Future<void> deleteObject(String path) async {
    objects.remove(path);
    etags.remove(path);
  }
}
