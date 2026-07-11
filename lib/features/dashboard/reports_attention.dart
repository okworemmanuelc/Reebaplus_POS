/// Home Reports button attention dot (issue #119).
///
/// The Home tab's Reports button (CEO + Manager only) shows a single dot — no
/// number — when there is something in Reports for this viewer to look at:
///   • pending approvals await them (the #115-fixed viewer-scoped count), OR
///   • a daily stock count has been recorded since they last opened the Daily
///     Reconciliation report.
/// The dot clears when both are false: opening Daily Reconciliation stamps a
/// per-user, device-local "last reviewed" marker, retiring the stock-count
/// reason. The in-hub Approvals card keeps its own numeric badge — only the
/// Home button collapses to a dot.
///
/// Mirrors [get_started_checklist.dart]'s shape: a pure, widget-free, Riverpod-
/// free derivation ([computeReportsAttentionDot]) wired to live signals by the
/// providers below, with the marker persisted the way [UiHintService] persists
/// its hints (SharedPreferences, un-synced, no migration — a UI-review pointer,
/// not business data) but keyed per device user, so a shared till tracks each
/// staff member's review independently.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';

/// Pure derivation of whether the Home Reports button shows its attention dot.
///
/// The dot is on when [pendingApprovals] > 0, or when a daily stock count exists
/// ([latestStockCountAt] non-null) recorded after the viewer last opened Daily
/// Reconciliation ([lastReviewedAt]). A null [lastReviewedAt] (never opened on
/// this device by this user) means every existing count is un-reviewed. With no
/// approvals and no counts the dot is off.
bool computeReportsAttentionDot({
  required int pendingApprovals,
  required DateTime? latestStockCountAt,
  required DateTime? lastReviewedAt,
}) {
  if (pendingApprovals > 0) return true;
  if (latestStockCountAt == null) return false;
  return lastReviewedAt == null || latestStockCountAt.isAfter(lastReviewedAt);
}

// ─────────────────────────────────────────────────────────────────────────────
// Providers — the live wiring. Each input is a watchable provider, so the
// derivation is unit-testable in a ProviderContainer with no widget tree.
// ─────────────────────────────────────────────────────────────────────────────

/// Per-user, device-local marker of when the current viewer last opened the
/// Daily Reconciliation report, mirroring [UiHintService]'s SharedPreferences
/// pattern. Un-synced and migration-free — it is a per-device UI-review pointer,
/// not business data — but keyed by the session user id so a shared till tracks
/// each staff member separately. Starts null (never opened) and hydrates
/// asynchronously from prefs; [markOpenedNow] stamps it to the current instant
/// and persists. Re-hydrates on a user switch (build watches the id seam).
class ReconReviewMarkerNotifier extends Notifier<DateTime?> {
  /// Pref-key prefix; the current user id is appended so the marker is per-user.
  static const prefKeyPrefix = 'recon_last_reviewed_at_v1_';

  static String prefKeyFor(String userId) => '$prefKeyPrefix$userId';

  @override
  DateTime? build() {
    final userId = ref.watch(currentUserIdProvider);
    if (userId == null) return null;
    _hydrate(userId);
    return null;
  }

  Future<void> _hydrate(String userId) async {
    final prefs = await SharedPreferences.getInstance();
    final millis = prefs.getInt(prefKeyFor(userId));
    if (millis != null) {
      state = DateTime.fromMillisecondsSinceEpoch(millis);
    }
  }

  /// Stamps the marker to now and persists it for the current user — called when
  /// the Daily Reconciliation report is opened; clears the dot's stock-count
  /// reason. No-op when logged out.
  Future<void> markOpenedNow() async {
    final userId = ref.read(currentUserIdProvider);
    if (userId == null) return;
    final now = DateTime.now();
    state = now;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(prefKeyFor(userId), now.millisecondsSinceEpoch);
  }
}

final reconReviewMarkerProvider =
    NotifierProvider<ReconReviewMarkerNotifier, DateTime?>(
      ReconReviewMarkerNotifier.new,
    );

/// Whether the Home Reports button shows its attention dot for the current
/// viewer. Composes the #115-fixed viewer-scoped pending-approval counts, the
/// latest daily-stock-count timestamp, and the per-user review marker through
/// [computeReportsAttentionDot]. Consumed only by the Home Reports button, which
/// is itself CEO/Manager-gated.
final reportsAttentionDotProvider = Provider<bool>((ref) {
  final pendingApprovals =
      ref.watch(viewerScopedPendingStockRequestsProvider).length +
      ref.watch(viewerScopedPendingQuickSaleRequestsProvider).length;

  final counts =
      ref.watch(allStockCountsProvider).valueOrNull ??
      const <StockCountData>[];
  // Compare wall-clock createdAt (when the count was saved), not the ordered
  // list head — watchAllForBusiness orders by businessDate first, so a
  // back-dated count saved today would not be counts.first.
  final latestStockCountAt = counts.isEmpty
      ? null
      : counts.map((c) => c.createdAt).reduce((a, b) => a.isAfter(b) ? a : b);

  final lastReviewedAt = ref.watch(reconReviewMarkerProvider);

  return computeReportsAttentionDot(
    pendingApprovals: pendingApprovals,
    latestStockCountAt: latestStockCountAt,
    lastReviewedAt: lastReviewedAt,
  );
});
