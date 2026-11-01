import 'config.dart';
import 'cost_rule.dart';
import 'export_reader.dart';
import 'history_layers.dart';
import 'ids.dart';
import 'mapping.dart';
import 'quantity.dart';
import 'sql.dart';

/// Live sales of one Lagos calendar day, as the old app counted them.
class DayFigures {
  int sales = 0;
  int takingsKobo = 0;
  int cashKobo = 0;
}

class CostGroupFigures {
  int lines = 0;
  int takingsKobo = 0;
  int costKobo = 0;
}

class StockFigure {
  final String productId;
  final String storeId;
  final double qty;

  const StockFigure({
    required this.productId,
    required this.storeId,
    required this.qty,
  });
}

/// Everything the import will write, plus what the checks must find afterwards.
class ImportPlan {
  final String businessId;
  final DateTime cutover;

  /// Written with triggers on: the small set the plan limits guard.
  final TargetTable businesses;
  final List<TargetTable> identityTables;

  /// Written under `session_replication_role = replica`.
  final List<TargetTable> historyTables;

  final Map<String, int> customerBalanceKobo = {};
  final Map<String, int> supplierBalanceKobo = {};
  final Map<String, int> heldDepositKobo = {};
  final List<StockFigure> stock = [];
  final Map<String, DayFigures> days = {};

  /// `customerId|manufacturerId` → crates owed.
  final Map<String, double> crates = {};

  final Map<CostGroup, CostGroupFigures> costGroups = {
    for (final group in CostGroup.values) group: CostGroupFigures(),
  };

  /// Sale lines left at cost 0: only a free line of a never-delivered product.
  int zeroCostLines = 0;
  int cancelledSales = 0;

  /// Plain-English notes for the report: what was left out, and why.
  final List<String> notes = [];

  ImportPlan({
    required this.businessId,
    required this.cutover,
    required this.businesses,
    required this.identityTables,
    required this.historyTables,
  });

  TargetTable table(String name) => [
    businesses,
    ...identityTables,
    ...historyTables,
  ].firstWhere((table) => table.name == name);
}

/// Turns the export into an [ImportPlan]. Touches no database and no file.
class Planner {
  final Export export;
  final ImportConfig config;

  Planner({required this.export, required this.config});

  final TargetTable _businesses = TargetTable('businesses', [
    'id',
    'name',
    'type',
    'phone',
    'email',
    'owner_id',
    'onboarding_complete',
    'tracks_empty_crates',
    'sells_one_price',
    'subscription_status',
    'subscription_plan',
    'current_period_end',
  ]);
  final TargetTable _settings = TargetTable('settings', [
    'id',
    'business_id',
    'key',
    'value',
  ]);
  final TargetTable _stores = TargetTable('stores', [
    'id',
    'business_id',
    'name',
    'address',
    'kind',
    'is_deleted',
    'created_at',
  ]);
  final TargetTable _users = TargetTable('users', [
    'id',
    'business_id',
    'auth_user_id',
    'name',
    'email',
    'store_id',
  ]);
  // redeem_invite_code's upsert: a login holds one profile, and it follows the
  // login into this business. The WHERE keeps a re-run a true no-op.
  final TargetTable _profiles = TargetTable(
    'profiles',
    ['id', 'business_id', 'name'],
    onConflict:
        'ON CONFLICT (id) DO UPDATE SET business_id = EXCLUDED.business_id, '
        'name = EXCLUDED.name WHERE public.profiles.business_id '
        'IS DISTINCT FROM EXCLUDED.business_id',
  );
  final TargetTable _userBusinesses = TargetTable('user_businesses', [
    'id',
    'business_id',
    'user_id',
    'role_id',
    'status',
    'is_hidden',
  ]);
  final TargetTable _userStores = TargetTable('user_stores', [
    'id',
    'business_id',
    'user_id',
    'store_id',
  ]);
  final TargetTable _categories = TargetTable('categories', [
    'id',
    'business_id',
    'name',
    'created_at',
  ]);
  final TargetTable _manufacturers = TargetTable('manufacturers', [
    'id',
    'business_id',
    'name',
    'created_at',
  ]);
  final TargetTable _suppliers = TargetTable('suppliers', [
    'id',
    'business_id',
    'name',
    'phone',
    'email',
    'address',
    'notes',
    'created_at',
  ]);
  final TargetTable _products = TargetTable('products', [
    'id',
    'business_id',
    'category_id',
    'manufacturer_id',
    'supplier_id',
    'name',
    'sku',
    'unit',
    'buying_price_kobo',
    'retailer_price_kobo',
    'wholesaler_price_kobo',
    'is_available',
    'low_stock_threshold',
    'track_empties',
    'allow_fractional_sales',
    'created_at',
  ]);
  final TargetTable _inventory = TargetTable('inventory', [
    'id',
    'business_id',
    'product_id',
    'store_id',
    'quantity',
  ]);
  final TargetTable _customers = TargetTable('customers', [
    'id',
    'business_id',
    'store_id',
    'name',
    'phone',
    'email',
    'address',
    'wallet_limit_kobo',
    'created_at',
  ]);
  final TargetTable _wallets = TargetTable('customer_wallets', [
    'id',
    'business_id',
    'customer_id',
    'created_at',
  ]);
  final TargetTable _orders = TargetTable('orders', [
    'id',
    'business_id',
    'order_number',
    'customer_id',
    'total_amount_kobo',
    'net_amount_kobo',
    'amount_paid_kobo',
    'payment_type',
    'status',
    'cancellation_reason',
    'staff_id',
    'store_id',
    'completed_at',
    'cancelled_at',
    'created_at',
  ]);
  final TargetTable _orderItems = TargetTable('order_items', [
    'id',
    'business_id',
    'order_id',
    'product_id',
    'store_id',
    'quantity',
    'unit_price_kobo',
    'buying_price_kobo',
    'total_kobo',
    'catalogue_price_kobo',
    'created_at',
  ]);
  final TargetTable _orderReversals = TargetTable('order_reversals', [
    'id',
    'business_id',
    'order_id',
    'performed_by',
    'cancellation_reason',
    'cancelled_at',
  ]);
  final TargetTable _adjustments = TargetTable('stock_adjustments', [
    'id',
    'business_id',
    'product_id',
    'store_id',
    'quantity_diff',
    'reason',
    'performed_by',
    'created_at',
  ]);
  final TargetTable _transfers = TargetTable('stock_transfers', [
    'id',
    'business_id',
    'from_location_id',
    'to_location_id',
    'product_id',
    'quantity',
    'status',
    'initiated_by',
    'received_by',
    'initiated_at',
    'received_at',
  ]);
  final TargetTable _stockTransactions = TargetTable('stock_transactions', [
    'id',
    'business_id',
    'product_id',
    'location_id',
    'quantity_delta',
    'movement_type',
    'order_id',
    'transfer_id',
    'adjustment_id',
    'performed_by',
    'created_at',
  ]);
  final TargetTable _walletTransactions = TargetTable('wallet_transactions', [
    'id',
    'business_id',
    'wallet_id',
    'customer_id',
    'type',
    'amount_kobo',
    'signed_amount_kobo',
    'reference_type',
    'order_id',
    'performed_by',
    'created_at',
  ]);
  final TargetTable _payments = TargetTable('payment_transactions', [
    'id',
    'business_id',
    'amount_kobo',
    'method',
    'type',
    'order_id',
    'wallet_txn_id',
    'performed_by',
    'store_id',
    'voided_at',
    'voided_by',
    'void_reason',
    'created_at',
  ]);
  final TargetTable _supplierLedger = TargetTable('supplier_ledger_entries', [
    'id',
    'business_id',
    'supplier_id',
    'type',
    'amount_kobo',
    'signed_amount_kobo',
    'reference_type',
    'payment_method',
    'reference_note',
    'activity_date',
    'performed_by',
    'store_id',
    'created_at',
  ]);
  final TargetTable _costBatches = TargetTable('cost_batches', [
    'id',
    'business_id',
    'product_id',
    'store_id',
    'qty_remaining',
    'qty_original',
    'cost_kobo',
    'received_at',
    'created_at',
  ]);
  final TargetTable _crateLedger = TargetTable('crate_ledger', [
    'id',
    'business_id',
    'customer_id',
    'manufacturer_id',
    'quantity_delta',
    'movement_type',
    'performed_by',
    'reason',
    'created_at',
  ]);
  final TargetTable _crateBalances = TargetTable('customer_crate_balances', [
    'id',
    'business_id',
    'customer_id',
    'manufacturer_id',
    'balance',
  ]);

