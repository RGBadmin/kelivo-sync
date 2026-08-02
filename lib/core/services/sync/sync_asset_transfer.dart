import 'dart:io';

import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../database/app_database.dart';
import 'sync_clock.dart';
import 'sync_object_codec.dart';
import 'sync_remote_store.dart';

/// Moves attachment files between the local content-addressed asset store
/// (`asset_rows`, keyed by SHA-256) and the remote `assets/<hash>` area.
/// Every asset travels at most once per direction.
final class SyncAssetTransfer {
  SyncAssetTransfer({
    required AppDatabase database,
    required Directory appDataDirectory,
  }) : _db = database,
       // ignore: prefer_initializing_formals
       _appDataDirectory = appDataDirectory;

  final AppDatabase _db;
  final Directory _appDataDirectory;

  /// Live activity feed for the status UI.
  void Function(String message)? onActivity;

  static const _knownSubdirs = {'upload', 'images', 'avatars', 'fonts'};

  /// Uploads every referenced asset the remote does not have yet. Returns
  /// hash → size for the manifest's asset map.
  Future<Map<String, int>> uploadMissingAssets(
    Iterable<SyncAssetRef> refs,
    Map<String, int> remoteAssets,
    SyncRemoteStore store,
  ) async {
    final uploaded = <String, int>{};
    for (final ref in refs) {
      if (remoteAssets.containsKey(ref.hash) ||
          uploaded.containsKey(ref.hash)) {
        continue;
      }
      if (!await ref.file.exists()) continue;
      try {
        onActivity?.call('上传附件 ${ref.name}…');
      } catch (_) {}
      await store.putFile('assets/${ref.hash}', ref.file);
      uploaded[ref.hash] = await ref.file.length();
    }
    return uploaded;
  }

  /// Returns the local absolute path for [hash] when the asset is already
  /// present on this device, null otherwise.
  Future<String?> localPathForHash(String hash) async {
    final rows = await _db
        .customSelect(
          'SELECT path FROM asset_rows WHERE content_hash = ?;',
          variables: [Variable.withString(hash)],
        )
        .get();
    if (rows.isEmpty) return null;
    final path = rows.single.read<String>('path');
    return File(path).existsSync() ? path : null;
  }

  /// Makes every wanted asset available locally, downloading the missing
  /// ones. Returns hash → absolute local path for all that succeeded.
  Future<Map<String, String>> ensureLocalAssets(
    SyncRemoteStore store,
    Iterable<({String hash, String subdir, String name})> wanted,
  ) async {
    final resolved = <String, String>{};
    for (final want in wanted) {
      if (resolved.containsKey(want.hash)) continue;
      final existing = await localPathForHash(want.hash);
      if (existing != null) {
        resolved[want.hash] = existing;
        continue;
      }
      final subdir = _knownSubdirs.contains(want.subdir)
          ? want.subdir
          : 'upload';
      final name = _sanitizeName(want.name);
      final shortHash = want.hash.length >= 12
          ? want.hash.substring(0, 12)
          : want.hash;
      final target = File(
        '${_appDataDirectory.path}/$subdir/sync_${shortHash}_$name',
      );
      try {
        onActivity?.call('下载附件 $name…');
      } catch (_) {}
      try {
        final found = await store.getToFile('assets/${want.hash}', target);
        if (!found) continue;
      } catch (_) {
        // Failed downloads leave the portable token in place; a later sync
        // round retries because the hash still cannot be resolved locally.
        continue;
      }
      await _registerAsset(want.hash, target);
      resolved[want.hash] = target.path;
    }
    return resolved;
  }

  Future<void> _registerAsset(String hash, File file) async {
    final now = SyncClock.nowMicros();
    await _db.customStatement(
      'INSERT INTO asset_rows '
      '(id, content_hash, path, byte_size, created_at, last_referenced_at) '
      'VALUES (?, ?, ?, ?, ?, ?) '
      'ON CONFLICT(content_hash) DO UPDATE SET '
      'last_referenced_at = excluded.last_referenced_at;',
      [const Uuid().v4(), hash, file.path, await file.length(), now, now],
    );
  }

  static String _sanitizeName(String name) {
    final cleaned = name.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), '_');
    return cleaned.length > 120 ? cleaned.substring(cleaned.length - 120) : cleaned;
  }
}
