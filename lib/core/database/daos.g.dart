// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'daos.dart';

// ignore_for_file: type=lint
mixin _$CatalogDaoMixin on DatabaseAccessor<AppDatabase> {
  $BusinessesTable get businesses => attachedDatabase.businesses;
  $CrateSizeGroupsTable get crateSizeGroups => attachedDatabase.crateSizeGroups;
  $SuppliersTable get suppliers => attachedDatabase.suppliers;
  $CategoriesTable get categories => attachedDatabase.categories;
  $ManufacturersTable get manufacturers => attachedDatabase.manufacturers;
  $ProductsTable get products => attachedDatabase.products;
  $StoresTable get stores => attachedDatabase.stores;
  CatalogDaoManager get managers => CatalogDaoManager(this);
}

class CatalogDaoManager {
  final _$CatalogDaoMixin _db;
  CatalogDaoManager(this._db);
  $$BusinessesTableTableManager get businesses =>
      $$BusinessesTableTableManager(_db.attachedDatabase, _db.businesses);
  $$CrateSizeGroupsTableTableManager get crateSizeGroups =>
      $$CrateSizeGroupsTableTableManager(
        _db.attachedDatabase,
        _db.crateSizeGroups,
      );
  $$SuppliersTableTableManager get suppliers =>
      $$SuppliersTableTableManager(_db.attachedDatabase, _db.suppliers);
  $$CategoriesTableTableManager get categories =>
      $$CategoriesTableTableManager(_db.attachedDatabase, _db.categories);
  $$ManufacturersTableTableManager get manufacturers =>
      $$ManufacturersTableTableManager(_db.attachedDatabase, _db.manufacturers);
  $$ProductsTableTableManager get products =>
      $$ProductsTableTableManager(_db.attachedDatabase, _db.products);
  $$StoresTableTableManager get stores =>
      $$StoresTableTableManager(_db.attachedDatabase, _db.stores);
}

mixin _$InventoryDaoMixin on DatabaseAccessor<AppDatabase> {
  $BusinessesTable get businesses => attachedDatabase.businesses;
  $CategoriesTable get categories => attachedDatabase.categories;
  $CrateSizeGroupsTable get crateSizeGroups => attachedDatabase.crateSizeGroups;
  $SuppliersTable get suppliers => attachedDatabase.suppliers;
  $ManufacturersTable get manufacturers => attachedDatabase.manufacturers;
  $ProductsTable get products => attachedDatabase.products;
  $StoresTable get stores => attachedDatabase.stores;
  $InventoryTable get inventory => attachedDatabase.inventory;
  $UsersTable get users => attachedDatabase.users;
  $StockAdjustmentsTable get stockAdjustments =>
      attachedDatabase.stockAdjustments;
  $CustomersTable get customers => attachedDatabase.customers;
  $OrdersTable get orders => attachedDatabase.orders;
  $StockTransfersTable get stockTransfers => attachedDatabase.stockTransfers;
  $ShipmentsTable get shipments => attachedDatabase.shipments;
  $StockTransactionsTable get stockTransactions =>
      attachedDatabase.stockTransactions;
  $PendingCrateReturnsTable get pendingCrateReturns =>
      attachedDatabase.pendingCrateReturns;
  $CrateLedgerTable get crateLedger => attachedDatabase.crateLedger;
  InventoryDaoManager get managers => InventoryDaoManager(this);
}

class InventoryDaoManager {
  final _$InventoryDaoMixin _db;
  InventoryDaoManager(this._db);
  $$BusinessesTableTableManager get businesses =>
      $$BusinessesTableTableManager(_db.attachedDatabase, _db.businesses);
  $$CategoriesTableTableManager get categories =>
      $$CategoriesTableTableManager(_db.attachedDatabase, _db.categories);
  $$CrateSizeGroupsTableTableManager get crateSizeGroups =>
      $$CrateSizeGroupsTableTableManager(
        _db.attachedDatabase,
        _db.crateSizeGroups,
      );
  $$SuppliersTableTableManager get suppliers =>
      $$SuppliersTableTableManager(_db.attachedDatabase, _db.suppliers);
  $$ManufacturersTableTableManager get manufacturers =>
      $$ManufacturersTableTableManager(_db.attachedDatabase, _db.manufacturers);
  $$ProductsTableTableManager get products =>
      $$ProductsTableTableManager(_db.attachedDatabase, _db.products);
  $$StoresTableTableManager get stores =>
      $$StoresTableTableManager(_db.attachedDatabase, _db.stores);
  $$InventoryTableTableManager get inventory =>
      $$InventoryTableTableManager(_db.attachedDatabase, _db.inventory);
  $$UsersTableTableManager get users =>
      $$UsersTableTableManager(_db.attachedDatabase, _db.users);
  $$StockAdjustmentsTableTableManager get stockAdjustments =>
      $$StockAdjustmentsTableTableManager(
        _db.attachedDatabase,
        _db.stockAdjustments,
      );
  $$CustomersTableTableManager get customers =>
      $$CustomersTableTableManager(_db.attachedDatabase, _db.customers);
  $$OrdersTableTableManager get orders =>
      $$OrdersTableTableManager(_db.attachedDatabase, _db.orders);
  $$StockTransfersTableTableManager get stockTransfers =>
      $$StockTransfersTableTableManager(
        _db.attachedDatabase,
        _db.stockTransfers,
      );
  $$ShipmentsTableTableManager get shipments =>
      $$ShipmentsTableTableManager(_db.attachedDatabase, _db.shipments);
  $$StockTransactionsTableTableManager get stockTransactions =>
      $$StockTransactionsTableTableManager(
        _db.attachedDatabase,
        _db.stockTransactions,
      );
  $$PendingCrateReturnsTableTableManager get pendingCrateReturns =>
      $$PendingCrateReturnsTableTableManager(
        _db.attachedDatabase,
        _db.pendingCrateReturns,
      );
  $$CrateLedgerTableTableManager get crateLedger =>
      $$CrateLedgerTableTableManager(_db.attachedDatabase, _db.crateLedger);
}

mixin _$StockLedgerDaoMixin on DatabaseAccessor<AppDatabase> {
  $BusinessesTable get businesses => attachedDatabase.businesses;
  $CategoriesTable get categories => attachedDatabase.categories;
  $CrateSizeGroupsTable get crateSizeGroups => attachedDatabase.crateSizeGroups;
  $SuppliersTable get suppliers => attachedDatabase.suppliers;
  $ManufacturersTable get manufacturers => attachedDatabase.manufacturers;
  $ProductsTable get products => attachedDatabase.products;
  $StoresTable get stores => attachedDatabase.stores;
  $CustomersTable get customers => attachedDatabase.customers;
  $UsersTable get users => attachedDatabase.users;
  $OrdersTable get orders => attachedDatabase.orders;
  $StockTransfersTable get stockTransfers => attachedDatabase.stockTransfers;
  $StockAdjustmentsTable get stockAdjustments =>
      attachedDatabase.stockAdjustments;
  $ShipmentsTable get shipments => attachedDatabase.shipments;
  $StockTransactionsTable get stockTransactions =>
      attachedDatabase.stockTransactions;
  $InventoryTable get inventory => attachedDatabase.inventory;
  StockLedgerDaoManager get managers => StockLedgerDaoManager(this);
}

class StockLedgerDaoManager {
  final _$StockLedgerDaoMixin _db;
  StockLedgerDaoManager(this._db);
  $$BusinessesTableTableManager get businesses =>
      $$BusinessesTableTableManager(_db.attachedDatabase, _db.businesses);
  $$CategoriesTableTableManager get categories =>
      $$CategoriesTableTableManager(_db.attachedDatabase, _db.categories);
  $$CrateSizeGroupsTableTableManager get crateSizeGroups =>
      $$CrateSizeGroupsTableTableManager(
        _db.attachedDatabase,
        _db.crateSizeGroups,
      );
  $$SuppliersTableTableManager get suppliers =>
      $$SuppliersTableTableManager(_db.attachedDatabase, _db.suppliers);
  $$ManufacturersTableTableManager get manufacturers =>
      $$ManufacturersTableTableManager(_db.attachedDatabase, _db.manufacturers);
  $$ProductsTableTableManager get products =>
      $$ProductsTableTableManager(_db.attachedDatabase, _db.products);
  $$StoresTableTableManager get stores =>
      $$StoresTableTableManager(_db.attachedDatabase, _db.stores);
  $$CustomersTableTableManager get customers =>
      $$CustomersTableTableManager(_db.attachedDatabase, _db.customers);
  $$UsersTableTableManager get users =>
      $$UsersTableTableManager(_db.attachedDatabase, _db.users);
  $$OrdersTableTableManager get orders =>
      $$OrdersTableTableManager(_db.attachedDatabase, _db.orders);
  $$StockTransfersTableTableManager get stockTransfers =>
      $$StockTransfersTableTableManager(
        _db.attachedDatabase,
        _db.stockTransfers,
      );
  $$StockAdjustmentsTableTableManager get stockAdjustments =>
      $$StockAdjustmentsTableTableManager(
        _db.attachedDatabase,
        _db.stockAdjustments,
      );
  $$ShipmentsTableTableManager get shipments =>
      $$ShipmentsTableTableManager(_db.attachedDatabase, _db.shipments);
  $$StockTransactionsTableTableManager get stockTransactions =>
      $$StockTransactionsTableTableManager(
        _db.attachedDatabase,
        _db.stockTransactions,
      );
  $$InventoryTableTableManager get inventory =>
      $$InventoryTableTableManager(_db.attachedDatabase, _db.inventory);
}