  late final ImportPlan _plan = ImportPlan(
    businessId: config.businessId,
    cutover: export.generatedAt,
    businesses: _businesses,
    identityTables: [
      _settings,
      _stores,
      _users,
      _profiles,
      _userBusinesses,
      _userStores,
    ],
    historyTables: [
      _categories,
      _manufacturers,
      _suppliers,
      _products,
      _inventory,
      _customers,
      _wallets,
      _orders,
      _orderItems,
      _orderReversals,
      _adjustments,
      _transfers,
      _stockTransactions,
      _walletTransactions,
      _payments,
      _supplierLedger,
      _costBatches,
      _crateLedger,
      _crateBalances,
    ],
  );

  late final String _biz = sqlText(config.businessId);
  late final Row _mainStore = () {
    final stores = export.rows('Store');
    return stores.firstWhere(
      (store) => store.flag('isMain'),
      orElse: () => stores.first,
    );
  }();

  final Map<String, String> _userByProfile = {};
  final Map<String, Row> _customerById = {};
  final Map<String, Row> _saleById = {};
  final Map<String, Row> _productById = {};
  final Map<String, String> _manufacturerByProduct = {};
  final Map<String, String> _supplierSurvivor = {};
  final Map<String, Row> _supplierById = {};
  String? _ownerUserId;

  late final CostRule _costRule = () {
    final deliveries = {for (final d in export.rows('SupplyDelivery')) d.id: d};
    return CostRule([
      for (final item in export.rows('SupplyDeliveryItem'))
        DeliveryPrice(
          productId: item.text('productId'),
          deliveredAt: deliveries[item.text('supplyDeliveryId')]!.time(
            'deliveryDate',
          ),
          unitKobo: item.integer('buyingRateCents'),
          isCancelled:
              deliveries[item.text('supplyDeliveryId')]!.timeOrNull(
                'cancelledAt',
              ) !=
              null,
        ),
    ]);
  }();

  ImportPlan build() {
    _verifyAgainstManifest();
    _planBusiness();
    _planStores();
    _planUsers();
    _planSuppliers();
    _planCatalogue();
    _planCustomers();
    _planSales();
    _planTransfers();
    _planMovements();
    _planCustomerLedger();
    _planDeposits();
    _planSupplierLedger();
    _planCrates();
    _noteWhatIsLeftOut();
    return _plan;
  }

