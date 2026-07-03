import 'package:reebaplus_pos/core/permissions/gate.dart';

/// A named entry in the [Gates] registry: one gated action, declared once
/// (CONTEXT.md glossary → *Gate Registry*). Carries the [rule] (a pure [Gate]
/// predicate), a stable [name] (telemetry id, matches the `Gates.<name>`
/// field), and a human-readable [action] used in denial feedback and the
/// no-access scaffold. Call sites cite the entry (`Gates.receiveStock`) — the
/// render layer, the screen guard, and the write boundary all cite the *same*
/// entry, so the rule cannot drift between layers.
class NamedGate {
  const NamedGate({
    required this.name,
    required this.action,
    required this.rule,
  });

  /// Stable identifier, equal to the `Gates.<name>` field that holds this entry.
  final String name;

  /// Human-readable action name for denial feedback ("Receive Stock").
  final String action;

  /// The pure predicate this entry names.
  final Gate rule;

  /// Whether the current context grants this gate. Thin delegate to [rule].
  bool evaluate(GateContext ctx) => rule.evaluate(ctx);
}

/// The Gate Registry — the single declaration site for every named gate in the
/// app (ADR 0002). Adding a gated action is one entry here plus citing it; the
/// membership test proves every entry is cited somewhere and the static-ban
/// test proves no bare `hasPermission` check survives outside this module.
///
/// **Tier atoms are convention-bound** (ADR 0002): `Gate.tierAtLeast` / `Gate.ceo`
/// are reserved for verbatim legacy lifts and the §19.3 money-visibility class;
/// a *new* tier-based gate is a review flag. Keys remain the canonical axis
/// (invariant #6).
abstract final class Gates {
  // ── Receive Stock cluster (tracer, issue #17) ──────────────────────────────

  /// Open the Receive Stock flow — any-of gate: a stock keeper (`stock.add`) or
  /// anyone who can add products (`products.add`) may receive. Cited by the
  /// Inventory FAB and the Receive Stock screen guard (their equivalence used
  /// to be comment-enforced).
  static const NamedGate receiveStock = NamedGate(
    name: 'receiveStock',
    action: 'Receive Stock',
    rule: Gate.anyKey(['stock.add', 'products.add']),
  );

  /// Create a new product (the New Product card inside Receive Stock, and the
  /// Inventory Add Product entry). Sub-gate of Receive Stock.
  static const NamedGate addProduct = NamedGate(
    name: 'addProduct',
    action: 'Add Product',
    rule: Gate.key('products.add'),
  );

  /// Edit a product's selling price (long-press to edit in Receive Stock, the
  /// receive hint, and the edit-item modal). Sub-gate of Receive Stock.
  static const NamedGate editProductPrice = NamedGate(
    name: 'editProductPrice',
    action: 'Edit Price',
    rule: Gate.key('products.edit_price'),
  );

  /// Edit a product's buying (cost) price in the receive edit-item modal.
  /// Sub-gate of Receive Stock.
  static const NamedGate editBuyingPrice = NamedGate(
    name: 'editBuyingPrice',
    action: 'Edit Buying Price',
    rule: Gate.key('products.edit_buying_price'),
  );

  /// Manage suppliers, incl. recording a supplier payment during a receipt.
  /// Sub-gate of the Receive Stock checkout's payment section.
  static const NamedGate manageSuppliers = NamedGate(
    name: 'manageSuppliers',
    action: 'Manage Suppliers',
    rule: Gate.key('suppliers.manage'),
  );

  // ── Dashboard & Reports cluster (issue #18) ────────────────────────────────
  // Verbatim lifts of the home-screen §11.4 money/report tiles and the Reports
  // hub / Profit report entries — the app's messiest composite gates. They mix
  // role tier with permission keys (the CEO-or-Manager-with-key pattern) or are
  // the deliberately tier-based §19.3/§18.4 money-visibility class that fails
  // closed while the role resolves. The tier atoms below are used *exactly* as
  // ADR 0002 permits for legacy lifts, so every tier dependence is visible here
  // in one place. **TIER-BASED / §19.3-class — review flag: "should this be a
  // permission key?"** These are render-only visibility gates (no write
  // boundary) — cited via `.allows(ref)`.

  /// Home Total Sales tile (§11.4). CEO always; a Manager or Cashier only with
  /// `reports.see_sales`; Stock keeper never. Lifted verbatim from
  /// `isCeo || ((isManager || isCashier) && key)` — the `(isManager||isCashier)`
  /// half is `tierAtLeast(cashier)` under the CEO disjunct. Tier-based legacy.
  static const NamedGate seeSalesMetric = NamedGate(
    name: 'seeSalesMetric',
    action: 'See Total Sales',
    rule: OrGate(
      Gate.ceo(),
      AndGate(Gate.tierAtLeast(GateTier.cashier), Gate.key('reports.see_sales')),
    ),
  );

  /// Home Net Profit tile (§11.4). CEO always, or anyone holding
  /// `reports.see_profit`. Verbatim `isCeo || key`. Tier-based legacy.
  static const NamedGate seeProfitMetric = NamedGate(
    name: 'seeProfitMetric',
    action: 'See Net Profit',
    rule: OrGate(Gate.ceo(), Gate.key('reports.see_profit')),
  );

