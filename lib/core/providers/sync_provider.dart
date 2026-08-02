// ignore_for_file: prefer_initializing_formals

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../utils/app_directories.dart';
import '../database/business_preferences.dart';
import '../database/business_repository.dart';
import '../database/chat_database_repository.dart';
import '../models/backup.dart';
import '../services/chat/chat_service.dart';
import '../services/sync/s3_sync_remote_store.dart';
import '../services/sync/sync_asset_transfer.dart';
import '../services/sync/sync_clock.dart';
import '../services/sync/sync_engine.dart';
import '../services/sync/sync_manifest.dart';
import '../services/sync/sync_merger.dart';
import '../services/sync/sync_object_codec.dart';
import '../services/sync/sync_remote_store.dart';
import '../services/sync/sync_state_store.dart';
import '../services/sync/sync_write_observer.dart';
import '../services/sync/webdav_sync_remote_store.dart';

export '../services/sync/sync_engine.dart' show SyncPullReport;

enum SyncBackendKind { webdav, s3 }

enum SyncPhase {
  /// Sync switched off on this device.
  disabled,

  /// Enabled and quiet; nothing in flight.
  idle,

  /// A round is running.
  syncing,

  /// Last round failed; the next trigger (message / generation / interval)
  /// retries after the cooldown.
  retrying,

  /// Credentials/config invalid or the daily budget fuse blew; no automatic
  /// activity until the user intervenes (or the day rolls over).
  configError,

  /// The remote was written by a newer schema; user must update the app.
  needsAppUpdate,
}

/// Probe result for the enable-wizard: what already lives on the remote.
typedef SyncRemoteProbe = ({
  bool hasData,
  int revision,
  String lastWriter,
  DateTime? writtenAt,
});

/// Sync scheduler, rebuilt around three explicit push triggers and nothing
/// else:
///
///  1. the user sent a message;
///  2. an AI generation finished;
///  3. a fixed interval tick.
///
/// Every push is incremental — it uploads whatever changed since the last
/// push (creations, edits and deletions alike) and never reads remote
/// changes. Receiving happens exactly twice: the bidirectional
/// newest-wins reconcile at startup, and the manual "download from cloud"
/// button. There are no write observers, no debounce, no retry timers and
/// no lifecycle-triggered rounds.
class SyncService extends ChangeNotifier with WidgetsBindingObserver {
  SyncService({
    required ChatDatabaseRepository chatRepository,
    required BusinessRepository businessRepository,
    required BusinessPreferences businessPreferences,
    required ChatService chatService,
    required String installationId,
  }) : _chatRepository = chatRepository,
       _businessRepository = businessRepository,
       _businessPreferences = businessPreferences,
       _chatService = chatService,
       _installationId = installationId {
    _chatRepository.syncDeviceId = installationId;
    _businessRepository.syncDeviceId = installationId;
    SyncPushSignals.onUserMessageSent = _onChatSignal;
    SyncPushSignals.onGenerationFinished = _onChatSignal;
    WidgetsBinding.instance.addObserver(this);
  }

  // ===== Configuration keys (device-local) =====
  static const enabledKey = 'sync_enabled_v1';
  static const backendKey = 'sync_backend_v1';
  static const pollIntervalKey = 'sync_poll_interval_minutes_v1';
  static const webdavConfigKey = 'webdav_config_v1';
  static const s3ConfigKey = 's3_config_v1';
  static const _uploadCountKey = 'sync_upload_count_v1';
  static const _uploadDateKey = 'sync_upload_date_v1';

  static const defaultPollMinutes = 5;

  /// A chat signal fires the push after a short settle delay so the
  /// follow-up writes of the same action land in the same push.
  static const _signalSettleDelay = Duration(seconds: 2);

  /// After a failed round, triggers are ignored until the cooldown passes;
  /// rate-limited servers get a much longer one.
  static const _errorCooldown = Duration(seconds: 30);
  static const _rateLimitCooldown = Duration(minutes: 3);

  /// A hard cap so no single round can hold "syncing" forever.
  static const _roundWatchdog = Duration(minutes: 20);

  /// Quota fuse: automatic pushes stop for the rest of the day once this
  /// many objects were uploaded within one calendar day. Normal usage is a
  /// few hundred at most; only a runaway loop can reach this.
  static const dailyUploadBudget = 2000;

  final ChatDatabaseRepository _chatRepository;
  final BusinessRepository _businessRepository;
  final BusinessPreferences _businessPreferences;
  final ChatService _chatService;
  final String _installationId;

  SyncEngine? _engine;

  bool _enabled = false;
  SyncBackendKind _backend = SyncBackendKind.webdav;
  int _pollMinutes = defaultPollMinutes;

