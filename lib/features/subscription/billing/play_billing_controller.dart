import 'dart:async';

import 'package:flutter/foundation.dart';
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
  });

  final PlayBillingPort port;
  final PurchaseVerifier verify;
  final String businessId;

  BillingState _state = const BillingState(BillingPhase.loading);
  BillingState get state => _state;
  StreamSubscription<PurchaseEvent>? _sub;
  bool _disposed = false;
  Timer? _restoreTimer;

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

  Future<void> subscribe(PlanTier t, BillingCycle c) async {
    final offer = offerFor(t, c);
    if (offer == null) {
      _set(BillingState(BillingPhase.error, offers: _state.offers,
          message: 'This plan is not available from the store yet. Try again later.'));
      return;
    }
    _set(BillingState(BillingPhase.purchasing, offers: _state.offers));
    try {
      await port.buy(offer, accountId: businessId);
    } catch (e) {
      _set(BillingState(BillingPhase.error, offers: _state.offers, message: '$e'));
    }
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
          _set(BillingState(BillingPhase.success, offers: offers,
              message: 'Your plan is active.'));
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
    _sub?.cancel();
    super.dispose();
  }
}
