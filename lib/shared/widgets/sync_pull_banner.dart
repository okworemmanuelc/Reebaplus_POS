import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/first_download_state.dart';
import 'package:reebaplus_pos/core/providers/manual_refresh.dart';
import 'package:reebaplus_pos/core/services/supabase_sync_service.dart';
import 'package:reebaplus_pos/features/sync/controllers/first_load_overlay_controller.dart';

/// Non-blocking sync-pull status overlay for [MainLayout].
///
/// Syncing is silent (PRD #313). This shows only:
///   - **First download**: a thin [LinearProgressIndicator] pinned to the very
///     top of the body, from a full sign-in until that first download finishes.
///     Never on a PIN unlock or any later background pull.
///   - **Synced**: a brief pill that auto-hides after 2 s, only after a
///     pull-down refresh whose pull really completed.
///   - **First-load overlay / retry card**: the centred "Setting up…"
///     reassurance and the "Couldn't reach your store" card, as the first-load
///     controller says.
///
/// A failed pull shows nothing here: the app retries by itself, and stuck
/// uploads stay visible on the side-menu badge and the Sync Issues screen.
///
/// Mount inside a [Stack] as the last child so it paints above tab content.
class SyncPullBanner extends ConsumerStatefulWidget {
  const SyncPullBanner({super.key});

  @override
  ConsumerState<SyncPullBanner> createState() => _SyncPullBannerState();
}

class _SyncPullBannerState extends ConsumerState<SyncPullBanner> {
  Timer? _successTimer;
  bool _retrying = false;
  PullStage? _lastStage;

  // Whether the success pill should be visible (briefly, after a pull-down
  // refresh that synced).
  bool _showSuccess = false;

  @override
  void dispose() {
    _successTimer?.cancel();
    super.dispose();
  }

  void _showSyncedPill() {
    setState(() => _showSuccess = true);
    _successTimer?.cancel();
    _successTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _showSuccess = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final statusNotifier = ref.watch(pullStatusProvider);
    // The top bar belongs to the first download after a full sign-in, and to
    // nothing else: a periodic, broadcast, reconnect, resume or PIN-unlock pull
    // runs with no bar.
    final firstDownload = ref.watch(firstDownloadInProgressProvider);
    // While the pull-down circle is on screen it is the sole animation —
    // suppress the top progress bar so the two don't animate at once.
    final manualPull = ref.watch(manualPullActiveProvider);
    // "Synced" answers a pull-down refresh whose pull really completed; no
    // other pull, however it ends, shows a pill.
    ref.listen(manualRefreshSyncedProvider, (_, _) => _showSyncedPill());

    // The first-load overlay state machine is the SOLE source of truth for the
    // centered "Setting up…" reassurance and the prominent retry card. This
    // widget only renders it (brief §4.1).
    final overlayState = ref.watch(firstLoadOverlayProvider);
    final businessName = ref.watch(currentBusinessNameProvider);

    return ValueListenableBuilder<PullStatus>(
      valueListenable: statusNotifier,
      builder: (context, status, _) {
        // A re-pull that fails frees the retry card's button straight away.
        if (status.stage != _lastStage) {
          _lastStage = status.stage;
          if (status.stage == PullStage.failed) _retrying = false;
        }

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

        // ── Top: thin progress bar during the first download ────────────
        children.add(
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 250),
              child:
                  firstDownload &&
                      status.stage == PullStage.background &&
                      !manualPull
                  ? LinearProgressIndicator(
                      key: const ValueKey('progress'),
                      minHeight: 2.5,
                      // Determinate once the table count is known so the bar
                      // fills in lock-step with the overlay's percentage; falls
                      // back to indeterminate during the initial fetch window.
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

        // ── Bottom: floating "Synced" pill ──────────────────────────────
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
              child: _showSuccess
                  ? const _SuccessPill(key: ValueKey('success'))
                  : const SizedBox.shrink(key: ValueKey('none')),
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
/// and only while the store is still empty (§4.7 / user stories 12–13).
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

/// Brief success pill, shown after a pull-down refresh that really synced.
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