mixin _$StockTransferDaoMixin on DatabaseAccessor<AppDatabase> {
  $BusinessesTable get businesses => attachedDatabase.businesses;
  $StoresTable get stores => attachedDatabase.stores;
  $CategoriesTable get categories => attachedDatabase.categories;
  $CrateSizeGroupsTable get crateSizeGroups => attachedDatabase.crateSizeGroups;
  $SuppliersTable get suppliers => attachedDatabase.suppliers;
  $ManufacturersTable get manufacturers => attachedDatabase.manufacturers;
  $ProductsTable get products => attachedDatabase.products;
  $UsersTable get users => attachedDatabase.users;
  $StockTransfersTable get stockTransfers => attachedDatabase.stockTransfers;
  $CustomersTable get customers => attachedDatabase.customers;
  $OrdersTable get orders => attachedDatabase.orders;
  $StockAdjustmentsTable get stockAdjustments =>
      attachedDatabase.stockAdjustments;
  $ShipmentsTable get shipments => attachedDatabase.shipments;
  $StockTransactionsTable get stockTransactions =>
      attachedDatabase.stockTransactions;
  StockTransferDaoManager get managers => StockTransferDaoManager(this);
}

class StockTransferDaoManager {
  final _$StockTransferDaoMixin _db;
  StockTransferDaoManager(this._db);
  $$BusinessesTableTableManager get businesses =>
      $$BusinessesTableTableManager(_db.attachedDatabase, _db.businesses);
  $$StoresTableTableManager get stores =>
      $$StoresTableTableManager(_db.attachedDatabase, _db.stores);
  $$CategoriesTableTableManager get categories =>
      $$CategoriesTableTableManager(_db.attachedDatabase, _db.categories);
  $$CrateSizeGroupsTableTableManager get crateSizeGroups =>
      $$CrateSizeGroupsTableTableManager(
        _db.attachedDatabase,
        _db.crateSizeGroups,
      );
  $$SuppliersTableTableManager get suppliers =>
      $$SuppliersTableTableManager(_db.attachedDatabase, _db.suppliers);
  $$ManufacturersTableTableManager get manufacturers =>
      $$ManufacturersTableTableManager(_db.attachedDatabase, _db.manufacturers);
  $$ProductsTableTableManager get products =>
      $$ProductsTableTableManager(_db.attachedDatabase, _db.products);
  $$UsersTableTableManager get users =>
      $$UsersTableTableManager(_db.attachedDatabase, _db.users);
  $$StockTransfersTableTableManager get stockTransfers =>
      $$StockTransfersTableTableManager(
        _db.attachedDatabase,
        _db.stockTransfers,
      );
  $$CustomersTableTableManager get customers =>
      $$CustomersTableTableManager(_db.attachedDatabase, _db.customers);
  $$OrdersTableTableManager get orders =>
      $$OrdersTableTableManager(_db.attachedDatabase, _db.orders);
  $$StockAdjustmentsTableTableManager get stockAdjustments =>
      $$StockAdjustmentsTableTableManager(
        _db.attachedDatabase,
        _db.stockAdjustments,
      );
  $$ShipmentsTableTableManager get shipments =>
      $$ShipmentsTableTableManager(_db.attachedDatabase, _db.shipments);
  $$StockTransactionsTableTableManager get stockTransactions =>
      $$StockTransactionsTableTableManager(
        _db.attachedDatabase,
        _db.stockTransactions,
      );
}

mixin _$StockAdjustmentRequestsDaoMixin on DatabaseAccessor<AppDatabase> {
  $BusinessesTable get businesses => attachedDatabase.businesses;
  $CategoriesTable get categories => attachedDatabase.categories;
  $CrateSizeGroupsTable get crateSizeGroups => attachedDatabase.crateSizeGroups;
  $SuppliersTable get suppliers => attachedDatabase.suppliers;
  $ManufacturersTable get manufacturers => attachedDatabase.manufacturers;
  $ProductsTable get products => attachedDatabase.products;
  $StoresTable get stores => attachedDatabase.stores;
  $UsersTable get users => attachedDatabase.users;
  $StockAdjustmentRequestsTable get stockAdjustmentRequests =>
      attachedDatabase.stockAdjustmentRequests;
  StockAdjustmentRequestsDaoManager get managers =>
      StockAdjustmentRequestsDaoManager(this);
}

class StockAdjustmentRequestsDaoManager {
  final _$StockAdjustmentRequestsDaoMixin _db;
  StockAdjustmentRequestsDaoManager(this._db);
  $$BusinessesTableTableManager get businesses =>
      $$BusinessesTableTableManager(_db.attachedDatabase, _db.businesses);
  $$CategoriesTableTableManager get categories =>
      $$CategoriesTableTableManager(_db.attachedDatabase, _db.categories);
  $$CrateSizeGroupsTableTableManager get crateSizeGroups =>
      $$CrateSizeGroupsTableTableManager(
        _db.attachedDatabase,
        _db.crateSizeGroups,
      );
  $$SuppliersTableTableManager get suppliers =>
      $$SuppliersTableTableManager(_db.attachedDatabase, _db.suppliers);
  $$ManufacturersTableTableManager get manufacturers =>
      $$ManufacturersTableTableManager(_db.attachedDatabase, _db.manufacturers);
  $$ProductsTableTableManager get products =>
      $$ProductsTableTableManager(_db.attachedDatabase, _db.products);
  $$StoresTableTableManager get stores =>
      $$StoresTableTableManager(_db.attachedDatabase, _db.stores);
  $$UsersTableTableManager get users =>
      $$UsersTableTableManager(_db.attachedDatabase, _db.users);
  $$StockAdjustmentRequestsTableTableManager get stockAdjustmentRequests =>
      $$StockAdjustmentRequestsTableTableManager(
        _db.attachedDatabase,
        _db.stockAdjustmentRequests,
      );
}

mixin _$StockCountsDaoMixin on DatabaseAccessor<AppDatabase> {
  $BusinessesTable get businesses => attachedDatabase.businesses;
  $StoresTable get stores => attachedDatabase.stores;
  $UsersTable get users => attachedDatabase.users;
  $StockCountsTable get stockCounts => attachedDatabase.stockCounts;
  StockCountsDaoManager get managers => StockCountsDaoManager(this);
}

class StockCountsDaoManager {
  final _$StockCountsDaoMixin _db;
  StockCountsDaoManager(this._db);
  $$BusinessesTableTableManager get businesses =>
      $$BusinessesTableTableManager(_db.attachedDatabase, _db.businesses);
  $$StoresTableTableManager get stores =>
      $$StoresTableTableManager(_db.attachedDatabase, _db.stores);
  $$UsersTableTableManager get users =>
      $$UsersTableTableManager(_db.attachedDatabase, _db.users);
  $$StockCountsTableTableManager get stockCounts =>
      $$StockCountsTableTableManager(_db.attachedDatabase, _db.stockCounts);
}

mixin _$CostBatchesDaoMixin on DatabaseAccessor<AppDatabase> {
  $BusinessesTable get businesses => attachedDatabase.businesses;
  $CategoriesTable get categories => attachedDatabase.categories;
  $CrateSizeGroupsTable get crateSizeGroups => attachedDatabase.crateSizeGroups;
  $SuppliersTable get suppliers => attachedDatabase.suppliers;
  $ManufacturersTable get manufacturers => attachedDatabase.manufacturers;
  $ProductsTable get products => attachedDatabase.products;
  $StoresTable get stores => attachedDatabase.stores;
  $CostBatchesTable get costBatches => attachedDatabase.costBatches;
  $CustomersTable get customers => attachedDatabase.customers;
  $UsersTable get users => attachedDatabase.users;
  $OrdersTable get orders => attachedDatabase.orders;
  $OrderItemsTable get orderItems => attachedDatabase.orderItems;
  CostBatchesDaoManager get managers => CostBatchesDaoManager(this);
}

class CostBatchesDaoManager {
  final _$CostBatchesDaoMixin _db;
  CostBatchesDaoManager(this._db);
  $$BusinessesTableTableManager get businesses =>
      $$BusinessesTableTableManager(_db.attachedDatabase, _db.businesses);
  $$CategoriesTableTableManager get categories =>
      $$CategoriesTableTableManager(_db.attachedDatabase, _db.categories);
  $$CrateSizeGroupsTableTableManager get crateSizeGroups =>
      $$CrateSizeGroupsTableTableManager(
        _db.attachedDatabase,
        _db.crateSizeGroups,
      );
  $$SuppliersTableTableManager get suppliers =>
      $$SuppliersTableTableManager(_db.attachedDatabase, _db.suppliers);
  $$ManufacturersTableTableManager get manufacturers =>
      $$ManufacturersTableTableManager(_db.attachedDatabase, _db.manufacturers);
  $$ProductsTableTableManager get products =>
      $$ProductsTableTableManager(_db.attachedDatabase, _db.products);
  $$StoresTableTableManager get stores =>
      $$StoresTableTableManager(_db.attachedDatabase, _db.stores);
  $$CostBatchesTableTableManager get costBatches =>
      $$CostBatchesTableTableManager(_db.attachedDatabase, _db.costBatches);
  $$CustomersTableTableManager get customers =>
      $$CustomersTableTableManager(_db.attachedDatabase, _db.customers);
  $$UsersTableTableManager get users =>
      $$UsersTableTableManager(_db.attachedDatabase, _db.users);
  $$OrdersTableTableManager get orders =>
      $$OrdersTableTableManager(_db.attachedDatabase, _db.orders);
  $$OrderItemsTableTableManager get orderItems =>
      $$OrderItemsTableTableManager(_db.attachedDatabase, _db.orderItems);
}

