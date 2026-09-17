import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/core/diagnostics/overflow_route_reporter.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/first_run_surface_state.dart';
import 'package:reebaplus_pos/core/settings/activity_logs_access_screen.dart';
import 'package:reebaplus_pos/core/settings/appearance_settings_screen.dart';
import 'package:reebaplus_pos/core/settings/business_info_screen.dart';
import 'package:reebaplus_pos/core/settings/delete_business_screen.dart';
import 'package:reebaplus_pos/core/settings/role_permissions_detail_screen.dart';
import 'package:reebaplus_pos/core/settings/roles_permissions_screen.dart';
import 'package:reebaplus_pos/core/settings/security_settings_screen.dart';
import 'package:reebaplus_pos/core/settings/settings_screen.dart';
import 'package:reebaplus_pos/core/settings/stores_settings_screen.dart';
import 'package:reebaplus_pos/core/settings/subscription_screen.dart';
import 'package:reebaplus_pos/core/settings/sync_issues_access_screen.dart';
import 'package:reebaplus_pos/core/theme/theme_settings_screen.dart';
import 'package:reebaplus_pos/features/auth/screens/ceo_sign_up_screen.dart';
import 'package:reebaplus_pos/features/auth/screens/coming_soon_screen.dart';
import 'package:reebaplus_pos/features/auth/screens/create_pin_screen.dart';
import 'package:reebaplus_pos/features/auth/screens/email_entry_screen.dart';
import 'package:reebaplus_pos/features/auth/screens/login_screen.dart';
import 'package:reebaplus_pos/features/auth/screens/no_account_found_screen.dart';
import 'package:reebaplus_pos/features/auth/screens/staff_sign_up_screen.dart';
import 'package:reebaplus_pos/features/auth/screens/success_dashboard_entry_screen.dart';
import 'package:reebaplus_pos/features/auth/screens/welcome_screen.dart';
import 'package:reebaplus_pos/features/customers/data/models/customer.dart';
import 'package:reebaplus_pos/features/customers/screens/customer_detail_screen.dart';
import 'package:reebaplus_pos/features/customers/screens/customers_screen.dart';
import 'package:reebaplus_pos/features/dashboard/reconciliation/recon_data.dart';
import 'package:reebaplus_pos/features/dashboard/screens/crate_deposits_report_screen.dart';
import 'package:reebaplus_pos/features/dashboard/screens/daily_reconciliation_detail_screen.dart';
import 'package:reebaplus_pos/features/dashboard/screens/daily_reconciliation_list_screen.dart';
import 'package:reebaplus_pos/features/dashboard/screens/home_screen.dart';
import 'package:reebaplus_pos/features/dashboard/screens/profit_report_screen.dart';
import 'package:reebaplus_pos/features/dashboard/screens/reports_hub_screen.dart';
import 'package:reebaplus_pos/features/dashboard/screens/sales_detail_screen.dart';
import 'package:reebaplus_pos/features/dashboard/screens/stock_approvals_screen.dart';
import 'package:reebaplus_pos/features/dashboard/screens/supplier_accounts_report_screen.dart';
import 'package:reebaplus_pos/features/expenses/screens/add_expense_screen.dart';
import 'package:reebaplus_pos/features/expenses/screens/expenses_screen.dart';
import 'package:reebaplus_pos/features/inventory/data/models/inventory_item.dart';
import 'package:reebaplus_pos/features/inventory/screens/add_product_screen.dart';
import 'package:reebaplus_pos/features/inventory/screens/inventory_screen.dart';
import 'package:reebaplus_pos/features/inventory/screens/product_detail_screen.dart';
import 'package:reebaplus_pos/features/inventory/screens/stock_count_screen.dart';
import 'package:reebaplus_pos/features/inventory/screens/supplier_detail_screen.dart';
import 'package:reebaplus_pos/features/orders/screens/crate_return_approval_screen.dart';
import 'package:reebaplus_pos/features/orders/screens/orders_screen.dart';
import 'package:reebaplus_pos/features/payments/screens/payments_screen.dart';
import 'package:reebaplus_pos/features/payments/screens/supplier_transactions_screen.dart';
import 'package:reebaplus_pos/features/pos/screens/cart_screen.dart';
import 'package:reebaplus_pos/features/pos/screens/pos_home_screen.dart';
import 'package:reebaplus_pos/features/profile/screens/profile_screen.dart';
import 'package:reebaplus_pos/features/receiving/screens/receive_cart_screen.dart';
import 'package:reebaplus_pos/features/receiving/screens/receive_checkout_screen.dart';
import 'package:reebaplus_pos/features/receiving/screens/receive_stock_screen.dart';
import 'package:reebaplus_pos/features/settings/screens/staff_settings_screen.dart';
import 'package:reebaplus_pos/features/staff/screens/invite_staff_screen.dart';
import 'package:reebaplus_pos/features/staff/screens/staff_detail_screen.dart';
import 'package:reebaplus_pos/features/staff/screens/staff_management_screen.dart';
import 'package:reebaplus_pos/features/staff/screens/staff_permissions_screen.dart';
import 'package:reebaplus_pos/features/stores/screens/request_stock_screen.dart';
import 'package:reebaplus_pos/features/stores/screens/store_details_screen.dart';
import 'package:reebaplus_pos/features/stores/screens/stores_screen.dart';
import 'package:reebaplus_pos/features/subscription/screens/subscription_locked_screen.dart';
import 'package:reebaplus_pos/features/subscription/screens/thank_you_subscription_screen.dart';
import 'package:reebaplus_pos/features/subscription/subscription_access.dart';
import 'package:reebaplus_pos/features/sync/screens/sync_issues_screen.dart';
import 'package:reebaplus_pos/features/van_sales/screens/driver_payments_screen.dart';
import 'package:reebaplus_pos/features/van_sales/screens/driver_profile_screen.dart';
import 'package:reebaplus_pos/features/van_sales/screens/driver_run_screen.dart';
import 'package:reebaplus_pos/features/van_sales/screens/driver_terminal_screen.dart';
import 'package:reebaplus_pos/features/van_sales/screens/drivers_list_screen.dart';
import 'package:reebaplus_pos/features/van_sales/screens/load_van_screen.dart';
import 'package:reebaplus_pos/features/van_sales/screens/van_reconcile_screen.dart';
import 'package:reebaplus_pos/features/van_sales/screens/van_return_screen.dart';
import 'package:reebaplus_pos/features/van_sales/screens/van_sales_hub_screen.dart';
import 'package:reebaplus_pos/shared/widgets/activity_log_screen.dart';

