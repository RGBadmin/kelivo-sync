import 'dart:io';
import 'dart:typed_data';

/// The remote write was rejected because its precondition (If-Match /
/// If-None-Match) failed: another device updated the object concurrently.
/// The engine reacts by re-pulling, re-merging and retrying.
final class RemotePreconditionFailedException implements Exception {
  const RemotePreconditionFailedException(this.path);

  final String path;

  @override
  String toString() => 'RemotePreconditionFailedException($path)';
}

/// Authentication failed (401/403); surfaced to the UI as a configuration
/// error instead of triggering retries.
final class RemoteAuthException implements Exception {
  const RemoteAuthException(this.message);

  final String message;

  @override
  String toString() => 'RemoteAuthException($message)';
}

sealed class RemoteGetResult {
  const RemoteGetResult();
}

/// 404: the object does not exist.
final class RemoteObjectMissing extends RemoteGetResult {
  const RemoteObjectMissing();
}

/// 304: the object still matches the ETag passed as `ifNoneMatch`.
final class RemoteObjectUnchanged extends RemoteGetResult {
  const RemoteObjectUnchanged();
}

final class RemoteObjectData extends RemoteGetResult {
  const RemoteObjectData(this.bytes, this.etag);

  final Uint8List bytes;
  final String? etag;
}

/// Storage-agnostic remote object store for the sync engine. Paths are
/// forward-slash relative paths under the sync root (e.g.
/// `conversations/<uuid>.json`, `assets/<hash>`); implementations map them
/// onto WebDAV collections or S3 keys.
abstract interface class SyncRemoteStore {
  /// Creates the sync root (and parents) when the backend needs it.
  Future<void> ensureReady();

  /// Reads an object. Pass [ifNoneMatch] (a previous ETag) to allow the
  /// server to answer 304 without transferring the body.
  Future<RemoteGetResult> getObject(String path, {String? ifNoneMatch});

  /// Writes an object and returns the new ETag when the server provides one.
  ///
  /// [ifMatch] makes the write conditional on the current ETag; [ifAbsent]
  /// makes it succeed only when the object does not exist yet. Servers that
  /// honor the conditions throw [RemotePreconditionFailedException] on
  /// conflict; servers that ignore them behave like an unconditional write.
  Future<String?> putObject(
    String path,
    Uint8List bytes, {
    String? ifMatch,
    bool ifAbsent = false,
    String contentType = 'application/json; charset=utf-8',
  });

  /// Streams a local file up as an object (assets; unconditional).
  Future<void> putFile(String path, File file, {String? contentType});

  /// Streams an object down into [destination]. Returns false on 404.
  Future<bool> getToFile(String path, File destination);

  Future<void> deleteObject(String path);
}
