import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/providers/sync_provider.dart';
import '../../features/sync/pages/sync_settings_page.dart'
    show confirmManualSyncAction, runSyncEnableFlow;
import '../../icons/lucide_adapter.dart' as lucide;
import '../../l10n/app_localizations.dart';
import '../../shared/widgets/ios_switch.dart';
import '../../theme/app_font_weights.dart';
import '../widgets/desktop_select_dropdown.dart';

class DesktopSyncPane extends StatelessWidget {
  const DesktopSyncPane({super.key});

  static const List<int> _pollPresets = <int>[1, 3, 5, 10, 30];

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

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context)!;
    final sync = context.watch<SyncService>();
    final phase = sync.phase;
    final syncing = phase == SyncPhase.syncing;
    final showError =
        sync.lastError != null &&
        (phase == SyncPhase.retrying ||
            phase == SyncPhase.configError ||
            phase == SyncPhase.needsAppUpdate);

    final pollOptions = <int>[
      ..._pollPresets,
      if (!_pollPresets.contains(sync.pollMinutes)) sync.pollMinutes,
    ]..sort();

    return Container(
      alignment: Alignment.topCenter,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 960),
          child: CustomScrollView(
            slivers: [
              // Title row
              SliverToBoxAdapter(
                child: SizedBox(
                  height: 36,
                  child: Row(
                    children: [
                      Expanded(
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            l10n.syncPageTitle,
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: AppFontWeights.regular,
                              color: cs.onSurface.withValues(alpha: 0.9),
                            ),
                          ),
                        ),
                      ),
                      if (syncing) const SizedBox(width: 8),
                      if (syncing)
                        SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.0,
                            color: cs.primary,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              const SliverToBoxAdapter(child: SizedBox(height: 6)),

              // 同步状态
              SliverToBoxAdapter(
                child: _sectionCard(
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Text(
                        l10n.syncStatusSectionTitle,
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: AppFontWeights.semibold,
                          color: cs.onSurface.withValues(alpha: 0.95),
                        ),
                      ),
                    ),
                    _ItemRow(
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
                              fontSize: 13,
                              color: cs.onSurface.withValues(alpha: 0.75),
                            ),
                          ),
                        ],
                      ),
                    ),
                    _rowDivider(context),
                    _ItemRow(
                      label: l10n.syncLastSyncAt,
                      trailing: Text(
                        _formatTime(sync.lastSyncAt) ?? l10n.syncNeverSynced,
                        style: TextStyle(
                          fontSize: 13,
                          color: cs.onSurface.withValues(alpha: 0.75),
                        ),
                      ),
                    ),
                    if (showError) ...[
                      _rowDivider(context),
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                        child: Row(
                          children: [
                            Icon(
                              lucide.Lucide.TriangleAlert,
                              size: 15,
                              color: cs.error,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                sync.lastError!,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 13,
                                  color: cs.error,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                    if (sync.wallClockLooksSkewed) ...[
                      _rowDivider(context),
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                        child: Row(
                          children: [
                            const Icon(
                              lucide.Lucide.clock,
                              size: 15,
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
                    _rowDivider(context),
                    _ItemRow(
                      label: l10n.syncUploadNow,
                      trailing: _DeskButton(
                        label: l10n.syncUploadNow,
                        filled: true,
                        busy: syncing,
                        onTap: (!sync.isEnabled || syncing)
                            ? null
                            : () =>
                                  confirmManualSyncAction(context, upload: true),
                      ),
                    ),
                    _rowDivider(context),
                    _ItemRow(
                      label: l10n.syncDownloadNow,
                      trailing: _DeskButton(
                        label: l10n.syncDownloadNow,
                        filled: false,
                        busy: syncing,
                        onTap: (!sync.isEnabled || syncing)
                            ? null
                            : () => confirmManualSyncAction(
                                context,
                                upload: false,
                              ),
                      ),
                    ),
                  ],
                ),
              ),

              const SliverToBoxAdapter(child: SizedBox(height: 10)),

              // 同步设置
              SliverToBoxAdapter(
                child: _sectionCard(
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Text(
                        l10n.syncSettingsSectionTitle,
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: AppFontWeights.semibold,
                          color: cs.onSurface.withValues(alpha: 0.95),
                        ),
                      ),
                    ),
                    _ItemRow(
                      label: l10n.syncEnableTitle,
                      vpad: 2,
                      trailing: IosSwitch(
                        value: sync.isEnabled,
                        onChanged: (value) async {
                          if (value) {
                            await runSyncEnableFlow(context);
                          } else {
                            await context.read<SyncService>().setEnabled(
                              false,
                            );
                          }
                        },
                      ),
                    ),
                    _rowDivider(context),
                    _ItemRow(
                      label: l10n.syncBackendSectionTitle,
                      trailing: DesktopSelectDropdown<SyncBackendKind>(
                        value: sync.backend,
                        minWidth: 150,
                        options: [
                          DesktopSelectOption(
                            value: SyncBackendKind.webdav,
                            label: l10n.syncBackendWebDav,
                          ),
                          DesktopSelectOption(
                            value: SyncBackendKind.s3,
                            label: l10n.syncBackendS3,
                          ),
                        ],
                        onSelected: (value) =>
                            context.read<SyncService>().setBackend(value),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          l10n.syncBackendConfigHint,
                          style: TextStyle(
                            fontSize: 12,
                            color: cs.onSurface.withValues(alpha: 0.55),
                          ),
                        ),
                      ),
                    ),
                    _rowDivider(context),
                    _ItemRow(
                      label: l10n.syncPollIntervalSectionTitle,
                      trailing: DesktopSelectDropdown<int>(
                        value: sync.pollMinutes,
                        minWidth: 150,
                        options: [
                          for (final minutes in pollOptions)
                            DesktopSelectOption(
                              value: minutes,
                              label: l10n.syncPollIntervalMinutes(minutes),
                            ),
                        ],
                        onSelected: (value) =>
                            context.read<SyncService>().setPollMinutes(value),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

Widget _rowDivider(BuildContext context) {
  final cs = Theme.of(context).colorScheme;
  final isDark = Theme.of(context).brightness == Brightness.dark;
  return Container(
    height: 1,
    color: cs.outlineVariant.withValues(alpha: isDark ? 0.08 : 0.06),
  );
}

Widget _sectionCard({required List<Widget> children}) {
  return Builder(
    builder: (context) {
      final cs = Theme.of(context).colorScheme;
      final isDark = Theme.of(context).brightness == Brightness.dark;
      final baseBg = isDark
          ? Colors.white10
          : Colors.white.withValues(alpha: 0.96);
      return Container(
        decoration: BoxDecoration(
          color: baseBg,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: cs.outlineVariant.withValues(alpha: isDark ? 0.12 : 0.08),
            width: 0.8,
          ),
        ),
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: children,
        ),
      );
    },
  );
}

class _ItemRow extends StatelessWidget {
  const _ItemRow({required this.label, required this.trailing, this.vpad = 8});

  final String label;
  final Widget trailing;
  final double vpad;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 12, vertical: vpad),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 14,
                color: cs.onSurface.withValues(alpha: 0.88),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Align(alignment: Alignment.centerRight, child: trailing),
        ],
      ),
    );
  }
}

