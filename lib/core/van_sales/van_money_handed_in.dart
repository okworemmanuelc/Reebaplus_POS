/// Van sales on Home (#805): the money drivers HANDED IN in a period.
///
/// The owner's rule (2026-11-13): a van's sales for a period are the
/// non-voided driver payments recorded in it — every `payment_transactions`
/// row typed `van_remittance`, whether it was taken against a trip
/// (`van_trip_id`) or from a driver with no trip (`van_driver_id`, #787). It is
/// NOT goods loaded minus returned, and it does not wait for the driver to ring
/// a sale: most drivers never ring one.
///
/// **One source only.** Each payment writes two legs in one transaction
/// (`VanTripsDao.recordDriverPayment` / `recordDriverPaymentNoTrip`): this
/// payment row and a driver-ledger `payment_cash` / `payment_transfer` credit
/// that references it. They are the same money, so only the payment row is
/// read here; the ledger is never added on top.
///
/// **Rung road orders stay out.** A road sale writes no payment row (ADR 0019
/// decision 2) and is already excluded from every Home figure (#140); the cash
/// for it arrives later as one of these payments. Adding the order too would
/// count the same money twice.
///
/// Dated by the payment row's own `created_at` (the day the money was
/// recorded, as "Cash from drivers" on the Daily Reconciliation counts it) and
/// scoped by its `store_id` (the loading store for a trip payment, the shop
/// that took the money for a no-trip one), through the caller's store
/// predicate — the same basis as the reconciliation's driver-payment total.
library;

import 'package:reebaplus_pos/core/database/app_database.dart';

/// Σ `amount_kobo` over the non-voided `van_remittance` rows in [payments]
/// whose `created_at` passes [inSpan] and whose `store_id` passes [inScope].
///
/// [recordedBy], when given, keeps only the rows that user recorded — Home's
/// cashier view, which counts the viewer's own takings only.
int vanMoneyHandedInKobo(
  Iterable<PaymentTransactionData> payments, {
  required bool Function(DateTime day) inSpan,
  required bool Function(String? storeId) inScope,
  String? recordedBy,
}) {
  var total = 0;
  for (final p in payments) {
    if (p.type != kPaymentTypeVanRemittance) continue;
    if (p.voidedAt != null) continue;
    if (!inSpan(p.createdAt)) continue;
    if (!inScope(p.storeId)) continue;
    if (recordedBy != null && p.performedBy != recordedBy) continue;
    total += p.amountKobo;
  }
  return total;
}
