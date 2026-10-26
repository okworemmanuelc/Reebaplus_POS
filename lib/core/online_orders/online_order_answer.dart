/// How the shop answers an Online Order (#427, PRD #421). Plain types shared
/// by the DAO write boundary and the Orders screens.
library;

/// The decline reasons the shop picks from. [other] carries typed text.
enum OnlineOrderDeclineReason {
  outOfStock('Out of stock'),
  noDelivery("We don't deliver to your area"),
  other('Other');

  const OnlineOrderDeclineReason(this.label);

  /// The words the Shopper sees (stored as `decline_reason`).
  final String label;
}

/// The cloud CHECK on `online_orders.decline_reason` (0205): at most 300.
const int kOnlineOrderReasonMaxLength = 300;

/// Which shop Customer an accepted order belongs to, chosen by staff on a
/// Shopper's FIRST order at the business (ADR 0030: never a phone match).
sealed class CustomerLinkChoice {
  const CustomerLinkChoice();
}

/// Link the Shopper to a Customer the shop already has.
final class LinkExistingCustomer extends CustomerLinkChoice {
  const LinkExistingCustomer(this.customerId);
  final String customerId;
}

/// Create a new Retailer Customer from the order's name, phone and address.
final class CreateRetailerCustomer extends CustomerLinkChoice {
  const CreateRetailerCustomer();
}

/// What happened when the shop answered.
enum OnlineOrderAnswerOutcome {
  /// Saved locally and queued for the cloud.
  answered,

  /// The order is no longer `new` here (another device answered it, or the
  /// customer cancelled it): nothing was written.
  alreadyAnswered,

  /// The Shopper has no linked Customer yet: ask existing-or-new first.
  needsCustomerChoice,
}

/// The status a shop phone shows for a customer cancel that beat an accept.
const String kCancelledBeforeAcceptText =
    'Cancelled by the customer before you accepted';
