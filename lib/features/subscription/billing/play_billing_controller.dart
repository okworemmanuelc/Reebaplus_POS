import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:reebaplus_pos/features/subscription/billing/play_billing_constants.dart';
import 'package:reebaplus_pos/features/subscription/billing/play_billing_port.dart';

/// Calls the server to verify a purchase and activate the plan.
typedef PurchaseVerifier = Future<VerifyOutcome> Function({
  required String businessId,
  required String purchaseToken,
  required String productId,
});

class VerifyOutcome {
  final bool ok;
  final String? error;
  const VerifyOutcome(this.ok, [this.error]);
}

PurchaseVerifier supabasePurchaseVerifier(SupabaseClient client) =>
    ({required businessId, required purchaseToken, required productId}) async {
      try {
        final res = await client.functions.invoke(
          kPlayBillingVerifyFunction,
          body: {
            'business_id': businessId,
            'purchase_token': purchaseToken,
            'product_id': productId,
          },
        );
        final data = res.data;
        final ok = data is Map && data['ok'] == true;
        return VerifyOutcome(ok, ok ? null : (data is Map ? '${data['error']}' : 'internal'));
      } catch (e) {
        return VerifyOutcome(false, e.toString());
      }
    };

/// Whether the business currently pays through a Google Play subscription
/// (an entitled row in play_subscription_purchases). Throws when it cannot be
/// checked (offline).
typedef PlaySubscriptionLookup = Future<bool> Function(String businessId);

PlaySubscriptionLookup supabasePlaySubscriptionLookup(SupabaseClient client) =>
    (businessId) async {
      final rows = await client
          .from('play_subscription_purchases')
          .select('id')
          .eq('business_id', businessId)
          .inFilter('state', const ['ACTIVE', 'IN_GRACE_PERIOD', 'CANCELED'])
          .gt('expiry_time', DateTime.now().toUtc().toIso8601String())
          .limit(1);
      return rows.isNotEmpty;
    };

/// The paid plan the business is on right now (from the synced businesses
/// row). Null when it is not on a running paid plan (free, trial, lapsed).
class CurrentPlan {
  final PlanTier tier;
  final BillingCycle cycle;
  final DateTime? periodEnd;
  const CurrentPlan(this.tier, this.cycle, {this.periodEnd});
}

const String kManageInPlayMessage =
    'Manage your subscription in Google Play on the phone you bought it with.';

enum BillingPhase { loading, unavailable, ready, purchasing, verifying, success, error }

class BillingState {
  final BillingPhase phase;
  final List<StoreOffer> offers;
  final String? message;
  const BillingState(this.phase, {this.offers = const [], this.message});
}

/// Drives the plans paywall: loads store offers, starts purchases/restores and
/// turns purchase events into a server verification + a user-facing result.
class PlayBillingController extends ChangeNotifier {
  PlayBillingController({
    required this.port,
    required this.verify,
    required this.businessId,
    CurrentPlan? Function()? currentPlan,
    PlaySubscriptionLookup? hasPlaySubscription,
  })  : _currentPlan = currentPlan ?? (() => null),
        _hasPlaySubscription = hasPlaySubscription;

  final PlayBillingPort port;
  final PurchaseVerifier verify;
  final String businessId;
  final CurrentPlan? Function() _currentPlan;
  final PlaySubscriptionLookup? _hasPlaySubscription;

  /// Shown instead of "Your plan is active." once a deferred downgrade is
  /// confirmed by the server.
  String? _pendingSuccessMessage;

  BillingState _state = const BillingState(BillingPhase.loading);
  BillingState get state => _state;
  StreamSubscription<PurchaseEvent>? _sub;
  bool _disposed = false;
  Timer? _restoreTimer;
  // A deferred downgrade may finish with no purchase event (Play can return an
  // empty update). Settle the paywall instead of spinning forever.
  Timer? _downgradeTimer;

  void _set(BillingState s) {
    if (_disposed) return;
    _state = s;
    notifyListeners();
  }

  Future<void> init() async {
    _sub = port.events.listen(handleEvent);
    try {
      if (!await port.isAvailable()) {
        _set(const BillingState(BillingPhase.unavailable));
        return;
      }
      _set(BillingState(BillingPhase.ready, offers: await port.loadOffers()));
    } catch (e) {
      // Store unreachable: still show the fallback prices (no offers).
      _set(const BillingState(BillingPhase.ready));
    }
  }

  /// Store price for a plan, else the fallback.
  String priceFor(PlanTier t, BillingCycle c, {required bool naira}) {
    final o = offerFor(t, c);
    return o?.price ?? fallbackPrice(t, c, naira: naira);
  }

  StoreOffer? offerFor(PlanTier t, BillingCycle c) {
    for (final o in _state.offers) {
      if (o.productId == productIdFor(t) && o.basePlanId == basePlanFor(c)) return o;
    }
    return null;
  }

  /// True for the plan the business is already on ("Current plan").
  bool isCurrentPlan(PlanTier t, BillingCycle c) {
    final cur = _currentPlan();
    return cur != null && planMove(cur.tier, cur.cycle, t, c) == PlanMove.same;
  }

