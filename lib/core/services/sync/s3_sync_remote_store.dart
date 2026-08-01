import 'dart:io';
import 'dart:typed_data';

import '../../models/backup.dart';
import '../backup/s3_client.dart';
import 'sync_remote_store.dart';

/// S3 (and S3-compatible) implementation of [SyncRemoteStore].
///
/// Sync data lives under a dedicated bucket-root prefix (`kelivo_sync/`),
/// deliberately separate from the backup prefix so a sync wipe can never
/// touch backups and vice versa. Conditional writes use `If-Match` /
/// `If-None-Match`, which AWS S3, Cloudflare R2 and MinIO all support.
final class S3SyncRemoteStore implements SyncRemoteStore {
  S3SyncRemoteStore(this._config, {S3BackupClient? client, String? rootPrefix})
    : _client = client ?? const S3BackupClient(),
      _rootPrefix = _normalizeRoot(rootPrefix ?? defaultRootPrefix);

  static const defaultRootPrefix = 'kelivo_sync';

  final S3Config _config;
  final S3BackupClient _client;
  final String _rootPrefix;

  static String _normalizeRoot(String root) {
    final trimmed = root.trim().replaceAll(RegExp(r'^/+|/+$'), '');
    return trimmed.isEmpty ? defaultRootPrefix : trimmed;
  }

  String _key(String path) => '$_rootPrefix/$path';

  @override
  Future<void> ensureReady() async {
    // S3 has no directories; nothing to create.
  }

  @override
  Future<RemoteGetResult> getObject(String path, {String? ifNoneMatch}) =>
      _client.getSyncObject(
        _config,
        key: _key(path),
        ifNoneMatch: ifNoneMatch,
      );

  @override
  Future<String?> putObject(
    String path,
    Uint8List bytes, {
    String? ifMatch,
    bool ifAbsent = false,
    String contentType = 'application/json; charset=utf-8',
  }) => _client.putSyncObject(
    _config,
    key: _key(path),
    bytes: bytes,
    contentType: contentType,
    ifMatch: ifMatch,
    ifAbsent: ifAbsent,
  );

  @override
  Future<void> putFile(String path, File file, {String? contentType}) =>
      _client.putSyncFile(
        _config,
        key: _key(path),
        file: file,
        contentType: contentType ?? 'application/octet-stream',
      );

  @override
  Future<bool> getToFile(String path, File destination) => _client
      .downloadSyncObjectToFile(_config, key: _key(path), destination: destination);

  @override
  Future<void> deleteObject(String path) =>
      _client.deleteSyncObject(_config, key: _key(path));
}