mixin _$OrdersDaoMixin on DatabaseAccessor<AppDatabase> {
  $BusinessesTable get businesses => attachedDatabase.businesses;
  $StoresTable get stores => attachedDatabase.stores;
  $CustomersTable get customers => attachedDatabase.customers;
  $UsersTable get users => attachedDatabase.users;
  $OrdersTable get orders => attachedDatabase.orders;
  $CategoriesTable get categories => attachedDatabase.categories;
  $CrateSizeGroupsTable get crateSizeGroups => attachedDatabase.crateSizeGroups;
  $SuppliersTable get suppliers => attachedDatabase.suppliers;
  $ManufacturersTable get manufacturers => attachedDatabase.manufacturers;
  $ProductsTable get products => attachedDatabase.products;
  $OrderItemsTable get orderItems => attachedDatabase.orderItems;
  $SavedCartsTable get savedCarts => attachedDatabase.savedCarts;
  $InventoryTable get inventory => attachedDatabase.inventory;
  $StockTransfersTable get stockTransfers => attachedDatabase.stockTransfers;
  $StockAdjustmentsTable get stockAdjustments =>
      attachedDatabase.stockAdjustments;
  $ShipmentsTable get shipments => attachedDatabase.shipments;
  $StockTransactionsTable get stockTransactions =>
      attachedDatabase.stockTransactions;
  $ExpenseCategoriesTable get expenseCategories =>
      attachedDatabase.expenseCategories;
  $ExpensesTable get expenses => attachedDatabase.expenses;
  $CustomerWalletsTable get customerWallets => attachedDatabase.customerWallets;
  $WalletTransactionsTable get walletTransactions =>
      attachedDatabase.walletTransactions;
  $DriversTable get drivers => attachedDatabase.drivers;
  $DeliveryReceiptsTable get deliveryReceipts =>
      attachedDatabase.deliveryReceipts;
  $PaymentTransactionsTable get paymentTransactions =>
      attachedDatabase.paymentTransactions;
  OrdersDaoManager get managers => OrdersDaoManager(this);
}

class OrdersDaoManager {
  final _$OrdersDaoMixin _db;
  OrdersDaoManager(this._db);
  $$BusinessesTableTableManager get businesses =>
      $$BusinessesTableTableManager(_db.attachedDatabase, _db.businesses);
  $$StoresTableTableManager get stores =>
      $$StoresTableTableManager(_db.attachedDatabase, _db.stores);
  $$CustomersTableTableManager get customers =>
      $$CustomersTableTableManager(_db.attachedDatabase, _db.customers);
  $$UsersTableTableManager get users =>
      $$UsersTableTableManager(_db.attachedDatabase, _db.users);
  $$OrdersTableTableManager get orders =>
      $$OrdersTableTableManager(_db.attachedDatabase, _db.orders);
  $$CategoriesTableTableManager get categories =>
      $$CategoriesTableTableManager(_db.attachedDatabase, _db.categories);
  $$CrateSizeGroupsTableTableManager get crateSizeGroups =>
      $$CrateSizeGroupsTableTableManager(
        _db.attachedDatabase,
        _db.crateSizeGroups,
      );
  $$SuppliersTableTableManager get suppliers =>
      $$SuppliersTableTableManager(_db.attachedDatabase, _db.suppliers);
  $$ManufacturersTableTableManager get manufacturers =>
      $$ManufacturersTableTableManager(_db.attachedDatabase, _db.manufacturers);
  $$ProductsTableTableManager get products =>
      $$ProductsTableTableManager(_db.attachedDatabase, _db.products);
  $$OrderItemsTableTableManager get orderItems =>
      $$OrderItemsTableTableManager(_db.attachedDatabase, _db.orderItems);
  $$SavedCartsTableTableManager get savedCarts =>
      $$SavedCartsTableTableManager(_db.attachedDatabase, _db.savedCarts);
  $$InventoryTableTableManager get inventory =>
      $$InventoryTableTableManager(_db.attachedDatabase, _db.inventory);
  $$StockTransfersTableTableManager get stockTransfers =>
      $$StockTransfersTableTableManager(
        _db.attachedDatabase,
        _db.stockTransfers,
      );
  $$StockAdjustmentsTableTableManager get stockAdjustments =>
      $$StockAdjustmentsTableTableManager(
        _db.attachedDatabase,
        _db.stockAdjustments,
      );
  $$ShipmentsTableTableManager get shipments =>
      $$ShipmentsTableTableManager(_db.attachedDatabase, _db.shipments);
  $$StockTransactionsTableTableManager get stockTransactions =>
      $$StockTransactionsTableTableManager(
        _db.attachedDatabase,
        _db.stockTransactions,
      );
  $$ExpenseCategoriesTableTableManager get expenseCategories =>
      $$ExpenseCategoriesTableTableManager(
        _db.attachedDatabase,
        _db.expenseCategories,
      );
  $$ExpensesTableTableManager get expenses =>
      $$ExpensesTableTableManager(_db.attachedDatabase, _db.expenses);
  $$CustomerWalletsTableTableManager get customerWallets =>
      $$CustomerWalletsTableTableManager(
        _db.attachedDatabase,
        _db.customerWallets,
      );
  $$WalletTransactionsTableTableManager get walletTransactions =>
      $$WalletTransactionsTableTableManager(
        _db.attachedDatabase,
        _db.walletTransactions,
      );
  $$DriversTableTableManager get drivers =>
      $$DriversTableTableManager(_db.attachedDatabase, _db.drivers);
  $$DeliveryReceiptsTableTableManager get deliveryReceipts =>
      $$DeliveryReceiptsTableTableManager(
        _db.attachedDatabase,
        _db.deliveryReceipts,
      );
  $$PaymentTransactionsTableTableManager get paymentTransactions =>
      $$PaymentTransactionsTableTableManager(
        _db.attachedDatabase,
        _db.paymentTransactions,
      );
}

mixin _$OrderCrateLinesDaoMixin on DatabaseAccessor<AppDatabase> {
  $BusinessesTable get businesses => attachedDatabase.businesses;
  $StoresTable get stores => attachedDatabase.stores;
  $CustomersTable get customers => attachedDatabase.customers;
  $UsersTable get users => attachedDatabase.users;
  $OrdersTable get orders => attachedDatabase.orders;
  $ManufacturersTable get manufacturers => attachedDatabase.manufacturers;
  $OrderCrateLinesTable get orderCrateLines => attachedDatabase.orderCrateLines;
  OrderCrateLinesDaoManager get managers => OrderCrateLinesDaoManager(this);
}

class OrderCrateLinesDaoManager {
  final _$OrderCrateLinesDaoMixin _db;
  OrderCrateLinesDaoManager(this._db);
  $$BusinessesTableTableManager get businesses =>
      $$BusinessesTableTableManager(_db.attachedDatabase, _db.businesses);
  $$StoresTableTableManager get stores =>
      $$StoresTableTableManager(_db.attachedDatabase, _db.stores);
  $$CustomersTableTableManager get customers =>
      $$CustomersTableTableManager(_db.attachedDatabase, _db.customers);
  $$UsersTableTableManager get users =>
      $$UsersTableTableManager(_db.attachedDatabase, _db.users);
  $$OrdersTableTableManager get orders =>
      $$OrdersTableTableManager(_db.attachedDatabase, _db.orders);
  $$ManufacturersTableTableManager get manufacturers =>
      $$ManufacturersTableTableManager(_db.attachedDatabase, _db.manufacturers);
  $$OrderCrateLinesTableTableManager get orderCrateLines =>
      $$OrderCrateLinesTableTableManager(
        _db.attachedDatabase,
        _db.orderCrateLines,
      );
}

mixin _$QuickSaleRequestsDaoMixin on DatabaseAccessor<AppDatabase> {
  $BusinessesTable get businesses => attachedDatabase.businesses;
  $StoresTable get stores => attachedDatabase.stores;
  $UsersTable get users => attachedDatabase.users;
  $QuickSaleRequestsTable get quickSaleRequests =>
      attachedDatabase.quickSaleRequests;
  QuickSaleRequestsDaoManager get managers => QuickSaleRequestsDaoManager(this);
}

class QuickSaleRequestsDaoManager {
  final _$QuickSaleRequestsDaoMixin _db;
  QuickSaleRequestsDaoManager(this._db);
  $$BusinessesTableTableManager get businesses =>
      $$BusinessesTableTableManager(_db.attachedDatabase, _db.businesses);
  $$StoresTableTableManager get stores =>
      $$StoresTableTableManager(_db.attachedDatabase, _db.stores);
  $$UsersTableTableManager get users =>
      $$UsersTableTableManager(_db.attachedDatabase, _db.users);
  $$QuickSaleRequestsTableTableManager get quickSaleRequests =>
      $$QuickSaleRequestsTableTableManager(
        _db.attachedDatabase,
        _db.quickSaleRequests,
      );
}

mixin _$PaymentTransactionsDaoMixin on DatabaseAccessor<AppDatabase> {
  $BusinessesTable get businesses => attachedDatabase.businesses;
  $StoresTable get stores => attachedDatabase.stores;
  $CustomersTable get customers => attachedDatabase.customers;
  $UsersTable get users => attachedDatabase.users;
  $OrdersTable get orders => attachedDatabase.orders;
  $CrateSizeGroupsTable get crateSizeGroups => attachedDatabase.crateSizeGroups;
  $SuppliersTable get suppliers => attachedDatabase.suppliers;
  $ShipmentsTable get shipments => attachedDatabase.shipments;
  $ExpenseCategoriesTable get expenseCategories =>
      attachedDatabase.expenseCategories;
  $ExpensesTable get expenses => attachedDatabase.expenses;
  $CustomerWalletsTable get customerWallets => attachedDatabase.customerWallets;
  $WalletTransactionsTable get walletTransactions =>
      attachedDatabase.walletTransactions;
  $DriversTable get drivers => attachedDatabase.drivers;
  $DeliveryReceiptsTable get deliveryReceipts =>
      attachedDatabase.deliveryReceipts;
  $PaymentTransactionsTable get paymentTransactions =>
      attachedDatabase.paymentTransactions;
  PaymentTransactionsDaoManager get managers =>
      PaymentTransactionsDaoManager(this);
}

