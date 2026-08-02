import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../../models/backup.dart';
import 'sync_remote_store.dart';

/// WebDAV implementation of [SyncRemoteStore].
///
/// Sync data lives in a dedicated `kelivo_sync/` collection directly under
/// the configured server URL (a sibling of the backup folder, never inside
/// it). Conditional headers (`If-Match` / `If-None-Match`) are always sent;
/// servers that honor them give real concurrency protection, servers that
/// ignore them degrade to last-writer-wins on the manifest — the engine
/// narrows that window by re-reading the manifest right before writing.
final class WebDavSyncRemoteStore implements SyncRemoteStore {
  WebDavSyncRemoteStore(this._config, {String? rootPath})
    : _rootPath = _normalizeRoot(rootPath ?? defaultRootPath);

  static const defaultRootPath = 'kelivo_sync';

  /// A hung connection must never wedge the sync engine in "syncing"
  /// forever: small objects time out fast, file transfers get longer.
  static const _objectTimeout = Duration(seconds: 30);
  static const _fileTimeout = Duration(minutes: 3);

  /// Subdirectories that [ensureReady] creates below the root. WebDAV
  /// requires every intermediate collection to exist before a PUT.
  static const _subCollections = ['conversations', 'entities', 'assets'];

  final WebDavConfig _config;
  final String _rootPath;

  static String _normalizeRoot(String root) {
    final trimmed = root.trim().replaceAll(RegExp(r'^/+|/+$'), '');
    return trimmed.isEmpty ? defaultRootPath : trimmed;
  }

  String get _baseUrl => _config.url.trim().replaceAll(RegExp(r'/+$'), '');

  Uri _objectUri(String path) {
    final child = path.replaceAll(RegExp(r'^/+'), '');
    return Uri.parse('$_baseUrl/$_rootPath/$child');
  }

  Map<String, String> _headers() {
    final headers = <String, String>{};
    if (_config.username.trim().isNotEmpty) {
      final token = base64Encode(
        utf8.encode('${_config.username}:${_config.password}'),
      );
      headers['Authorization'] = 'Basic $token';
    }
    final userAgent = _config.userAgent.trim();
    if (userAgent.isNotEmpty) headers['User-Agent'] = userAgent;
    return headers;
  }

  Never _throwHttp(String operation, Uri uri, int statusCode, [String? body]) {
    if (statusCode == 401 || statusCode == 403) {
      throw RemoteAuthException('WebDAV $operation $uri: HTTP $statusCode');
    }
    if (statusCode == 429 || statusCode == 503) {
      throw RemoteRateLimitedException(
        'WebDAV $operation $uri: HTTP $statusCode',
      );
    }
    throw Exception(
      'WebDAV $operation failed at $uri: HTTP $statusCode'
      '${body == null || body.isEmpty ? '' : ' $body'}',
    );
  }

  @override
  Future<void> ensureReady() async {
    final client = http.Client();
    try {
      final targets = <String>[
        _rootPath,
        for (final sub in _subCollections) '$_rootPath/$sub',
      ];
      for (final target in targets) {
        final uri = Uri.parse('$_baseUrl/$target/');
        final probe = http.Request('PROPFIND', uri);
        probe.headers.addAll({
          'Depth': '0',
          'Content-Type': 'application/xml; charset=utf-8',
          ..._headers(),
        });
        probe.body =
            '<?xml version="1.0" encoding="utf-8" ?>'
            '<d:propfind xmlns:d="DAV:"><d:prop><d:displayname/></d:prop>'
            '</d:propfind>';
        final probeRes = await client
            .send(probe)
            .then(http.Response.fromStream)
          .timeout(_objectTimeout);
        if (probeRes.statusCode == 404) {
          final mkcol = await client
              .send(http.Request('MKCOL', uri)..headers.addAll(_headers()))
              .then(http.Response.fromStream)
          .timeout(_objectTimeout);
          if (mkcol.statusCode != 201 &&
              mkcol.statusCode != 200 &&
              mkcol.statusCode != 405) {
            _throwHttp('MKCOL', uri, mkcol.statusCode);
          }
        } else if (probeRes.statusCode == 401 || probeRes.statusCode == 403) {
          _throwHttp('PROPFIND', uri, probeRes.statusCode);
        } else if (probeRes.statusCode != 207 &&
            (probeRes.statusCode < 200 || probeRes.statusCode >= 400)) {
          _throwHttp('PROPFIND', uri, probeRes.statusCode);
        }
      }
    } finally {
      client.close();
    }
  }

