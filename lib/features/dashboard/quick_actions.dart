import 'package:reebaplus_pos/core/permissions/permissions.dart';

/// A Home quick-action tile (PRD #270, redesign #362). Declared in the row's
/// fixed order: Add Expense, Stock Transfer, Receive Stock, Record Payment,
/// Take Stock. Record Payment (#362 PR 4) joins in its place when it ships.
enum QuickAction { addExpense, stockTransfer, receiveStock, takeStock }

/// Who a "Record Payment" can be for (#362 PR 4): a customer paying us, or us
/// paying a supplier.
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
/// tile live) and a test passes `(g) => g.evaluate(ctx)`. [storeCount] is the
/// business's active stores with vans excluded — the same list Request
/// Stock's pickers use (`withoutVans(allStoresProvider)`), not the viewer's
/// selectable stores — so a second store shows Stock Transfer live.
///
/// | Tile           | Visible when                                        |
/// |----------------|-----------------------------------------------------|
/// | Add Expense    | [Gates.addExpense]                                  |
/// | Stock Transfer | [Gates.requestStoreTransfer] and [storeCount] ≥ 2   |
/// | Receive Stock  | [Gates.receiveStock]                                |
/// | Take Stock     | [Gates.dailyStockCount]                             |
///
/// Each destination keeps its own screen guard and write-boundary check; a
/// tile is a shortcut, never the only line of defence. The Record Payment
/// sides stay empty until #362 PR 4 adds the tile.
QuickActions resolveQuickActions(
  bool Function(NamedGate gate) allows, {
  required int storeCount,
}) {
  bool visible(QuickAction a) => switch (a) {
    // A transfer needs somewhere to come from: one store has nowhere.
    QuickAction.stockTransfer => storeCount >= 2 && allows(_gateFor(a)),
    _ => allows(_gateFor(a)),
  };
  return (
    tiles: [
      for (final a in QuickAction.values)
        if (visible(a)) a,
    ],
    paymentSides: const <PaymentSide>[],
  );
}

NamedGate _gateFor(QuickAction action) => switch (action) {
  QuickAction.addExpense => Gates.addExpense,
  QuickAction.stockTransfer => Gates.requestStoreTransfer,
  QuickAction.receiveStock => Gates.receiveStock,
  QuickAction.takeStock => Gates.dailyStockCount,
};
