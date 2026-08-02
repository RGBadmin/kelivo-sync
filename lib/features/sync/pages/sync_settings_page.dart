import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:Kelivo/theme/app_font_weights.dart';

import '../../../core/providers/sync_provider.dart';
import '../../../core/services/haptics.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/ios_switch.dart';
import '../../../shared/widgets/loading_dialog_card.dart';
import '../../../shared/widgets/restart_app_action.dart';
import '../../../shared/widgets/snackbar.dart';
import '../../../utils/platform_utils.dart';

const List<int> _pollOptions = <int>[1, 3, 5, 10, 30];

String? _formatTime(DateTime? time) {
  if (time == null) return null;
  return time.toLocal().toString().split('.').first;
}

Color _phaseColor(BuildContext context, SyncPhase phase) {
  final cs = Theme.of(context).colorScheme;
  switch (phase) {
    case SyncPhase.idle:
      return Colors.green;
    case SyncPhase.syncing:
      return Colors.blue;
    case SyncPhase.retrying:
      return Colors.orange;
    case SyncPhase.configError:
    case SyncPhase.needsAppUpdate:
      return cs.error;
    case SyncPhase.disabled:
      return Colors.grey;
  }
}

String _phaseLabel(AppLocalizations l10n, SyncPhase phase) {
  switch (phase) {
    case SyncPhase.idle:
      return l10n.syncStatusIdle;
    case SyncPhase.syncing:
      return l10n.syncStatusSyncing;
    case SyncPhase.retrying:
      return l10n.syncStatusRetrying;
    case SyncPhase.configError:
      return l10n.syncStatusConfigError;
    case SyncPhase.needsAppUpdate:
      return l10n.syncStatusNeedsAppUpdate;
    case SyncPhase.disabled:
      return l10n.syncStatusDisabled;
  }
}

/// Shared enable-wizard: probes the remote and asks the user to confirm
/// before switching sync on. Used by both the mobile page and desktop pane.
Future<void> runSyncEnableFlow(BuildContext context) async {
  final l10n = AppLocalizations.of(context)!;
  final sync = context.read<SyncService>();
  if (!sync.backendConfigured) {
    showAppSnackBar(
      context,
      message: l10n.syncNotConfiguredMessage,
      type: NotificationType.error,
    );
    return;
  }

  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => LoadingDialogCard(label: l10n.syncChecking),
  );
  SyncRemoteProbe probe;
  try {
    probe = await sync.probeRemote();
  } catch (error) {
    if (context.mounted) {
      Navigator.of(context, rootNavigator: true).pop();
    }
    if (!context.mounted) return;
    showAppSnackBar(
      context,
      message: l10n.syncProbeFailedMessage('$error'),
      type: NotificationType.error,
    );
    return;
  }
  if (context.mounted) {
    Navigator.of(context, rootNavigator: true).pop();
  }
  if (!context.mounted) return;

  final cs = Theme.of(context).colorScheme;
  final String? direction;
  if (probe.hasData) {
    // Cloud already holds data: the user picks the initialization
    // direction — download (cloud overwrites local) or upload (local
    // overwrites cloud) — or cancels without enabling anything.
    direction = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: cs.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(l10n.syncEnableConfirmTitle),
        content: Text(
          l10n.syncEnableConfirmHasData(
            probe.revision,
            _formatTime(probe.writtenAt) ?? l10n.syncUnknownTime,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(null),
            child: Text(l10n.syncCancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop('upload'),
            child: Text(l10n.syncUploadNow),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop('download'),
            child: Text(l10n.syncDownloadNow),
          ),
        ],
      ),
    );
    if (direction == null) return;
  } else {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: cs.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(l10n.syncEnableConfirmTitle),
        content: Text(l10n.syncEnableConfirmNoData),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(l10n.syncCancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(l10n.syncEnableConfirmOk),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    direction = 'upload';
  }
  if (!context.mounted) return;

  // First sync runs in the foreground: full download/upload with the remote,
  // so the user sees progress and knows when it is safe to restart.
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => LoadingDialogCard(label: l10n.syncInitialSyncing),
  );
  SyncPullReport report;
  try {
    report = await sync.enableWithInitialSync(
      uploadLocal: direction == 'upload',
    );
  } catch (error) {
    if (context.mounted) {
      Navigator.of(context, rootNavigator: true).pop();
      showAppSnackBar(
        context,
        message: l10n.syncProbeFailedMessage('$error'),
        type: NotificationType.error,
      );
    }
    return;
  }
  if (!context.mounted) return;
  Navigator.of(context, rootNavigator: true).pop();

  // Cloud data was pulled in: settings-backed providers only fully refresh
  // on a cold start, so prompt for a restart like the backup restore does.
  if (direction == 'download' && report.uiRefreshNeeded) {
    await showSyncRestartRequiredDialog(context);
  }
}