  /// Fails before writing anything if the files differ from what was verified.
  void _verifyAgainstManifest() {
    export.manifestRows.forEach((table, expected) {
      final actual = export.rows(table).length;
      if (actual != expected) {
        throw StateError('$table has $actual rows, manifest says $expected');
      }
    });
    final expectedNet = export.manifestCustomerLedgerNetKobo;
    if (expectedNet != null) {
      final net = export
          .rows('CustomerLedgerEntry')
          .fold<int>(0, (total, row) => total + row.integer('amountCents'));
      if (net != expectedNet) {
        throw StateError('Customer ledger nets $net, manifest $expectedNet');
      }
    }
  }

  String _storeId(String oldId) => legacyId('Store', oldId);
  String _productId(String oldId) => legacyId('Product', oldId);
  String _customerId(String oldId) => legacyId('Customer', oldId);
  String _orderId(String oldId) => legacyId('Sale', oldId);

  /// The `users` row behind an old profile id, or NULL if it was blank.
  String _user(String? profileId) =>
      sqlText(profileId == null ? null : _userByProfile[profileId]);

  void _planBusiness() {
    final settings = export.rows('BusinessSettings').firstOrNull;
    _businesses.add({
      'id': _biz,
      'name': sqlText(config.businessName),
      'type': sqlText(config.businessType),
      'phone': sqlText(config.businessPhone ?? settings?.textOrNull('phone')),
      'email': sqlText(config.businessEmail ?? settings?.textOrNull('email')),
      'owner_id': sqlText(config.ownerAuthUid),
      'onboarding_complete': sqlBool(true),
      'tracks_empty_crates': sqlBool(true),
      'sells_one_price': sqlBool(true),
      'subscription_status': sqlText('active'),
      'subscription_plan': sqlText('premium'),
      'current_period_end': 'NULL',
    });
    for (final (key, value) in const [
      ('default_currency', 'NGN'),
      ('timezone', 'Africa/Lagos'),
    ]) {
      _settings.add({
        'id': sqlText(legacyId('Setting', key)),
        'business_id': _biz,
        'key': sqlText(key),
        'value': sqlText(value),
      });
    }
  }

  void _planStores() {
    final address = export
        .rows('BusinessSettings')
        .firstOrNull
        ?.textOrNull('address');
    for (final store in export.rows('Store')) {
      _stores.add({
        'id': sqlText(_storeId(store.id)),
        'business_id': _biz,
        'name': sqlText(store.text('name')),
        'address': sqlText(store.id == _mainStore.id ? address : null),
        'kind': sqlText('store'),
        'is_deleted': sqlBool(!store.flag('isActive')),
        'created_at': sqlTime(store.time('createdAt')),
      });
    }
  }

  void _planUsers() {
    final usedAccounts = <Account>{};
    for (final profile in export.rows('Profile')) {
      final email = profile.text('email').trim().toLowerCase();
      final account = config.accounts
          .where((a) => a.oldProfileId == profile.id || a.email == email)
          .firstOrNull;
      if (account != null) usedAccounts.add(account);
      final userId = legacyId('User', profile.id);
      _userByProfile[profile.id] = userId;
      final oldStore = profile.textOrNull('storeId');
      _addUser(
        userId: userId,
        account: account,
        name: account?.name ?? profile.text('name'),
        email: email,
        oldStoreId: oldStore ?? _mainStore.id,
      );
      if (account == null) {
        _plan.notes.add(
          'One old profile has no account in the accounts file: it keeps a '
          'history-only user row with no login, so past sales still name them.',
        );
      }
    }
    for (final account in config.accounts) {
      if (usedAccounts.contains(account)) continue;
      _addUser(
        userId: legacyId('User', 'account:${account.email}'),
        account: account,
        name: account.name ?? account.email,
        email: account.email,
        oldStoreId: _mainStore.id,
      );
    }
    if (_ownerUserId == null) {
      throw StateError('The owner account produced no user row');
    }
  }

  void _addUser({
    required String userId,
    required Account? account,
    required String name,
    required String email,
    required String oldStoreId,
  }) {
    _users.add({
      'id': sqlText(userId),
      'business_id': _biz,
      'auth_user_id': sqlText(account?.authUid),
      'name': sqlText(name),
      'email': sqlText(email),
      'store_id': sqlText(_storeId(oldStoreId)),
    });
    if (account == null) return;
    if (account.authUid == config.ownerAuthUid) _ownerUserId = userId;
    _profiles.add({
      'id': sqlText(account.authUid),
      'business_id': _biz,
      'name': sqlText(name),
    });
    _userBusinesses.add({
      'id': sqlText(legacyId('UserBusiness', userId)),
      'business_id': _biz,
      'user_id': sqlText(userId),
      'role_id':
          '(SELECT id FROM public.roles WHERE business_id = $_biz '
          'AND slug = ${sqlText(account.role)})',
      'status': sqlText('active'),
      'is_hidden': sqlBool(account.hidden),
    });
    for (final store in export.rows('Store')) {
      _userStores.add({
        'id': sqlText(legacyId('UserStore', '$userId:${store.id}')),
        'business_id': _biz,
        'user_id': sqlText(userId),
        'store_id': sqlText(_storeId(store.id)),
      });
    }
  }

