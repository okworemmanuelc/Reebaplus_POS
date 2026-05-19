import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/services/supabase_sync_service.dart';
import 'package:reebaplus_pos/features/sync/screens/sync_issues_screen.dart';

/// Top-of-`MainLayout` banner that surfaces the background data-pull
/// state machine. Renders nothing when pull is idle or in the pre-mount
/// `minimum` stage; expands to a 36px row plus optional progress bar
/// during `background`; shows graduated copy on `failed` based on the
/// persisted `consecutive_pull_failures::<biz>` count; flashes
/// "Caught up." for 2s on `completed` before auto-collapsing.
///
/// Tap target routes to [SyncIssuesScreen] for `background` and the
/// high-failure-count `failed` state; for low-failure-count `failed`
/// it directly retries `pullChanges` so the user doesn't have to
/// navigate to clear the banner.
class SyncBanner extends ConsumerStatefulWidget {
  const SyncBanner({super.key});

  @override
  ConsumerState<SyncBanner> createState() => _SyncBannerState();
}

class _SyncBannerState extends ConsumerState<SyncBanner> {
  /// Auto-hide timer. The banner surfaces a state change for [_autoHideAfter]
  /// then collapses; ongoing sync state lives in the drawer's "Sync Issues"
  /// badge and the SyncIssuesScreen. Re-shows on every stage transition.
  static const _autoHideAfter = Duration(seconds: 3);
  Timer? _autoHideTimer;
  bool _autoHidden = false;
  int _failureCount = 0;
  PullStage? _lastStage;

  @override
  void initState() {
    super.initState();
    unawaited(_loadFailureCount());
  }

  @override
  void dispose() {
    _autoHideTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadFailureCount() async {
    final businessId = ref.read(authProvider).currentUser?.businessId;
    if (businessId == null) return;
    final prefs = await SharedPreferences.getInstance();
    final n = prefs.getInt('consecutive_pull_failures::$businessId') ?? 0;
    if (mounted && n != _failureCount) {
      setState(() => _failureCount = n);
    }
  }

  void _onStageEntered(PullStage stage) {
    // Refresh the persisted failure count on every transition — pullChanges
    // increments or resets the prefs key as it ends.
    unawaited(_loadFailureCount());
    _autoHideTimer?.cancel();
    _autoHidden = false;
    // Idle/minimum render shrink unconditionally — no auto-hide needed.
    // For every other stage, surface the change for 3s then collapse.
    // Ongoing state is still observable via the drawer sync badge and
    // the SyncIssuesScreen "Catching up" card.
    if (stage == PullStage.background ||
        stage == PullStage.failed ||
        stage == PullStage.completed) {
      _autoHideTimer = Timer(_autoHideAfter, () {
        if (mounted) setState(() => _autoHidden = true);
      });
    }
  }

  void _openSyncIssues() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const SyncIssuesScreen()),
    );
  }

  void _retryPull() {
    final businessId = ref.read(authProvider).currentUser?.businessId;
    if (businessId == null) return;
    unawaited(ref.read(supabaseSyncServiceProvider).pullChanges(businessId));
  }

  @override
  Widget build(BuildContext context) {
    final status = ref.watch(pullStatusProvider).value;
    if (_lastStage != status.stage) {
      final next = status.stage;
      _lastStage = next;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _onStageEntered(next);
      });
    }

    final t = Theme.of(context);
    final Widget child;
    // Once the 3s window has elapsed for the current stage, collapse.
    // Ongoing sync state is still surfaced via the drawer sync badge
    // and the SyncIssuesScreen.
    if (_autoHidden) {
      return const AnimatedSize(
        duration: Duration(milliseconds: 220),
        curve: Curves.easeOut,
        alignment: Alignment.topCenter,
        child: SizedBox.shrink(),
      );
    }
    switch (status.stage) {
      case PullStage.idle:
      case PullStage.minimum:
        child = const SizedBox.shrink();
        break;
      case PullStage.background:
        final progress = status.tablesTotal > 0
            ? status.tablesDone / status.tablesTotal
            : null;
        final label = status.tablesTotal > 0
            ? 'Syncing your store… (${status.tablesDone}/${status.tablesTotal})'
            : 'Syncing your store…';
        child = SafeArea(
          bottom: false,
          child: _row(
            t,
            icon: Icons.cloud_sync_outlined,
            tint: t.colorScheme.primary,
            message: label,
            onTap: _openSyncIssues,
            progress: progress,
            showProgress: true,
          ),
        );
        break;
      case PullStage.failed:
        final String label;
        VoidCallback onTap;
        if (_failureCount >= 10) {
          label =
              "Catch-up sync hasn't completed in $_failureCount attempts. Tap for details.";
          onTap = _openSyncIssues;
        } else if (_failureCount >= 3) {
          label =
              'Connection too weak for full sync — live activity is working, history may be incomplete. Tap to retry.';
          onTap = _retryPull;
        } else {
          label = 'Sync paused — tap to retry';
          onTap = _retryPull;
        }
        child = SafeArea(
          bottom: false,
          child: _row(
            t,
            icon: Icons.cloud_off_outlined,
            tint: t.colorScheme.error,
            message: label,
            onTap: onTap,
          ),
        );
        break;
      case PullStage.completed:
        child = SafeArea(
          bottom: false,
          child: _row(
            t,
            icon: Icons.check_circle_outline,
            tint: t.colorScheme.primary,
            message: 'Caught up.',
            onTap: null,
          ),
        );
        break;
    }

    return AnimatedSize(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
      alignment: Alignment.topCenter,
      child: child,
    );
  }

  Widget _row(
    ThemeData t, {
    required IconData icon,
    required Color tint,
    required String message,
    required VoidCallback? onTap,
    double? progress,
    bool showProgress = false,
  }) {
    return Material(
      color: tint.withValues(alpha: 0.08),
      child: InkWell(
        onTap: onTap,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              height: 36,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    Icon(icon, size: 16, color: tint),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        message,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: t.textTheme.bodySmall?.copyWith(
                          color: tint,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                    if (onTap != null)
                      Icon(
                        Icons.chevron_right,
                        size: 18,
                        color: tint.withValues(alpha: 0.6),
                      ),
                  ],
                ),
              ),
            ),
            if (showProgress)
              SizedBox(
                height: 2,
                child: LinearProgressIndicator(
                  value: progress,
                  backgroundColor: tint.withValues(alpha: 0.12),
                  valueColor: AlwaysStoppedAnimation<Color>(tint),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