/// Shared confirm-and-run for the manual upload/download buttons (used by
/// both the mobile page and the desktop pane).
Future<void> confirmManualSyncAction(
  BuildContext context, {
  required bool upload,
}) async {
  final l10n = AppLocalizations.of(context)!;
  final cs = Theme.of(context).colorScheme;
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: cs.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Text(upload ? l10n.syncUploadNow : l10n.syncDownloadNow),
      content: Text(
        upload ? l10n.syncUploadConfirmBody : l10n.syncDownloadConfirmBody,
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: Text(l10n.syncCancel),
        ),
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          child: Text(l10n.syncEnableConfirmOk),
        ),
      ],
    ),
  );
  if (confirmed != true || !context.mounted) return;
  final sync = context.read<SyncService>();
  if (upload) {
    await sync.uploadNow();
    return;
  }
  final report = await sync.downloadNow();
  if (report != null && report.businessChanged && context.mounted) {
    await showSyncRestartRequiredDialog(context);
  }
}

Future<void> showSyncRestartRequiredDialog(BuildContext context) {
  final l10n = AppLocalizations.of(context)!;
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) => AlertDialog(
      backgroundColor: Theme.of(dialogContext).colorScheme.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Text(l10n.syncRestartRequired),
      content: Text(l10n.syncRestartContent),
      actions: [
        TextButton(
          onPressed: () async {
            if (await requestAppRestart(
                  dialogContext,
                  PlatformUtils.restartApp,
                ) &&
                dialogContext.mounted) {
              Navigator.of(dialogContext).pop();
            }
          },
          child: Text(l10n.syncRestartOk),
        ),
      ],
    ),
  );
}

class SyncSettingsPage extends StatelessWidget {
  const SyncSettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final sync = context.watch<SyncService>();
    final phase = sync.phase;
    final syncing = phase == SyncPhase.syncing;
    final showError =
        sync.lastError != null &&
        (phase == SyncPhase.retrying ||
            phase == SyncPhase.configError ||
            phase == SyncPhase.needsAppUpdate);