import '../helpers/screen_harness.dart';
import '../helpers/viewports.dart';

/// Issue #241 / PRD #239 — the runtime discovery sweep.
///
/// Not a regression test. It pumps every screen at the shortest supported
/// landscape viewport, in an empty and a populated data state, and records both
/// failure modes rather than asserting on them:
///
///   * **Loud** — overflow reports, tagged with their owning screen by
///     [OverflowRouteReporter].
///   * **Silent** — every on-screen vertical scrollable whose viewport, *at
///     rest*, is shorter than one content row while it has content to show.
///     A starved scrollable throws nothing, so this has to be measured.
///
/// Skipped unless `VIEWPORT_SWEEP=1`, so the normal suite stays fast:
///
///     VIEWPORT_SWEEP=1 flutter test test/discovery/viewport_sweep_test.dart
///
/// Each result prints one `SWEEP|` line; grep for them.

/// A vertical viewport shorter than this cannot show one complete row.
const double _kRowFloor = 48.0;

/// Every permission key the gate registry names — the sweep runs as a CEO who
/// can reach every surface.
const Set<String> _allGrants = {
  'activity_logs.view',
  'customers.add', 'customers.delete', 'customers.set_debt_limit',
  'customers.update', 'customers.wallet.totals.view', 'customers.wallet.update',
  'customers.wallet.withdraw', 'expenses.approve', 'expenses.create',
  'products.add', 'products.edit_buying_price', 'products.edit_price',
  'reports.see_cost_prices', 'reports.see_expenses', 'reports.see_profit',
  'reports.see_sales', 'sales.cancel', 'sales.confirm', 'sales.make',
  'sales.set_custom_price', 'settings.delete_business', 'settings.manage',
  'staff.assign_stores', 'staff.change_role', 'staff.invite', 'staff.remove',
  'staff.suspend', 'stock.add', 'stock.adjust', 'stock.view',
  'stores.dispatch_transfer', 'stores.manage', 'stores.receive_transfer',
  'stores.request_transfer', 'suppliers.manage', 'sync.view', 'van.manage',
  'van.sell',
};