class _DeskButton extends StatefulWidget {
  const _DeskButton({
    required this.label,
    required this.filled,
    required this.onTap,
    this.busy = false,
  });

  final String label;
  final bool filled;
  final VoidCallback? onTap;
  final bool busy;

  @override
  State<_DeskButton> createState() => _DeskButtonState();
}

class _DeskButtonState extends State<_DeskButton> {
  bool _hover = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final enabled = widget.onTap != null;
    final textColor = widget.filled
        ? Colors.white
        : cs.onSurface.withValues(alpha: 0.9);
    final bg = widget.filled
        ? (enabled
              ? (_hover ? cs.primary.withValues(alpha: 0.92) : cs.primary)
              : cs.primary.withValues(alpha: 0.35))
        : (_hover && enabled
              ? (isDark
                    ? Colors.white.withValues(alpha: 0.06)
                    : Colors.black.withValues(alpha: 0.05))
              : Colors.transparent);
    final borderColor = widget.filled
        ? Colors.transparent
        : cs.outlineVariant.withValues(alpha: isDark ? 0.22 : 0.18);
    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: enabled ? (_) => setState(() => _pressed = true) : null,
        onTapUp: enabled ? (_) => setState(() => _pressed = false) : null,
        onTapCancel: enabled ? () => setState(() => _pressed = false) : null,
        onTap: widget.onTap,
        child: AnimatedScale(
          scale: _pressed ? 0.98 : 1.0,
          duration: const Duration(milliseconds: 110),
          curve: Curves.easeOutCubic,
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: borderColor),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (widget.busy) ...[
                  SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: textColor,
                    ),
                  ),
                  const SizedBox(width: 6),
                ],
                Text(
                  widget.label,
                  style: TextStyle(
                    color: textColor,
                    fontWeight: AppFontWeights.semibold,
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