  void _planSuppliers() {
    final rows = export.rows('Supplier');
    _supplierById.addAll({for (final row in rows) row.id: row});
    _supplierSurvivor.addAll(
      mergeSuppliers(
        suppliers: [
          for (final row in rows)
            SupplierInput(
              id: row.id,
              name: row.text('name'),
              storeId: row.text('storeId'),
              createdAt: row.time('createdAt'),
            ),
        ],
        mainStoreId: _mainStore.id,
      ),
    );

    final members = <String, List<Row>>{};
    for (final row in rows) {
      members.putIfAbsent(_supplierSurvivor[row.id]!, () => []).add(row);
    }
    members.forEach((survivorId, group) {
      final survivor = _supplierById[survivorId]!;
      // A copy may hold a detail the surviving row lacks; keep it.
      final ordered = [survivor, ...group.where((m) => m.id != survivorId)];
      String? firstOf(String column) => ordered
          .map((member) => member.textOrNull(column))
          .firstWhere((value) => value != null, orElse: () => null);
      final contact = firstOf('contactName');
      _suppliers.add({
        'id': sqlText(legacyId('Supplier', survivorId)),
        'business_id': _biz,
        'name': sqlText(survivor.text('name').trim()),
        'phone': sqlText(firstOf('phone')),
        'email': sqlText(firstOf('email')),
        'address': sqlText(_joinAddress(firstOf('address'), firstOf('state'))),
        'notes': sqlText(contact == null ? null : 'Contact: $contact'),
        'created_at': sqlTime(survivor.time('createdAt')),
      });
    });
    _plan.notes.add(
      '${rows.length} old suppliers merged into ${members.length} by name.',
    );
  }

  String? _joinAddress(String? address, String? state) {
    final parts = [address, state].nonNulls;
    return parts.isEmpty ? null : parts.join(', ');
  }

  void _planCatalogue() {
    final categories = {for (final c in export.rows('Category')) c.id: c};
    final categoryRows = <String, String>{};

    String categoryFor(String name) {
      final key = name.trim().toLowerCase();
      return categoryRows.putIfAbsent(key, () {
        final id = legacyId('CategoryName', key);
        _categories.add({
          'id': sqlText(id),
          'business_id': _biz,
          'name': sqlText(name.trim()),
          'created_at': sqlTime(_plan.cutover),
        });
        return id;
      });
    }

    for (final category in categories.values) {
      if (config.isProductTypeCategory(category.text('name'))) {
        categoryFor(category.text('name'));
        continue;
      }
      _manufacturers.add({
        'id': sqlText(legacyId('Manufacturer', category.id)),
        'business_id': _biz,
        'name': sqlText(category.text('name').trim()),
        'created_at': sqlTime(category.time('createdAt')),
      });
    }

    final mainThreshold = <String, int>{
      for (final stock in export.rows('StoreStock'))
        if (stock.text('storeId') == _mainStore.id)
          stock.text('productId'): stock.integer('lowStockThreshold'),
    };

    for (final product in export.rows('Product')) {
      _productById[product.id] = product;
      final category = categories[product.textOrNull('categoryId')];
      final isCompany =
          category != null &&
          !config.isProductTypeCategory(category.text('name'));
      final manufacturerId = isCompany
          ? legacyId('Manufacturer', category.id)
          : null;
      if (manufacturerId != null) {
        _manufacturerByProduct[product.id] = manufacturerId;
      }
      final categoryName =
          product.textOrNull('drinkType') ??
          (category != null && !isCompany ? category.text('name') : 'Other');
      final name = product.text('name').trim();
      final isReturnable = product.flag('isReturnable');
      final oldSupplier = product.textOrNull('supplierId');
      final priceKobo = product.integer('unitPriceCents');
      _products.add({
        'id': sqlText(_productId(product.id)),
        'business_id': _biz,
        'category_id': sqlText(categoryFor(categoryName)),
        'manufacturer_id': sqlText(manufacturerId),
        'supplier_id': sqlText(
          oldSupplier == null
              ? null
              : legacyId('Supplier', _supplierSurvivor[oldSupplier]!),
        ),
        'name': sqlText(name),
        'sku': sqlText(product.textOrNull('sku')),
        'unit': sqlText(productUnit(isReturnable: isReturnable, name: name)),
        'buying_price_kobo': sqlInt(product.intOrNull('costCents') ?? 0),
        'retailer_price_kobo': sqlInt(priceKobo),
        'wholesaler_price_kobo': sqlInt(priceKobo),
        'is_available': sqlBool(product.flag('isActive')),
        'low_stock_threshold': sqlInt(mainThreshold[product.id] ?? 5),
        'track_empties': sqlBool(isReturnable && manufacturerId != null),
        // Every product can sell in parts (#620 decision 4).
        'allow_fractional_sales': sqlBool(true),
        'created_at': sqlTime(product.time('createdAt')),
      });
      if (isReturnable && manufacturerId == null) {
        _plan.notes.add(
          'A returnable product has no company, so its crates cannot be '
          'tracked.',
        );
      }
    }
    _planInventory();
  }

  /// Stock is the old figure, not a replay of movements: it is the truth, and a
  /// few rows differ from the movement history (see the sender's report).
  void _planInventory() {
    var uncostedOpening = 0;
    for (final stock in export.rows('StoreStock')) {
      final oldProduct = stock.text('productId');
      final productId = _productId(oldProduct);
      final storeId = _storeId(stock.text('storeId'));
      final qty = stock.decimal('stockQty');
      _inventory.add({
        'id': sqlText(legacyId('Inventory', stock.id)),
        'business_id': _biz,
        'product_id': sqlText(productId),
        'store_id': sqlText(storeId),
        'quantity': sqlQty(qty),
      });
      _plan.stock.add(
        StockFigure(productId: productId, storeId: storeId, qty: qty),
      );
      if (qty <= 0) continue;
      final costKobo = _productById[oldProduct]!.intOrNull('costCents') ?? 0;
      if (costKobo == 0) uncostedOpening++;
      _addCostLayer(
        id: legacyId('OpeningLayer', stock.id),
        productId: productId,
        storeId: storeId,
        qtyOriginal: qty,
        qtyRemaining: qty,
        costKobo: costKobo,
        receivedAt: _plan.cutover,
      );
    }
    if (uncostedOpening > 0) {
      _plan.notes.add(
        '$uncostedOpening opening cost layers are at 0 because the product had '
        'no buying price: new sales of them stay uncosted until one is set.',
      );
    }
  }

