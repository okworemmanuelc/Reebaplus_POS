import 'dart:async';

import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:in_app_purchase_android/in_app_purchase_android.dart';

import 'package:reebaplus_pos/features/subscription/billing/play_billing_constants.dart';

/// A purchasable (product, base plan) with the store's localized price.
class StoreOffer {
  final String productId;
  final String basePlanId;
  final String price;
  final Object? token; // adapter-private handle (offer token / details)
  const StoreOffer(this.productId, this.basePlanId, this.price, [this.token]);
}

enum PurchaseEventStatus { pending, purchased, restored, canceled, error }

/// A store purchase update, flattened away from the plugin types.
class PurchaseEvent {
  final PurchaseEventStatus status;
  final String? productId;
  final String? purchaseToken;
  final String? message;
  final Object? raw; // adapter-private, handed back to [PlayBillingPort.complete]
  const PurchaseEvent(
    this.status, {
    this.productId,
    this.purchaseToken,
    this.message,
    this.raw,
  });
}

/// Seam over the `in_app_purchase` plugin so the paywall and result handling
/// are testable without Play Services.
abstract class PlayBillingPort {
  Future<bool> isAvailable();
  Future<List<StoreOffer>> loadOffers();
  Stream<PurchaseEvent> get events;

  /// Starts the purchase sheet. [accountId] (the business id) is attached as
  /// the obfuscated account id so the server can bind the token to a business.
  Future<void> buy(StoreOffer offer, {required String accountId});
  Future<void> restore();

  /// Tell the store the purchase was handled (clears it from the queue). The
  /// server, not the client, acknowledges it with Google.
  Future<void> complete(PurchaseEvent event);
}

class InAppPurchasePort implements PlayBillingPort {
  InAppPurchasePort([InAppPurchase? iap]) : _iap = iap ?? InAppPurchase.instance;
  final InAppPurchase _iap;
  final Map<String, ProductDetails> _details = {};

  @override
  Future<bool> isAvailable() => _iap.isAvailable();

  @override
  Future<List<StoreOffer>> loadOffers() async {
    final res = await _iap.queryProductDetails(kSubscriptionProductIds);
    final out = <StoreOffer>[];
    for (final d in res.productDetails) {
      if (d is! GooglePlayProductDetails) continue;
      for (final o in d.productDetails.subscriptionOfferDetails ?? const []) {
        // Only the base-plan price (no promo offer): offerId == null.
        if (o.offerId != null || o.pricingPhases.isEmpty) continue;
        final price = o.pricingPhases.last.formattedPrice;
        final key = '${d.id}|${o.basePlanId}';
        _details[key] = d;
        out.add(StoreOffer(d.id, o.basePlanId, price, o.offerIdToken));
      }
    }
    return out;
  }

  @override
  Stream<PurchaseEvent> get events => _iap.purchaseStream.expand(
    (list) => list.map(_map),
  );

  PurchaseEvent _map(PurchaseDetails p) {
    final status = switch (p.status) {
      PurchaseStatus.pending => PurchaseEventStatus.pending,
      PurchaseStatus.purchased => PurchaseEventStatus.purchased,
      PurchaseStatus.restored => PurchaseEventStatus.restored,
      PurchaseStatus.canceled => PurchaseEventStatus.canceled,
      PurchaseStatus.error => PurchaseEventStatus.error,
    };
    return PurchaseEvent(
      status,
      productId: p.productID,
      purchaseToken: p.verificationData.serverVerificationData,
      message: p.error?.message,
      raw: p,
    );
  }

  @override
  Future<void> buy(StoreOffer offer, {required String accountId}) async {
    final d = _details['${offer.productId}|${offer.basePlanId}'];
    if (d == null) throw StateError('Plan not available from the store.');
    final param = GooglePlayPurchaseParam(
      productDetails: d,
      offerToken: offer.token as String?,
      applicationUserName: accountId,
    );
    await _iap.buyNonConsumable(purchaseParam: param);
  }

  @override
  Future<void> restore() => _iap.restorePurchases();

  @override
  Future<void> complete(PurchaseEvent event) async {
    final raw = event.raw;
    if (raw is PurchaseDetails && raw.pendingCompletePurchase) {
      await _iap.completePurchase(raw);
    }
  }
}