class PaymentTransactionsDaoManager {
  final _$PaymentTransactionsDaoMixin _db;
  PaymentTransactionsDaoManager(this._db);
  $$BusinessesTableTableManager get businesses =>
      $$BusinessesTableTableManager(_db.attachedDatabase, _db.businesses);
  $$StoresTableTableManager get stores =>
      $$StoresTableTableManager(_db.attachedDatabase, _db.stores);
  $$CustomersTableTableManager get customers =>
      $$CustomersTableTableManager(_db.attachedDatabase, _db.customers);
  $$UsersTableTableManager get users =>
      $$UsersTableTableManager(_db.attachedDatabase, _db.users);
  $$OrdersTableTableManager get orders =>
      $$OrdersTableTableManager(_db.attachedDatabase, _db.orders);
  $$CrateSizeGroupsTableTableManager get crateSizeGroups =>
      $$CrateSizeGroupsTableTableManager(
        _db.attachedDatabase,
        _db.crateSizeGroups,
      );
  $$SuppliersTableTableManager get suppliers =>
      $$SuppliersTableTableManager(_db.attachedDatabase, _db.suppliers);
  $$ShipmentsTableTableManager get shipments =>
      $$ShipmentsTableTableManager(_db.attachedDatabase, _db.shipments);
  $$ExpenseCategoriesTableTableManager get expenseCategories =>
      $$ExpenseCategoriesTableTableManager(
        _db.attachedDatabase,
        _db.expenseCategories,
      );
  $$ExpensesTableTableManager get expenses =>
      $$ExpensesTableTableManager(_db.attachedDatabase, _db.expenses);
  $$CustomerWalletsTableTableManager get customerWallets =>
      $$CustomerWalletsTableTableManager(
        _db.attachedDatabase,
        _db.customerWallets,
      );
  $$WalletTransactionsTableTableManager get walletTransactions =>
      $$WalletTransactionsTableTableManager(
        _db.attachedDatabase,
        _db.walletTransactions,
      );
  $$DriversTableTableManager get drivers =>
      $$DriversTableTableManager(_db.attachedDatabase, _db.drivers);
  $$DeliveryReceiptsTableTableManager get deliveryReceipts =>
      $$DeliveryReceiptsTableTableManager(
        _db.attachedDatabase,
        _db.deliveryReceipts,
      );
  $$PaymentTransactionsTableTableManager get paymentTransactions =>
      $$PaymentTransactionsTableTableManager(
        _db.attachedDatabase,
        _db.paymentTransactions,
      );
}

mixin _$CustomersDaoMixin on DatabaseAccessor<AppDatabase> {
  $BusinessesTable get businesses => attachedDatabase.businesses;
  $StoresTable get stores => attachedDatabase.stores;
  $CustomersTable get customers => attachedDatabase.customers;
  $ManufacturersTable get manufacturers => attachedDatabase.manufacturers;
  $CustomerCrateBalancesTable get customerCrateBalances =>
      attachedDatabase.customerCrateBalances;
  $CustomerWalletsTable get customerWallets => attachedDatabase.customerWallets;
  $UsersTable get users => attachedDatabase.users;
  $OrdersTable get orders => attachedDatabase.orders;
  $WalletTransactionsTable get walletTransactions =>
      attachedDatabase.walletTransactions;
  CustomersDaoManager get managers => CustomersDaoManager(this);
}

class CustomersDaoManager {
  final _$CustomersDaoMixin _db;
  CustomersDaoManager(this._db);
  $$BusinessesTableTableManager get businesses =>
      $$BusinessesTableTableManager(_db.attachedDatabase, _db.businesses);
  $$StoresTableTableManager get stores =>
      $$StoresTableTableManager(_db.attachedDatabase, _db.stores);
  $$CustomersTableTableManager get customers =>
      $$CustomersTableTableManager(_db.attachedDatabase, _db.customers);
  $$ManufacturersTableTableManager get manufacturers =>
      $$ManufacturersTableTableManager(_db.attachedDatabase, _db.manufacturers);
  $$CustomerCrateBalancesTableTableManager get customerCrateBalances =>
      $$CustomerCrateBalancesTableTableManager(
        _db.attachedDatabase,
        _db.customerCrateBalances,
      );
  $$CustomerWalletsTableTableManager get customerWallets =>
      $$CustomerWalletsTableTableManager(
        _db.attachedDatabase,
        _db.customerWallets,
      );
  $$UsersTableTableManager get users =>
      $$UsersTableTableManager(_db.attachedDatabase, _db.users);
  $$OrdersTableTableManager get orders =>
      $$OrdersTableTableManager(_db.attachedDatabase, _db.orders);
  $$WalletTransactionsTableTableManager get walletTransactions =>
      $$WalletTransactionsTableTableManager(
        _db.attachedDatabase,
        _db.walletTransactions,
      );
}

mixin _$CustomerWalletsDaoMixin on DatabaseAccessor<AppDatabase> {
  $BusinessesTable get businesses => attachedDatabase.businesses;
  $StoresTable get stores => attachedDatabase.stores;
  $CustomersTable get customers => attachedDatabase.customers;
  $CustomerWalletsTable get customerWallets => attachedDatabase.customerWallets;
  CustomerWalletsDaoManager get managers => CustomerWalletsDaoManager(this);
}

class CustomerWalletsDaoManager {
  final _$CustomerWalletsDaoMixin _db;
  CustomerWalletsDaoManager(this._db);
  $$BusinessesTableTableManager get businesses =>
      $$BusinessesTableTableManager(_db.attachedDatabase, _db.businesses);
  $$StoresTableTableManager get stores =>
      $$StoresTableTableManager(_db.attachedDatabase, _db.stores);
  $$CustomersTableTableManager get customers =>
      $$CustomersTableTableManager(_db.attachedDatabase, _db.customers);
  $$CustomerWalletsTableTableManager get customerWallets =>
      $$CustomerWalletsTableTableManager(
        _db.attachedDatabase,
        _db.customerWallets,
      );
}

mixin _$WalletTransactionsDaoMixin on DatabaseAccessor<AppDatabase> {
  $BusinessesTable get businesses => attachedDatabase.businesses;
  $StoresTable get stores => attachedDatabase.stores;
  $CustomersTable get customers => attachedDatabase.customers;
  $CustomerWalletsTable get customerWallets => attachedDatabase.customerWallets;
  $UsersTable get users => attachedDatabase.users;
  $OrdersTable get orders => attachedDatabase.orders;
  $WalletTransactionsTable get walletTransactions =>
      attachedDatabase.walletTransactions;
  $CrateSizeGroupsTable get crateSizeGroups => attachedDatabase.crateSizeGroups;
  $SuppliersTable get suppliers => attachedDatabase.suppliers;
  $ShipmentsTable get shipments => attachedDatabase.shipments;
  $ExpenseCategoriesTable get expenseCategories =>
      attachedDatabase.expenseCategories;
  $ExpensesTable get expenses => attachedDatabase.expenses;
  $DriversTable get drivers => attachedDatabase.drivers;
  $DeliveryReceiptsTable get deliveryReceipts =>
      attachedDatabase.deliveryReceipts;
  $PaymentTransactionsTable get paymentTransactions =>
      attachedDatabase.paymentTransactions;
  WalletTransactionsDaoManager get managers =>
      WalletTransactionsDaoManager(this);
}

class WalletTransactionsDaoManager {
  final _$WalletTransactionsDaoMixin _db;
  WalletTransactionsDaoManager(this._db);
  $$BusinessesTableTableManager get businesses =>
      $$BusinessesTableTableManager(_db.attachedDatabase, _db.businesses);
  $$StoresTableTableManager get stores =>
      $$StoresTableTableManager(_db.attachedDatabase, _db.stores);
  $$CustomersTableTableManager get customers =>
      $$CustomersTableTableManager(_db.attachedDatabase, _db.customers);
  $$CustomerWalletsTableTableManager get customerWallets =>
      $$CustomerWalletsTableTableManager(
        _db.attachedDatabase,
        _db.customerWallets,
      );
  $$UsersTableTableManager get users =>
      $$UsersTableTableManager(_db.attachedDatabase, _db.users);
  $$OrdersTableTableManager get orders =>
      $$OrdersTableTableManager(_db.attachedDatabase, _db.orders);
  $$WalletTransactionsTableTableManager get walletTransactions =>
      $$WalletTransactionsTableTableManager(
        _db.attachedDatabase,
        _db.walletTransactions,
      );
  $$CrateSizeGroupsTableTableManager get crateSizeGroups =>
      $$CrateSizeGroupsTableTableManager(
        _db.attachedDatabase,
        _db.crateSizeGroups,
      );
  $$SuppliersTableTableManager get suppliers =>
      $$SuppliersTableTableManager(_db.attachedDatabase, _db.suppliers);
  $$ShipmentsTableTableManager get shipments =>
      $$ShipmentsTableTableManager(_db.attachedDatabase, _db.shipments);
  $$ExpenseCategoriesTableTableManager get expenseCategories =>
      $$ExpenseCategoriesTableTableManager(
        _db.attachedDatabase,
        _db.expenseCategories,
      );
  $$ExpensesTableTableManager get expenses =>
      $$ExpensesTableTableManager(_db.attachedDatabase, _db.expenses);
  $$DriversTableTableManager get drivers =>
      $$DriversTableTableManager(_db.attachedDatabase, _db.drivers);
  $$DeliveryReceiptsTableTableManager get deliveryReceipts =>
      $$DeliveryReceiptsTableTableManager(
        _db.attachedDatabase,
        _db.deliveryReceipts,
      );
  $$PaymentTransactionsTableTableManager get paymentTransactions =>
      $$PaymentTransactionsTableTableManager(
        _db.attachedDatabase,
        _db.paymentTransactions,
      );
}

mixin _$CustomerCrateBalancesDaoMixin on DatabaseAccessor<AppDatabase> {
  $BusinessesTable get businesses => attachedDatabase.businesses;
  $StoresTable get stores => attachedDatabase.stores;
  $CustomersTable get customers => attachedDatabase.customers;
  $ManufacturersTable get manufacturers => attachedDatabase.manufacturers;
  $CustomerCrateBalancesTable get customerCrateBalances =>
      attachedDatabase.customerCrateBalances;
  CustomerCrateBalancesDaoManager get managers =>
      CustomerCrateBalancesDaoManager(this);
}

