import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/services/supabase_sync_service.dart';

/// Non-blocking sync-pull status overlay for [MainLayout].
///
/// Three visual states, all minimal and non-intrusive:
///   - **Background pull**: Thin indeterminate [LinearProgressIndicator] pinned
///     to the very top of the body (beneath the status bar). No text, no label.
///   - **Failed**: Compact floating pill anchored above the bottom nav with
///     "Sync failed" and a retry action. Dismissible.
///   - **Completed**: Brief "Synced ✓" pill that auto-hides after 2 s.
///
/// Mount inside a [Stack] as the last child so it paints above tab content.
class SyncPullBanner extends ConsumerStatefulWidget {
  const SyncPullBanner({super.key});

  @override
  ConsumerState<SyncPullBanner> createState() => _SyncPullBannerState();
}

class _SyncPullBannerState extends ConsumerState<SyncPullBanner> {
  Timer? _successTimer;
  bool _errorDismissed = false;
  bool _retrying = false;
  PullStage? _lastStage;

  // Whether the success pill should be visible (briefly, after a pull).
  bool _showSuccess = false;

  @override
  void dispose() {
    _successTimer?.cancel();
    super.dispose();
  }

  void _onStageChanged(PullStage stage) {
    if (stage == _lastStage) return;
    final prev = _lastStage;
    _lastStage = stage;

    switch (stage) {
      case PullStage.background:
        _errorDismissed = false;
        _showSuccess = false;
        _successTimer?.cancel();

      case PullStage.completed:
        if (prev == PullStage.background) {
          _showSuccess = true;
          _successTimer?.cancel();
          _successTimer = Timer(const Duration(seconds: 2), () {
            if (mounted) setState(() => _showSuccess = false);
          });
        }

      case PullStage.failed:
        _retrying = false;
        _showSuccess = false;

      case PullStage.idle:
      case PullStage.minimum:
        _showSuccess = false;
    }
  }

  Future<void> _retry() async {
    if (_retrying) return;
    final sync = ref.read(supabaseSyncServiceProvider);
    final businessId = ref.read(authProvider).currentUser?.businessId;
    if (businessId == null) return;
    setState(() {
      _retrying = true;
      _errorDismissed = false;
    });
    try {
      await sync.pullChanges(businessId);
    } catch (_) {
      // pullChanges already set pullStatus → failed.
    } finally {
      if (mounted) setState(() => _retrying = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final statusNotifier = ref.watch(pullStatusProvider);
    // While the user is pulling-to-refresh, the AppRefreshWrapper orb is the
    // sole animation — suppress this banner's top progress bar so the two don't
    // animate at once. The success / failure pill below still shows.
    final manualPull = ref.watch(manualPullActiveProvider);

    return ValueListenableBuilder<PullStatus>(
      valueListenable: statusNotifier,
      builder: (context, status, _) {
        _onStageChanged(status.stage);

        // Live percentage from the pull's table-restore progress. Null until
        // the snapshot's table count is known (the brief initial-fetch window),
        // so the UI shows a spinning indeterminate state, then fills in.
        final total = status.tablesTotal;
        final done = status.tablesDone;
        final int? percent =
            total > 0 ? ((done / total) * 100).clamp(0, 100).round() : null;

        // Prominent (but non-blocking) first-load indicator: shown while the
        // background catch-up pull streams data into the empty MainLayout shell.
        final bool showLoading =
            status.stage == PullStage.background && !manualPull;

        final children = <Widget>[];

        // ── Top: thin progress bar while syncing ────────────────────────
        children.add(
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 250),
              child: status.stage == PullStage.background && !manualPull
                  ? LinearProgressIndicator(
                      key: const ValueKey('progress'),
                      minHeight: 2.5,
                      // Determinate once the table count is known so the bar
                      // fills in lock-step with the percentage pill; falls back
                      // to indeterminate during the initial fetch window.
                      value: percent != null ? percent / 100 : null,
                      backgroundColor: Theme.of(context)
                          .colorScheme
                          .primary
                          .withValues(alpha: 0.12),
                    )
                  : const SizedBox.shrink(key: ValueKey('no-progress')),
            ),
          ),
        );

        // ── Center: prominent first-load indicator (non-blocking) ───────
        // First login / fresh business: data streams into the empty MainLayout
        // shell. A centered spinner + percentage tells the user something is
        // happening. Wrapped in IgnorePointer so it never gates interaction —
        // the drawer and everything beneath stay tappable (invariant #11).
        children.add(
          Positioned.fill(
            child: IgnorePointer(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 250),
                child: showLoading
                    ? _LoadingOverlay(
                        key: const ValueKey('loading'),
                        percent: percent,
                      )
                    : const SizedBox.shrink(key: ValueKey('no-loading')),
              ),
            ),
          ),
        );

