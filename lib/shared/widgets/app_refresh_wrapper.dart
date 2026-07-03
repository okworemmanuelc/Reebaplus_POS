import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';

/// App-wide pull-to-refresh with the **conventional overscroll model** and a
/// single, theme-aware circular spinner.
///
/// **How it arms (the standard behaviour):** a refresh begins only when the
/// scrollable is already at its very top and the user drags *past* the boundary
/// — i.e. an [OverscrollNotification] from an active finger drag. Normal
/// scrolling never triggers it: if you are in the middle of a list and drag
/// down, that drag is spent scrolling back up to the top (and resets any partial
/// pull); you must reach the top and pull *again* to refresh. This matches iOS,
/// Android, and every modern app.
///
/// **Works on short/empty bodies too:** the wrapped subtree is forced to always
/// be scrollable so it can report overscroll even when its content fits — but the
/// override is *composed onto* the platform physics
/// (`AlwaysScrollableScrollPhysics(parent: platform)`), so Android keeps clamping
/// the overscroll: the content does not move, only the spinner does. A
/// parent-less `AlwaysScrollableScrollPhysics` would strip that clamping and let
/// the whole screen drag down — do not reintroduce it.
///
/// **Indicator:** one [CircularProgressIndicator] that descends from the top edge
/// and fills as you overpull, then spins while the sync runs. No background orb.
///
/// **Single animation:** while a manual pull runs, `manualPullActiveProvider` is
/// set so [SyncPullBanner] suppresses its top progress bar. The banner still
/// surfaces the brief "Synced ✓" / "Sync failed · Retry" pill on completion, and
/// still owns automatic/background pulls (no spinner there).
///
/// Wrap each screen's body **as high as possible** so the spinner appears at the
/// top of the screen; the gesture itself is taken from whatever scrollable the
/// user overpulls.
class AppRefreshWrapper extends ConsumerStatefulWidget {
  final Widget child;
  final FutureOr<void> Function()? onRefresh;

  const AppRefreshWrapper({super.key, required this.child, this.onRefresh});

  @override
  ConsumerState<AppRefreshWrapper> createState() => _AppRefreshWrapperState();
}

class _AppRefreshWrapperState extends ConsumerState<AppRefreshWrapper> {
  /// Accumulated active-drag overscroll past the top, in logical px.
  double _pull = 0;

  /// True from the moment a pull fires until the sync settles.
  bool _refreshing = false;

  /// Position-animation duration: zero while the finger drives the spinner
  /// (snappy tracking), 220 ms when it settles back / holds during a refresh.
  Duration _animDuration = Duration.zero;

  /// Overpull (px) needed to fire, and the point the spinner reads as full.
  static const double _triggerThreshold = 100;

  /// Clamp so an aggressive fling can't throw the spinner off-screen.
  static const double _maxPull = 170;

  bool _handleNotification(ScrollNotification n) {
    if (_refreshing) return false;
    // Vertical scrollables only — a horizontal TabBarView swipe must not pull.
    if (n.metrics.axis != Axis.vertical) return false;

    if (n is OverscrollNotification) {
      // overscroll < 0 == pulling DOWN past the top. dragDetails != null keeps us
      // on the active finger, ignoring the ballistic bounce-back (iOS) so a
      // released pull isn't decayed before [ScrollEndNotification] checks it.
      // This is what makes the trigger fire ONLY at the top boundary.
      if (n.overscroll < 0 && n.dragDetails != null) {
        final next = (_pull - n.overscroll).clamp(0.0, _maxPull);
        if (next != _pull) _setPull(next);
      }
    } else if (n is ScrollUpdateNotification) {
      // A real user drag that actually moved the content == normal scrolling, not
      // a pull. Cancel any partial pull. Ballistic updates (dragDetails == null)
      // are ignored so a released overpull survives to ScrollEnd.
      if (_pull != 0 && n.dragDetails != null) _setPull(0);
    } else if (n is ScrollEndNotification) {
      if (_pull >= _triggerThreshold) {
        _onRefresh();
      } else if (_pull != 0) {
        _settleTo(0);
      }
    }
    return false;
  }