    Widget header(String text, {bool first = false}) => Padding(
      padding: EdgeInsets.fromLTRB(12, first ? 2 : 18, 12, 6),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 13,
          fontWeight: AppFontWeights.semibold,
          color: cs.onSurface.withValues(alpha: 0.8),
        ),
      ),
    );

    return Scaffold(
      appBar: AppBar(
        leading: Tooltip(
          message: l10n.settingsPageBackButton,
          child: _TactileIconButton(
            icon: Lucide.ArrowLeft,
            color: cs.onSurface,
            size: 22,
            onTap: () => Navigator.of(context).maybePop(),
          ),
        ),
        title: Text(l10n.syncPageTitle),
        actions: const [SizedBox(width: 12)],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          // 状态
          header(l10n.syncStatusSectionTitle, first: true),
          _sectionCard(
            children: [
              _infoRow(
                context,
                label: l10n.syncStatusLabel,
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: _phaseColor(context, phase),
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      _phaseLabel(l10n, phase),
                      style: TextStyle(
                        fontSize: 14,
                        color: cs.onSurface.withValues(alpha: 0.75),
                      ),
                    ),
                  ],
                ),
              ),
              _divider(context),
              _infoRow(
                context,
                label: l10n.syncLastSyncAt,
                trailing: Text(
                  _formatTime(sync.lastSyncAt) ?? l10n.syncNeverSynced,
                  style: TextStyle(
                    fontSize: 14,
                    color: cs.onSurface.withValues(alpha: 0.75),
                  ),
                ),
              ),
              if (showError) ...[
                _divider(context),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  child: Row(
                    children: [
                      Icon(Lucide.TriangleAlert, size: 16, color: cs.error),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          sync.lastError!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 13, color: cs.error),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              if (sync.wallClockLooksSkewed) ...[
                _divider(context),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Lucide.clock,
                        size: 16,
                        color: Colors.orange,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          l10n.syncClockSkewWarning,
                          style: const TextStyle(
                            fontSize: 13,
                            color: Colors.orange,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _SyncNowButton(
                  label: l10n.syncUploadNow,
                  busy: syncing,
                  enabled: sync.isEnabled && !syncing,
                  onTap: () => confirmManualSyncAction(context, upload: true),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _SyncNowButton(
                  label: l10n.syncDownloadNow,
                  busy: syncing,
                  enabled: sync.isEnabled && !syncing,
                  onTap: () => confirmManualSyncAction(context, upload: false),
                ),
              ),
            ],
          ),

          // 同步设置
          header(l10n.syncSettingsSectionTitle),
          _sectionCard(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                child: Row(
                  children: [
                    SizedBox(
                      width: 36,
                      child: Icon(
                        Lucide.RefreshCw,
                        size: 20,
                        color: cs.onSurface.withValues(alpha: 0.9),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        l10n.syncEnableTitle,
                        style: TextStyle(
                          fontSize: 15,
                          color: cs.onSurface.withValues(alpha: 0.9),
                        ),
                      ),
                    ),
                    IosSwitch(
                      value: sync.isEnabled,
                      onChanged: (value) async {
                        if (value) {
                          await runSyncEnableFlow(context);
                        } else {
                          await context.read<SyncService>().setEnabled(false);
                        }
                      },
                    ),
                  ],
                ),
              ),
            ],
          ),

          // 同步后端
          header(l10n.syncBackendSectionTitle),
          _sectionCard(
            children: [
              _optionRow(
                context,
                label: l10n.syncBackendWebDav,
                selected: sync.backend == SyncBackendKind.webdav,
                onTap: () => context.read<SyncService>().setBackend(
                  SyncBackendKind.webdav,
                ),
              ),
              _divider(context),
              _optionRow(
                context,
                label: l10n.syncBackendS3,
                selected: sync.backend == SyncBackendKind.s3,
                onTap: () =>
                    context.read<SyncService>().setBackend(SyncBackendKind.s3),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
            child: Text(
              l10n.syncBackendConfigHint,
              style: TextStyle(
                fontSize: 12,
                color: cs.onSurface.withValues(alpha: 0.55),
              ),
            ),
          ),

          // 轮询间隔
          header(l10n.syncPollIntervalSectionTitle),
          _sectionCard(
            children: [
              for (int i = 0; i < _pollOptions.length; i++) ...[
                if (i > 0) _divider(context),
                _optionRow(
                  context,
                  label: l10n.syncPollIntervalMinutes(_pollOptions[i]),
                  selected: sync.pollMinutes == _pollOptions[i],
                  onTap: () => context.read<SyncService>().setPollMinutes(
                    _pollOptions[i],
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

// ===== iOS-style helpers (visual language mirrors backup_page.dart) =====

Widget _sectionCard({required List<Widget> children}) {
  return Builder(
    builder: (context) {
      final theme = Theme.of(context);
      final cs = theme.colorScheme;
      final isDark = theme.brightness == Brightness.dark;
      final Color bg = isDark
          ? Colors.white10
          : Colors.white.withValues(alpha: 0.96);
      return Container(
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: cs.outlineVariant.withValues(alpha: isDark ? 0.08 : 0.06),
            width: 0.6,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Column(children: children),
        ),
      );
    },
  );
}

Widget _divider(BuildContext context) {
  final cs = Theme.of(context).colorScheme;
  return Divider(
    height: 6,
    thickness: 0.6,
    indent: 12,
    endIndent: 12,
    color: cs.outlineVariant.withValues(alpha: 0.18),
  );
}

Widget _infoRow(
  BuildContext context, {
  required String label,
  required Widget trailing,
}) {
  final cs = Theme.of(context).colorScheme;
  return Padding(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
    child: Row(
      children: [
        Expanded(
          child: Text(
            label,
            style: TextStyle(
              fontSize: 15,
              color: cs.onSurface.withValues(alpha: 0.9),
            ),
          ),
        ),
        const SizedBox(width: 12),
        trailing,
      ],
    ),
  );
}

Widget _optionRow(
  BuildContext context, {
  required String label,
  required bool selected,
  required VoidCallback onTap,
}) {
  return _TactileOptionRow(label: label, selected: selected, onTap: onTap);
}

class _TactileOptionRow extends StatefulWidget {
  const _TactileOptionRow({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_TactileOptionRow> createState() => _TactileOptionRowState();
}

class _TactileOptionRowState extends State<_TactileOptionRow> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) => setState(() => _pressed = false),
      onTapCancel: () => setState(() => _pressed = false),
      onTap: () {
        Haptics.soft();
        widget.onTap();
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        curve: Curves.easeOutCubic,
        color: _pressed
            ? cs.onSurface.withValues(alpha: 0.05)
            : Colors.transparent,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        child: Row(
          children: [
            Expanded(
              child: Text(
                widget.label,
                style: TextStyle(
                  fontSize: 15,
                  color: cs.onSurface.withValues(alpha: 0.9),
                ),
              ),
            ),
            if (widget.selected)
              Icon(Lucide.Check, size: 18, color: cs.primary),
          ],
        ),
      ),
    );
  }
}

class _SyncNowButton extends StatefulWidget {
  const _SyncNowButton({
    required this.label,
    required this.busy,
    required this.enabled,
    required this.onTap,
  });

  final String label;
  final bool busy;
  final bool enabled;
  final VoidCallback onTap;

  @override
  State<_SyncNowButton> createState() => _SyncNowButtonState();
}

class _SyncNowButtonState extends State<_SyncNowButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final enabled = widget.enabled;
    final bg = enabled ? cs.primary : cs.primary.withValues(alpha: 0.35);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: enabled ? (_) => setState(() => _pressed = true) : null,
      onTapUp: enabled ? (_) => setState(() => _pressed = false) : null,
      onTapCancel: enabled ? () => setState(() => _pressed = false) : null,
      onTap: enabled
          ? () {
              Haptics.soft();
              widget.onTap();
            }
          : null,
      child: AnimatedScale(
        scale: _pressed ? 0.97 : 1.0,
        duration: const Duration(milliseconds: 110),
        curve: Curves.easeOutCubic,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 12),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.busy) ...[
                SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: cs.onPrimary,
                  ),
                ),
                const SizedBox(width: 8),
              ],
              Text(
                widget.label,
                style: TextStyle(
                  color: cs.onPrimary,
                  fontWeight: AppFontWeights.semibold,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TactileIconButton extends StatefulWidget {
  const _TactileIconButton({
    required this.icon,
    required this.color,
    required this.onTap,
    this.size = 22,
  });

  final IconData icon;
  final Color color;
  final VoidCallback onTap;
  final double size;

  @override
  State<_TactileIconButton> createState() => _TactileIconButtonState();
}

class _TactileIconButtonState extends State<_TactileIconButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final base = widget.color;
    final press = base.withValues(alpha: 0.7);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) => setState(() => _pressed = false),
      onTapCancel: () => setState(() => _pressed = false),
      onTap: () {
        Haptics.light();
        widget.onTap();
      },
      child: Padding(
        padding: const EdgeInsets.all(6),
        child: Icon(
          widget.icon,
          size: widget.size,
          color: _pressed ? press : base,
        ),
      ),
    );
  }
}