  SyncPhase _phase = SyncPhase.disabled;
  String? _lastError;
  String? _activity;
  DateTime? _lastSyncAt;
  DateTime? _cooldownUntil;
  bool _running = false;
  bool _budgetExhausted = false;
  bool _disposed = false;

  Timer? _signalTimer;
  Timer? _intervalTimer;
  AppLifecycleState? _lastLifecycleState;

  /// Optional hook the app shell installs to reload settings-backed
  /// providers after remote business data was applied.
  VoidCallback? onBusinessDataApplied;

  // ===== Public state =====
  SyncPhase get phase => _phase;
  bool get isEnabled => _enabled;
  SyncBackendKind get backend => _backend;
  int get pollMinutes => _pollMinutes;
  String? get lastError => _lastError;
  String? get activity => _activity;
  DateTime? get lastSyncAt => _lastSyncAt;
  bool get dailyBudgetExhausted => _budgetExhausted;
  bool get wallClockLooksSkewed => SyncClock.wallClockLooksSkewed();
  bool get backendConfigured => _buildStore() != null;

  // ===== Lifecycle =====

  Future<void> start() async {
    final preferences = await SharedPreferences.getInstance();
    _enabled = preferences.getBool(enabledKey) ?? false;
    _backend = (preferences.getString(backendKey) ?? 'webdav') == 's3'
        ? SyncBackendKind.s3
        : SyncBackendKind.webdav;
    _pollMinutes = preferences.getInt(pollIntervalKey) ?? defaultPollMinutes;
    if (!_enabled) {
      _setPhase(SyncPhase.disabled);
      return;
    }
    _budgetExhausted =
        preferences.getString(_uploadDateKey) == _todayStamp() &&
        (preferences.getInt(_uploadCountKey) ?? 0) > dailyUploadBudget;
    await _ensureEngine();
    if (_budgetExhausted) {
      _lastError = _budgetMessage;
      _setPhase(SyncPhase.configError);
      return;
    }
    _startIntervalTimer();
    // Startup is the one bidirectional moment: newest side wins, applied
    // as an object-level mirror diff.
    unawaited(_runRound((engine, store) => engine.syncOnce(store)));
  }

  @override
  void dispose() {
    _disposed = true;
    _signalTimer?.cancel();
    _intervalTimer?.cancel();
    if (identical(SyncPushSignals.onUserMessageSent, _onChatSignal)) {
      SyncPushSignals.onUserMessageSent = null;
    }
    if (identical(SyncPushSignals.onGenerationFinished, _onChatSignal)) {
      SyncPushSignals.onGenerationFinished = null;
    }
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final previous = _lastLifecycleState;
    _lastLifecycleState = state;
    if (!_enabled) return;
    if (state == AppLifecycleState.paused) {
      // The process may be killed while backgrounded: one bounded push so
      // the last actions reach the cloud. Timers stop meanwhile.
      _intervalTimer?.cancel();
      _intervalTimer = null;
      _signalTimer?.cancel();
      unawaited(flushPendingPush());
    } else if (state == AppLifecycleState.resumed &&
        previous == AppLifecycleState.paused) {
      _startIntervalTimer();
    }
  }

  /// Registered with AppExitFlush: best-effort bounded push of pending
  /// changes. Must never make closing the app feel stuck.
  Future<void> flushPendingPush() async {
    if (!_enabled || _running) return;
    try {
      final engine = await _ensureEngine();
      final store = _buildStore();
      if (store == null) return;
      if (!await engine.hasPendingLocalChanges()) return;
      await engine.pushPending(store).timeout(const Duration(seconds: 2));
    } catch (_) {
      // Best effort; the pending queue survives in SQLite.
    }
  }

  // ===== Triggers =====

  void _onChatSignal() {
    if (!_enabled || _disposed || _budgetExhausted || _inCooldown) return;
    _signalTimer?.cancel();
    _signalTimer = Timer(_signalSettleDelay, () {
      unawaited(_runRound((engine, store) => engine.pushPending(store)));
    });
  }

  void _startIntervalTimer() {
    _intervalTimer?.cancel();
    _intervalTimer = Timer.periodic(Duration(minutes: _pollMinutes), (_) {
      if (_budgetExhausted) {
        unawaited(_maybeReleaseBudget());
        return;
      }
      if (_inCooldown) return;
      unawaited(_runRound((engine, store) => engine.pushPending(store)));
    });
  }

  bool get _inCooldown {
    final until = _cooldownUntil;
    return until != null && DateTime.now().isBefore(until);
  }

  // ===== User actions =====