class CustomerCrateBalancesDaoManager {
  final _$CustomerCrateBalancesDaoMixin _db;
  CustomerCrateBalancesDaoManager(this._db);
  $$BusinessesTableTableManager get businesses =>
      $$BusinessesTableTableManager(_db.attachedDatabase, _db.businesses);
  $$StoresTableTableManager get stores =>
      $$StoresTableTableManager(_db.attachedDatabase, _db.stores);
  $$CustomersTableTableManager get customers =>
      $$CustomersTableTableManager(_db.attachedDatabase, _db.customers);
  $$ManufacturersTableTableManager get manufacturers =>
      $$ManufacturersTableTableManager(_db.attachedDatabase, _db.manufacturers);
  $$CustomerCrateBalancesTableTableManager get customerCrateBalances =>
      $$CustomerCrateBalancesTableTableManager(
        _db.attachedDatabase,
        _db.customerCrateBalances,
      );
}

mixin _$ShipmentsDaoMixin on DatabaseAccessor<AppDatabase> {
  $BusinessesTable get businesses => attachedDatabase.businesses;
  $CrateSizeGroupsTable get crateSizeGroups => attachedDatabase.crateSizeGroups;
  $SuppliersTable get suppliers => attachedDatabase.suppliers;
  $ShipmentsTable get shipments => attachedDatabase.shipments;
  $CategoriesTable get categories => attachedDatabase.categories;
  $ManufacturersTable get manufacturers => attachedDatabase.manufacturers;
  $ProductsTable get products => attachedDatabase.products;
  $PurchaseItemsTable get purchaseItems => attachedDatabase.purchaseItems;
  ShipmentsDaoManager get managers => ShipmentsDaoManager(this);
}

class ShipmentsDaoManager {
  final _$ShipmentsDaoMixin _db;
  ShipmentsDaoManager(this._db);
  $$BusinessesTableTableManager get businesses =>
      $$BusinessesTableTableManager(_db.attachedDatabase, _db.businesses);
  $$CrateSizeGroupsTableTableManager get crateSizeGroups =>
      $$CrateSizeGroupsTableTableManager(
        _db.attachedDatabase,
        _db.crateSizeGroups,
      );
  $$SuppliersTableTableManager get suppliers =>
      $$SuppliersTableTableManager(_db.attachedDatabase, _db.suppliers);
  $$ShipmentsTableTableManager get shipments =>
      $$ShipmentsTableTableManager(_db.attachedDatabase, _db.shipments);
  $$CategoriesTableTableManager get categories =>
      $$CategoriesTableTableManager(_db.attachedDatabase, _db.categories);
  $$ManufacturersTableTableManager get manufacturers =>
      $$ManufacturersTableTableManager(_db.attachedDatabase, _db.manufacturers);
  $$ProductsTableTableManager get products =>
      $$ProductsTableTableManager(_db.attachedDatabase, _db.products);
  $$PurchaseItemsTableTableManager get purchaseItems =>
      $$PurchaseItemsTableTableManager(_db.attachedDatabase, _db.purchaseItems);
}

mixin _$SupplierLedgerDaoMixin on DatabaseAccessor<AppDatabase> {
  $BusinessesTable get businesses => attachedDatabase.businesses;
  $CrateSizeGroupsTable get crateSizeGroups => attachedDatabase.crateSizeGroups;
  $SuppliersTable get suppliers => attachedDatabase.suppliers;
  $StoresTable get stores => attachedDatabase.stores;
  $UsersTable get users => attachedDatabase.users;
  $SupplierLedgerEntriesTable get supplierLedgerEntries =>
      attachedDatabase.supplierLedgerEntries;
  SupplierLedgerDaoManager get managers => SupplierLedgerDaoManager(this);
}

class SupplierLedgerDaoManager {
  final _$SupplierLedgerDaoMixin _db;
  SupplierLedgerDaoManager(this._db);
  $$BusinessesTableTableManager get businesses =>
      $$BusinessesTableTableManager(_db.attachedDatabase, _db.businesses);
  $$CrateSizeGroupsTableTableManager get crateSizeGroups =>
      $$CrateSizeGroupsTableTableManager(
        _db.attachedDatabase,
        _db.crateSizeGroups,
      );
  $$SuppliersTableTableManager get suppliers =>
      $$SuppliersTableTableManager(_db.attachedDatabase, _db.suppliers);
  $$StoresTableTableManager get stores =>
      $$StoresTableTableManager(_db.attachedDatabase, _db.stores);
  $$UsersTableTableManager get users =>
      $$UsersTableTableManager(_db.attachedDatabase, _db.users);
  $$SupplierLedgerEntriesTableTableManager get supplierLedgerEntries =>
      $$SupplierLedgerEntriesTableTableManager(
        _db.attachedDatabase,
        _db.supplierLedgerEntries,
      );
}

mixin _$SupplierCrateLedgerDaoMixin on DatabaseAccessor<AppDatabase> {
  $BusinessesTable get businesses => attachedDatabase.businesses;
  $CrateSizeGroupsTable get crateSizeGroups => attachedDatabase.crateSizeGroups;
  $SuppliersTable get suppliers => attachedDatabase.suppliers;
  $ManufacturersTable get manufacturers => attachedDatabase.manufacturers;
  $StoresTable get stores => attachedDatabase.stores;
  $UsersTable get users => attachedDatabase.users;
  $SupplierCrateLedgerTable get supplierCrateLedger =>
      attachedDatabase.supplierCrateLedger;
  $SupplierCrateBalancesTable get supplierCrateBalances =>
      attachedDatabase.supplierCrateBalances;
  SupplierCrateLedgerDaoManager get managers =>
      SupplierCrateLedgerDaoManager(this);
}

class SupplierCrateLedgerDaoManager {
  final _$SupplierCrateLedgerDaoMixin _db;
  SupplierCrateLedgerDaoManager(this._db);
  $$BusinessesTableTableManager get businesses =>
      $$BusinessesTableTableManager(_db.attachedDatabase, _db.businesses);
  $$CrateSizeGroupsTableTableManager get crateSizeGroups =>
      $$CrateSizeGroupsTableTableManager(
        _db.attachedDatabase,
        _db.crateSizeGroups,
      );
  $$SuppliersTableTableManager get suppliers =>
      $$SuppliersTableTableManager(_db.attachedDatabase, _db.suppliers);
  $$ManufacturersTableTableManager get manufacturers =>
      $$ManufacturersTableTableManager(_db.attachedDatabase, _db.manufacturers);
  $$StoresTableTableManager get stores =>
      $$StoresTableTableManager(_db.attachedDatabase, _db.stores);
  $$UsersTableTableManager get users =>
      $$UsersTableTableManager(_db.attachedDatabase, _db.users);
  $$SupplierCrateLedgerTableTableManager get supplierCrateLedger =>
      $$SupplierCrateLedgerTableTableManager(
        _db.attachedDatabase,
        _db.supplierCrateLedger,
      );
  $$SupplierCrateBalancesTableTableManager get supplierCrateBalances =>
      $$SupplierCrateBalancesTableTableManager(
        _db.attachedDatabase,
        _db.supplierCrateBalances,
      );
}

mixin _$SupplierCrateBalancesDaoMixin on DatabaseAccessor<AppDatabase> {
  $BusinessesTable get businesses => attachedDatabase.businesses;
  $CrateSizeGroupsTable get crateSizeGroups => attachedDatabase.crateSizeGroups;
  $SuppliersTable get suppliers => attachedDatabase.suppliers;
  $ManufacturersTable get manufacturers => attachedDatabase.manufacturers;
  $SupplierCrateBalancesTable get supplierCrateBalances =>
      attachedDatabase.supplierCrateBalances;
  SupplierCrateBalancesDaoManager get managers =>
      SupplierCrateBalancesDaoManager(this);
}

class SupplierCrateBalancesDaoManager {
  final _$SupplierCrateBalancesDaoMixin _db;
  SupplierCrateBalancesDaoManager(this._db);
  $$BusinessesTableTableManager get businesses =>
      $$BusinessesTableTableManager(_db.attachedDatabase, _db.businesses);
  $$CrateSizeGroupsTableTableManager get crateSizeGroups =>
      $$CrateSizeGroupsTableTableManager(
        _db.attachedDatabase,
        _db.crateSizeGroups,
      );
  $$SuppliersTableTableManager get suppliers =>
      $$SuppliersTableTableManager(_db.attachedDatabase, _db.suppliers);
  $$ManufacturersTableTableManager get manufacturers =>
      $$ManufacturersTableTableManager(_db.attachedDatabase, _db.manufacturers);
  $$SupplierCrateBalancesTableTableManager get supplierCrateBalances =>
      $$SupplierCrateBalancesTableTableManager(
        _db.attachedDatabase,
        _db.supplierCrateBalances,
      );
}

mixin _$PendingCrateReturnsDaoMixin on DatabaseAccessor<AppDatabase> {
  $BusinessesTable get businesses => attachedDatabase.businesses;
  $StoresTable get stores => attachedDatabase.stores;
  $CustomersTable get customers => attachedDatabase.customers;
  $UsersTable get users => attachedDatabase.users;
  $OrdersTable get orders => attachedDatabase.orders;
  $ManufacturersTable get manufacturers => attachedDatabase.manufacturers;
  $PendingCrateReturnsTable get pendingCrateReturns =>
      attachedDatabase.pendingCrateReturns;
  PendingCrateReturnsDaoManager get managers =>
      PendingCrateReturnsDaoManager(this);
}

class PendingCrateReturnsDaoManager {
  final _$PendingCrateReturnsDaoMixin _db;
  PendingCrateReturnsDaoManager(this._db);
  $$BusinessesTableTableManager get businesses =>
      $$BusinessesTableTableManager(_db.attachedDatabase, _db.businesses);
  $$StoresTableTableManager get stores =>
      $$StoresTableTableManager(_db.attachedDatabase, _db.stores);
  $$CustomersTableTableManager get customers =>
      $$CustomersTableTableManager(_db.attachedDatabase, _db.customers);
  $$UsersTableTableManager get users =>
      $$UsersTableTableManager(_db.attachedDatabase, _db.users);
  $$OrdersTableTableManager get orders =>
      $$OrdersTableTableManager(_db.attachedDatabase, _db.orders);
  $$ManufacturersTableTableManager get manufacturers =>
      $$ManufacturersTableTableManager(_db.attachedDatabase, _db.manufacturers);
  $$PendingCrateReturnsTableTableManager get pendingCrateReturns =>
      $$PendingCrateReturnsTableTableManager(
        _db.attachedDatabase,
        _db.pendingCrateReturns,
      );
}

