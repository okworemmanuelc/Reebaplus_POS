import 'package:reebaplus_pos/core/permissions/permissions.dart';

/// A Home quick-action tile (PRD #270, redesign #362). Declared in the row's
/// fixed order — the declaration order IS the display order: Add Expense,
/// Stock Transfer, Take Stock, Record Payment, Receive Stock. **Receive Stock
/// is always last** (owner, 2026-10-10).
enum QuickAction {
  addExpense,
  stockTransfer,
  takeStock,
  recordPayment,
  receiveStock,
}

/// Who a "Record Payment" can be for (#362 PR 4): a customer paying us, or us
/// paying a supplier. Declared in the chooser's order.
enum PaymentSide { customer, supplier }

/// What the Home quick-actions row shows: the visible tiles in their fixed
/// order, and the Record Payment sides available to the viewer.
typedef QuickActions = ({
  List<QuickAction> tiles,
  List<PaymentSide> paymentSides,
});

/// The single place that decides which quick actions a viewer sees (PRD #270
/// "Which tiles show"). Pure: [allows] answers a Gate Registry entry, so the
/// Home row passes `(g) => g.allows(ref)` (reactive — a revoked key hides its
/// tile live) and a test passes `(g) => g.evaluate(ctx)`. The counts are live
/// inputs, so the first store, customer or supplier shows its tile without a
/// restart:
/// - [storeCount]: the business's active stores with vans excluded — the
///   same list Request Stock's pickers use (`withoutVans(allStoresProvider)`),
///   not the viewer's selectable stores;
/// - [customerCount]: registered customers — not deleted, never the walk-in
///   (the customer payment picker's list);
/// - [supplierCount]: suppliers that are not deleted (the supplier payment
///   form's dropdown).
///
/// | Tile           | Visible when                                        |
/// |----------------|-----------------------------------------------------|
/// | Add Expense    | [Gates.addExpense]                                  |
/// | Stock Transfer | [Gates.requestStoreTransfer] and [storeCount] ≥ 2   |
/// | Take Stock     | [Gates.dailyStockCount]                             |
/// | Record Payment | at least one payment side (below)                   |
/// | Receive Stock  | [Gates.receiveStock]                                |
///
/// | Payment side | Available when                                         |
/// |--------------|--------------------------------------------------------|
/// | customer     | [Gates.addCustomerCredit] and [customerCount] ≥ 1      |
/// | supplier     | [Gates.manageSuppliers] and [supplierCount] ≥ 1        |
///
/// Tiles come out in [QuickAction]'s declaration order, sides in
/// [PaymentSide]'s. Each destination keeps its own screen guard and
/// write-boundary check; a tile is a shortcut, never the only line of
/// defence.
QuickActions resolveQuickActions(
  bool Function(NamedGate gate) allows, {
  required int storeCount,
  required int customerCount,
  required int supplierCount,
}) {
  final paymentSides = [
    for (final side in PaymentSide.values)
      if (switch (side) {
        // Nobody to pick: no point opening an empty picker.
        PaymentSide.customer =>
          customerCount >= 1 && allows(Gates.addCustomerCredit),
        PaymentSide.supplier =>
          supplierCount >= 1 && allows(Gates.manageSuppliers),
      })
        side,
  ];
  bool visible(QuickAction a) => switch (a) {
    QuickAction.addExpense => allows(Gates.addExpense),
    // A transfer needs somewhere to come from: one store has nowhere.
    QuickAction.stockTransfer =>
      storeCount >= 2 && allows(Gates.requestStoreTransfer),
    QuickAction.takeStock => allows(Gates.dailyStockCount),
    QuickAction.recordPayment => paymentSides.isNotEmpty,
    QuickAction.receiveStock => allows(Gates.receiveStock),
  };
  return (
    tiles: [
      for (final a in QuickAction.values)
        if (visible(a)) a,
    ],
    paymentSides: paymentSides,
  );
}
