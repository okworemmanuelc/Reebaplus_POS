import 'package:reebaplus_pos/core/permissions/permissions.dart';

/// A Home quick-action tile (PRD #270, redesign #362). Declared in the row's
/// fixed order: Add Expense, Stock Transfer, Receive Stock, Record Payment,
/// Take Stock. Stock Transfer (#362 PR 2) and Record Payment (#362 PR 4) join
/// in their places when they ship.
enum QuickAction { addExpense, receiveStock, takeStock }

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
/// tile live) and a test passes `(g) => g.evaluate(ctx)`.
///
/// | Tile          | Visible when              |
/// |---------------|---------------------------|
/// | Add Expense   | [Gates.addExpense]        |
/// | Receive Stock | [Gates.receiveStock]      |
/// | Take Stock    | [Gates.dailyStockCount]   |
///
/// Each destination keeps its own screen guard and write-boundary check; a
/// tile is a shortcut, never the only line of defence. The Record Payment
/// sides stay empty until #362 PR 4 adds the tile.
QuickActions resolveQuickActions(bool Function(NamedGate gate) allows) {
  return (
    tiles: [
      for (final a in QuickAction.values)
        if (allows(_gateFor(a))) a,
    ],
    paymentSides: const <PaymentSide>[],
  );
}

NamedGate _gateFor(QuickAction action) => switch (action) {
  QuickAction.addExpense => Gates.addExpense,
  QuickAction.receiveStock => Gates.receiveStock,
  QuickAction.takeStock => Gates.dailyStockCount,
};
