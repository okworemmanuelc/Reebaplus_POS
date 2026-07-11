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
  /// receive hint, and the edit-item modal — sub-gate of Receive Stock — plus
  /// the Inventory list's long-press full product editor, issue #20).
  static const NamedGate editProductPrice = NamedGate(
    name: 'editProductPrice',
    action: 'Edit Price',
    rule: Gate.key('products.edit_price'),
  );

  /// Edit a product's buying (cost) price — the receive edit-item modal
  /// (sub-gate of Receive Stock) and the Add Product screen's buying-price
  /// field (issue #20).
  static const NamedGate editBuyingPrice = NamedGate(
    name: 'editBuyingPrice',
    action: 'Edit Buying Price',
    rule: Gate.key('products.edit_buying_price'),
  );

  /// Manage suppliers, incl. recording a supplier payment during a receipt.
  /// Sub-gate of the Receive Stock checkout's payment section; also the Add
  /// Product screen's "Add new supplier" button (issue #20).
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
  /// picker, and the Customers screen FAB — issue #20). The AddCustomerSheet
  /// re-checks the same key at its write boundary.
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

  // ── Operations cluster: Inventory, Stores, Customers, Expenses (issue #20) ─
  // The mechanical batch — single-key and any-of lifts, plus one role-set lift
  // (Daily Stock Count) that needed the `Gate.tierIn` atom.

  /// Open the Inventory screen (`stock.view`, §16.7) — the Stock tab's
  /// body-guard. The drawer item and bottom-nav tab already hide on the same
  /// key; the `Guarded.screen` guard covers deep-links / programmatic tab
  /// switches.
  static const NamedGate viewInventory = NamedGate(
    name: 'viewInventory',
    action: 'Inventory',
    rule: Gate.key('stock.view'),
  );

  /// The Daily Stock Count entry (§16.1/§17.4): Stock keeper, Manager or CEO —
  /// *not* Cashier — AND `stock.adjust`, since count/damage actions decrement
  /// stock and the key is independently revocable. The skipped-tier role set
  /// is exactly what [Gate.tierIn] exists for. **TIER-BASED legacy lift —
  /// review flag: "should this be a permission key?"**
  static const NamedGate dailyStockCount = NamedGate(
    name: 'dailyStockCount',
    action: 'Daily Stock Count',
    rule: AndGate(
      Gate.tierIn([GateTier.ceo, GateTier.manager, GateTier.stockKeeper]),
      Gate.key('stock.adjust'),
    ),
  );

  /// Add/Edit/Delete a store (`stores.manage`, CEO-only by default grant) —
  /// the Stores FAB and each store card's Edit/Delete actions row.
  static const NamedGate manageStores = NamedGate(
    name: 'manageStores',
    action: 'Manage Stores',
    rule: Gate.key('stores.manage'),
  );

  /// Request a stock transfer from another store (§16.8.2) — store details,
  /// and one leg of the Stores screen's browse composite.
  static const NamedGate requestStoreTransfer = NamedGate(
    name: 'requestStoreTransfer',
    action: 'Request Stock Transfer',
    rule: Gate.key('stores.request_transfer'),
  );

  /// Dispatch a stock transfer (fulfil a request / cancel an in-transit one)
  /// in the transfer hub.
  static const NamedGate dispatchStoreTransfer = NamedGate(
    name: 'dispatchStoreTransfer',
    action: 'Dispatch Transfer',
    rule: Gate.key('stores.dispatch_transfer'),
  );

  /// Receive a dispatched transfer into the destination store in the
  /// transfer hub.
  static const NamedGate receiveStoreTransfer = NamedGate(
    name: 'receiveStoreTransfer',
    action: 'Receive Transfer',
    rule: Gate.key('stores.receive_transfer'),
  );

  /// Edit a customer's details (`customers.update`) — the detail screen's pen
  /// icon and its open boundary, re-checked at EditCustomerSheet's save
  /// (write boundary).
  static const NamedGate editCustomer = NamedGate(
    name: 'editCustomer',
    action: 'Edit Customer',
    rule: Gate.key('customers.update'),
  );

  /// Soft-delete a customer (§18.4, `customers.delete`) — never offered for
  /// the synthetic walk-in.
  static const NamedGate deleteCustomer = NamedGate(
    name: 'deleteCustomer',
    action: 'Delete Customer',
    rule: Gate.key('customers.delete'),
  );

  /// Add funds to a customer's wallet (the Add Credit button,
  /// `customers.wallet.update`).
  static const NamedGate addCustomerCredit = NamedGate(
    name: 'addCustomerCredit',
    action: 'Add Credit',
    rule: Gate.key('customers.wallet.update'),
  );

  /// Set a customer's debt limit (`customers.set_debt_limit`).
  static const NamedGate setDebtLimit = NamedGate(
    name: 'setDebtLimit',
    action: 'Set Debt Limit',
    rule: Gate.key('customers.set_debt_limit'),
  );

  /// Refund cash out of a customer's wallet (`customers.wallet.withdraw`).
  static const NamedGate refundCustomerWallet = NamedGate(
    name: 'refundCustomerWallet',
    action: 'Refund Cash',
    rule: Gate.key('customers.wallet.withdraw'),
  );

  /// The wallet Total In / Total Out summary row (§18.4 money visibility).
  /// Deliberately key-based — granted to Manager + CEO by default, per-user
  /// revocable, no role-tier bypass — so an override actually takes effect.
  static const NamedGate seeWalletTotals = NamedGate(
    name: 'seeWalletTotals',
    action: 'See Wallet Totals',
    rule: Gate.key('customers.wallet.totals.view'),
  );

  /// Record crates a customer brought back (§13.4's "+" card on the Crates
  /// tab). Gated on `sales.make` — the till-side transaction permission —
  /// deliberately the same key as [makeSale] but a distinct action with its
  /// own name and denial text.
  static const NamedGate recordCrateReturn = NamedGate(
    name: 'recordCrateReturn',
    action: 'Record Crate Return',
    rule: Gate.key('sales.make'),
  );

  /// Open the Expenses screen (`reports.see_expenses`, hard rule #6): the
  /// screen IS the expense report/list, so its body-guard uses the same key as
  /// the drawer item and the Home "Total Expenses" card ([seeExpensesMetric]
  /// is the home tile's tier-composite form of the same key).
  static const NamedGate viewExpenses = NamedGate(
    name: 'viewExpenses',
    action: 'Expenses',
    rule: Gate.key('reports.see_expenses'),
  );

  /// Record a new expense (the Add Expense FAB, `expenses.create`).
  static const NamedGate addExpense = NamedGate(
    name: 'addExpense',
    action: 'Add Expense',
    rule: Gate.key('expenses.create'),
  );

  /// See and act on the pending-approval section of the Expenses list
  /// (`expenses.approve`).
  static const NamedGate approveExpenses = NamedGate(
    name: 'approveExpenses',
    action: 'Approve Expenses',
    rule: Gate.key('expenses.approve'),
  );

  // ── Settings & sidebar/nav cluster (issue #21) ─────────────────────────────
  // The CEO Settings screens and the drawer's nav-entry visibility gates. Nav
  // gates are render-only (`.allows`); each menu entry cites the same entry as
  // its destination surface, so entry point and screen can't drift. Nav
  // entries whose destination gates already exist cite those directly:
  // Point of Sale → [makeSale], Inventory → [viewInventory], Supplier
  // Accounts → [manageSuppliers], Expenses → [viewExpenses]; the CEO
  // Settings > Stores screen body-guard cites [manageStores].

  /// Open the Sync Issues troubleshooting screen — the composite: `sync.view`
  /// OR CEO (implicit owner of this infra screen; they may not hold the grant
  /// itself — other roles get it via CEO Settings → Sync Issues access). The
  /// ONE entry cited by every surface: the screen's body-guard, the sidebar
  /// item, and the drawer header's sync status badge/banner pill. Replaces the
  /// standalone `canViewSyncIssues` helper. Tier atom is a verbatim lift.
  static const NamedGate viewSyncIssues = NamedGate(
    name: 'viewSyncIssues',
    action: 'Sync Issues',
    rule: OrGate(Gate.key('sync.view'), Gate.ceo()),
  );

  /// CEO Settings (§10.1) — the drawer entry, the settings home screen, and
  /// every sub-screen's body-guard (Business Info, Subscription, Security,
  /// Roles & Permissions and its per-role editor, Activity Logs access,
  /// Sync Issues access, Appearance). `settings.manage` is CEO-only by
  /// default (migration 0043). The Stores sub-screen is the exception — it
  /// body-guards on [manageStores], verbatim.
  static const NamedGate manageSettings = NamedGate(
    name: 'manageSettings',
    action: 'CEO Settings',
    rule: Gate.key('settings.manage'),
  );

  /// Delete Business & Account (§10.3 Danger Zone). Cited by the Danger Zone
  /// entry in CEO Settings (compounded there with a search-match condition,
  /// which is not a permission rule and stays at the call site) and re-checked
  /// by the Delete Business screen's body-guard. Only the CEO holds
  /// `settings.delete_business`.
  static const NamedGate deleteBusiness = NamedGate(
    name: 'deleteBusiness',
    action: 'Delete Business',
    rule: Gate.key('settings.delete_business'),
  );

  /// Customers — the drawer entry (§27.3, hidden for Stock keeper). Gated on
  /// `customers.add` verbatim (there is no separate customers-view key).
  /// Distinct action from [addCustomer] (the register-a-customer write) even
  /// though the rules currently coincide.
  static const NamedGate viewCustomers = NamedGate(
    name: 'viewCustomers',
    action: 'Customers',
    rule: Gate.key('customers.add'),
  );

  /// Staff Management — the drawer entry, gated to the roles that can invite
  /// staff (CEO + Manager, `staff.invite`).
  static const NamedGate manageStaff = NamedGate(
    name: 'manageStaff',
    action: 'Staff Management',
    rule: Gate.key('staff.invite'),
  );

  /// Activity Logs — the drawer entry (§27.3: CEO always; Manager only if
  /// granted `activity_logs.view`; hidden for Cashier/Stock keeper).
  static const NamedGate viewActivityLogs = NamedGate(
    name: 'viewActivityLogs',
    action: 'Activity Logs',
    rule: Gate.key('activity_logs.view'),
  );

  /// Stores — the drawer entry: the CEO (`stores.manage`) plus any Manager
  /// who takes part in the store-scoped transfer flow (§16.8.2): request /
  /// dispatch / receive. Lifted verbatim from the drawer's four-way OR. The
  /// Stores screen's own browse composite is wider (it adds the all-stores-
  /// viewer leg, a provider not a key) and stays inline at that call site.
  static const NamedGate viewStores = NamedGate(
    name: 'viewStores',
    action: 'Stores',
    rule: Gate.anyKey([
      'stores.manage',
      'stores.request_transfer',
      'stores.dispatch_transfer',
      'stores.receive_transfer',
    ]),
  );

  // ── Staff, Orders & finish-line cluster (issue #22) ────────────────────────
  // The last bare `hasPermission` sites (staff actions, order refund, activity
  // logs), plus the §19 money/history-visibility gates lifted off the retired
  // `isManagerOrAbove` cross-cutting helper — with the flip, tier logic lives
  // ONLY in these registry atoms, never inline in feature code. The tier gates
  // below are verbatim legacy lifts (`isManagerOrAbove` → `tierAtLeast(manager)`,
  // identical: `roleRank(slug) <= 1`), render-only (`.allows`), and carry the
  // §19.3-class review flag.

  /// Assign a staff member to specific stores (§9.5, `staff.assign_stores`) —
  /// the staff-detail store-assignment editor; re-checked at the write site.
  static const NamedGate assignStaffStores = NamedGate(
    name: 'assignStaffStores',
    action: 'Assign Stores',
    rule: Gate.key('staff.assign_stores'),
  );

  /// Change a staff member's role (§9, `staff.change_role`, CEO + Manager by
  /// default) — the staff-detail "Change role" action.
  static const NamedGate changeStaffRole = NamedGate(
    name: 'changeStaffRole',
    action: 'Change Role',
    rule: Gate.key('staff.change_role'),
  );

  /// Suspend or reactivate a staff member (§9, `staff.suspend`, CEO + Manager by
  /// default) — the staff-detail Suspend/Reactivate action.
  static const NamedGate suspendStaff = NamedGate(
    name: 'suspendStaff',
    action: 'Suspend Staff',
    rule: Gate.key('staff.suspend'),
  );

  /// Permanently remove a staff member (#107 staff offboarding, `staff.remove`,
  /// CEO-only by default) — the staff-detail "Remove" action. Terminal: it runs
  /// the server-authoritative `remove_staff_member` RPC, which nulls the
  /// identity's auth link (freeing the email for a fresh business) and sets the
  /// membership status to `removed`, while KEEPING the users row as an
  /// attribution stub so historical sales still show the person's name. Removing
  /// the business owner is rejected. More destructive than suspend, so it is
  /// CEO-only by default (the CEO can grant it to a Manager via the role page).
  static const NamedGate staffRemove = NamedGate(
    name: 'staffRemove',
    action: 'Remove Staff',
    rule: Gate.key('staff.remove'),
  );

  /// Refund a pending order (§19.7, `sales.cancel`, CEO + Manager by default) —
  /// the Orders Pending-tab Refund action, gated at render.
  static const NamedGate refundOrder = NamedGate(
    name: 'refundOrder',
    action: 'Refund Order',
    rule: Gate.key('sales.cancel'),
  );

  /// See monetary values on Orders (§19.3): the per-order line prices / total /
  /// paid / discount, and the per-tab money summary stats (Total Value, Revenue,
  /// Collected, Crate Deposits). Roles below Manager see items + quantities only.
  /// Verbatim `isManagerOrAbove` → `tierAtLeast(manager)`. **TIER-BASED / §19.3
  /// money-visibility — review flag.** Render-only (`.allows`).
  static const NamedGate seeOrderMoney = NamedGate(
    name: 'seeOrderMoney',
    action: 'See Order Amounts',
    rule: Gate.tierAtLeast(GateTier.manager),
  );

  /// Choose the wider date-range presets (This Year / To Date) on the period-
  /// scoped screens (§19.2/§30.11). Roles below Manager are capped to Today /
  /// This Week / This Month / Custom (see `datePeriodLabelsForRole`). Verbatim
  /// `isManagerOrAbove` → `tierAtLeast(manager)`. **TIER-BASED / §19.2 — review
  /// flag.** Render-only (`.allows`).
  static const NamedGate seeExtendedDateRanges = NamedGate(
    name: 'seeExtendedDateRanges',
    action: 'See Extended Date Ranges',
    rule: Gate.tierAtLeast(GateTier.manager),
  );

  /// Reports hub → Approvals entry (§16.6.1/§12.3.1): stock-keeper adjustment +
  /// cashier quick-sale approvals await a Manager / the CEO. Manager-up. Verbatim
  /// `isMgrUp` → `tierAtLeast(manager)`. **TIER-BASED — review flag.** Render-only.
  static const NamedGate viewApprovals = NamedGate(
    name: 'viewApprovals',
    action: 'Approvals',
    rule: Gate.tierAtLeast(GateTier.manager),
  );

  /// Reports hub → Daily Reconciliation entry (§25.9). Manager-up. Verbatim
  /// `isMgrUp` → `tierAtLeast(manager)`. **TIER-BASED — review flag.** Render-only.
  static const NamedGate dailyReconciliation = NamedGate(
    name: 'dailyReconciliation',
    action: 'Daily Reconciliation',
    rule: Gate.tierAtLeast(GateTier.manager),
  );

  /// Reports hub → Crate Deposits entry (§13.4 Ring 7). Manager-up — compounded
  /// at the call site with the crate-business-type check (a business-type rule,
  /// not a permission, so it stays inline, like `deleteBusiness`'s search-match).
  /// Verbatim `isMgrUp` → `tierAtLeast(manager)`. **TIER-BASED — review flag.**
  static const NamedGate crateDepositsReport = NamedGate(
    name: 'crateDepositsReport',
    action: 'Crate Deposits Report',
    rule: Gate.tierAtLeast(GateTier.manager),
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
    viewInventory,
    dailyStockCount,
    manageStores,
    requestStoreTransfer,
    dispatchStoreTransfer,
    receiveStoreTransfer,
    editCustomer,
    deleteCustomer,
    addCustomerCredit,
    setDebtLimit,
    refundCustomerWallet,
    seeWalletTotals,
    recordCrateReturn,
    viewExpenses,
    addExpense,
    approveExpenses,
    viewSyncIssues,
    manageSettings,
    deleteBusiness,
    viewCustomers,
    manageStaff,
    viewActivityLogs,
    viewStores,
    assignStaffStores,
    changeStaffRole,
    suspendStaff,
    staffRemove,
    refundOrder,
    seeOrderMoney,
    seeExtendedDateRanges,
    viewApprovals,
    dailyReconciliation,
    crateDepositsReport,
  ];
}