/// The subjects a detail screen opens on. Seeded in both data states: an
/// "empty" Customer Detail is a customer with no history, not no customer.
class _Subjects {
  final ScreenTestEnvironment env;
  final CustomerData customer;
  final String supplierId;
  final RoleData role;
  final UserData staff;
  final String membershipId;
  final String driverUserId;
  final StoreData vanStore;
  final VanTripData trip;
  final BusinessData business;
  final List<OrderWithItems> orders;

  const _Subjects({
    required this.env,
    required this.customer,
    required this.supplierId,
    required this.role,
    required this.staff,
    required this.membershipId,
    required this.driverUserId,
    required this.vanStore,
    required this.trip,
    required this.business,
    required this.orders,
  });
}

class _Screen {
  final String name;
  final Widget Function(_Subjects s) build;

  /// Fills provider-held state the screen reads instead of its constructor
  /// (the cart). Runs after the pump, in the populated state only.
  final void Function(ProviderContainer c, _Subjects s)? populate;

  const _Screen(this.name, this.build, {this.populate});
}

final List<_Screen> _screens = [
  // Bottom-nav tabs.
  _Screen('HomeScreen', (_) => const HomeScreen()),
  _Screen('PosHomeScreen', (_) => const PosHomeScreen()),
  _Screen('InventoryScreen', (_) => const InventoryScreen()),
  _Screen('OrdersScreen', (_) => const OrdersScreen()),
  _Screen('CustomersScreen', (_) => const CustomersScreen()),
  _Screen('PaymentsScreen', (_) => const PaymentsScreen()),
  _Screen('ExpensesScreen', (_) => const ExpensesScreen()),
  _Screen('StoresScreen', (_) => const StoresScreen()),
  _Screen(
    'CartScreen',
    (_) => CartScreen(cart: const [], onCustomerChanged: (_) {}),
    populate: (c, s) {
      for (final p in s.env.products) {
        c.read(cartProvider).addItem(p, qty: 2);
      }
    },
  ),
  _Screen('ActivityLogScreen', (_) => const ActivityLogScreen()),
  // Pushed screens.
  _Screen('CustomerDetailScreen', (s) => CustomerDetailScreen(customer: Customer.fromDb(s.customer))),
  _Screen('SupplierDetailScreen', (s) => SupplierDetailScreen(supplierId: s.supplierId)),
  _Screen('SupplierTransactionsScreen', (_) => const SupplierTransactionsScreen()),
  _Screen('AddProductScreen', (_) => const AddProductScreen()),
  _Screen(
    'ProductDetailScreen',
    (s) => ProductDetailScreen(
      item: InventoryItem(
        id: s.env.products.isEmpty ? 'missing' : s.env.products.first.id,
        productName: s.env.products.isEmpty ? 'Product' : s.env.products.first.name,
        subtitle: 'Drinks',
        icon: Icons.local_drink,
        color: Colors.blue,
        storeStock: {s.env.storeId: 50},
        lowStockThreshold: 5,
      ),
      onUpdateStock: () {},
      selectedStoreId: s.env.storeId,
    ),
  ),
  _Screen('StockCountScreen', (s) => StockCountScreen(storeId: s.env.storeId)),
  _Screen('CrateReturnApprovalScreen', (_) => const CrateReturnApprovalScreen()),
  _Screen('ReceiveStockScreen', (_) => const ReceiveStockScreen()),
  _Screen('ReceiveCartScreen', (_) => const ReceiveCartScreen()),
  _Screen('ReceiveCheckoutScreen', (_) => const ReceiveCheckoutScreen()),
  _Screen('AddExpenseScreen', (_) => const AddExpenseScreen()),
  _Screen('ReportsHubScreen', (_) => const ReportsHubScreen()),
  _Screen('ProfitReportScreen', (_) => const ProfitReportScreen()),
  _Screen('CrateDepositsReportScreen', (_) => const CrateDepositsReportScreen()),
  _Screen('SupplierAccountsReportScreen', (_) => const SupplierAccountsReportScreen()),
  _Screen('DailyReconciliationListScreen', (_) => const DailyReconciliationListScreen()),
  _Screen(
    'DailyReconciliationDetailScreen',
    (_) {
      final now = DateTime.now();
      final start = DateTime(now.year, now.month, now.day);
      return DailyReconciliationDetailScreen(
        start: start,
        endExclusive: start.add(const Duration(days: 1)),
        grouping: ReconGrouping.day,
        title: 'Today',
      );
    },
  ),
  _Screen(
    'SalesDetailScreen',
    (s) => SalesDetailScreen(orders: s.orders, mode: 'sales', period: 'Today'),
  ),
  _Screen('StockApprovalsScreen', (_) => const StockApprovalsScreen()),
  _Screen('ProfileScreen', (_) => const ProfileScreen()),
  _Screen('StoreDetailsScreen', (s) => StoreDetailsScreen(store: s.env.store)),
  _Screen('RequestStockScreen', (s) => RequestStockScreen(fixedDestStoreId: s.env.storeId)),
  _Screen('StaffManagementScreen', (_) => const StaffManagementScreen()),
  _Screen('StaffDetailScreen', (s) => StaffDetailScreen(membershipId: s.membershipId)),
  _Screen('StaffPermissionsScreen', (s) => StaffPermissionsScreen(user: s.staff, role: s.role)),
  _Screen('InviteStaffScreen', (_) => const InviteStaffScreen()),
  _Screen('StaffSettingsScreen', (_) => const StaffSettingsScreen()),
  _Screen('SyncIssuesScreen', (_) => const SyncIssuesScreen()),
  // Van sales.
  _Screen('VanSalesHubScreen', (_) => const VanSalesHubScreen()),
  _Screen('DriversListScreen', (_) => const DriversListScreen()),
  _Screen('DriverProfileScreen', (s) => DriverProfileScreen(driverUserId: s.driverUserId)),
  _Screen('DriverTerminalScreen', (_) => const DriverTerminalScreen()),
  _Screen('DriverRunScreen', (s) => DriverRunScreen(tripId: s.trip.id)),
  _Screen(
    'DriverPaymentsScreen',
    (s) => DriverPaymentsScreen(tripId: s.trip.id, driverName: 'Dayo', vanName: 'Van 1'),
  ),
  _Screen('LoadVanScreen', (s) => LoadVanScreen(vanStoreId: s.vanStore.id, trip: s.trip)),
  _Screen(
    'VanReconcileScreen',
    (s) => VanReconcileScreen(tripId: s.trip.id, driverName: 'Dayo', vanName: 'Van 1'),
  ),
  _Screen(
    'VanReturnScreen',
    (s) => VanReturnScreen(trip: s.trip, driverName: 'Dayo', vanName: 'Van 1'),
  ),
  // Settings.
  _Screen('SettingsScreen', (_) => const SettingsScreen()),
  _Screen('AppearanceSettingsScreen', (_) => const AppearanceSettingsScreen()),
  _Screen('ThemeSettingsScreen', (_) => const ThemeSettingsScreen()),
  _Screen('BusinessInfoScreen', (_) => const BusinessInfoScreen()),
  _Screen('SecuritySettingsScreen', (_) => const SecuritySettingsScreen()),
  _Screen('StoresSettingsScreen', (_) => const StoresSettingsScreen()),
  _Screen('RolesPermissionsScreen', (_) => const RolesPermissionsScreen()),
  _Screen('RolePermissionsDetailScreen', (s) => RolePermissionsDetailScreen(role: s.role)),
  _Screen('ActivityLogsAccessScreen', (_) => const ActivityLogsAccessScreen()),
  _Screen('SyncIssuesAccessScreen', (_) => const SyncIssuesAccessScreen()),
  _Screen('SubscriptionScreen', (_) => const SubscriptionScreen()),
  _Screen('DeleteBusinessScreen', (_) => const DeleteBusinessScreen()),
  _Screen(
    'SubscriptionLockedScreen',
    (_) => const SubscriptionLockedScreen(access: SubscriptionAccess.trialExpired),
  ),
  _Screen('ThankYouSubscriptionScreen', (s) => ThankYouSubscriptionScreen(business: s.business)),
  // Pre-shell (auth). The fuller auth suite already pumps these at 800x360.
  _Screen('WelcomeScreen', (_) => const WelcomeScreen()),
  _Screen('LoginScreen', (_) => const LoginScreen()),
  _Screen('CreatePinScreen', (_) => const CreatePinScreen(isNewBusinessSetup: true)),
  _Screen('EmailEntryScreen', (_) => const EmailEntryScreen()),
  _Screen('CeoSignUpScreen', (_) => const CeoSignUpScreen()),
  _Screen('StaffSignUpScreen', (_) => const StaffSignUpScreen()),
  _Screen('NoAccountFoundScreen', (_) => const NoAccountFoundScreen(email: 'a@b.co')),
  _Screen('SuccessDashboardEntryScreen', (_) => const SuccessDashboardEntryScreen()),
  _Screen(
    'ComingSoonScreen',
    (_) => const ComingSoonScreen(title: 'Coming soon', message: 'Soon.'),
  ),
];