  void _addCostLayer({
    required String id,
    required String productId,
    required String storeId,
    required double qtyOriginal,
    required double qtyRemaining,
    required int costKobo,
    required DateTime receivedAt,
  }) {
    _costBatches.add({
      'id': sqlText(id),
      'business_id': _biz,
      'product_id': sqlText(productId),
      'store_id': sqlText(storeId),
      'qty_remaining': sqlQty(qtyRemaining),
      'qty_original': sqlQty(qtyOriginal),
      'cost_kobo': sqlInt(costKobo),
      'received_at': sqlTime(receivedAt),
      'created_at': sqlTime(receivedAt),
    });
  }

  void _planCustomers() {
    for (final customer in export.rows('Customer')) {
      _customerById[customer.id] = customer;
      final customerId = _customerId(customer.id);
      _customers.add({
        'id': sqlText(customerId),
        'business_id': _biz,
        'store_id': sqlText(_storeId(customer.text('storeId'))),
        'name': sqlText(
          customerDisplayName(
            name: customer.text('name'),
            businessName: customer.textOrNull('businessName'),
          ),
        ),
        'phone': sqlText(customer.textOrNull('phone')),
        'email': sqlText(customer.textOrNull('email')),
        'address': sqlText(
          _joinAddress(
            customer.textOrNull('address'),
            customer.textOrNull('state'),
          ),
        ),
        'wallet_limit_kobo': sqlInt(
          customer.intOrNull('creditLimitCents') ?? 0,
        ),
        'created_at': sqlTime(customer.time('createdAt')),
      });
      _wallets.add({
        'id': sqlText(legacyId('Wallet', customer.id)),
        'business_id': _biz,
        'customer_id': sqlText(customerId),
        'created_at': sqlTime(customer.time('createdAt')),
      });
      _plan.customerBalanceKobo[customerId] = 0;
    }
  }

  DateTime _soldAt(Row sale) =>
      sale.timeOrNull('occurredAt') ?? sale.time('createdAt');

  void _planSales() {
    final numbers = <String>{};
    for (final sale in export.rows('Sale')) {
      _saleById[sale.id] = sale;
      final number = orderNumberFor(sale.id);
      if (!numbers.add(number)) {
        throw StateError('Two old sales share order number $number');
      }
      _planOrder(sale, number);
    }
    _planOrderItems();
  }

  void _planOrder(Row sale, String number) {
    final orderId = _orderId(sale.id);
    final soldAt = _soldAt(sale);
    final cancelledAt = sale.timeOrNull('cancelledAt');
    final isLive = cancelledAt == null;
    final total = sale.integer('totalCents');
    final paid = sale.integer('amountPaidCents');
    final oldCustomer = sale.textOrNull('customerId');
    final staff = sale.textOrNull('createdByProfileId');
    final storeId = _storeId(sale.text('storeId'));
    final reason = sale.textOrNull('cancelReason');

    _orders.add({
      'id': sqlText(orderId),
      'business_id': _biz,
      'order_number': sqlText(number),
      'customer_id': sqlText(
        oldCustomer == null ? null : _customerId(oldCustomer),
      ),
      'total_amount_kobo': sqlInt(total),
      'net_amount_kobo': sqlInt(total),
      // A cancelled sale's paid figure is an old-app artifact, not real cash.
      'amount_paid_kobo': sqlInt(isLive ? paid : 0),
      'payment_type': sqlText(
        orderPaymentType(paidKobo: paid, totalKobo: total),
      ),
      'status': sqlText(isLive ? 'completed' : 'cancelled'),
      'cancellation_reason': sqlText(reason),
      'staff_id': _user(staff),
      'store_id': sqlText(storeId),
      'completed_at': sqlTime(soldAt),
      'cancelled_at': sqlTime(cancelledAt),
      'created_at': sqlTime(soldAt),
    });

    if (!isLive) {
      _plan.cancelledSales++;
      _orderReversals.add({
        'id': sqlText(legacyId('Reversal', sale.id)),
        'business_id': _biz,
        'order_id': sqlText(orderId),
        'performed_by': _user(sale.textOrNull('cancelledByProfileId')),
        'cancellation_reason': sqlText(reason),
        'cancelled_at': sqlTime(cancelledAt),
      });
      return;
    }

    final day = _plan.days.putIfAbsent(lagosDay(soldAt), DayFigures.new);
    day.sales++;
    day.takingsKobo += total;
    day.cashKobo += paid;

    final tender = splitTender(paidKobo: paid, totalKobo: total);
    void addTender(String kind, String type, int amount) {
      if (amount <= 0) return;
      _payments.add({
        'id': sqlText(legacyId('SalePayment$kind', sale.id)),
        'business_id': _biz,
        'amount_kobo': sqlInt(amount),
        'method': sqlText('cash'),
        'type': sqlText(type),
        'order_id': sqlText(orderId),
        'wallet_txn_id': 'NULL',
        'performed_by': _user(staff),
        'store_id': sqlText(storeId),
        'voided_at': 'NULL',
        'voided_by': 'NULL',
        'void_reason': 'NULL',
        'created_at': sqlTime(soldAt),
      });
    }

    addTender('Goods', 'sale', tender.goodsKobo);
    addTender('Over', 'wallet_topup', tender.overpaidKobo);
  }

