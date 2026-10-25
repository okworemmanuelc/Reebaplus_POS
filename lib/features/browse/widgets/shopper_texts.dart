import 'package:reebaplus_pos/core/storefront/shopper_cart.dart';
import 'package:reebaplus_pos/core/storefront/shopper_models.dart';
import 'package:reebaplus_pos/core/storefront/shopper_service.dart';

/// Shown wherever the Shopper gives contact details (PRD #421 story 28).
const String kShopperSharingNotice =
    'Your name, phone and address are shared with the shops you order from, '
    'so they can reach you and deliver.';

/// "You've placed a lot of orders — please wait a little" (#426 spam limit).
const String kRateLimitedMessage =
    "You've placed a lot of orders — please wait a little";

/// Plain words for a failed Shopper command.
String shopperFailureText(ShopperFailure failure) => switch (failure) {
  ShopperFailure.offline => 'No internet connection. Connect and try again.',
  ShopperFailure.signedOut => 'Please sign in again.',
  ShopperFailure.profileRequired => 'Add your details first.',
  ShopperFailure.notCancellable =>
    'The shop has already answered this order. Call the shop to change it.',
  ShopperFailure.failed => 'Something went wrong. Please try again.',
};

/// Why one shop's order was not placed. [productName] names the line a
/// line-level failure points at, when known. Never reveals a stock count.
String placeOrderFailureText(PlaceOrderFailure failure, {String? productName}) {
  final item = productName == null ? '' : '$productName: ';
  return switch (failure) {
    PlaceOrderFailure.rateLimited => kRateLimitedMessage,
    PlaceOrderFailure.storeUnavailable =>
      "This shop isn't taking online orders right now.",
    PlaceOrderFailure.outOfArea =>
      "This shop doesn't deliver to the address you chose.",
    PlaceOrderFailure.ownBusiness => "You can't order from your own business.",
    PlaceOrderFailure.productUnavailable =>
      '${item}no longer available online.',
    PlaceOrderFailure.quantityRule =>
      "${item}that quantity isn't allowed for this product.",
    PlaceOrderFailure.notEnoughStock => '$item$kStoreCannotSupplyMessage.',
    PlaceOrderFailure.invalid =>
      'Something went wrong with this order. '
          'Please try again.',
  };
}