  /// Starts a purchase, or a plan switch that REPLACES the existing Play
  /// subscription (#589): upgrades now (prorated), downgrades at renewal.
  Future<void> subscribe(PlanTier t, BillingCycle c) async {
    final offers = _state.offers;
    final offer = offerFor(t, c);
    if (offer == null) {
      _set(BillingState(BillingPhase.error, offers: offers,
          message: 'This plan is not available from the store yet. Try again later.'));
      return;
    }
    final cur = _currentPlan();
    if (cur != null && planMove(cur.tier, cur.cycle, t, c) == PlanMove.same) {
      _set(BillingState(BillingPhase.ready, offers: offers,
          message: 'This is your current plan.'));
      return;
    }
    _set(BillingState(BillingPhase.purchasing, offers: offers));
    _pendingSuccessMessage = null;
    try {
      OwnedSubscription? owned;
      try {
        owned = await port.queryOwnedSubscription();
      } catch (_) {
        owned = null;
      }
      // A subscription tagged for a different business is not ours to replace.
      if (owned != null &&
          owned.accountId != null &&
          owned.accountId!.isNotEmpty &&
          owned.accountId != businessId) {
        owned = null;
      }

      PlanChange? change;
      if (owned != null) {
        final fromTier = cur?.tier ?? tierForProduct(owned.productId) ?? t;
        final fromCycle = cur?.cycle ?? BillingCycle.monthly;
        final move = planMove(fromTier, fromCycle, t, c);
        if (move == PlanMove.same) {
          _set(BillingState(BillingPhase.ready, offers: offers,
              message: 'You already have this plan. If it is not showing, '
                  'tap Restore purchases.'));
          return;
        }
        final downgrade = move == PlanMove.downgrade;
        change = PlanChange(owned,
            downgrade ? ReplacementKind.downgradeAtRenewal : ReplacementKind.upgradeNow);
        if (downgrade) _pendingSuccessMessage = _downgradeMessage(t, cur?.periodEnd);
      } else if (cur != null) {
        // Paid, but no subscription on this device: if it is a Play
        // subscription (bought on another phone / Google account), a new
        // purchase would bill twice. A hand-given plan can be bought over.
        final lookup = _hasPlaySubscription;
        bool onPlay;
        try {
          onPlay = lookup != null && await lookup(businessId);
        } catch (_) {
          _set(BillingState(BillingPhase.error, offers: offers,
              message: 'We could not check your current subscription. Check '
                  'your internet connection and try again.'));
          return;
        }
        if (onPlay) {
          _set(BillingState(BillingPhase.ready, offers: offers,
              message: kManageInPlayMessage));
          return;
        }
      }
      await port.buy(offer, accountId: businessId, change: change);
      if (change?.kind == ReplacementKind.downgradeAtRenewal) {
        final msg = _pendingSuccessMessage;
        _downgradeTimer?.cancel();
        _downgradeTimer = Timer(const Duration(seconds: 60), () {
          if (_state.phase != BillingPhase.purchasing) return;
          _pendingSuccessMessage = null;
          _set(BillingState(BillingPhase.ready, offers: _state.offers,
              message: msg == null ? null : 'If you confirmed the change: $msg'));
        });
      }
    } catch (e) {
      _pendingSuccessMessage = null;
      _set(BillingState(BillingPhase.error, offers: offers, message: '$e'));
    }
  }

  static String _downgradeMessage(PlanTier t, DateTime? on) {
    final name = t == PlanTier.basic ? 'Basic' : 'Premium';
    if (on == null) return 'Your plan changes to $name at your next renewal.';
    return 'Your plan changes to $name on ${DateFormat('d MMM yyyy').format(on.toLocal())}.';
  }

  Future<void> restore() async {
    _set(BillingState(BillingPhase.purchasing, offers: _state.offers));
    try {
      await port.restore();
      // Restored purchases arrive on the event stream. If none do, settle.
      _restoreTimer?.cancel();
      _restoreTimer = Timer(const Duration(seconds: 4), () {
        if (_state.phase == BillingPhase.purchasing) {
          _set(BillingState(BillingPhase.ready, offers: _state.offers,
              message: 'No previous purchases found.'));
        }
      });
    } catch (e) {
      _set(BillingState(BillingPhase.error, offers: _state.offers, message: '$e'));
    }
  }

  @visibleForTesting
  Future<void> handleEvent(PurchaseEvent e) async {
    final offers = _state.offers;
    switch (e.status) {
      case PurchaseEventStatus.pending:
        _set(BillingState(BillingPhase.purchasing, offers: offers,
            message: 'Waiting for payment to complete...'));
      case PurchaseEventStatus.canceled:
        _set(BillingState(BillingPhase.ready, offers: offers));
      case PurchaseEventStatus.error:
        _set(BillingState(BillingPhase.error, offers: offers,
            message: e.message ?? 'The purchase failed.'));
      case PurchaseEventStatus.purchased:
      case PurchaseEventStatus.restored:
        final token = e.purchaseToken;
        final product = e.productId;
        if (token == null || token.isEmpty || product == null) {
          _set(BillingState(BillingPhase.error, offers: offers,
              message: 'The purchase could not be read.'));
          return;
        }
        _set(BillingState(BillingPhase.verifying, offers: offers));
        final out = await verify(
          businessId: businessId,
          purchaseToken: token,
          productId: product,
        );
        if (out.ok) {
          await port.complete(e);
          final msg = _pendingSuccessMessage ?? 'Your plan is active.';
          _pendingSuccessMessage = null;
          _set(BillingState(BillingPhase.success, offers: offers, message: msg));
        } else {
          // Do NOT complete: the purchase stays queued and is re-delivered to
          // retry verification on the next launch/restore.
          _set(BillingState(BillingPhase.error, offers: offers,
              message: 'We could not confirm your purchase yet. It will be '
                  'retried; if your plan does not update, tap Restore purchases.'));
        }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _restoreTimer?.cancel();
    _downgradeTimer?.cancel();
    _sub?.cancel();
    super.dispose();
  }
}
