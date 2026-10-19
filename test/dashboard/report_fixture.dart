// Shared sample data for the Dashboard report screens' tests and goldens
// (#413). Sample data only: business "Stallion Global", store "Abuja HQ".
// Every date is fixed so a golden never depends on the clock.

import 'dart:convert';

import 'package:drift/drift.dart' show Value;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';

import '../helpers/screen_harness.dart';

/// The fixed day the sales rows are stamped with.
final DateTime kReportDay = DateTime(2026, 7, 14, 10, 30);

OrderWithItems reportOrder(
  ScreenTestEnvironment env, {
  required int n,
  required DateTime at,
  required List<(ProductData? product, int qty, int unitKobo, int costKobo)>
  lines,
  int discountKobo = 0,
  String status = 'completed',
  String? quickName,
}) {
  final orderId = 'order-$n';
  final gross = lines.fold<int>(0, (s, l) => s + l.$2 * l.$3);
  final order = OrderData(
    id: orderId,
    businessId: env.businessId,
    orderNumber: 'ORD-00000$n-ABC123',
    customerId: null,
    totalAmountKobo: gross - discountKobo,
    discountKobo: discountKobo,
    netAmountKobo: gross - discountKobo,
    amountPaidKobo: gross - discountKobo,
    paymentType: 'cash',
    status: status,
    riderName: 'Pick-up Order',
    cancellationReason: null,
    barcode: null,
    staffId: null,
    storeId: env.storeId,
    confirmedBy: null,
    crateDepositPaidKobo: 0,
    completedAt: null,
    cancelledAt: null,
    createdAt: at,
    lastUpdatedAt: at,
  );
  final items = <OrderItemDataWithProductData>[
    for (var i = 0; i < lines.length; i++)
      OrderItemDataWithProductData(
        OrderItemData(
          id: '$orderId-$i',
          businessId: env.businessId,
          orderId: orderId,
          productId: lines[i].$1?.id,
          storeId: env.storeId,
          quantity: lines[i].$2,
          unitPriceKobo: lines[i].$3,
          buyingPriceKobo: lines[i].$4,
          totalKobo: lines[i].$2 * lines[i].$3,
          cataloguePriceKobo: lines[i].$1 == null ? null : lines[i].$3 + 5000,
          priceSnapshot: lines[i].$1 == null
              ? jsonEncode({'name': quickName ?? 'Quick Sale'})
              : null,
          createdAt: at,
          lastUpdatedAt: at,
        ),
        lines[i].$1,
      ),
  ];
  return OrderWithItems(order, items, null);
}

/// Three sample orders: two products with a recorded cost and a quick sale
/// with none.
List<OrderWithItems> sampleReportOrders(
  ScreenTestEnvironment env,
  DateTime at,
) {
  final p = env.products;
  return [
    reportOrder(
      env,
      n: 1,
      at: at,
      lines: [(p[0], 12, 450000, 380000), (p[1], 6, 820000, 700000)],
      discountKobo: 250000,
    ),
    reportOrder(
      env,
      n: 2,
      at: at.subtract(const Duration(hours: 2)),
      lines: [(p[2], 3, 1500000, 1250000)],
    ),
    reportOrder(
      env,
      n: 3,
      at: at.subtract(const Duration(hours: 5)),
      lines: [(null, 2, 300000, 0)],
      quickName: 'Ice block',
    ),
  ];
}

List<SupplierData> sampleSuppliers(ScreenTestEnvironment env) {
  final at = DateTime(2026, 7, 1);
  SupplierData s(String id, String name) => SupplierData(
    id: id,
    businessId: env.businessId,
    name: name,
    isDeleted: false,
    createdAt: at,
    lastUpdatedAt: at,
  );
  return [
    s('sup-1', 'Lagos Bottling Co'),
    s('sup-2', 'Kano Beverages Ltd'),
    s('sup-3', 'Ibadan Cold Chain'),
  ];
}

List<SupplierLedgerEntryData> sampleLedger(ScreenTestEnvironment env) {
  final at = DateTime(2026, 7, 10);
  SupplierLedgerEntryData e(
    String id,
    String supplier,
    String ref,
    int signed,
  ) => SupplierLedgerEntryData(
    id: id,
    businessId: env.businessId,
    supplierId: supplier,
    storeId: env.storeId,
    type: signed < 0 ? 'debit' : 'credit',
    amountKobo: signed.abs(),
    signedAmountKobo: signed,
    referenceType: ref,
    paymentMethod: ref.startsWith('payment_') ? 'cash' : null,
    activityDate: at,
    createdAt: at,
    lastUpdatedAt: at,
  );
  return [
    e('l1', 'sup-1', 'invoice', -48000000),
    e('l2', 'sup-1', 'payment_cash', 30000000),
    e('l3', 'sup-2', 'invoice', -12000000),
    e('l4', 'sup-2', 'payment_cash', 15000000),
    e('l5', 'sup-3', 'invoice', -9000000),
    e('l6', 'sup-3', 'payment_cash', 9000000),
  ];
}

/// Noon today: the anchor for [reportOverrides] in tests whose screens
/// default to the "Today" period. The sample orders sit 2h and 5h before
/// the anchor, so anchoring on `DateTime.now()` pushed them into yesterday
/// whenever the suite ran between midnight and 5am.
DateTime reportTodayAnchor() {
  final now = DateTime.now();
  return DateTime(now.year, now.month, now.day, 12);
}

/// Provider overrides that feed the report screens the sample data above.
List<Override> reportOverrides(ScreenTestEnvironment env, DateTime orderAt) => [
  allOrdersProvider.overrideWith(
    (ref) => Stream.value(sampleReportOrders(env, orderAt)),
  ),
  crateDepositSummaryProvider.overrideWith(
    (ref) => Stream.value(
      const CrateDepositSummary(
        takenKobo: 24000000,
        refundedKobo: 9000000,
        keptKobo: 3000000,
        heldKobo: 12000000,
      ),
    ),
  ),
  depositsHeldByCustomerProvider.overrideWith(
    (ref) => Stream.value({'c1': 7000000, 'c2': 5000000}),
  ),
  allSuppliersProvider.overrideWith(
    (ref) => Stream.value(sampleSuppliers(env)),
  ),
  supplierAllHistoryProvider.overrideWith(
    (ref) => Stream.value(sampleLedger(env)),
  ),
];

/// Two customers holding crate deposits (ids match `reportOverrides`).
Future<void> seedReportCustomers(ScreenTestEnvironment env) async {
  final db = env.db;
  for (final (id, name) in const [
    ('c1', 'Adaeze Okafor'),
    ('c2', 'Bola Adewale'),
  ]) {
    await db
        .into(db.customers)
        .insert(
          CustomersCompanion.insert(
            id: Value(id),
            businessId: env.businessId,
            name: name,
            storeId: Value(env.storeId),
          ),
        );
  }
}
