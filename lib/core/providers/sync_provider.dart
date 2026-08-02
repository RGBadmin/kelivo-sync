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

  /// A pull/push round is running.
  syncing,

  /// Last round failed with a network-ish error; backoff retry scheduled.
  retrying,

  /// Credentials rejected or config invalid; no automatic retries.
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

/// Orchestrates automatic multi-device sync: startup reconcile, debounced
/// push on local changes, periodic remote polling, lifecycle flushes.
class SyncService extends ChangeNotifier
    with WidgetsBindingObserver
    implements SyncWriteObserver {
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
    _chatRepository.syncObserver = this;
    _chatRepository.syncDeviceId = installationId;
    _businessRepository.syncObserver = this;
    _businessRepository.syncDeviceId = installationId;
    WidgetsBinding.instance.addObserver(this);
  }

  static const enabledKey = 'sync_enabled_v1';
  static const backendKey = 'sync_backend_v1';
  static const pollIntervalKey = 'sync_poll_interval_minutes_v1';
  static const webdavConfigKey = 'webdav_config_v1';
  static const s3ConfigKey = 's3_config_v1';
  static const _uploadCountKey = 'sync_upload_count_v1';
  static const _uploadDateKey = 'sync_upload_date_v1';

  /// Quota fuse: when automatic rounds upload more objects than this within
  /// one calendar day, automatic syncing pauses until the next day (manual
  /// upload/download stays available). Normal usage is a few hundred at
  /// most; only a runaway loop can reach this.
  static const dailyUploadBudget = 2000;

  // Rate-limit friendly cadence: WebDAV providers like Jianguoyun throttle
  // aggressively (HTTP 503), so changes coalesce for 10s and automatic
  // rounds never run more often than every 20s.
  static const _debounceDuration = Duration(seconds: 10);
  static const _minAutoRoundGap = Duration(seconds: 20);
  static const _minRetryDelay = Duration(seconds: 5);
  static const _maxRetryDelay = Duration(minutes: 5);
  static const _rateLimitedRetryDelay = Duration(minutes: 3);
  static const defaultPollMinutes = 5;

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
  DateTime? _lastSyncAt;
  DateTime? _lastRoundAt;
  bool _syncing = false;
  bool _followUpRequested = false;
  int _consecutiveFailures = 0;
  bool _disposed = false;
  bool _budgetExhausted = false;
  String? _activity;

  bool get dailyBudgetExhausted => _budgetExhausted;

  /// What the engine is doing right now ("上传会话 …"); null when idle.
  String? get activity => _activity;

  /// A hard cap so no single round can hold "syncing" forever, whatever
  /// happens inside; per-request timeouts keep normal failures much faster.
  static const _roundWatchdog = Duration(minutes: 20);

  static String _todayStamp() =>
      DateTime.now().toIso8601String().substring(0, 10);

  Future<int> _recordUploads(int uploadedObjects) async {
    final preferences = await SharedPreferences.getInstance();
    final today = _todayStamp();
    var total = preferences.getString(_uploadDateKey) == today
        ? (preferences.getInt(_uploadCountKey) ?? 0)
        : 0;
    total += uploadedObjects;
    await preferences.setString(_uploadDateKey, today);
    await preferences.setInt(_uploadCountKey, total);
    if (total > dailyUploadBudget && !_budgetExhausted) {
      _budgetExhausted = true;
      _pollTimer?.cancel();
      _debounceTimer?.cancel();
      _lastError = '今日自动同步上传已达安全上限（$dailyUploadBudget 次），'
          '已暂停自动同步保护存储配额；手动上传/下载仍可用，明日自动恢复';
      _setPhase(SyncPhase.configError);
    } else if (total <= dailyUploadBudget && _budgetExhausted) {
      // New day: the counter reset above re-arms automatic syncing.
      _budgetExhausted = false;
    }
    return total;
  }

  Timer? _debounceTimer;
  Timer? _pollTimer;
  Timer? _retryTimer;

  /// Optional hook the app shell installs to reload settings-backed
  /// providers after remote business data was applied.
  VoidCallback? onBusinessDataApplied;

  SyncPhase get phase => _phase;
  bool get isEnabled => _enabled;
  SyncBackendKind get backend => _backend;
  int get pollMinutes => _pollMinutes;
  String? get lastError => _lastError;
  DateTime? get lastSyncAt => _lastSyncAt;
  bool get wallClockLooksSkewed => SyncClock.wallClockLooksSkewed();

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
      _lastError = '今日自动同步上传已达安全上限（$dailyUploadBudget 次），'
          '已暂停自动同步保护存储配额；手动上传/下载仍可用，明日自动恢复';
      _setPhase(SyncPhase.configError);
      return;
    }
    _startPolling();
    unawaited(_runSync(full: true, auto: false));
  }

  @override
  void dispose() {
    _disposed = true;
    _debounceTimer?.cancel();
    _pollTimer?.cancel();
    _retryTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    if (identical(_chatRepository.syncObserver, this)) {
      _chatRepository.syncObserver = null;
    }
    if (identical(_businessRepository.syncObserver, this)) {
      _businessRepository.syncObserver = null;
    }
    super.dispose();
  }

  AppLifecycleState? _lastLifecycleState;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final previous = _lastLifecycleState;
    _lastLifecycleState = state;
    if (!_enabled) return;
    if (state == AppLifecycleState.paused) {
      _pollTimer?.cancel();
      _pollTimer = null;
      if (_debounceTimer?.isActive ?? false) {
        _debounceTimer!.cancel();
        unawaited(_runSync());
      }
    } else if (state == AppLifecycleState.resumed &&
        previous == AppLifecycleState.paused) {
      // Only a genuine return from background triggers a round; desktop
      // focus changes bounce through inactive/resumed constantly and must
      // not spam the remote. The gap limiter applies (auto: true).
      _startPolling();
      unawaited(_runSync(full: true));
    }
  }

  /// Registered with AppExitFlush: best-effort push of pending changes
  /// before exit. Must never make closing the window feel stuck: skips
  /// instantly when a round is already running or nothing is pending, and
  /// caps the attempt hard — the dirty queue survives in SQLite either way.
  Future<void> flushPendingPush() async {
    if (!_enabled || _syncing) return;
    _debounceTimer?.cancel();
    try {
      final engine = await _ensureEngine();
      final store = _buildStore();
      if (store == null) return;
      if (!await engine.hasPendingLocalChanges()) return;
      await engine.syncOnce(store).timeout(const Duration(seconds: 2));
    } catch (_) {
      // Exit flush is best effort; the dirty queue survives in SQLite.
    }
  }

  // ===== SyncWriteObserver =====

  @override
  void onLocalChange({required SyncScope scope, required bool quiet}) {
    if (!_enabled || quiet || _disposed || _budgetExhausted) return;
    _debounceTimer?.cancel();
    _debounceTimer = Timer(_debounceDuration, () {
      unawaited(_runSync());
    });
  }

  // ===== User actions =====

  Future<void> syncNow() async {
    if (!_enabled) return;
    _retryTimer?.cancel();
    await _runSync(full: true, auto: false);
  }

  /// Manual upload: make the cloud identical to this device.
  Future<void> uploadNow() =>
      _runManual((engine, store) => engine.forceUpload(store));

  /// Manual download: make this device identical to the cloud. Returns the
  /// report so the UI can prompt for a restart when settings changed.
  Future<SyncPullReport?> downloadNow() =>
      _runManual((engine, store) => engine.forceDownload(store));

  Future<SyncPullReport?> _runManual(
    Future<SyncPullReport> Function(SyncEngine engine, SyncRemoteStore store)
    operation,
  ) async {
    if (!_enabled || _syncing) return null;
    final store = _buildStore();
    if (store == null) {
      _lastError = 'sync_backend_not_configured';
      _setPhase(SyncPhase.configError);
      return null;
    }
    _retryTimer?.cancel();
    _syncing = true;
    _lastRoundAt = DateTime.now();
    _setPhase(SyncPhase.syncing);
    try {
      final engine = await _ensureEngine();
      final report = await operation(engine, store).timeout(_roundWatchdog);
      await _applyUiRefresh(report);
      _consecutiveFailures = 0;
      _lastError = null;
      _lastSyncAt = DateTime.now();
      _setPhase(SyncPhase.idle);
      return report;
    } on SyncSchemaTooNewException {
      _lastError = 'sync_schema_too_new';
      _setPhase(SyncPhase.needsAppUpdate);
      return null;
    } on RemoteAuthException catch (error) {
      _lastError = error.message;
      _setPhase(SyncPhase.configError);
      return null;
    } on RemoteRateLimitedException catch (error) {
      _lastError = '服务器限流 (${error.message})，已暂停并将稍后自动重试';
      _setPhase(SyncPhase.retrying);
      return null;
    } catch (error) {
      _lastError = '$error';
      _setPhase(SyncPhase.retrying);
      return null;
    } finally {
      _syncing = false;
    }
  }

  /// Enable flow for the settings UI: switches sync on, creates the remote
  /// directories, then runs the FIRST sync synchronously so the caller can
  /// show progress. With [uploadLocal] the local state force-overwrites the
  /// cloud; otherwise the engine's normal first-sync rule applies (a
  /// populated cloud overwrites this device, and the caller prompts for a
  /// restart). Later rounds are incremental and run in the background.
  Future<SyncPullReport> enableWithInitialSync({
    bool uploadLocal = false,
  }) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setBool(enabledKey, true);
    _enabled = true;
    final store = _buildStore();
    if (store == null) {
      _lastError = 'sync_backend_not_configured';
      _setPhase(SyncPhase.configError);
      throw StateError('sync_backend_not_configured');
    }
    _syncing = true;
    _lastRoundAt = DateTime.now();
    _setPhase(SyncPhase.syncing);
    try {
      final engine = await _ensureEngine();
      // Create kelivo_sync/ and its subdirectories up front; WebDAV servers
      // answer 409 on writes into a missing collection.
      await store.ensureReady();
      final report = uploadLocal
          ? await engine.forceUpload(store).timeout(_roundWatchdog)
          : await engine.syncOnce(store).timeout(_roundWatchdog);
      await _applyUiRefresh(report);
      _consecutiveFailures = 0;
      _lastError = null;
      _lastSyncAt = DateTime.now();
      _setPhase(SyncPhase.idle);
      return report;
    } on RemoteRateLimitedException catch (error) {
      _lastError = '服务器限流 (${error.message})，已暂停并将稍后自动重试';
      _setPhase(SyncPhase.retrying);
      _scheduleRetry(_rateLimitedRetryDelay);
      rethrow;
    } catch (error) {
      _lastError = '$error';
      _setPhase(SyncPhase.retrying);
      _scheduleRetry(_backoffDelay());
      rethrow;
    } finally {
      _syncing = false;
      _startPolling();
      notifyListeners();
    }
  }

  Future<void> setEnabled(bool value) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setBool(enabledKey, value);
    _enabled = value;
    if (value) {
      await _ensureEngine();
      _startPolling();
      _setPhase(SyncPhase.idle);
      unawaited(_runSync(full: true));
    } else {
      _debounceTimer?.cancel();
      _pollTimer?.cancel();
      _retryTimer?.cancel();
      _setPhase(SyncPhase.disabled);
    }
    notifyListeners();
  }

  Future<void> setBackend(SyncBackendKind value) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(
      backendKey,
      value == SyncBackendKind.s3 ? 's3' : 'webdav',
    );
    _backend = value;
    notifyListeners();
    if (_enabled) unawaited(_runSync(full: true));
  }

  Future<void> setPollMinutes(int minutes) async {
    final normalized = minutes.clamp(1, 720);
    final preferences = await SharedPreferences.getInstance();
    await preferences.setInt(pollIntervalKey, normalized);
    _pollMinutes = normalized;
    if (_enabled) _startPolling();
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

  /// True when the selected backend has a plausible configuration.
  bool get backendConfigured => _buildStore() != null;

  // ===== Internals =====

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

  void _startPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(Duration(minutes: _pollMinutes), (_) {
      unawaited(_runSync());
    });
  }

  Future<void> _runSync({bool full = false, bool auto = true}) async {
    if (!_enabled || _disposed) return;
    if (auto && _budgetExhausted) {
      // Re-arm automatically once the calendar day rolls over.
      if (await _recordUploads(0) > dailyUploadBudget) return;
    }
    if (_syncing) {
      _followUpRequested = true;
      return;
    }
    // Automatic rounds keep a minimum gap so a chatty session cannot hammer
    // rate-limited servers; the postponed round is rescheduled, not lost.
    if (auto) {
      final lastRound = _lastRoundAt;
      if (lastRound != null) {
        final sinceLast = DateTime.now().difference(lastRound);
        if (sinceLast < _minAutoRoundGap) {
          _debounceTimer?.cancel();
          _debounceTimer = Timer(_minAutoRoundGap - sinceLast, () {
            unawaited(_runSync(full: full));
          });
          return;
        }
      }
    }
    final store = _buildStore();
    if (store == null) {
      _lastError = 'sync_backend_not_configured';
      _setPhase(SyncPhase.configError);
      return;
    }
    _syncing = true;
    _lastRoundAt = DateTime.now();
    _setPhase(SyncPhase.syncing);
    try {
      final engine = await _ensureEngine();
      // One round = one manifest fetch + mirror in the winning direction.
      final report = await engine.syncOnce(store).timeout(_roundWatchdog);
      await _applyUiRefresh(report);
      await _recordUploads(report.uploadedObjects);
      if (_budgetExhausted) return;
      _consecutiveFailures = 0;
      _lastError = null;
      _lastSyncAt = DateTime.now();
      _setPhase(SyncPhase.idle);
      // Conversations skipped because a generation was still running are
      // NOT retried on a timer: the generation's own completion write is a
      // loud change event that schedules the next push. Event-driven only.
    } on SyncSchemaTooNewException {
      _lastError = 'sync_schema_too_new';
      _setPhase(SyncPhase.needsAppUpdate);
    } on RemoteAuthException catch (error) {
      _lastError = error.message;
      _setPhase(SyncPhase.configError);
    } on RemoteRateLimitedException catch (error) {
      // Hammering a throttled server extends the ban; wait several minutes.
      _consecutiveFailures += 1;
      _lastError = '服务器限流 (${error.message})，已暂停并将稍后自动重试';
      _setPhase(SyncPhase.retrying);
      _scheduleRetry(_rateLimitedRetryDelay * _consecutiveFailures.clamp(1, 5));
    } catch (error) {
      _consecutiveFailures += 1;
      _lastError = '$error';
      _setPhase(SyncPhase.retrying);
      _scheduleRetry(_backoffDelay());
    } finally {
      _syncing = false;
    }
    if (_followUpRequested && _phase == SyncPhase.idle) {
      _followUpRequested = false;
      unawaited(_runSync());
    } else {
      _followUpRequested = false;
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

  Duration _backoffDelay() {
    final exponent = _consecutiveFailures.clamp(1, 10);
    var delay = _minRetryDelay * (1 << (exponent - 1));
    if (delay > _maxRetryDelay) delay = _maxRetryDelay;
    return delay;
  }

  void _scheduleRetry(Duration delay) {
    _retryTimer?.cancel();
    _retryTimer = Timer(delay, () {
      unawaited(_runSync(full: true));
    });
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