  void _setPull(double v) {
    _animDuration = Duration.zero;
    if (mounted) setState(() => _pull = v);
  }

  void _settleTo(double v) {
    _animDuration = const Duration(milliseconds: 220);
    if (mounted) setState(() => _pull = v);
  }

  Future<void> _onRefresh() async {
    HapticFeedback.lightImpact();
    _animDuration = const Duration(milliseconds: 220);
    if (mounted) {
      setState(() {
        _refreshing = true;
        _pull = _triggerThreshold; // hold the spinner at the trigger point
      });
    }
    // Tell SyncPullBanner to stand down: the spinner is the sole animation now.
    // Read up front so it can still be cleared if the widget is disposed
    // mid-pull (the provider is app-scoped, so the controller outlives us).
    final manualPull = ref.read(manualPullActiveProvider.notifier);
    manualPull.state = true;

    try {
      // Floor the spin at ~550 ms so a fast/no-op refresh doesn't flicker.
      await Future.wait([
        _runRefresh(),
        Future<void>.delayed(const Duration(milliseconds: 550)),
      ]);
    } catch (_) {
      // SyncPullBanner already surfaces the failure + Retry.
    } finally {
      manualPull.state = false;
      _animDuration = const Duration(milliseconds: 220);
      if (mounted) {
        setState(() {
          _refreshing = false;
          _pull = 0;
        });
      }
    }
  }

  Future<void> _runRefresh() async {
    // Screen-specific refresh (provider invalidation / local reload).
    await widget.onRefresh?.call();

    final user = ref.read(authProvider).currentUser;
    if (user != null) {
      // Awaited so the spinner keeps spinning for the real duration of the
      // pull; SyncPullBanner independently reflects pullStatus → completed/failed.
      // §3.4 upload-before-download: pull-to-refresh drains the outbox first,
      // then pulls, so a manual refresh uploads pending work before downloading.
      await ref
          .read(supabaseSyncServiceProvider)
          .pushThenPull(user.businessId);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final progress = (_refreshing ? 1.0 : _pull / _triggerThreshold).clamp(
      0.0,
      1.0,
    );
    final visible = _refreshing || _pull > 0.5;
    final spinnerSize = context.getRSize(26);
    final descend = context.getRSize(8) + progress * context.getRSize(22);

    // Force the subtree to always overscroll (so short/empty bodies still report
    // a pull) — composed onto the platform physics so Android keeps clamping (no
    // content drag-down). A parent-less AlwaysScrollableScrollPhysics would strip
    // that clamping.
    final behavior = ScrollConfiguration.of(context);
    final physics = AlwaysScrollableScrollPhysics(
      parent: behavior.getScrollPhysics(context),
    );

    return NotificationListener<ScrollNotification>(
      onNotification: _handleNotification,
      child: Stack(
        children: [
          ScrollConfiguration(
            behavior: behavior.copyWith(physics: physics),
            child: widget.child,
          ),
          AnimatedPositioned(
            duration: _animDuration,
            curve: Curves.easeOut,
            top: visible ? descend : -spinnerSize,
            left: 0,
            right: 0,
            child: IgnorePointer(
              child: AnimatedOpacity(
                opacity: visible ? 1.0 : 0.0,
                duration: const Duration(milliseconds: 150),
                child: Center(
                  child: Transform.scale(
                    scale: 0.7 + 0.3 * progress,
                    child: SizedBox(
                      width: spinnerSize,
                      height: spinnerSize,
                      child: CircularProgressIndicator(
                        strokeWidth: context.getRSize(2.6),
                        value: _refreshing ? null : progress.clamp(0.05, 1.0),
                        color: theme.colorScheme.primary,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