mixin _$CrateSizeGroupsDaoMixin on DatabaseAccessor<AppDatabase> {
  $BusinessesTable get businesses => attachedDatabase.businesses;
  $CrateSizeGroupsTable get crateSizeGroups => attachedDatabase.crateSizeGroups;
  CrateSizeGroupsDaoManager get managers => CrateSizeGroupsDaoManager(this);
}

class CrateSizeGroupsDaoManager {
  final _$CrateSizeGroupsDaoMixin _db;
  CrateSizeGroupsDaoManager(this._db);
  $$BusinessesTableTableManager get businesses =>
      $$BusinessesTableTableManager(_db.attachedDatabase, _db.businesses);
  $$CrateSizeGroupsTableTableManager get crateSizeGroups =>
      $$CrateSizeGroupsTableTableManager(
        _db.attachedDatabase,
        _db.crateSizeGroups,
      );
}

mixin _$ManufacturerCrateBalancesDaoMixin on DatabaseAccessor<AppDatabase> {
  $BusinessesTable get businesses => attachedDatabase.businesses;
  $ManufacturersTable get manufacturers => attachedDatabase.manufacturers;
  $ManufacturerCrateBalancesTable get manufacturerCrateBalances =>
      attachedDatabase.manufacturerCrateBalances;
  ManufacturerCrateBalancesDaoManager get managers =>
      ManufacturerCrateBalancesDaoManager(this);
}

class ManufacturerCrateBalancesDaoManager {
  final _$ManufacturerCrateBalancesDaoMixin _db;
  ManufacturerCrateBalancesDaoManager(this._db);
  $$BusinessesTableTableManager get businesses =>
      $$BusinessesTableTableManager(_db.attachedDatabase, _db.businesses);
  $$ManufacturersTableTableManager get manufacturers =>
      $$ManufacturersTableTableManager(_db.attachedDatabase, _db.manufacturers);
  $$ManufacturerCrateBalancesTableTableManager get manufacturerCrateBalances =>
      $$ManufacturerCrateBalancesTableTableManager(
        _db.attachedDatabase,
        _db.manufacturerCrateBalances,
      );
}

mixin _$StoreCrateBalancesDaoMixin on DatabaseAccessor<AppDatabase> {
  $BusinessesTable get businesses => attachedDatabase.businesses;
  $StoresTable get stores => attachedDatabase.stores;
  $ManufacturersTable get manufacturers => attachedDatabase.manufacturers;
  $StoreCrateBalancesTable get storeCrateBalances =>
      attachedDatabase.storeCrateBalances;
  StoreCrateBalancesDaoManager get managers =>
      StoreCrateBalancesDaoManager(this);
}

class StoreCrateBalancesDaoManager {
  final _$StoreCrateBalancesDaoMixin _db;
  StoreCrateBalancesDaoManager(this._db);
  $$BusinessesTableTableManager get businesses =>
      $$BusinessesTableTableManager(_db.attachedDatabase, _db.businesses);
  $$StoresTableTableManager get stores =>
      $$StoresTableTableManager(_db.attachedDatabase, _db.stores);
  $$ManufacturersTableTableManager get manufacturers =>
      $$ManufacturersTableTableManager(_db.attachedDatabase, _db.manufacturers);
  $$StoreCrateBalancesTableTableManager get storeCrateBalances =>
      $$StoreCrateBalancesTableTableManager(
        _db.attachedDatabase,
        _db.storeCrateBalances,
      );
}

mixin _$CratePoolDaoMixin on DatabaseAccessor<AppDatabase> {
  $BusinessesTable get businesses => attachedDatabase.businesses;
  $StoresTable get stores => attachedDatabase.stores;
  $CustomersTable get customers => attachedDatabase.customers;
  $ManufacturersTable get manufacturers => attachedDatabase.manufacturers;
  $CrateSizeGroupsTable get crateSizeGroups => attachedDatabase.crateSizeGroups;
  $UsersTable get users => attachedDatabase.users;
  $OrdersTable get orders => attachedDatabase.orders;
  $PendingCrateReturnsTable get pendingCrateReturns =>
      attachedDatabase.pendingCrateReturns;
  $CrateLedgerTable get crateLedger => attachedDatabase.crateLedger;
  $CustomerCrateBalancesTable get customerCrateBalances =>
      attachedDatabase.customerCrateBalances;
  $ManufacturerCrateBalancesTable get manufacturerCrateBalances =>
      attachedDatabase.manufacturerCrateBalances;
  $StoreCrateBalancesTable get storeCrateBalances =>
      attachedDatabase.storeCrateBalances;
  $SuppliersTable get suppliers => attachedDatabase.suppliers;
  $SupplierCrateLedgerTable get supplierCrateLedger =>
      attachedDatabase.supplierCrateLedger;
  $SupplierCrateBalancesTable get supplierCrateBalances =>
      attachedDatabase.supplierCrateBalances;
  CratePoolDaoManager get managers => CratePoolDaoManager(this);
}

class CratePoolDaoManager {
  final _$CratePoolDaoMixin _db;
  CratePoolDaoManager(this._db);
  $$BusinessesTableTableManager get businesses =>
      $$BusinessesTableTableManager(_db.attachedDatabase, _db.businesses);
  $$StoresTableTableManager get stores =>
      $$StoresTableTableManager(_db.attachedDatabase, _db.stores);
  $$CustomersTableTableManager get customers =>
      $$CustomersTableTableManager(_db.attachedDatabase, _db.customers);
  $$ManufacturersTableTableManager get manufacturers =>
      $$ManufacturersTableTableManager(_db.attachedDatabase, _db.manufacturers);
  $$CrateSizeGroupsTableTableManager get crateSizeGroups =>
      $$CrateSizeGroupsTableTableManager(
        _db.attachedDatabase,
        _db.crateSizeGroups,
      );
  $$UsersTableTableManager get users =>
      $$UsersTableTableManager(_db.attachedDatabase, _db.users);
  $$OrdersTableTableManager get orders =>
      $$OrdersTableTableManager(_db.attachedDatabase, _db.orders);
  $$PendingCrateReturnsTableTableManager get pendingCrateReturns =>
      $$PendingCrateReturnsTableTableManager(
        _db.attachedDatabase,
        _db.pendingCrateReturns,
      );
  $$CrateLedgerTableTableManager get crateLedger =>
      $$CrateLedgerTableTableManager(_db.attachedDatabase, _db.crateLedger);
  $$CustomerCrateBalancesTableTableManager get customerCrateBalances =>
      $$CustomerCrateBalancesTableTableManager(
        _db.attachedDatabase,
        _db.customerCrateBalances,
      );
  $$ManufacturerCrateBalancesTableTableManager get manufacturerCrateBalances =>
      $$ManufacturerCrateBalancesTableTableManager(
        _db.attachedDatabase,
        _db.manufacturerCrateBalances,
      );
  $$StoreCrateBalancesTableTableManager get storeCrateBalances =>
      $$StoreCrateBalancesTableTableManager(
        _db.attachedDatabase,
        _db.storeCrateBalances,
      );
  $$SuppliersTableTableManager get suppliers =>
      $$SuppliersTableTableManager(_db.attachedDatabase, _db.suppliers);
  $$SupplierCrateLedgerTableTableManager get supplierCrateLedger =>
      $$SupplierCrateLedgerTableTableManager(
        _db.attachedDatabase,
        _db.supplierCrateLedger,
      );
  $$SupplierCrateBalancesTableTableManager get supplierCrateBalances =>
      $$SupplierCrateBalancesTableTableManager(
        _db.attachedDatabase,
        _db.supplierCrateBalances,
      );
}

mixin _$ExpensesDaoMixin on DatabaseAccessor<AppDatabase> {
  $BusinessesTable get businesses => attachedDatabase.businesses;
  $ExpenseCategoriesTable get expenseCategories =>
      attachedDatabase.expenseCategories;
  $StoresTable get stores => attachedDatabase.stores;
  $UsersTable get users => attachedDatabase.users;
  $ExpensesTable get expenses => attachedDatabase.expenses;
  $ActivityLogsTable get activityLogs => attachedDatabase.activityLogs;
  $CustomersTable get customers => attachedDatabase.customers;
  $OrdersTable get orders => attachedDatabase.orders;
  $CrateSizeGroupsTable get crateSizeGroups => attachedDatabase.crateSizeGroups;
  $SuppliersTable get suppliers => attachedDatabase.suppliers;
  $ShipmentsTable get shipments => attachedDatabase.shipments;
  $CustomerWalletsTable get customerWallets => attachedDatabase.customerWallets;
  $WalletTransactionsTable get walletTransactions =>
      attachedDatabase.walletTransactions;
  $DriversTable get drivers => attachedDatabase.drivers;
  $DeliveryReceiptsTable get deliveryReceipts =>
      attachedDatabase.deliveryReceipts;
  $PaymentTransactionsTable get paymentTransactions =>
      attachedDatabase.paymentTransactions;
  ExpensesDaoManager get managers => ExpensesDaoManager(this);
}