  /// Manual upload: make the cloud identical to this device.
  Future<void> uploadNow() async {
    await _runRound(
      (engine, store) => engine.forceUpload(store),
      manual: true,
    );
  }

  /// Manual download: make this device identical to the cloud. Returns the
  /// report so the UI can prompt for a restart when settings changed.
  Future<SyncPullReport?> downloadNow() => _runRound(
    (engine, store) => engine.forceDownload(store),
    manual: true,
  );

  Future<void> setEnabled(bool value) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setBool(enabledKey, value);
    _enabled = value;
    if (value) {
      await _ensureEngine();
      _startIntervalTimer();
      _setPhase(SyncPhase.idle);
    } else {
      _signalTimer?.cancel();
      _intervalTimer?.cancel();
      _intervalTimer = null;
      _setPhase(SyncPhase.disabled);
    }
    notifyListeners();
  }

  /// Enable flow for the settings UI: switches sync on and runs the FIRST
  /// round synchronously so the caller can show progress. [uploadLocal]
  /// force-overwrites the cloud with this device; otherwise a populated
  /// cloud overwrites this device (the caller then prompts for a restart).
  Future<SyncPullReport> enableWithInitialSync({
    bool uploadLocal = false,
  }) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setBool(enabledKey, true);
    _enabled = true;
    final report = await _runRound(
      (engine, store) async {
        await store.ensureReady();
        return uploadLocal
            ? await engine.forceUpload(store)
            : await engine.syncOnce(store);
      },
      manual: true,
      rethrowErrors: true,
    );
    _startIntervalTimer();
    if (report == null) throw StateError('sync_busy');
    return report;
  }

  Future<void> setBackend(SyncBackendKind value) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(
      backendKey,
      value == SyncBackendKind.s3 ? 's3' : 'webdav',
    );
    _backend = value;
    notifyListeners();
  }

  Future<void> setPollMinutes(int minutes) async {
    final normalized = minutes.clamp(1, 720);
    final preferences = await SharedPreferences.getInstance();
    await preferences.setInt(pollIntervalKey, normalized);
    _pollMinutes = normalized;
    if (_enabled) _startIntervalTimer();
    notifyListeners();
  }

  /// Checks whether the configured backend already holds sync data (used by
  /// the enable wizard) and that the credentials work.
  Future<SyncRemoteProbe> probeRemote() async {
    final store = _buildStore();
    if (store == null) {
      throw StateError('sync_backend_not_configured');
    }
    final result = await store.getObject(SyncManifest.path);
    if (result is RemoteObjectData) {
      final manifest = SyncManifest.decode(result.bytes);
      return (
        hasData: manifest.objects.isNotEmpty,
        revision: manifest.revision,
        lastWriter: manifest.lastWriter,
        writtenAt: manifest.writtenAt == 0
            ? null
            : DateTime.fromMicrosecondsSinceEpoch(manifest.writtenAt),
      );
    }
    return (hasData: false, revision: 0, lastWriter: '', writtenAt: null);
  }

  // ===== Round execution =====

  Future<SyncPullReport?> _runRound(
    Future<SyncPullReport> Function(SyncEngine engine, SyncRemoteStore store)
    operation, {
    bool manual = false,
    bool rethrowErrors = false,
  }) async {
    if (!_enabled || _disposed || _running) return null;
    if (!manual && _budgetExhausted) return null;
    final store = _buildStore();
    if (store == null) {
      _lastError = 'sync_backend_not_configured';
      _setPhase(SyncPhase.configError);
      if (rethrowErrors) throw StateError('sync_backend_not_configured');
      return null;
    }
    if (manual) _cooldownUntil = null;
    _running = true;
    _setPhase(SyncPhase.syncing);
    try {
      final engine = await _ensureEngine();
      final report = await operation(engine, store).timeout(_roundWatchdog);
      await _applyUiRefresh(report);
      await _recordUploads(report.uploadedObjects);
      _lastError = null;
      _lastSyncAt = DateTime.now();
      _cooldownUntil = null;
      _setPhase(_budgetExhausted ? SyncPhase.configError : SyncPhase.idle);
      if (_budgetExhausted) _lastError = _budgetMessage;
      return report;
    } on SyncSchemaTooNewException {
      _lastError = 'sync_schema_too_new';
      _setPhase(SyncPhase.needsAppUpdate);
      if (rethrowErrors) rethrow;
      return null;
    } on RemoteAuthException catch (error) {
      _lastError = error.message;
      _setPhase(SyncPhase.configError);
      if (rethrowErrors) rethrow;
      return null;
    } on RemoteRateLimitedException catch (error) {
      _lastError = '服务器限流 (${error.message})，暂停片刻后随下次触发重试';
      _cooldownUntil = DateTime.now().add(_rateLimitCooldown);
      _setPhase(SyncPhase.retrying);
      if (rethrowErrors) rethrow;
      return null;
    } catch (error) {
      _lastError = '$error';
      _cooldownUntil = DateTime.now().add(_errorCooldown);
      _setPhase(SyncPhase.retrying);
      if (rethrowErrors) rethrow;
      return null;
    } finally {
      _running = false;
    }
  }

  Future<void> _applyUiRefresh(SyncPullReport report) async {
    if (!report.uiRefreshNeeded) return;
    if (report.businessChanged) {
      await _businessPreferences.applyExternalSnapshot();
      try {
        onBusinessDataApplied?.call();
      } catch (_) {}
    }
    if (report.changedConversationIds.isNotEmpty ||
        report.deletedConversationIds.isNotEmpty) {
      await _chatService.reloadAfterExternalMerge();
    }
  }

  // ===== Budget fuse =====

  static const _budgetMessage =
      '今日自动同步上传已达安全上限（$dailyUploadBudget 次），'
      '已暂停自动同步保护存储配额；手动上传/下载仍可用，明日自动恢复';

  static String _todayStamp() =>
      DateTime.now().toIso8601String().substring(0, 10);

  Future<void> _recordUploads(int uploadedObjects) async {
    final preferences = await SharedPreferences.getInstance();
    final today = _todayStamp();
    var total = preferences.getString(_uploadDateKey) == today
        ? (preferences.getInt(_uploadCountKey) ?? 0)
        : 0;
    total += uploadedObjects;
    await preferences.setString(_uploadDateKey, today);
    await preferences.setInt(_uploadCountKey, total);
    _budgetExhausted = total > dailyUploadBudget;
  }

  Future<void> _maybeReleaseBudget() async {
    final preferences = await SharedPreferences.getInstance();
    if (preferences.getString(_uploadDateKey) != _todayStamp()) {
      _budgetExhausted = false;
      _lastError = null;
      _setPhase(SyncPhase.idle);
    }
  }

  // ===== Wiring =====

  Future<SyncEngine> _ensureEngine() async {
    final existing = _engine;
    if (existing != null) return existing;
    final appDataDirectory = await AppDirectories.getAppDataDirectory();
    final database = _chatRepository.syncDatabase;
    final stateStore = SyncStateStore(database);
    await stateStore.initializeClock();
    final assetTransfer = SyncAssetTransfer(
      database: database,
      appDataDirectory: appDataDirectory,
    );
    final engine = SyncEngine(
      database: database,
      stateStore: stateStore,
      codec: SyncObjectCodec(
        database: database,
        appDataDirectory: appDataDirectory,
      ),
      merger: SyncMerger(database),
      assetTransfer: assetTransfer,
      deviceId: _installationId,
    );
    engine.onActivity = _onEngineActivity;
    assetTransfer.onActivity = _onEngineActivity;
    await engine.ensureConsistentIdentity();
    final lastSyncRaw = await stateStore.readMeta(
      SyncStateStore.metaLastSyncAt,
    );
    final lastSyncMicros = int.tryParse(lastSyncRaw ?? '');
    if (lastSyncMicros != null) {
      _lastSyncAt = DateTime.fromMicrosecondsSinceEpoch(lastSyncMicros);
    }
    _engine = engine;
    return engine;
  }

  SyncRemoteStore? _buildStore() {
    switch (_backend) {
      case SyncBackendKind.webdav:
        final raw = _businessPreferences.get(webdavConfigKey);
        final config = raw is String
            ? WebDavConfig.fromJsonString(raw)
            : const WebDavConfig();
        if (config.url.trim().isEmpty) return null;
        return WebDavSyncRemoteStore(config);
      case SyncBackendKind.s3:
        final raw = _businessPreferences.get(s3ConfigKey);
        final config = raw is String
            ? S3Config.fromJsonString(raw)
            : const S3Config();
        if (config.endpoint.trim().isEmpty ||
            config.bucket.trim().isEmpty ||
            config.accessKeyId.trim().isEmpty ||
            config.secretAccessKey.trim().isEmpty) {
          return null;
        }
        return S3SyncRemoteStore(config);
    }
  }

  void _onEngineActivity(String message) {
    if (_disposed) return;
    _activity = message;
    notifyListeners();
  }

  void _setPhase(SyncPhase phase) {
    if (_disposed) return;
    if (phase != SyncPhase.syncing) _activity = null;
    _phase = phase;
    notifyListeners();
  }
}