Future<_Subjects> _seedSubjects(ScreenTestEnvironment env, {required bool populated}) async {
  final db = env.db;
  final b = env.businessId;

  Future<String> role(String name, String slug) async {
    final id = UuidV7.generate();
    await db.into(db.roles).insert(
          RolesCompanion.insert(id: Value(id), businessId: b, name: name, slug: slug),
        );
    return id;
  }

  Future<(UserData, String)> member(String name, String roleId) async {
    final id = UuidV7.generate();
    await db.into(db.users).insert(
          UsersCompanion.insert(id: Value(id), businessId: b, name: name, pin: '123456'),
        );
    final membershipId = UuidV7.generate();
    await db.into(db.userBusinesses).insert(
          UserBusinessesCompanion.insert(
            id: Value(membershipId),
            businessId: b,
            userId: id,
            roleId: roleId,
            status: const Value('active'),
          ),
        );
    final user = await (db.select(db.users)..where((u) => u.id.equals(id))).getSingle();
    return (user, membershipId);
  }

  final ceoRoleId = await role('CEO', 'ceo');
  final cashierRoleId = await role('Cashier', 'cashier');
  final driverRoleId = await role('Driver', 'driver');
  final (staff, membershipId) = await member('Chidi Cashier', cashierRoleId);
  final (driver, _) = await member('Dayo Driver', driverRoleId);

  final customerId = UuidV7.generate();
  await db.into(db.customers).insert(
        CustomersCompanion.insert(id: Value(customerId), businessId: b, name: 'Ada Customer'),
      );
  final supplierId = UuidV7.generate();
  await db.into(db.suppliers).insert(
        SuppliersCompanion.insert(id: Value(supplierId), businessId: b, name: 'Bola Supplies'),
      );

  final vanStoreId = UuidV7.generate();
  await db.into(db.stores).insert(
        StoresCompanion.insert(
          id: Value(vanStoreId),
          businessId: b,
          name: 'Van 1',
          kind: const Value(kStoreKindVan),
        ),
      );
  final tripId = UuidV7.generate();
  await db.into(db.vanTrips).insert(
        VanTripsCompanion.insert(
          id: Value(tripId),
          businessId: b,
          vanStoreId: vanStoreId,
          driverUserId: driver.id,
          sourceStoreId: env.storeId,
        ),
      );

  if (populated) {
    await _seedHistory(env, customerId: customerId, supplierId: supplierId, staffId: staff.id);
  }

  return _Subjects(
    env: env,
    customer: await (db.select(db.customers)..where((t) => t.id.equals(customerId))).getSingle(),
    supplierId: supplierId,
    role: await (db.select(db.roles)..where((t) => t.id.equals(ceoRoleId))).getSingle(),
    staff: staff,
    membershipId: membershipId,
    driverUserId: driver.id,
    vanStore: (await db.storesDao.getStore(vanStoreId))!,
    trip: await (db.select(db.vanTrips)..where((t) => t.id.equals(tripId))).getSingle(),
    business: await (db.select(db.businesses)..where((t) => t.id.equals(b))).getSingle(),
    orders: await db.ordersDao.watchAllOrdersWithItems().first,
  );
}