  void _planOrderItems() {
    final replayByPair = <String, List<ReplayLine>>{};
    for (final item in export.rows('SaleItem')) {
      final sale = _saleById[item.text('saleId')]!;
      final soldAt = _soldAt(sale);
      final oldProduct = item.text('productId');
      final productId = _productId(oldProduct);
      final storeId = _storeId(sale.text('storeId'));
      final orderId = _orderId(sale.id);
      final lineId = legacyId('SaleItem', item.id);
      final unitKobo = item.integer('unitPriceCents');
      final totalKobo = item.integer('lineTotalCents');
      final qty = item.decimal('quantity');
      final cost = _costRule.costFor(
        productId: oldProduct,
        soldAt: soldAt,
        saleUnitKobo: unitKobo,
      );

      _orderItems.add({
        'id': sqlText(lineId),
        'business_id': _biz,
        'order_id': sqlText(orderId),
        'product_id': sqlText(productId),
        'store_id': sqlText(storeId),
        'quantity': sqlQty(qty),
        'unit_price_kobo': sqlInt(unitKobo),
        'buying_price_kobo': sqlInt(cost.unitKobo),
        'total_kobo': sqlInt(totalKobo),
        'catalogue_price_kobo': sqlInt(
          item.intOrNull('standardUnitPriceCents'),
        ),
        'created_at': sqlTime(soldAt),
      });
      if (cost.unitKobo == 0) _plan.zeroCostLines++;

      if (sale.timeOrNull('cancelledAt') != null) continue;
      final figures = _plan.costGroups[cost.group]!;
      figures.lines++;
      figures.takingsKobo += totalKobo;
      figures.costKobo += lineValueKobo(unitKobo: cost.unitKobo, qty: qty);
      replayByPair
          .putIfAbsent('$productId|$storeId', () => [])
          .add(
            ReplayLine(
              lineId: lineId,
              orderId: orderId,
              soldAt: soldAt,
              qty: qty,
              costKobo: cost.unitKobo,
            ),
          );
    }

    replayByPair.forEach((pair, lines) {
      final [productId, storeId] = pair.split('|');
      final layers = buildHistoryLayers(lines: lines, cutover: _plan.cutover);
      for (var i = 0; i < layers.length; i++) {
        _addCostLayer(
          id: legacyId('HistoryLayer', '$pair:$i'),
          productId: productId,
          storeId: storeId,
          qtyOriginal: layers[i].qty,
          qtyRemaining: 0,
          costKobo: layers[i].costKobo,
          receivedAt: layers[i].receivedAt,
        );
      }
    });
  }

  void _planTransfers() {
    final transfers = {for (final t in export.rows('StoreTransfer')) t.id: t};
    for (final item in export.rows('StoreTransferItem')) {
      final transfer = transfers[item.text('storeTransferId')]!;
      final received = transfer.text('status') == 'RECEIVED';
      final dispatcher = transfer.textOrNull('dispatchedByProfileId');
      _transfers.add({
        'id': sqlText(legacyId('Transfer', item.id)),
        'business_id': _biz,
        'from_location_id': sqlText(_storeId(transfer.text('fromStoreId'))),
        'to_location_id': sqlText(_storeId(transfer.text('toStoreId'))),
        'product_id': sqlText(_productId(item.text('productId'))),
        'quantity': sqlQty(item.decimal('quantitySent')),
        'status': sqlText(received ? 'received' : 'in_transit'),
        // Required here, optional in the old app.
        'initiated_by': dispatcher == null
            ? sqlText(_ownerUserId)
            : _user(dispatcher),
        'received_by': _user(transfer.textOrNull('receivedByProfileId')),
        'initiated_at': sqlTime(transfer.time('dispatchedAt')),
        'received_at': sqlTime(transfer.timeOrNull('receivedAt')),
      });
    }
  }

