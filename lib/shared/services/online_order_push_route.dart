import 'package:flutter/foundation.dart';

/// Where a tapped "New online order" push (#433) should land.
enum OnlineOrderTapTarget { detail, onlineTab }

/// Routes an `online_order` push tap. Invariant #13 (push is an alert only):
/// the order reaches Drift by pull, so the tap must tolerate it not being local
/// yet. If the row is local, open its detail; otherwise (or on any error) open
/// the Online tab. Never waits on a pull and never throws.
Future<OnlineOrderTapTarget> routeOnlineOrderTap({
  required String? onlineOrderId,
  required Future<bool> Function(String id) isLocal,
  required void Function(String id) openDetail,
  required void Function() openOnlineTab,
}) async {
  try {
    if (onlineOrderId != null &&
        onlineOrderId.isNotEmpty &&
        await isLocal(onlineOrderId)) {
      openDetail(onlineOrderId);
      return OnlineOrderTapTarget.detail;
    }
  } catch (e) {
    debugPrint('[Push] online order lookup failed, opening tab: $e');
  }
  try {
    openOnlineTab();
  } catch (e) {
    debugPrint('[Push] open Online tab failed: $e');
  }
  return OnlineOrderTapTarget.onlineTab;
}
