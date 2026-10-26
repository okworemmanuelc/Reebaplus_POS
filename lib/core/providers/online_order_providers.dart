import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/online_orders/pay_on_delivery.dart';
import 'package:reebaplus_pos/core/permissions/gate_registry.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/business_scoped_stream.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';

// Online Orders on the shop's phones (#427, PRD #421). Core (not the Orders
// feature) because the side menu's New-orders badge reads the same count as
// the Online tab, so the two can never disagree.

/// Every Online Order of the business, newest first.
final onlineOrdersProvider = businessScopedStream<List<OnlineOrderData>>(
  (ref, db, businessId) => db.onlineOrdersDao.watchAll(),
  whenAbsent: const [],
);

/// The Online Orders the viewer sees in the active store scope: the active
/// store's (`lockedStoreProvider`), or every store the viewer works in when
/// "All Stores" is chosen. Empty without `online_orders.view`.
final scopedOnlineOrdersProvider = Provider<List<OnlineOrderData>>((ref) {
  final ctx = ref.watch(gateContextProvider);
  if (!Gates.viewOnlineOrders.rule.evaluate(ctx)) return const [];
  final all = ref.watch(onlineOrdersProvider).valueOrNull ?? const [];
  final activeStoreId = ref.watch(lockedStoreProvider).value;
  if (activeStoreId != null) {
    return all.where((o) => o.storeId == activeStoreId).toList();
  }
  final mine = ref.watch(selectableStoresProvider).map((s) => s.id).toSet();
  return all.where((o) => mine.contains(o.storeId)).toList();
});

/// The New-orders badge (Online tab and side menu).
final newOnlineOrderCountProvider = Provider<int>(
  (ref) => ref
      .watch(scopedOnlineOrdersProvider)
      .where((o) => o.status == 'new')
      .length,
);

/// One Online Order by id (null once it is gone).
final onlineOrderProvider =
    businessScopedStreamFamily<OnlineOrderData?, String>(
      (ref, db, businessId, id) => db.onlineOrdersDao.watchById(id),
      whenAbsent: null,
    );

/// The lines of one Online Order.
final onlineOrderLinesProvider =
    businessScopedStreamFamily<List<OnlineOrderLineData>, String>(
      (ref, db, businessId, id) => db.onlineOrdersDao.watchLines(id),
      whenAbsent: const [],
    );

/// Current retail price (kobo) per product on the order's lines, for the
/// accept screen's price-change flag (#428).
final onlineOrderRetailPricesProvider =
    businessScopedStreamFamily<Map<String, int>, String>(
      (ref, db, businessId, id) => db.onlineOrdersDao.watchRetailPrices(id),
      whenAbsent: const {},
    );

/// The shop Customer an accepted order is attached to, if any.
final onlineOrderCustomerProvider =
    businessScopedStreamFamily<CustomerData?, String>(
      (ref, db, businessId, customerId) =>
          db.customersDao.watchCustomerById(customerId),
      whenAbsent: null,
    );

/// Whether the viewer may accept / decline an order of [storeId]: the
/// `online_orders.answer` key AND a store they work in (all-stores viewers:
/// any store).
final canAnswerOnlineOrderProvider = Provider.family<bool, String>((
  ref,
  storeId,
) {
  final ctx = ref.watch(gateContextProvider);
  if (!Gates.answerOnlineOrders.rule.evaluate(ctx)) return false;
  if (ref.watch(canViewAllStoresProvider)) return true;
  return ref.watch(selectableStoresProvider).any((s) => s.id == storeId);
});

/// Whether the viewer may Send to till an accepted order of [storeId] (#431):
/// they make sales (`sales.make`) in a store they work in (all-stores viewers:
/// any store). No custom-price grant is needed — accepting agreed the prices.
final canSendOnlineOrderToTillProvider = Provider.family<bool, String>((
  ref,
  storeId,
) {
  final ctx = ref.watch(gateContextProvider);
  if (!Gates.makeSale.rule.evaluate(ctx)) return false;
  if (ref.watch(canViewAllStoresProvider)) return true;
  return ref.watch(selectableStoresProvider).any((s) => s.id == storeId);
});

/// Every Pay on delivery order of the business (#432), any status: a `credit`
/// order an Online Order is linked to, with what Mark as paid has collected.
final payOnDeliveryOrdersProvider =
    businessScopedStream<List<PayOnDeliveryOrder>>(
      (ref, db, businessId) => db.onlineOrdersDao.watchPayOnDelivery(),
      whenAbsent: const [],
    );

/// [payOnDeliveryOrdersProvider] by order id — how the Orders screen, the
/// receipt and the customer page know to say "Pay on delivery" (never
/// "credit").
final payOnDeliveryByOrderProvider = Provider<Map<String, PayOnDeliveryOrder>>(
  (ref) => {
    for (final o
        in ref.watch(payOnDeliveryOrdersProvider).valueOrNull ??
            const <PayOnDeliveryOrder>[])
      o.orderId: o,
  },
);