/// Enough rows that every list-bearing screen has more content than fits.
Future<void> _seedHistory(
  ScreenTestEnvironment env, {
  required String customerId,
  required String supplierId,
  required String staffId,
}) async {
  final db = env.db;
  final b = env.businessId;
  final now = DateTime.now();

  for (var i = 1; i <= 8; i++) {
    final c = UuidV7.generate();
    await db.into(db.customers).insert(
          CustomersCompanion.insert(id: Value(c), businessId: b, name: 'Customer $i'),
        );
    await db.into(db.suppliers).insert(
          SuppliersCompanion.insert(id: Value(UuidV7.generate()), businessId: b, name: 'Supplier $i'),
        );
  }

  final expenseCategoryId = UuidV7.generate();
  await db.into(db.expenseCategories).insert(
        ExpenseCategoriesCompanion.insert(id: Value(expenseCategoryId), businessId: b, name: 'Fuel'),
      );

  final walletId = UuidV7.generate();
  await db.into(db.customerWallets).insert(
        CustomerWalletsCompanion.insert(id: Value(walletId), businessId: b, customerId: customerId),
      );

  for (var i = 1; i <= 12; i++) {
    await db.into(db.walletTransactions).insert(
          WalletTransactionsCompanion.insert(
            id: Value(UuidV7.generate()),
            businessId: b,
            walletId: walletId,
            customerId: customerId,
            type: 'credit',
            amountKobo: 10000 * i,
            signedAmountKobo: 10000 * i,
            referenceType: 'topup_cash',
            createdAt: Value(now.subtract(Duration(hours: i))),
          ),
        );
    final orderId = UuidV7.generate();
    final at = now.subtract(Duration(hours: i));
    await db.into(db.orders).insert(
          OrdersCompanion.insert(
            id: Value(orderId),
            businessId: b,
            orderNumber: 'ORD-00000$i-SWEEP',
            customerId: Value(i.isEven ? customerId : null),
            totalAmountKobo: 200000,
            netAmountKobo: 200000,
            amountPaidKobo: const Value(200000),
            paymentType: 'cash',
            status: i % 4 == 0 ? 'pending' : 'completed',
            staffId: Value(staffId),
            storeId: Value(env.storeId),
            completedAt: Value(at),
            createdAt: Value(at),
          ),
        );
    if (env.products.isNotEmpty) {
      await db.into(db.orderItems).insert(
            OrderItemsCompanion.insert(
              id: Value(UuidV7.generate()),
              businessId: b,
              orderId: orderId,
              storeId: env.storeId,
              productId: Value(env.products[i % env.products.length].id),
              quantity: 2,
              unitPriceKobo: 100000,
              totalKobo: 200000,
              createdAt: Value(at),
            ),
          );
    }
    await db.into(db.expenses).insert(
          ExpensesCompanion.insert(
            id: Value(UuidV7.generate()),
            businessId: b,
            amountKobo: 5000 * i,
            description: 'Expense $i',
            categoryId: Value(expenseCategoryId),
            storeId: Value(env.storeId),
            createdAt: Value(at),
          ),
        );
    await db.into(db.activityLogs).insert(
          ActivityLogsCompanion.insert(
            id: Value(UuidV7.generate()),
            businessId: b,
            action: 'sale',
            description: 'Activity $i',
            createdAt: Value(at),
          ),
        );
    await db.into(db.supplierLedgerEntries).insert(
          SupplierLedgerEntriesCompanion.insert(
            id: Value(UuidV7.generate()),
            businessId: b,
            supplierId: supplierId,
            type: 'credit',
            amountKobo: 10000 * i,
            signedAmountKobo: 10000 * i,
            referenceType: 'payment_cash',
            activityDate: at,
            storeId: Value(env.storeId),
            createdAt: Value(at),
          ),
        );
  }
}