  void _planMovements() {
    final movements = export.rows('StockMovement');
    final offGrid = reconcileOffGridMovements([
      for (final m in movements)
        MovementQty(
          id: m.id,
          groupKey:
              '${m.text('storeId')}|${m.text('productId')}|'
              '${m.textOrNull('relatedSaleId')}',
          createdAt: m.time('createdAt'),
          qty: m.decimal('quantityChange'),
        ),
    ]);
    if (offGrid.replacedQty.isNotEmpty) {
      _plan.notes.add(
        '${offGrid.dropped.length + offGrid.replacedQty.length} stock '
        'movements off the 0.25 grid folded into '
        '${offGrid.replacedQty.length}, keeping the same total.',
      );
    }
    if (offGrid.unresolved.isNotEmpty) {
      _plan.notes.add(
        '${offGrid.unresolved.length} stock movements could not be put on the '
        '0.25 grid and were left out. Stock itself is unaffected.',
      );
    }

    final transferItems = <String, Row>{
      for (final item in export.rows('StoreTransferItem'))
        '${item.text('storeTransferId')}|${item.text('productId')}': item,
    };
    final trips = {for (final t in export.rows('VanTrip')) t.id: t};
    final vans = {for (final v in export.rows('Van')) v.id: v};

    String? vanLabel(Row movement) {
      final tripId = movement.textOrNull('relatedVanTripId');
      if (tripId == null) return null;
      final trip = trips[tripId]!;
      final van = vans[trip.text('vanId')]!;
      final at = trip.timeOrNull('departedAt') ?? movement.time('createdAt');
      return '${van.text('name')}, ${lagosDay(at)}';
    }

    for (final movement in movements) {
      if (offGrid.dropped.contains(movement.id)) continue;
      final qty =
          offGrid.replacedQty[movement.id] ??
          movement.decimal('quantityChange');
      final oldSale = movement.textOrNull('relatedSaleId');
      final movementPlan = movementPlanFor(
        oldType: movement.text('type'),
        qty: qty,
        hasSale: oldSale != null,
        hasDelivery: movement.textOrNull('relatedSupplyDeliveryId') != null,
        note: movement.textOrNull('note'),
        vanLabel: vanLabel(movement),
      );
      final productId = _productId(movement.text('productId'));
      final storeId = _storeId(movement.text('storeId'));
      final actor = _user(movement.textOrNull('createdByProfileId'));
      final createdAt = sqlTime(movement.time('createdAt'));

      String? adjustmentId;
      if (movementPlan.link == MovementLink.adjustment) {
        adjustmentId = legacyId('Adjustment', movement.id);
        _adjustments.add({
          'id': sqlText(adjustmentId),
          'business_id': _biz,
          'product_id': sqlText(productId),
          'store_id': sqlText(storeId),
          'quantity_diff': sqlQty(qty),
          'reason': sqlText(movementPlan.reason),
          'performed_by': actor,
          'created_at': createdAt,
        });
      }

      String? transferId;
      if (movementPlan.link == MovementLink.transfer) {
        final key =
            '${movement.text('relatedStoreTransferId')}|'
            '${movement.text('productId')}';
        transferId = legacyId('Transfer', transferItems[key]!.id);
      }

      _stockTransactions.add({
        'id': sqlText(legacyId('StockMovement', movement.id)),
        'business_id': _biz,
        'product_id': sqlText(productId),
        'location_id': sqlText(storeId),
        'quantity_delta': sqlQty(qty),
        'movement_type': sqlText(movementPlan.movementType),
        'order_id': sqlText(
          movementPlan.link == MovementLink.order ? _orderId(oldSale!) : null,
        ),
        'transfer_id': sqlText(transferId),
        'adjustment_id': sqlText(adjustmentId),
        'performed_by': actor,
        'created_at': createdAt,
      });
    }
  }

  /// Every row counts, cancelled ones included, because a cancellation's
  /// offsetting row is its own entry. `voided_at` stays NULL on the ledger: some
  /// readers skip voided rows, which would then count the offset alone.
  void _planCustomerLedger() {
    for (final entry in export.rows('CustomerLedgerEntry')) {
      final oldCustomer = entry.text('customerId');
      final customerId = _customerId(oldCustomer);
      final oldAmount = entry.integer('amountCents');
      final leg = walletLegFor(
        oldType: entry.text('type'),
        oldAmountKobo: oldAmount,
      );
      final walletTxnId = legacyId('WalletEntry', entry.id);
      final oldSale = entry.textOrNull('relatedSaleId');
      final actor = _user(entry.textOrNull('createdByProfileId'));
      final createdAt = entry.time('createdAt');
      _addWalletRow(
        id: walletTxnId,
        oldCustomer: oldCustomer,
        leg: leg,
        orderId: oldSale == null ? null : _orderId(oldSale),
        actor: actor,
        createdAt: createdAt,
      );
      _plan.customerBalanceKobo[customerId] =
          _plan.customerBalanceKobo[customerId]! + leg.signedKobo;

      if (!leg.isCashIn) continue;
      // A cancelled payment's cash never stayed in the drawer. Its offset is a
      // wallet row with no cash row, so the cash row is what must be voided.
      final cancelledAt = entry.timeOrNull('cancelledAt');
      _payments.add({
        'id': sqlText(legacyId('WalletCash', entry.id)),
        'business_id': _biz,
        'amount_kobo': sqlInt(leg.amountKobo),
        'method': sqlText('cash'),
        'type': sqlText('wallet_topup'),
        'order_id': 'NULL',
        'wallet_txn_id': sqlText(walletTxnId),
        'performed_by': actor,
        'store_id': sqlText(
          _storeId(_customerById[oldCustomer]!.text('storeId')),
        ),
        'voided_at': sqlTime(cancelledAt),
        'voided_by': _user(entry.textOrNull('cancelledByProfileId')),
        'void_reason': sqlText(entry.textOrNull('cancelReason')),
        'created_at': sqlTime(createdAt),
      });
    }
  }

  void _addWalletRow({
    required String id,
    required String oldCustomer,
    required WalletLeg leg,
    required String? orderId,
    required String actor,
    required DateTime createdAt,
  }) {
    _walletTransactions.add({
      'id': sqlText(id),
      'business_id': _biz,
      'wallet_id': sqlText(legacyId('Wallet', oldCustomer)),
      'customer_id': sqlText(_customerId(oldCustomer)),
      'type': sqlText(leg.type),
      'amount_kobo': sqlInt(leg.amountKobo),
      'signed_amount_kobo': sqlInt(leg.signedKobo),
      'reference_type': sqlText(leg.referenceType),
      'order_id': sqlText(orderId),
      'performed_by': actor,
      'created_at': sqlTime(createdAt),
    });
  }

