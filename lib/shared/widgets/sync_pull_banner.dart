import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/services/supabase_sync_service.dart';
import 'package:reebaplus_pos/features/sync/controllers/first_load_overlay_controller.dart';

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

    // The first-load overlay state machine is the SOLE source of truth for the
    // centered "Setting up…" reassurance and the prominent retry card. This
    // widget only renders it (brief §4.1).
    final overlayState = ref.watch(firstLoadOverlayProvider);
    final firstLoadActive = ref.watch(firstLoadActiveProvider);
    final businessName = ref.watch(currentBusinessNameProvider);

    return ValueListenableBuilder<PullStatus>(
      valueListenable: statusNotifier,
      builder: (context, status, _) {
        _onStageChanged(status.stage);

        // Live percentage — row-weighted (§4.5) so the bar advances in
        // proportion to data actually restored rather than jumping per table.
        // Falls back to the per-table count, then to indeterminate during the
        // brief window before the snapshot's row count is known.
        final total = status.tablesTotal;
        final done = status.tablesDone;
        final int? percent =
            status.rowPercent ??
            (total > 0 ? ((done / total) * 100).clamp(0, 100).round() : null);

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

        // ── Center: first-load overlay (loading) or retry card ──────────
        // Driven entirely by the first-load controller (§4.1). The `loading`
        // reassurance is non-interactive (IgnorePointer — nav/drawer beneath
        // stay tappable, invariant #11); the `retryNeeded` card IS interactive
        // (a real Retry action), so it must NOT be wrapped in IgnorePointer.
        final Widget centerChild;
        switch (overlayState) {
          case FirstLoadOverlayState.loading:
            centerChild = IgnorePointer(
              child: _LoadingOverlay(
                key: const ValueKey('loading'),
                percent: percent,
                businessName: businessName,
              ),
            );
          case FirstLoadOverlayState.retryNeeded:
            centerChild = _RetryCard(
              key: const ValueKey('retry'),
              retrying: _retrying,
              onRetry: () {
                if (_retrying) return;
                setState(() => _retrying = true);
                ref.read(firstLoadOverlayProvider.notifier).manualRetry();
                // The re-pull drives pullStatus; reset the local flag shortly
                // after so the button can be tapped again if it fails again.
                Future.delayed(const Duration(seconds: 1), () {
                  if (mounted) setState(() => _retrying = false);
                });
              },
            );
          case FirstLoadOverlayState.hidden:
            centerChild = const SizedBox.shrink(key: ValueKey('no-center'));
        }
        children.add(
          Positioned.fill(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 250),
              child: centerChild,
            ),
          ),
        );

        // ── Bottom: floating pill — error / success ─────────────────────
        // During a genuine first load the prominent retry card / skeletons own
        // the failure experience, so the compact error pill is suppressed; it
        // (and the "Synced ✓" pill) keep their existing behaviour for
        // already-populated devices (§4.7).
        final Widget? bottomPill;
        if (status.stage == PullStage.failed &&
            !_errorDismissed &&
            !firstLoadActive) {
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

/// Brief, non-interactive first-load reassurance. Centered in the empty
/// MainLayout shell during the loading window (≤ ~2 s) while the background pull
/// begins streaming data in. Names the business ("Setting up ‹Business›…") so
/// the user trusts the right store is loading (§4.5 / user story 1). [percent]
/// is row-weighted; null during the brief window before the row count is known.
class _LoadingOverlay extends StatelessWidget {
  const _LoadingOverlay({
    super.key,
    required this.percent,
    required this.businessName,
  });

  final int? percent;
  final String businessName;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final primary = t.colorScheme.primary;
    final name = businessName.trim();
    final title = name.isNotEmpty ? 'Setting up $name…' : 'Setting up your store…';

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
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Text(
              title,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: t.colorScheme.onSurface,
              ),
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

/// Prominent, interactive "couldn't reach your store" card. Shown (centered)
/// only after silent retries are exhausted (online) or immediately (offline),
/// and only while the store is still empty — never the small bottom pill in that
/// case (§4.7 / user stories 12–13).
class _RetryCard extends StatelessWidget {
  const _RetryCard({super.key, required this.retrying, required this.onRetry});

  final bool retrying;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final scheme = t.colorScheme;

    return Center(
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 32),
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 28),
        decoration: BoxDecoration(
          color: scheme.surface,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: t.dividerColor),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(
                alpha: t.brightness == Brightness.dark ? 0.4 : 0.08,
              ),
              blurRadius: 16,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off_rounded, size: 40, color: scheme.error),
            const SizedBox(height: 16),
            Text(
              "Couldn't reach your store",
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: scheme.onSurface,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Check your connection and try again. Your data is safe and will '
              'load as soon as we reconnect.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w400,
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: retrying ? null : onRetry,
                style: FilledButton.styleFrom(
                  backgroundColor: scheme.primary,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
                child: retrying
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Text(
                        'Retry',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
              ),
            ),
          ],
        ),
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