  /// Home Total Expenses tile (§11.4). CEO always; a Manager only with
  /// `reports.see_expenses`. Verbatim `isCeo || (isManager && key)`. Tier-based.
  static const NamedGate seeExpensesMetric = NamedGate(
    name: 'seeExpensesMetric',
    action: 'See Total Expenses',
    rule: OrGate(
      Gate.ceo(),
      AndGate(
        Gate.tierAtLeast(GateTier.manager),
        Gate.key('reports.see_expenses'),
      ),
    ),
  );

  /// Home Stock Value tile (§11.4). CEO always; a Manager only with
  /// `stock.view`. Verbatim `isCeo || (isManager && key)`. Tier-based legacy.
  static const NamedGate seeStockValueMetric = NamedGate(
    name: 'seeStockValueMetric',
    action: 'See Stock Value',
    rule: OrGate(
      Gate.ceo(),
      AndGate(Gate.tierAtLeast(GateTier.manager), Gate.key('stock.view')),
    ),
  );

  /// Home Customer Credits Balance tile (§11.4). CEO always; a Manager or
  /// Cashier only with `customers.add`. Verbatim
  /// `isCeo || ((isManager || isCashier) && key)`. Tier-based legacy.
  static const NamedGate seeCreditBalanceMetric = NamedGate(
    name: 'seeCreditBalanceMetric',
    action: 'See Customer Credits',
    rule: OrGate(
      Gate.ceo(),
      AndGate(Gate.tierAtLeast(GateTier.cashier), Gate.key('customers.add')),
    ),
  );

  /// Home Staff Sales breakdown (§11.4 money-visibility). CEO or Manager only —
  /// verbatim `isCeo || isManager` = `tierAtLeast(manager)` (same rule as
  /// `isManagerOrAbove`, §19.3/§18.4). Pure tier — review flag.
  static const NamedGate seeStaffSales = NamedGate(
    name: 'seeStaffSales',
    action: 'See Staff Sales',
    rule: Gate.tierAtLeast(GateTier.manager),
  );

  /// Reports hub → Supplier Accounts report entry (§25.2). Manager-up AND
  /// `suppliers.manage`. Verbatim `isMgrUp && key`. Tier-based legacy.
  static const NamedGate supplierAccountsReport = NamedGate(
    name: 'supplierAccountsReport',
    action: 'Supplier Accounts Report',
    rule: AndGate(
      Gate.tierAtLeast(GateTier.manager),
      Gate.key('suppliers.manage'),
    ),
  );

  /// Reports hub → Profit Report entry (§25.2/§25.3). Manager-up AND
  /// `reports.see_profit` (CEO-only by default grant). Verbatim `isMgrUp && key`.
  /// Tier-based legacy. Distinct from [seeProfitMetric] (home tile, `ceo || key`).
  static const NamedGate profitReportEntry = NamedGate(
    name: 'profitReportEntry',
    action: 'Profit Report',
    rule: AndGate(
      Gate.tierAtLeast(GateTier.manager),
      Gate.key('reports.see_profit'),
    ),
  );

  /// See raw Cost-of-goods figures inside the Profit Report (`reports.see_cost_prices`)
  /// — layered on top of the screen's upstream profit gate. Cited by the on-screen
  /// headline/CSV column and the export path so the two can't drift.
  static const NamedGate seeReportCostPrices = NamedGate(
    name: 'seeReportCostPrices',
    action: 'See Cost Prices in Reports',
    rule: Gate.key('reports.see_cost_prices'),
  );

  // ── POS & Checkout cluster (issue #19) ─────────────────────────────────────

  /// Sell at the till — the sale-making gate (`sales.make`). Cited by the POS
  /// home screen guard (`Guarded.screen`, encoding the no-denial-flash policy it
  /// used to hand-roll) and re-checked as the write boundary at the top of the
  /// checkout confirm path (`require`), so a session that lost the grant mid-flow
  /// — or reached checkout via a stale back-stack — can't post a sale. Revenue
  /// recognition and the discount cap are untouched by this gate.
  static const NamedGate makeSale = NamedGate(
    name: 'makeSale',
    action: 'Point of Sale',
    rule: Gate.key('sales.make'),
  );

  /// Register a new customer (the "New" button in the cart's change-customer
  /// picker). The AddCustomerSheet re-checks the same key at its write boundary.
  static const NamedGate addCustomer = NamedGate(
    name: 'addCustomer',
    action: 'Add Customer',
    rule: Gate.key('customers.add'),
  );

  /// Override a cart line's selling price (the Custom Price field in the edit-
  /// item modal, §13.4). The discount cap still clamps the effective price.
  static const NamedGate setCustomPrice = NamedGate(
    name: 'setCustomPrice',
    action: 'Set Custom Price',
    rule: Gate.key('sales.set_custom_price'),
  );

  /// Every declared gate. Backs the membership test (every entry cited) and
  /// doubles as a living inventory of gated actions (support / onboarding).
  static const List<NamedGate> all = <NamedGate>[
    receiveStock,
    addProduct,
    editProductPrice,
    editBuyingPrice,
    manageSuppliers,
    seeSalesMetric,
    seeProfitMetric,
    seeExpensesMetric,
    seeStockValueMetric,
    seeCreditBalanceMetric,
    seeStaffSales,
    supplierAccountsReport,
    profitReportEntry,
    seeReportCostPrices,
    makeSale,
    addCustomer,
    setCustomPrice,
  ];
}
