import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';

/// Tracks whether the celebratory "Thank you for subscribing" screen (master
/// plan §32) has already been shown for a business's CURRENT activation.
///
/// "Once per activation" is keyed by `current_period_end`: each activation /
/// renewal from the admin console stamps a new period end, so a fresh value the
/// device hasn't acknowledged means a new activation to celebrate. Re-opening
/// the app on the same period does nothing; the next renewal (new period end)
/// celebrates again. Acks persist in SharedPreferences (per business) so the
/// screen survives restarts but never repeats for the same period.
class SubscriptionThanksService extends ChangeNotifier {
  static const _prefix = 'subscription_thanks_ack::';

  final Map<String, String> _ackedPeriodByBiz = {};
  bool _loaded = false;

  SubscriptionThanksService() {
    _load();
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      for (final key in prefs.getKeys()) {
        if (!key.startsWith(_prefix)) continue;
        final period = prefs.getString(key);
        if (period != null) {
          _ackedPeriodByBiz[key.substring(_prefix.length)] = period;
        }
      }
    } catch (e) {
      debugPrint('[SubscriptionThanks] load failed: $e');
    } finally {
      _loaded = true;
      notifyListeners();
    }
  }

  /// True when [business] is `active` on a period we haven't celebrated yet.
  /// Returns false until prefs have loaded (so we never double-show on the same
  /// period across a race) and false for active subscriptions with no period
  /// end (nothing to key the once-per-activation guard on).
  bool shouldCelebrate(BusinessData business) {
    if (!_loaded) return false;
    if (business.subscriptionStatus != 'active') return false;
    final period = business.currentPeriodEnd?.toIso8601String();
    if (period == null) return false;
    return _ackedPeriodByBiz[business.id] != period;
  }

  /// Records that the thank-you screen was shown for [business]'s current
  /// activation so it won't show again until the next renewal.
  Future<void> acknowledge(BusinessData business) async {
    final period = business.currentPeriodEnd?.toIso8601String();
    if (period == null) return;
    _ackedPeriodByBiz[business.id] = period;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('$_prefix${business.id}', period);
    } catch (e) {
      debugPrint('[SubscriptionThanks] persist failed: $e');
    }
  }
}

final subscriptionThanksProvider =
    ChangeNotifierProvider<SubscriptionThanksService>(
      (ref) => SubscriptionThanksService(),
    );