/// One vertical scroll surface as laid out at rest.
class _Surface {
  final String owner;
  final double viewport;
  final double content;
  const _Surface(this.owner, this.viewport, this.content);

  bool get starved => viewport < _kRowFloor && content > viewport + 0.5;

  @override
  String toString() =>
      '$owner ${viewport.toStringAsFixed(1)}/${content.toStringAsFixed(1)}dp';
}

List<_Surface> _measureSurfaces(WidgetTester tester) {
  final surfaces = <_Surface>[];
  // skipOffstage: false — the framework counts a sliver scrolled below its
  // viewport as offstage, which is exactly where a starved tab body sits at
  // rest. The sweep pumps one screen with no hidden tabs, so nothing truly
  // offstage is counted.
  for (final state in tester.stateList<ScrollableState>(
    find.byType(Scrollable, skipOffstage: false),
  )) {
    final position = state.position;
    if (position.axis != Axis.vertical) continue;
    if (!position.hasViewportDimension || !position.hasContentDimensions) continue;
    final box = state.context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize || box.size.width <= 0) continue;
    // Deliberately not filtered on position: a starved list often sits below
    // the screen edge at rest, and its viewport is starved wherever it is.

    String? owner;
    var inTextField = false;
    state.context.visitAncestorElements((e) {
      final name = e.widget.runtimeType.toString();
      if (e.widget is EditableText) inTextField = true;
      if (owner == null && !name.startsWith('_') && !_plumbing.contains(name)) {
        owner = name;
      }
      return !inTextField && owner == null;
    });
    if (inTextField) continue;
    surfaces.add(
      _Surface(
        owner ?? 'Scrollable',
        position.viewportDimension,
        position.maxScrollExtent + position.viewportDimension,
      ),
    );
  }
  return surfaces;
}