  void _planDeposits() {
    for (final entry in export.rows('EmptiesDepositEntry')) {
      final oldCustomer = entry.textOrNull('customerId');
      if (oldCustomer == null) {
        _plan.notes.add(
          'A held deposit from a walk-in has no wallet to sit in and was left '
          'out.',
        );
        continue;
      }
      final leg = depositLegFor(
        oldType: entry.text('type'),
        oldAmountKobo: entry.integer('amountCents'),
      );
      _addWalletRow(
        id: legacyId('DepositEntry', entry.id),
        oldCustomer: oldCustomer,
        leg: leg,
        orderId: null,
        actor: _user(entry.textOrNull('createdByProfileId')),
        createdAt: entry.time('createdAt'),
      );
      final customerId = _customerId(oldCustomer);
      _plan.heldDepositKobo[customerId] =
          (_plan.heldDepositKobo[customerId] ?? 0) + leg.signedKobo;
    }
  }

  void _planSupplierLedger() {
    final deliveries = {for (final d in export.rows('SupplyDelivery')) d.id: d};
    for (final row in _supplierSurvivor.values.toSet()) {
      _plan.supplierBalanceKobo[legacyId('Supplier', row)] = 0;
    }
    for (final entry in export.rows('SupplierLedgerEntry')) {
      final oldSupplier = entry.text('supplierId');
      final supplierId = legacyId('Supplier', _supplierSurvivor[oldSupplier]!);
      final note = entry.textOrNull('note');
      final leg = supplierLegFor(
        oldType: entry.text('type'),
        oldAmountKobo: entry.integer('amountCents'),
        note: note,
      );
      final delivery = deliveries[entry.textOrNull('relatedSupplyDeliveryId')];
      final createdAt = entry.time('createdAt');
      _supplierLedger.add({
        'id': sqlText(legacyId('SupplierEntry', entry.id)),
        'business_id': _biz,
        'supplier_id': sqlText(supplierId),
        'type': sqlText(leg.type),
        'amount_kobo': sqlInt(leg.amountKobo),
        'signed_amount_kobo': sqlInt(leg.signedKobo),
        'reference_type': sqlText(leg.referenceType),
        'payment_method': sqlText(leg.paymentMethod),
        'reference_note': sqlText(note),
        'activity_date': sqlTime(delivery?.time('deliveryDate') ?? createdAt),
        'performed_by': _user(entry.textOrNull('createdByProfileId')),
        // The branch stays on the row even though the supplier merged.
        'store_id': sqlText(
          _storeId(_supplierById[oldSupplier]!.text('storeId')),
        ),
        'created_at': sqlTime(createdAt),
      });
      _plan.supplierBalanceKobo[supplierId] =
          _plan.supplierBalanceKobo[supplierId]! + leg.signedKobo;
    }
  }

  /// One opening balance per customer per company. Old and new both count
  /// crates owed as positive, so the sign stays.
  void _planCrates() {
    final balances = <String, double>{};
    var walkInRows = 0;
    var walkInNet = 0.0;
    var unmappedRows = 0;
    var unmappedNet = 0.0;
    for (final entry in export.rows('EmptiesLedgerEntry')) {
      final qty = entry.decimal('quantity');
      final oldCustomer = entry.textOrNull('customerId');
      if (oldCustomer == null) {
        walkInRows++;
        walkInNet += qty;
        continue;
      }
      final manufacturerId =
          _manufacturerByProduct[entry.textOrNull('productId')];
      if (manufacturerId == null) {
        unmappedRows++;
        unmappedNet += qty;
        continue;
      }
      final key = '${_customerId(oldCustomer)}|$manufacturerId';
      balances[key] = (balances[key] ?? 0) + qty;
    }

    balances.forEach((key, balance) {
      if (balance == 0) return;
      final [customerId, manufacturerId] = key.split('|');
      _crateLedger.add({
        'id': sqlText(legacyId('CrateOpening', key)),
        'business_id': _biz,
        'customer_id': sqlText(customerId),
        'manufacturer_id': sqlText(manufacturerId),
        'quantity_delta': sqlQty(balance),
        'movement_type': sqlText('adjusted'),
        'performed_by': sqlText(_ownerUserId),
        'reason': sqlText('Opening balance from old app'),
        'created_at': sqlTime(_plan.cutover),
      });
      _crateBalances.add({
        'id': sqlText(legacyId('CrateBalance', key)),
        'business_id': _biz,
        'customer_id': sqlText(customerId),
        'manufacturer_id': sqlText(manufacturerId),
        'balance': sqlQty(balance),
      });
      _plan.crates[key] = balance;
    });

    _plan.notes.add(
      '$walkInRows walk-in empties rows left out; they net to $walkInNet '
      'crates (the PRD expects exactly 0).',
    );
    if (unmappedRows > 0) {
      _plan.notes.add(
        '$unmappedRows customer empties rows left out because their product '
        'has no company; they net to $unmappedNet crates.',
      );
    }
  }

  void _noteWhatIsLeftOut() {
    final overrides = export
        .rows('StoreStock')
        .where((stock) => stock.intOrNull('priceOverrideCents') != null)
        .length;
    if (overrides > 0) {
      _plan.notes.add(
        '$overrides per-branch price overrides have no home here and were '
        'left out.',
      );
    }
    _plan.notes.addAll(const [
      'Deliveries arrive as their receipt movements and supplier ledger rows. '
          'They write no cost layers of their own: see the README on FIFO.',
      'Sale notes and edit notes have no column on orders and were left out.',
      'Receipt footer and bank details have no setting in the app yet.',
      'Not imported by decision (PRD #619): van trips, payroll, loans, standing '
          'orders, price and edit history, auth, rate-limit log, Prisma tables.',
    ]);
  }
}