class ExpensesDaoManager {
  final _$ExpensesDaoMixin _db;
  ExpensesDaoManager(this._db);
  $$BusinessesTableTableManager get businesses =>
      $$BusinessesTableTableManager(_db.attachedDatabase, _db.businesses);
  $$ExpenseCategoriesTableTableManager get expenseCategories =>
      $$ExpenseCategoriesTableTableManager(
        _db.attachedDatabase,
        _db.expenseCategories,
      );
  $$StoresTableTableManager get stores =>
      $$StoresTableTableManager(_db.attachedDatabase, _db.stores);
  $$UsersTableTableManager get users =>
      $$UsersTableTableManager(_db.attachedDatabase, _db.users);
  $$ExpensesTableTableManager get expenses =>
      $$ExpensesTableTableManager(_db.attachedDatabase, _db.expenses);
  $$ActivityLogsTableTableManager get activityLogs =>
      $$ActivityLogsTableTableManager(_db.attachedDatabase, _db.activityLogs);
  $$CustomersTableTableManager get customers =>
      $$CustomersTableTableManager(_db.attachedDatabase, _db.customers);
  $$OrdersTableTableManager get orders =>
      $$OrdersTableTableManager(_db.attachedDatabase, _db.orders);
  $$CrateSizeGroupsTableTableManager get crateSizeGroups =>
      $$CrateSizeGroupsTableTableManager(
        _db.attachedDatabase,
        _db.crateSizeGroups,
      );
  $$SuppliersTableTableManager get suppliers =>
      $$SuppliersTableTableManager(_db.attachedDatabase, _db.suppliers);
  $$ShipmentsTableTableManager get shipments =>
      $$ShipmentsTableTableManager(_db.attachedDatabase, _db.shipments);
  $$CustomerWalletsTableTableManager get customerWallets =>
      $$CustomerWalletsTableTableManager(
        _db.attachedDatabase,
        _db.customerWallets,
      );
  $$WalletTransactionsTableTableManager get walletTransactions =>
      $$WalletTransactionsTableTableManager(
        _db.attachedDatabase,
        _db.walletTransactions,
      );
  $$DriversTableTableManager get drivers =>
      $$DriversTableTableManager(_db.attachedDatabase, _db.drivers);
  $$DeliveryReceiptsTableTableManager get deliveryReceipts =>
      $$DeliveryReceiptsTableTableManager(
        _db.attachedDatabase,
        _db.deliveryReceipts,
      );
  $$PaymentTransactionsTableTableManager get paymentTransactions =>
      $$PaymentTransactionsTableTableManager(
        _db.attachedDatabase,
        _db.paymentTransactions,
      );
}

mixin _$ExpenseBudgetsDaoMixin on DatabaseAccessor<AppDatabase> {
  $BusinessesTable get businesses => attachedDatabase.businesses;
  $StoresTable get stores => attachedDatabase.stores;
  $ExpenseBudgetsTable get expenseBudgets => attachedDatabase.expenseBudgets;
  ExpenseBudgetsDaoManager get managers => ExpenseBudgetsDaoManager(this);
}

class ExpenseBudgetsDaoManager {
  final _$ExpenseBudgetsDaoMixin _db;
  ExpenseBudgetsDaoManager(this._db);
  $$BusinessesTableTableManager get businesses =>
      $$BusinessesTableTableManager(_db.attachedDatabase, _db.businesses);
  $$StoresTableTableManager get stores =>
      $$StoresTableTableManager(_db.attachedDatabase, _db.stores);
  $$ExpenseBudgetsTableTableManager get expenseBudgets =>
      $$ExpenseBudgetsTableTableManager(
        _db.attachedDatabase,
        _db.expenseBudgets,
      );
}

mixin _$SyncDaoMixin on DatabaseAccessor<AppDatabase> {
  $BusinessesTable get businesses => attachedDatabase.businesses;
  $SyncQueueTable get syncQueue => attachedDatabase.syncQueue;
  $SyncQueueOrphansTable get syncQueueOrphans =>
      attachedDatabase.syncQueueOrphans;
  SyncDaoManager get managers => SyncDaoManager(this);
}

class SyncDaoManager {
  final _$SyncDaoMixin _db;
  SyncDaoManager(this._db);
  $$BusinessesTableTableManager get businesses =>
      $$BusinessesTableTableManager(_db.attachedDatabase, _db.businesses);
  $$SyncQueueTableTableManager get syncQueue =>
      $$SyncQueueTableTableManager(_db.attachedDatabase, _db.syncQueue);
  $$SyncQueueOrphansTableTableManager get syncQueueOrphans =>
      $$SyncQueueOrphansTableTableManager(
        _db.attachedDatabase,
        _db.syncQueueOrphans,
      );
}

mixin _$ErrorLogDaoMixin on DatabaseAccessor<AppDatabase> {
  $BusinessesTable get businesses => attachedDatabase.businesses;
  $StoresTable get stores => attachedDatabase.stores;
  $UsersTable get users => attachedDatabase.users;
  $ErrorLogsTable get errorLogs => attachedDatabase.errorLogs;
  ErrorLogDaoManager get managers => ErrorLogDaoManager(this);
}

class ErrorLogDaoManager {
  final _$ErrorLogDaoMixin _db;
  ErrorLogDaoManager(this._db);
  $$BusinessesTableTableManager get businesses =>
      $$BusinessesTableTableManager(_db.attachedDatabase, _db.businesses);
  $$StoresTableTableManager get stores =>
      $$StoresTableTableManager(_db.attachedDatabase, _db.stores);
  $$UsersTableTableManager get users =>
      $$UsersTableTableManager(_db.attachedDatabase, _db.users);
  $$ErrorLogsTableTableManager get errorLogs =>
      $$ErrorLogsTableTableManager(_db.attachedDatabase, _db.errorLogs);
}

mixin _$ActivityLogDaoMixin on DatabaseAccessor<AppDatabase> {
  $BusinessesTable get businesses => attachedDatabase.businesses;
  $StoresTable get stores => attachedDatabase.stores;
  $UsersTable get users => attachedDatabase.users;
  $ActivityLogsTable get activityLogs => attachedDatabase.activityLogs;
  ActivityLogDaoManager get managers => ActivityLogDaoManager(this);
}

class ActivityLogDaoManager {
  final _$ActivityLogDaoMixin _db;
  ActivityLogDaoManager(this._db);
  $$BusinessesTableTableManager get businesses =>
      $$BusinessesTableTableManager(_db.attachedDatabase, _db.businesses);
  $$StoresTableTableManager get stores =>
      $$StoresTableTableManager(_db.attachedDatabase, _db.stores);
  $$UsersTableTableManager get users =>
      $$UsersTableTableManager(_db.attachedDatabase, _db.users);
  $$ActivityLogsTableTableManager get activityLogs =>
      $$ActivityLogsTableTableManager(_db.attachedDatabase, _db.activityLogs);
}

mixin _$NotificationsDaoMixin on DatabaseAccessor<AppDatabase> {
  $BusinessesTable get businesses => attachedDatabase.businesses;
  $StoresTable get stores => attachedDatabase.stores;
  $UsersTable get users => attachedDatabase.users;
  $NotificationsTable get notifications => attachedDatabase.notifications;
  NotificationsDaoManager get managers => NotificationsDaoManager(this);
}

class NotificationsDaoManager {
  final _$NotificationsDaoMixin _db;
  NotificationsDaoManager(this._db);
  $$BusinessesTableTableManager get businesses =>
      $$BusinessesTableTableManager(_db.attachedDatabase, _db.businesses);
  $$StoresTableTableManager get stores =>
      $$StoresTableTableManager(_db.attachedDatabase, _db.stores);
  $$UsersTableTableManager get users =>
      $$UsersTableTableManager(_db.attachedDatabase, _db.users);
  $$NotificationsTableTableManager get notifications =>
      $$NotificationsTableTableManager(_db.attachedDatabase, _db.notifications);
}

mixin _$StoresDaoMixin on DatabaseAccessor<AppDatabase> {
  $BusinessesTable get businesses => attachedDatabase.businesses;
  $StoresTable get stores => attachedDatabase.stores;
  $UsersTable get users => attachedDatabase.users;
  StoresDaoManager get managers => StoresDaoManager(this);
}

class StoresDaoManager {
  final _$StoresDaoMixin _db;
  StoresDaoManager(this._db);
  $$BusinessesTableTableManager get businesses =>
      $$BusinessesTableTableManager(_db.attachedDatabase, _db.businesses);
  $$StoresTableTableManager get stores =>
      $$StoresTableTableManager(_db.attachedDatabase, _db.stores);
  $$UsersTableTableManager get users =>
      $$UsersTableTableManager(_db.attachedDatabase, _db.users);
}

mixin _$SessionsDaoMixin on DatabaseAccessor<AppDatabase> {
  $BusinessesTable get businesses => attachedDatabase.businesses;
  $StoresTable get stores => attachedDatabase.stores;
  $UsersTable get users => attachedDatabase.users;
  $SessionsTable get sessions => attachedDatabase.sessions;
  SessionsDaoManager get managers => SessionsDaoManager(this);
}

class SessionsDaoManager {
  final _$SessionsDaoMixin _db;
  SessionsDaoManager(this._db);
  $$BusinessesTableTableManager get businesses =>
      $$BusinessesTableTableManager(_db.attachedDatabase, _db.businesses);
  $$StoresTableTableManager get stores =>
      $$StoresTableTableManager(_db.attachedDatabase, _db.stores);
  $$UsersTableTableManager get users =>
      $$UsersTableTableManager(_db.attachedDatabase, _db.users);
  $$SessionsTableTableManager get sessions =>
      $$SessionsTableTableManager(_db.attachedDatabase, _db.sessions);
}

mixin _$UserStoresDaoMixin on DatabaseAccessor<AppDatabase> {
  $BusinessesTable get businesses => attachedDatabase.businesses;
  $StoresTable get stores => attachedDatabase.stores;
  $UsersTable get users => attachedDatabase.users;
  $UserStoresTable get userStores => attachedDatabase.userStores;
  UserStoresDaoManager get managers => UserStoresDaoManager(this);
}

class UserStoresDaoManager {
  final _$UserStoresDaoMixin _db;
  UserStoresDaoManager(this._db);
  $$BusinessesTableTableManager get businesses =>
      $$BusinessesTableTableManager(_db.attachedDatabase, _db.businesses);
  $$StoresTableTableManager get stores =>
      $$StoresTableTableManager(_db.attachedDatabase, _db.stores);
  $$UsersTableTableManager get users =>
      $$UsersTableTableManager(_db.attachedDatabase, _db.users);
  $$UserStoresTableTableManager get userStores =>
      $$UserStoresTableTableManager(_db.attachedDatabase, _db.userStores);
}