const Set<String> _plumbing = {
  'Scrollable', 'NotificationListener<ScrollMetricsNotification>',
  'RepaintBoundary', 'Semantics', 'PrimaryScrollController', 'ScrollConfiguration',
  'Listener', 'KeyedSubtree', 'NotificationListener<ScrollNotification>',
  'GlowingOverscrollIndicator', 'StretchingOverscrollIndicator',
  'NotificationListener<ScrollUpdateNotification>',
};

Future<void> _sweep(
  WidgetTester tester, {
  required String state,
  required _Screen screen,
  required _Subjects subjects,
  required bool populated,
}) async {
  final original = FlutterError.onError;
  final reports = <OverflowReport>[];
  final otherErrors = <String>[];
  FlutterError.onError = (details) {
    if (!OverflowRouteReporter.isOverflow(details)) {
      otherErrors.add(details.exceptionAsString().split('\n').first);
    }
  };
  OverflowRouteReporter.install(enabled: true, onReport: reports.add);

  var pumpError = '';
  var surfaces = <_Surface>[];
  var loaders = 0;
  var allScrollables = '';
  var texts = '';
  try {
    final context = await pumpScreen(
      tester,
      env: subjects.env,
      size: androidCompactLandscape,
      screen: screen.build(subjects),
      grantedKeys: _allGrants,
      // Pinned to the data state, as the Inventory viewport suite does: the
      // live provider graph keeps a Drift stream open that hangs db.close().
      overrides: [
        firstRunSurfaceStateProvider.overrideWithValue(
          populated ? FirstRunSurfaceState.hasContent : FirstRunSurfaceState.addProductCta,
        ),
      ],
      settle: false,
    );
    if (populated && screen.populate != null) {
      screen.populate!(ProviderScope.containerOf(context, listen: false), subjects);
    }
    // Let Drift streams deliver, then let animations run out.
    // Bounded rather than pumpAndSettle: shimmer and spinner animations never
    // settle. The real-async gaps let one-shot DAO futures resolve; without
    // them a detail screen is measured while it is still on its spinner.
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 250));
    }
    surfaces = _measureSurfaces(tester);
    loaders = find.byType(CircularProgressIndicator).evaluate().length;
    allScrollables = tester
        .stateList<ScrollableState>(find.byType(Scrollable, skipOffstage: false))
        .where((st) => st.position.axis == Axis.vertical)
        .map((st) {
          final box = st.context.findRenderObject() as RenderBox?;
          final h = box != null && box.hasSize ? box.size.height : -1;
          final vp = st.position.hasViewportDimension ? st.position.viewportDimension : -1;
          return '${st.widget.runtimeType}:${h.toStringAsFixed(0)}/${vp.toStringAsFixed(0)}';
        })
        .join(',');
    texts = find
        .byType(Text)
        .evaluate()
        .map((e) => (e.widget as Text).data ?? '')
        .where((t) => t.trim().isNotEmpty)
        .take(int.tryParse(Platform.environment['VIEWPORT_SWEEP_TEXTS'] ?? '') ?? 6)
        .join(' / ');
  } catch (e) {
    pumpError = e.toString().split('\n').first;
  } finally {
    FlutterError.onError = original;
  }

  final starved = surfaces.where((s) => s.starved).toList();
  final loud = reports.isNotEmpty;
  final verdict = pumpError.isNotEmpty
      ? 'NOT-PUMPED'
      : [
          if (otherErrors.isNotEmpty) 'ERROR',
          if (loud) 'LOUD',
          if (starved.isNotEmpty) 'SILENT',
        ].join('+');
  final line = [
    'SWEEP',
    state,
    screen.name,
    verdict.isEmpty ? 'OK' : verdict,
    'overflows=${reports.map((r) => '${r.route} ${r.widget}: ${r.summary}').toSet().join(' ; ')}',
    'starved=${starved.join(' ; ')}',
    'surfaces=${surfaces.join(' ; ')}',
    'loaders=$loaders',
    'allVertical=$allScrollables',
    'texts=$texts',
    'errors=${{...otherErrors, if (pumpError.isNotEmpty) pumpError}.join(' ; ')}',
  ].join('|');
  // ignore: avoid_print
  print(line);
  final out = Platform.environment['VIEWPORT_SWEEP_OUT'];
  if (out != null) {
    File(out).writeAsStringSync('$line\n', mode: FileMode.append);
  }

  try {
    await disposeScreen(tester);
  } catch (_) {}
  // Swallow anything the binding captured; the line above already recorded it.
  tester.takeException();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final enabled = Platform.environment['VIEWPORT_SWEEP'] == '1';

  for (final populated in [false, true]) {
    final state = populated ? 'populated' : 'empty';
    group('viewport sweep — $state', () {
      late ScreenTestEnvironment env;
      late _Subjects subjects;

      setUp(() async {
        env = await setupScreenTestEnvironment(
          productCount: populated ? 12 : 0,
          manufacturerCount: populated ? 2 : 0,
        );
        subjects = await _seedSubjects(env, populated: populated);
      });

      // Some screens' live provider graphs keep a Drift stream open that hangs
      // close(). A leaked in-memory database is harmless in a diagnostic run;
      // a hung sweep is not.
      tearDown(
        () => env.dispose().timeout(const Duration(seconds: 2), onTimeout: () {}),
      );

      for (final screen in _screens) {
        testWidgets(
          '${screen.name} at 800x360',
          (tester) => _sweep(
            tester,
            state: state,
            screen: screen,
            subjects: subjects,
            populated: populated,
          ),
          skip: !enabled,
        );
      }
    });
  }
}