  @override
  Future<RemoteGetResult> getObject(String path, {String? ifNoneMatch}) async {
    final uri = _objectUri(path);
    final client = http.Client();
    try {
      final request = http.Request('GET', uri);
      request.headers.addAll({
        ..._headers(),
        if (ifNoneMatch != null) 'If-None-Match': ifNoneMatch,
      });
      final response = await client
          .send(request)
          .then(http.Response.fromStream)
          .timeout(_objectTimeout);
      switch (response.statusCode) {
        case 200:
          return RemoteObjectData(
            response.bodyBytes,
            response.headers['etag'],
          );
        case 304:
          return const RemoteObjectUnchanged();
        // 409: the parent collection does not exist yet (fresh server) —
        // semantically the object is missing.
        case 404:
        case 409:
          return const RemoteObjectMissing();
        default:
          _throwHttp('GET', uri, response.statusCode);
      }
    } finally {
      client.close();
    }
  }

  @override
  Future<String?> putObject(
    String path,
    Uint8List bytes, {
    String? ifMatch,
    bool ifAbsent = false,
    String contentType = 'application/json; charset=utf-8',
  }) async {
    return _putObjectAttempt(
      path,
      bytes,
      ifMatch: ifMatch,
      ifAbsent: ifAbsent,
      contentType: contentType,
      retryOnMissingCollection: true,
    );
  }

  Future<String?> _putObjectAttempt(
    String path,
    Uint8List bytes, {
    required String? ifMatch,
    required bool ifAbsent,
    required String contentType,
    required bool retryOnMissingCollection,
  }) async {
    final uri = _objectUri(path);
    final client = http.Client();
    try {
      final request = http.Request('PUT', uri);
      request.headers.addAll({
        ..._headers(),
        'Content-Type': contentType,
        if (ifMatch != null) 'If-Match': ifMatch,
        if (ifAbsent) 'If-None-Match': '*',
      });
      request.bodyBytes = bytes;
      final response = await client
          .send(request)
          .then(http.Response.fromStream)
          .timeout(_objectTimeout);
      if (response.statusCode == 412) {
        throw RemotePreconditionFailedException(path);
      }
      // 409 Conflict: the parent collection does not exist yet. Create the
      // sync directories and retry once.
      if (response.statusCode == 409 && retryOnMissingCollection) {
        await ensureReady();
        return _putObjectAttempt(
          path,
          bytes,
          ifMatch: ifMatch,
          ifAbsent: ifAbsent,
          contentType: contentType,
          retryOnMissingCollection: false,
        );
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        _throwHttp('PUT', uri, response.statusCode);
      }
      return response.headers['etag'];
    } finally {
      client.close();
    }
  }

  @override
  Future<void> putFile(String path, File file, {String? contentType}) async {
    await _putFileAttempt(path, file, contentType, true);
  }

  Future<void> _putFileAttempt(
    String path,
    File file,
    String? contentType,
    bool retryOnMissingCollection,
  ) async {
    final uri = _objectUri(path);
    final client = http.Client();
    try {
      final length = await file.length();
      final request = http.StreamedRequest('PUT', uri);
      request.headers.addAll({
        ..._headers(),
        'Content-Type': contentType ?? 'application/octet-stream',
      });
      request.contentLength = length;
      file.openRead().listen(
        request.sink.add,
        onDone: request.sink.close,
        onError: request.sink.addError,
      );
      final response = await client
          .send(request)
          .then(http.Response.fromStream)
          .timeout(_fileTimeout);
      if (response.statusCode == 409 && retryOnMissingCollection) {
        await ensureReady();
        return _putFileAttempt(path, file, contentType, false);
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        _throwHttp('PUT', uri, response.statusCode);
      }
    } finally {
      client.close();
    }
  }

  @override
  Future<bool> getToFile(String path, File destination) async {
    final uri = _objectUri(path);
    final client = http.Client();
    try {
      final request = http.Request('GET', uri);
      request.headers.addAll(_headers());
      final streamed = await client.send(request).timeout(_objectTimeout);
      if (streamed.statusCode == 404 || streamed.statusCode == 409) {
        await streamed.stream.drain<void>();
        return false;
      }
      if (streamed.statusCode < 200 || streamed.statusCode >= 300) {
        final response = await http.Response.fromStream(streamed);
        _throwHttp('GET', uri, response.statusCode);
      }
      await destination.parent.create(recursive: true);
      final sink = destination.openWrite();
      try {
        await streamed.stream.pipe(sink).timeout(_fileTimeout);
      } catch (_) {
        try {
          await sink.close();
        } catch (_) {}
        rethrow;
      }
      return true;
    } finally {
      client.close();
    }
  }

  @override
  Future<void> deleteObject(String path) async {
    final uri = _objectUri(path);
    final client = http.Client();
    try {
      final request = http.Request('DELETE', uri);
      request.headers.addAll(_headers());
      final response = await client
          .send(request)
          .then(http.Response.fromStream)
          .timeout(_objectTimeout);
      if (response.statusCode != 404 &&
          (response.statusCode < 200 || response.statusCode >= 300)) {
        _throwHttp('DELETE', uri, response.statusCode);
      }
    } finally {
      client.close();
    }
  }
}