mixin _$PermissionsDaoMixin on DatabaseAccessor<AppDatabase> {
  $PermissionsTable get permissions => attachedDatabase.permissions;
  PermissionsDaoManager get managers => PermissionsDaoManager(this);
}

class PermissionsDaoManager {
  final _$PermissionsDaoMixin _db;
  PermissionsDaoManager(this._db);
  $$PermissionsTableTableManager get permissions =>
      $$PermissionsTableTableManager(_db.attachedDatabase, _db.permissions);
}

mixin _$RolesDaoMixin on DatabaseAccessor<AppDatabase> {
  $BusinessesTable get businesses => attachedDatabase.businesses;
  $RolesTable get roles => attachedDatabase.roles;
  RolesDaoManager get managers => RolesDaoManager(this);
}

class RolesDaoManager {
  final _$RolesDaoMixin _db;
  RolesDaoManager(this._db);
  $$BusinessesTableTableManager get businesses =>
      $$BusinessesTableTableManager(_db.attachedDatabase, _db.businesses);
  $$RolesTableTableManager get roles =>
      $$RolesTableTableManager(_db.attachedDatabase, _db.roles);
}

mixin _$RolePermissionsDaoMixin on DatabaseAccessor<AppDatabase> {
  $BusinessesTable get businesses => attachedDatabase.businesses;
  $RolesTable get roles => attachedDatabase.roles;
  $RolePermissionsTable get rolePermissions => attachedDatabase.rolePermissions;
  RolePermissionsDaoManager get managers => RolePermissionsDaoManager(this);
}

class RolePermissionsDaoManager {
  final _$RolePermissionsDaoMixin _db;
  RolePermissionsDaoManager(this._db);
  $$BusinessesTableTableManager get businesses =>
      $$BusinessesTableTableManager(_db.attachedDatabase, _db.businesses);
  $$RolesTableTableManager get roles =>
      $$RolesTableTableManager(_db.attachedDatabase, _db.roles);
  $$RolePermissionsTableTableManager get rolePermissions =>
      $$RolePermissionsTableTableManager(
        _db.attachedDatabase,
        _db.rolePermissions,
      );
}

mixin _$UserPermissionOverridesDaoMixin on DatabaseAccessor<AppDatabase> {
  $BusinessesTable get businesses => attachedDatabase.businesses;
  $StoresTable get stores => attachedDatabase.stores;
  $UsersTable get users => attachedDatabase.users;
  $UserPermissionOverridesTable get userPermissionOverrides =>
      attachedDatabase.userPermissionOverrides;
  UserPermissionOverridesDaoManager get managers =>
      UserPermissionOverridesDaoManager(this);
}

class UserPermissionOverridesDaoManager {
  final _$UserPermissionOverridesDaoMixin _db;
  UserPermissionOverridesDaoManager(this._db);
  $$BusinessesTableTableManager get businesses =>
      $$BusinessesTableTableManager(_db.attachedDatabase, _db.businesses);
  $$StoresTableTableManager get stores =>
      $$StoresTableTableManager(_db.attachedDatabase, _db.stores);
  $$UsersTableTableManager get users =>
      $$UsersTableTableManager(_db.attachedDatabase, _db.users);
  $$UserPermissionOverridesTableTableManager get userPermissionOverrides =>
      $$UserPermissionOverridesTableTableManager(
        _db.attachedDatabase,
        _db.userPermissionOverrides,
      );
}

mixin _$StoreRolePermissionsDaoMixin on DatabaseAccessor<AppDatabase> {
  $BusinessesTable get businesses => attachedDatabase.businesses;
  $StoresTable get stores => attachedDatabase.stores;
  $RolesTable get roles => attachedDatabase.roles;
  $StoreRolePermissionsTable get storeRolePermissions =>
      attachedDatabase.storeRolePermissions;
  StoreRolePermissionsDaoManager get managers =>
      StoreRolePermissionsDaoManager(this);
}

class StoreRolePermissionsDaoManager {
  final _$StoreRolePermissionsDaoMixin _db;
  StoreRolePermissionsDaoManager(this._db);
  $$BusinessesTableTableManager get businesses =>
      $$BusinessesTableTableManager(_db.attachedDatabase, _db.businesses);
  $$StoresTableTableManager get stores =>
      $$StoresTableTableManager(_db.attachedDatabase, _db.stores);
  $$RolesTableTableManager get roles =>
      $$RolesTableTableManager(_db.attachedDatabase, _db.roles);
  $$StoreRolePermissionsTableTableManager get storeRolePermissions =>
      $$StoreRolePermissionsTableTableManager(
        _db.attachedDatabase,
        _db.storeRolePermissions,
      );
}

mixin _$RoleSettingsDaoMixin on DatabaseAccessor<AppDatabase> {
  $BusinessesTable get businesses => attachedDatabase.businesses;
  $RolesTable get roles => attachedDatabase.roles;
  $RoleSettingsTable get roleSettings => attachedDatabase.roleSettings;
  RoleSettingsDaoManager get managers => RoleSettingsDaoManager(this);
}

class RoleSettingsDaoManager {
  final _$RoleSettingsDaoMixin _db;
  RoleSettingsDaoManager(this._db);
  $$BusinessesTableTableManager get businesses =>
      $$BusinessesTableTableManager(_db.attachedDatabase, _db.businesses);
  $$RolesTableTableManager get roles =>
      $$RolesTableTableManager(_db.attachedDatabase, _db.roles);
  $$RoleSettingsTableTableManager get roleSettings =>
      $$RoleSettingsTableTableManager(_db.attachedDatabase, _db.roleSettings);
}

mixin _$SettingsDaoMixin on DatabaseAccessor<AppDatabase> {
  $BusinessesTable get businesses => attachedDatabase.businesses;
  $SettingsTable get settings => attachedDatabase.settings;
  SettingsDaoManager get managers => SettingsDaoManager(this);
}

class SettingsDaoManager {
  final _$SettingsDaoMixin _db;
  SettingsDaoManager(this._db);
  $$BusinessesTableTableManager get businesses =>
      $$BusinessesTableTableManager(_db.attachedDatabase, _db.businesses);
  $$SettingsTableTableManager get settings =>
      $$SettingsTableTableManager(_db.attachedDatabase, _db.settings);
}

mixin _$BusinessesDaoMixin on DatabaseAccessor<AppDatabase> {
  $BusinessesTable get businesses => attachedDatabase.businesses;
  BusinessesDaoManager get managers => BusinessesDaoManager(this);
}

class BusinessesDaoManager {
  final _$BusinessesDaoMixin _db;
  BusinessesDaoManager(this._db);
  $$BusinessesTableTableManager get businesses =>
      $$BusinessesTableTableManager(_db.attachedDatabase, _db.businesses);
}

mixin _$SystemConfigDaoMixin on DatabaseAccessor<AppDatabase> {
  $SystemConfigTable get systemConfig => attachedDatabase.systemConfig;
  SystemConfigDaoManager get managers => SystemConfigDaoManager(this);
}

class SystemConfigDaoManager {
  final _$SystemConfigDaoMixin _db;
  SystemConfigDaoManager(this._db);
  $$SystemConfigTableTableManager get systemConfig =>
      $$SystemConfigTableTableManager(_db.attachedDatabase, _db.systemConfig);
}

mixin _$UserBusinessesDaoMixin on DatabaseAccessor<AppDatabase> {
  $BusinessesTable get businesses => attachedDatabase.businesses;
  $StoresTable get stores => attachedDatabase.stores;
  $UsersTable get users => attachedDatabase.users;
  $RolesTable get roles => attachedDatabase.roles;
  $UserBusinessesTable get userBusinesses => attachedDatabase.userBusinesses;
  UserBusinessesDaoManager get managers => UserBusinessesDaoManager(this);
}

class UserBusinessesDaoManager {
  final _$UserBusinessesDaoMixin _db;
  UserBusinessesDaoManager(this._db);
  $$BusinessesTableTableManager get businesses =>
      $$BusinessesTableTableManager(_db.attachedDatabase, _db.businesses);
  $$StoresTableTableManager get stores =>
      $$StoresTableTableManager(_db.attachedDatabase, _db.stores);
  $$UsersTableTableManager get users =>
      $$UsersTableTableManager(_db.attachedDatabase, _db.users);
  $$RolesTableTableManager get roles =>
      $$RolesTableTableManager(_db.attachedDatabase, _db.roles);
  $$UserBusinessesTableTableManager get userBusinesses =>
      $$UserBusinessesTableTableManager(
        _db.attachedDatabase,
        _db.userBusinesses,
      );
}

mixin _$InviteCodesDaoMixin on DatabaseAccessor<AppDatabase> {
  $BusinessesTable get businesses => attachedDatabase.businesses;
  $RolesTable get roles => attachedDatabase.roles;
  $StoresTable get stores => attachedDatabase.stores;
  $UsersTable get users => attachedDatabase.users;
  $InviteCodesTable get inviteCodes => attachedDatabase.inviteCodes;
  InviteCodesDaoManager get managers => InviteCodesDaoManager(this);
}

class InviteCodesDaoManager {
  final _$InviteCodesDaoMixin _db;
  InviteCodesDaoManager(this._db);
  $$BusinessesTableTableManager get businesses =>
      $$BusinessesTableTableManager(_db.attachedDatabase, _db.businesses);
  $$RolesTableTableManager get roles =>
      $$RolesTableTableManager(_db.attachedDatabase, _db.roles);
  $$StoresTableTableManager get stores =>
      $$StoresTableTableManager(_db.attachedDatabase, _db.stores);
  $$UsersTableTableManager get users =>
      $$UsersTableTableManager(_db.attachedDatabase, _db.users);
  $$InviteCodesTableTableManager get inviteCodes =>
      $$InviteCodesTableTableManager(_db.attachedDatabase, _db.inviteCodes);
}