        // ── Bottom: floating pill — error / success ─────────────────────
        final Widget? bottomPill;
        if (status.stage == PullStage.failed && !_errorDismissed) {
          bottomPill = _ErrorPill(
            key: const ValueKey('error'),
            retrying: _retrying,
            onRetry: _retry,
            onDismiss: () => setState(() => _errorDismissed = true),
          );
        } else if (_showSuccess) {
          bottomPill = const _SuccessPill(key: ValueKey('success'));
        } else {
          bottomPill = null;
        }

        children.add(
          Positioned(
            bottom: 8,
            left: 0,
            right: 0,
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 250),
              switchInCurve: Curves.easeOutCubic,
              switchOutCurve: Curves.easeIn,
              transitionBuilder: (child, anim) => SlideTransition(
                position: Tween<Offset>(
                  begin: const Offset(0, 0.5),
                  end: Offset.zero,
                ).animate(anim),
                child: FadeTransition(opacity: anim, child: child),
              ),
              child: bottomPill ?? const SizedBox.shrink(key: ValueKey('none')),
            ),
          ),
        );

        return Stack(children: children);
      },
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Sub-widgets
// ─────────────────────────────────────────────────────────────────────────────

/// Compact floating error pill with retry.
class _ErrorPill extends StatelessWidget {
  const _ErrorPill({
    super.key,
    required this.retrying,
    required this.onRetry,
    required this.onDismiss,
  });

  final bool retrying;
  final VoidCallback onRetry;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final errorColor = t.colorScheme.error;
    final isDark = t.brightness == Brightness.dark;
    final bg = isDark ? const Color(0xFF2C1B1B) : const Color(0xFFFFF0F0);

    return Center(
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 24),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(28),
          border: Border.all(
            color: errorColor.withValues(alpha: 0.25),
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: isDark ? 0.4 : 0.08),
              blurRadius: 12,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off_rounded, size: 16, color: errorColor),
            const SizedBox(width: 8),
            Text(
              'Sync failed',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: errorColor,
              ),
            ),
            Container(
              width: 1,
              height: 16,
              margin: const EdgeInsets.symmetric(horizontal: 10),
              color: errorColor.withValues(alpha: 0.2),
            ),
            GestureDetector(
              onTap: retrying ? null : onRetry,
              behavior: HitTestBehavior.opaque,
              child: retrying
                  ? SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 1.8,
                        color: errorColor,
                      ),
                    )
                  : Text(
                      'Retry',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: errorColor,
                      ),
                    ),
            ),
            const SizedBox(width: 6),
            GestureDetector(
              onTap: onDismiss,
              behavior: HitTestBehavior.opaque,
              child: Padding(
                padding: const EdgeInsets.all(2),
                child: Icon(
                  Icons.close_rounded,
                  size: 14,
                  color: errorColor.withValues(alpha: 0.5),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Prominent (but non-blocking) first-load indicator. Centered in the empty
/// MainLayout shell while the background catch-up pull streams data in. A
/// spinner plus a live percentage derived from how many tables have been
/// restored. [percent] is null during the brief window before the table count
/// is known — it then shows a neutral "getting ready" line under the spinner.
class _LoadingOverlay extends StatelessWidget {
  const _LoadingOverlay({super.key, required this.percent});

  final int? percent;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final primary = t.colorScheme.primary;

    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 36,
            height: 36,
            child: CircularProgressIndicator(strokeWidth: 3, color: primary),
          ),
          const SizedBox(height: 16),
          Text(
            'Loading your store',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: t.colorScheme.onSurface,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            percent != null ? '$percent%' : 'Getting things ready…',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: percent != null ? primary : t.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// Brief success pill.
class _SuccessPill extends StatelessWidget {
  const _SuccessPill({super.key});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final isDark = t.brightness == Brightness.dark;
    const green = Color(0xFF34C759);
    final bg = isDark ? const Color(0xFF1B2C1E) : const Color(0xFFF0FFF4);

    return Center(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(28),
          border: Border.all(color: green.withValues(alpha: 0.25)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: isDark ? 0.4 : 0.08),
              blurRadius: 12,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.check_circle_rounded, size: 15, color: green),
            SizedBox(width: 6),
            Text(
              'Synced',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: green,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
