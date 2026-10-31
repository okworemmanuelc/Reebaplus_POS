import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/settings/vat_settings.dart';
import 'package:reebaplus_pos/core/utils/name_case.dart';

/// The real-data fields of a receipt (#605 slice 3): business contact, cashier,
/// sale date, the VAT-included line, the customer's crate balance and the full
/// crate deposit. ONE resolver feeds all 8 call sites (phone + paper, checkout,
/// Orders, customer page, van), so both renderers in a file get identical
/// values. Display only: nothing here changes a total.
class ReceiptExtras {
  const ReceiptExtras({
    this.businessPhone,
    this.businessEmail,
    this.cashierName,
    this.saleDate,
    this.vatRateBps,
    this.vatIncluded,
    this.cratesOwedByManufacturer,
    this.crateDepositFull,
  });

  static const ReceiptExtras none = ReceiptExtras();

  final String? businessPhone;
  final String? businessEmail;
  final String? cashierName;
  final DateTime? saleDate;
  final int? vatRateBps;
  final double? vatIncluded;
  final Map<String, double>? cratesOwedByManufacturer;
  final double? crateDepositFull;
}

String? _blankToNull(String? s) {
  final t = s?.trim();
  return (t == null || t.isEmpty) ? null : t;
}

/// Pure composition (unit-tested). [totalKobo] is the amount owed (goods net +
/// deposit); goods = total − [depositKobo]. VAT is ALWAYS worked out on the
/// inclusive basis, whatever the shop's basis setting says (owner decision).
ReceiptExtras composeReceiptExtras({
  String? businessPhone,
  String? businessEmail,
  String? cashierName,
  DateTime? saleDate,
  VatConfig vat = VatConfig.off,
  required int totalKobo,
  int depositKobo = 0,
  int? fullDepositKobo,
  List<CrateBalanceEntry>? crateBalances,
  Map<String, int> depositCrates = const {},
}) {
  final vatOn = vat.enabled && vat.rateBps > 0;
  final goodsKobo = totalKobo - depositKobo;
  final cashier = _blankToNull(cashierName);
  return ReceiptExtras(
    businessPhone: _blankToNull(businessPhone),
    businessEmail: _blankToNull(businessEmail),
    cashierName: cashier == null ? null : toNameCase(cashier),
    saleDate: saleDate?.toLocal(),
    vatRateBps: vatOn ? vat.rateBps : null,
    vatIncluded: vatOn
        ? computeVatKobo(goodsKobo, vat.rateBps, basis: VatBasis.inclusive) /
              100.0
        : null,
    cratesOwedByManufacturer: crateBalances == null
        ? null
        : _cratesOwed(crateBalances, depositCrates),
    crateDepositFull: (fullDepositKobo != null && fullDepositKobo > depositKobo)
        ? fullDepositKobo / 100.0
        : null,
  );
}

/// "Crates still to bring back", per brand (owner decision, #605): the
/// customer's no-deposit ledger debt (positive = owes us empties, floored at 0)
/// plus the crates THIS sale took under a deposit. The ledger only records
/// crates taken with no deposit, so without the second term a deposit sale
/// would print "Owed: 0". Older deposit-covered crates are not tracked per
/// customer, so they are not counted.
Map<String, double> _cratesOwed(
  List<CrateBalanceEntry> balances,
  Map<String, int> depositCrates,
) {
  final owed = <String, double>{
    for (final b in balances)
      b.manufacturerId: b.balance > 0 ? b.balance.toDouble() : 0.0,
  };
  depositCrates.forEach((mfrId, crates) {
    owed[mfrId] = (owed[mfrId] ?? 0) + crates;
  });
  return owed;
}

/// Reads what the call site does not already hold, then composes.
///
/// [staffId] names the cashier (reprints) unless [cashierName] is given
/// (checkout). [orderId] supplies the full crate deposit for a recorded order;
/// a fresh sale passes [fullDepositKobo] from the cart instead. A null
/// [customerId] (walk-in) leaves the crate balance null.
Future<ReceiptExtras> loadReceiptExtras(
  AppDatabase db, {
  required BusinessData? business,
  required VatConfig vat,
  required int totalKobo,
  int depositKobo = 0,
  DateTime? saleDate,
  String? cashierName,
  String? staffId,
  String? customerId,
  String? orderId,
  int? fullDepositKobo,
  Map<String, int>? depositCrates,
}) async {
  var cashier = cashierName;
  if (cashier == null && staffId != null) {
    cashier = (await db.storesDao.getUserById(staffId))?.name;
  }
  var full = fullDepositKobo;
  var covered = depositCrates;
  if ((full == null || covered == null) && orderId != null) {
    final lines = await db.orderCrateLinesDao.getForOrder(orderId);
    if (full == null && lines.isNotEmpty) {
      full = lines.fold<int>(0, (s, l) => s + l.cratesTaken * l.depositRateKobo);
    }
    covered ??= {
      for (final l in lines)
        if (l.depositPaidKobo > 0) l.manufacturerId: l.cratesTaken,
    };
  }
  List<CrateBalanceEntry>? balances;
  if (customerId != null) {
    balances = await db.customersDao
        .watchCrateBalancesWithGroups(customerId)
        .first;
  }
  return composeReceiptExtras(
    businessPhone: business?.phone,
    businessEmail: business?.email,
    cashierName: cashier,
    saleDate: saleDate,
    vat: vat,
    totalKobo: totalKobo,
    depositKobo: depositKobo,
    fullDepositKobo: full,
    crateBalances: balances,
    depositCrates: covered ?? const {},
  );
}

/// [loadReceiptExtras] for an already-recorded order (reprints from Orders and
/// the customer page, van re-opens): the sale date is the order's `createdAt`
/// in local time, the cashier is the order's `staffId` user, the crate deposit
/// and the full deposit come off the order.
Future<ReceiptExtras> loadReceiptExtrasForOrder(
  AppDatabase db,
  OrderData order, {
  required BusinessData? business,
  required VatConfig vat,
}) => loadReceiptExtras(
  db,
  business: business,
  vat: vat,
  totalKobo: order.totalAmountKobo,
  depositKobo: order.crateDepositPaidKobo,
  saleDate: order.createdAt,
  staffId: order.staffId,
  customerId: order.customerId,
  orderId: order.id,
);
