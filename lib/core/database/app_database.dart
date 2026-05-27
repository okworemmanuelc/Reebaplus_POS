import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:flutter/foundation.dart';
import 'package:reebaplus_pos/core/database/daos.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/core/diagnostics/schema_audit.dart';
export 'daos.dart';

part 'app_database.g.dart';

/// Sentinel stored in `users.pin` for rows that exist locally but have no PIN
/// configured on this device yet — e.g. staff seeded from a cloud sync who
/// haven't authenticated here, or the current auth user before they complete
/// PIN setup. Detected by the OTP / email-entry flow to route into
/// `CreatePinScreen` instead of the PIN-entry path.
///
/// Lives here (rather than on AuthService) so the sync layer can also write
/// it during restore without a circular `auth_service ↔ sync_service` import.
const String kSetupRequiredPin = '__SETUP_REQUIRED__';

// ---------------------------------------------------------------------------
// Tenant + lookup tables
// ---------------------------------------------------------------------------

@DataClassName('BusinessData')
class Businesses extends Table {
  TextColumn get id => text().clientDefault(() => UuidV7.generate())();
  TextColumn get name => text()();
  TextColumn get type => text().nullable()();
  TextColumn get phone => text().nullable()();
  TextColumn get email => text().nullable()();
  TextColumn get logoUrl => text().nullable()();
  TextColumn get timezone => text().withDefault(const Constant('UTC'))();
  // Mirrors public.businesses.onboarding_complete. Drives the startup
  // resume gate — a row with onboardingComplete = false means onboarding
  // was interrupted and the app should route back into it on next launch.
  BoolColumn get onboardingComplete =>
      boolean().withDefault(const Constant(false))();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get lastUpdatedAt =>
      dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('CrateGroupData')
class CrateGroups extends Table {
  TextColumn get id => text().clientDefault(() => UuidV7.generate())();
  TextColumn get businessId => text().references(Businesses, #id)();
  TextColumn get name => text()();
  IntColumn get size => integer()(); // 12, 20, 24
  IntColumn get emptyCrateStock => integer().withDefault(const Constant(0))();
  IntColumn get depositAmountKobo => integer().withDefault(const Constant(0))();
  BoolColumn get isDeleted => boolean().withDefault(const Constant(false))();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get lastUpdatedAt =>
      dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {id};

  @override
  List<String> get customConstraints => ['CHECK (size IN (12,20,24))'];
}

@DataClassName('ManufacturerData')
class Manufacturers extends Table {
  TextColumn get id => text().clientDefault(() => UuidV7.generate())();
  TextColumn get businessId => text().references(Businesses, #id)();
  TextColumn get name => text()();
  IntColumn get emptyCrateStock => integer().withDefault(const Constant(0))();
  IntColumn get depositAmountKobo => integer().withDefault(const Constant(0))();
  BoolColumn get isDeleted => boolean().withDefault(const Constant(false))();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get lastUpdatedAt =>
      dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('WarehouseData')
class Warehouses extends Table {
  TextColumn get id => text().clientDefault(() => UuidV7.generate())();
  TextColumn get businessId => text().references(Businesses, #id)();
  TextColumn get name => text()();
  TextColumn get location => text().nullable()();
  BoolColumn get isDeleted => boolean().withDefault(const Constant(false))();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get lastUpdatedAt =>
      dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('UserData')
class Users extends Table {
  TextColumn get id => text().clientDefault(() => UuidV7.generate())();
  TextColumn get businessId => text().references(Businesses, #id)();
  TextColumn get authUserId => text().nullable()();
  TextColumn get name => text()();
  TextColumn get email => text().nullable()();
  // pin / passwordHash / pinSalt / pinIterations are local-only auth fields;
  // not present in Supabase. Sync layer (PR 3) will exclude them from payloads.
  // TODO(PR 4g): drop unused passwordHash column or wire when password login lands.
  TextColumn get passwordHash => text().nullable()();
  TextColumn get pin => text()();
  TextColumn get pinHash => text().nullable()();
  TextColumn get pinSalt => text().nullable()();
  IntColumn get pinIterations => integer().nullable()();
  TextColumn get avatarColor => text().withDefault(const Constant('#3B82F6'))();
  BoolColumn get biometricEnabled =>
      boolean().withDefault(const Constant(false))();
  TextColumn get warehouseId => text().nullable().references(Warehouses, #id)();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get lastNotificationSentAt => dateTime().nullable()();
  DateTimeColumn get lastUpdatedAt =>
      dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {id};

  @override
  List<String> get customConstraints => [
    'UNIQUE (business_id, email)',
    'UNIQUE (auth_user_id)',
  ];
}

@DataClassName('CategoryData')
class Categories extends Table {
  TextColumn get id => text().clientDefault(() => UuidV7.generate())();
  TextColumn get businessId => text().references(Businesses, #id)();
  TextColumn get name => text()();
  TextColumn get description => text().nullable()();
  BoolColumn get isDeleted => boolean().withDefault(const Constant(false))();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get lastUpdatedAt =>
      dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('SupplierData')
class Suppliers extends Table {
  TextColumn get id => text().clientDefault(() => UuidV7.generate())();
  TextColumn get businessId => text().references(Businesses, #id)();
  TextColumn get name => text()();
  TextColumn get phone => text().nullable()();
  TextColumn get email => text().nullable()();
  TextColumn get address => text().nullable()();
  TextColumn get crateGroupId =>
      text().nullable().references(CrateGroups, #id)();
  BoolColumn get isDeleted => boolean().withDefault(const Constant(false))();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get lastUpdatedAt =>
      dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('ProductData')
class Products extends Table {
  TextColumn get id => text().clientDefault(() => UuidV7.generate())();
  TextColumn get businessId => text().references(Businesses, #id)();
  TextColumn get categoryId => text().nullable().references(Categories, #id)();
  TextColumn get crateGroupId =>
      text().nullable().references(CrateGroups, #id)();
  TextColumn get supplierId => text().nullable().references(Suppliers, #id)();
  TextColumn get manufacturerId =>
      text().nullable().references(Manufacturers, #id)();
  TextColumn get name => text()();
  TextColumn get subtitle => text().nullable()();
  TextColumn get sku => text().nullable()();
  TextColumn get size => text().nullable()();
  TextColumn get unit => text().withDefault(const Constant('Bottle'))();
  IntColumn get retailPriceKobo => integer().withDefault(const Constant(0))();
  IntColumn get bulkBreakerPriceKobo => integer().nullable()();
  IntColumn get distributorPriceKobo => integer().nullable()();
  IntColumn get sellingPriceKobo => integer().withDefault(const Constant(0))();
  IntColumn get buyingPriceKobo => integer().withDefault(const Constant(0))();
  IntColumn get iconCodePoint => integer().nullable()();
  TextColumn get colorHex => text().nullable()();
  BoolColumn get isAvailable => boolean().withDefault(const Constant(true))();
  BoolColumn get isDeleted => boolean().withDefault(const Constant(false))();
  IntColumn get lowStockThreshold => integer().withDefault(const Constant(5))();
  RealColumn get avgDailySales => real().withDefault(const Constant(0.0))();
  IntColumn get leadTimeDays => integer().withDefault(const Constant(0))();
  IntColumn get safetyStockQty => integer().withDefault(const Constant(0))();
  IntColumn get monthlyTargetUnits =>
      integer().withDefault(const Constant(0))();
  IntColumn get emptyCrateValueKobo =>
      integer().withDefault(const Constant(0))();
  BoolColumn get trackEmpties => boolean().withDefault(const Constant(false))();
  TextColumn get imagePath => text().nullable()();
  IntColumn get version => integer().withDefault(const Constant(1))();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get lastUpdatedAt =>
      dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {id};

  @override
  List<String> get customConstraints => [
    "CHECK (size IS NULL OR size IN ('big','medium','small'))",
    "CHECK (unit IN ('Bottle','Crate','Pack','Carton','Piece','Bag','Other'))",
  ];
}

@DataClassName('PriceListData')
class PriceLists extends Table {
  TextColumn get id => text().clientDefault(() => UuidV7.generate())();
  TextColumn get businessId => text().references(Businesses, #id)();
  TextColumn get name => text()();
  TextColumn get productId => text().references(Products, #id)();
  IntColumn get priceKobo => integer()();
  DateTimeColumn get effectiveFrom =>
      dateTime().withDefault(currentDateAndTime)();
  BoolColumn get isDeleted => boolean().withDefault(const Constant(false))();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get lastUpdatedAt =>
      dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('CustomerData')
class Customers extends Table {
  TextColumn get id => text().clientDefault(() => UuidV7.generate())();
  TextColumn get businessId => text().references(Businesses, #id)();
  TextColumn get warehouseId => text().nullable().references(Warehouses, #id)();
  TextColumn get name => text()();
  TextColumn get phone => text().nullable()();
  TextColumn get email => text().nullable()();
  TextColumn get address => text().nullable()();
  TextColumn get googleMapsLocation => text().nullable()();
  TextColumn get customerGroup =>
      text().withDefault(const Constant('retailer'))();
  IntColumn get walletLimitKobo => integer().withDefault(const Constant(0))();
  BoolColumn get isDeleted => boolean().withDefault(const Constant(false))();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get lastUpdatedAt =>
      dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {id};

  @override
  List<String> get customConstraints => [
    "CHECK (customer_group IN ('retailer','wholesaler','distributor','walk_in'))",
  ];
}

@DataClassName('CustomerWalletData')
class CustomerWallets extends Table {
  TextColumn get id => text().clientDefault(() => UuidV7.generate())();
  TextColumn get businessId => text().references(Businesses, #id)();
  TextColumn get customerId => text().references(Customers, #id)();
  TextColumn get currency => text().withDefault(const Constant('NGN'))();
  BoolColumn get isActive => boolean().withDefault(const Constant(true))();
  BoolColumn get isDeleted => boolean().withDefault(const Constant(false))();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get lastUpdatedAt =>
      dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {id};

  @override
  List<String> get customConstraints => ['UNIQUE (business_id, customer_id)'];
}

// Append-only ledger.
@DataClassName('WalletTransactionData')
class WalletTransactions extends Table {
  TextColumn get id => text().clientDefault(() => UuidV7.generate())();
  TextColumn get businessId => text().references(Businesses, #id)();
  TextColumn get walletId => text().references(CustomerWallets, #id)();
  TextColumn get customerId => text().references(Customers, #id)();
  TextColumn get type => text()(); // credit | debit
  IntColumn get amountKobo => integer()();
  IntColumn get signedAmountKobo => integer()();
  TextColumn get referenceType => text()();
  TextColumn get orderId => text().nullable().references(Orders, #id)();
  TextColumn get performedBy => text().nullable().references(Users, #id)();
  BoolColumn get customerVerified =>
      boolean().withDefault(const Constant(false))();
  DateTimeColumn get voidedAt => dateTime().nullable()();
  TextColumn get voidedBy => text().nullable().references(Users, #id)();
  TextColumn get voidReason => text().nullable()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get lastUpdatedAt =>
      dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {id};

  @override
  List<String> get customConstraints => [
    "CHECK (type IN ('credit','debit'))",
    'CHECK (amount_kobo >= 0)',
    "CHECK (reference_type IN ('topup_cash','topup_transfer','order_payment','refund','reward','fee','adjustment','void'))",
    "CHECK ((type = 'credit' AND signed_amount_kobo >= 0) OR "
        "(type = 'debit' AND signed_amount_kobo <= 0))",
  ];
}

class CustomerCrateBalances extends Table {
  TextColumn get id => text().clientDefault(() => UuidV7.generate())();
  TextColumn get businessId => text().references(Businesses, #id)();
  TextColumn get customerId => text().references(Customers, #id)();
  TextColumn get crateGroupId => text().references(CrateGroups, #id)();
  IntColumn get balance => integer().withDefault(const Constant(0))();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get lastUpdatedAt =>
      dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {id};

  @override
  List<String> get customConstraints => [
    'UNIQUE (business_id, customer_id, crate_group_id)',
  ];
}

class ManufacturerCrateBalances extends Table {
  TextColumn get id => text().clientDefault(() => UuidV7.generate())();
  TextColumn get businessId => text().references(Businesses, #id)();
  TextColumn get manufacturerId => text().references(Manufacturers, #id)();
  TextColumn get crateGroupId => text().references(CrateGroups, #id)();
  IntColumn get balance => integer().withDefault(const Constant(0))();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get lastUpdatedAt =>
      dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {id};

  @override
  List<String> get customConstraints => [
    'UNIQUE (business_id, manufacturer_id, crate_group_id)',
  ];
}

// Append-only ledger of crate movements.
class CrateLedger extends Table {
  TextColumn get id => text().clientDefault(() => UuidV7.generate())();
  TextColumn get businessId => text().references(Businesses, #id)();
  TextColumn get customerId => text().nullable().references(Customers, #id)();
  TextColumn get manufacturerId =>
      text().nullable().references(Manufacturers, #id)();
  TextColumn get crateGroupId => text().references(CrateGroups, #id)();
  IntColumn get quantityDelta => integer()();
  TextColumn get movementType => text().withLength(min: 1, max: 32)();
  TextColumn get referenceOrderId =>
      text().nullable().references(Orders, #id)();
  TextColumn get referenceReturnId =>
      text().nullable().references(PendingCrateReturns, #id)();
  TextColumn get performedBy => text().nullable().references(Users, #id)();
  DateTimeColumn get voidedAt => dateTime().nullable()();
  TextColumn get voidedBy => text().nullable().references(Users, #id)();
  TextColumn get voidReason => text().nullable()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get lastUpdatedAt =>
      dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {id};

  @override
  List<String> get customConstraints => [
    "CHECK (movement_type IN ('issued','returned','damaged','adjusted','transferred_in','transferred_out'))",
    '''CHECK (
          (CASE WHEN customer_id IS NOT NULL THEN 1 ELSE 0 END) +
          (CASE WHEN manufacturer_id IS NOT NULL THEN 1 ELSE 0 END) = 1
        )''',
  ];
}

@DataClassName('InventoryData')
class Inventory extends Table {
  TextColumn get id => text().clientDefault(() => UuidV7.generate())();
  TextColumn get businessId => text().references(Businesses, #id)();
  TextColumn get productId => text().references(Products, #id)();
  TextColumn get warehouseId => text().references(Warehouses, #id)();
  IntColumn get quantity => integer().withDefault(const Constant(0))();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get lastUpdatedAt =>
      dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {id};

  @override
  List<String> get customConstraints => [
    'UNIQUE (business_id, product_id, warehouse_id)',
  ];
}

// `Crates` table dropped in schemaVersion 5 (phase D §4.5). It was never
// written by the live code path — `_syncedTenantTables` listed it but
// no DAO touched it; the cloud counterpart will be dropped by the
// `0016_drop_crates_and_lock_caches.sql` migration. Existing rows on
// upgraded devices are dropped by the `from < 5` migration step.

@DataClassName('StockTransferData')
class StockTransfers extends Table {
  TextColumn get id => text().clientDefault(() => UuidV7.generate())();
  TextColumn get businessId => text().references(Businesses, #id)();
  TextColumn get fromLocationId => text().references(Warehouses, #id)();
  TextColumn get toLocationId => text().references(Warehouses, #id)();
  TextColumn get productId => text().references(Products, #id)();
  IntColumn get quantity => integer()();
  TextColumn get status => text().withDefault(const Constant('pending'))();
  TextColumn get initiatedBy => text().references(Users, #id)();
  TextColumn get receivedBy => text().nullable().references(Users, #id)();
  DateTimeColumn get initiatedAt =>
      dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get receivedAt => dateTime().nullable()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get lastUpdatedAt =>
      dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {id};

  @override
  List<String> get customConstraints => [
    "CHECK (status IN ('pending','in_transit','received','cancelled'))",
  ];
}

@DataClassName('StockAdjustmentData')
class StockAdjustments extends Table {
  TextColumn get id => text().clientDefault(() => UuidV7.generate())();
  TextColumn get businessId => text().references(Businesses, #id)();
  TextColumn get productId => text().references(Products, #id)();
  TextColumn get warehouseId => text().references(Warehouses, #id)();
  IntColumn get quantityDiff => integer()();
  TextColumn get reason => text()();
  TextColumn get performedBy => text().nullable().references(Users, #id)();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get lastUpdatedAt =>
      dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {id};
}

// Append-only ledger.
@DataClassName('StockTransactionData')
class StockTransactions extends Table {
  TextColumn get id => text().clientDefault(() => UuidV7.generate())();
  TextColumn get businessId => text().references(Businesses, #id)();
  TextColumn get productId => text().references(Products, #id)();
  TextColumn get locationId => text().references(Warehouses, #id)();
  IntColumn get quantityDelta => integer()();
  TextColumn get movementType => text()();
  TextColumn get orderId => text().nullable().references(Orders, #id)();
  TextColumn get transferId =>
      text().nullable().references(StockTransfers, #id)();
  TextColumn get adjustmentId =>
      text().nullable().references(StockAdjustments, #id)();
  TextColumn get purchaseId => text().nullable().references(Purchases, #id)();
  TextColumn get performedBy => text().nullable().references(Users, #id)();
  DateTimeColumn get voidedAt => dateTime().nullable()();
  TextColumn get voidedBy => text().nullable().references(Users, #id)();
  TextColumn get voidReason => text().nullable()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get lastUpdatedAt =>
      dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {id};

  @override
  List<String> get customConstraints => [
    "CHECK (movement_type IN ('sale','return','damage','transfer_out','transfer_in','purchase_received','adjustment'))",
    '''CHECK (
          (CASE WHEN order_id IS NOT NULL THEN 1 ELSE 0 END) +
          (CASE WHEN transfer_id IS NOT NULL THEN 1 ELSE 0 END) +
          (CASE WHEN adjustment_id IS NOT NULL THEN 1 ELSE 0 END) +
          (CASE WHEN purchase_id IS NOT NULL THEN 1 ELSE 0 END) = 1
        )''',
  ];
}

@DataClassName('OrderData')
class Orders extends Table {
  TextColumn get id => text().clientDefault(() => UuidV7.generate())();
  TextColumn get businessId => text().references(Businesses, #id)();
  TextColumn get orderNumber => text()();
  TextColumn get customerId => text().nullable().references(Customers, #id)();
  IntColumn get totalAmountKobo => integer()();
  IntColumn get discountKobo => integer().withDefault(const Constant(0))();
  IntColumn get netAmountKobo => integer()();
  IntColumn get amountPaidKobo => integer().withDefault(const Constant(0))();
  TextColumn get paymentType => text()();
  TextColumn get status => text()();
  TextColumn get riderName =>
      text().withDefault(const Constant('Pick-up Order'))();
  TextColumn get cancellationReason => text().nullable()();
  TextColumn get barcode => text().nullable()();
  TextColumn get staffId => text().nullable().references(Users, #id)();
  TextColumn get warehouseId => text().nullable().references(Warehouses, #id)();
  IntColumn get crateDepositPaidKobo =>
      integer().withDefault(const Constant(0))();
  DateTimeColumn get completedAt => dateTime().nullable()();
  DateTimeColumn get cancelledAt => dateTime().nullable()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get lastUpdatedAt =>
      dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {id};

  @override
  List<String> get customConstraints => [
    "CHECK (payment_type IN ('cash','transfer','card','wallet','credit','mixed'))",
    "CHECK (status IN ('pending','completed','cancelled','refunded'))",
    'UNIQUE (business_id, order_number)',
  ];
}

@DataClassName('OrderItemData')
class OrderItems extends Table {
  TextColumn get id => text().clientDefault(() => UuidV7.generate())();
  TextColumn get businessId => text().references(Businesses, #id)();
  TextColumn get orderId => text().references(Orders, #id)();
  TextColumn get productId => text().references(Products, #id)();
  TextColumn get warehouseId => text().references(Warehouses, #id)();
  IntColumn get quantity => integer()();
  IntColumn get unitPriceKobo => integer()();
  IntColumn get buyingPriceKobo => integer().withDefault(const Constant(0))();
  IntColumn get totalKobo => integer()();
  TextColumn get priceSnapshot => text().nullable()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get lastUpdatedAt =>
      dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {id};

  @override
  List<String> get customConstraints => [
    'CHECK (quantity > 0)',
    "CHECK (price_snapshot IS NULL OR json_valid(price_snapshot))",
  ];
}

@DataClassName('DeliveryData')
class Purchases extends Table {
  TextColumn get id => text().clientDefault(() => UuidV7.generate())();
  TextColumn get businessId => text().references(Businesses, #id)();
  TextColumn get supplierId => text().references(Suppliers, #id)();
  IntColumn get totalAmountKobo => integer()();
  TextColumn get status => text()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get lastUpdatedAt =>
      dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {id};

  @override
  List<String> get customConstraints => [
    "CHECK (status IN ('pending','received','cancelled'))",
  ];
}

@DataClassName('PurchaseItemData')
class PurchaseItems extends Table {
  TextColumn get id => text().clientDefault(() => UuidV7.generate())();
  TextColumn get businessId => text().references(Businesses, #id)();
  TextColumn get purchaseId => text().references(Purchases, #id)();
  TextColumn get productId => text().references(Products, #id)();
  IntColumn get quantity => integer()();
  IntColumn get unitPriceKobo => integer()();
  IntColumn get totalKobo => integer()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get lastUpdatedAt =>
      dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {id};

  @override
  List<String> get customConstraints => ['CHECK (quantity > 0)'];
}

@DataClassName('ExpenseCategoryData')
class ExpenseCategories extends Table {
  TextColumn get id => text().clientDefault(() => UuidV7.generate())();
  TextColumn get businessId => text().references(Businesses, #id)();
  TextColumn get name => text()();
  BoolColumn get isDeleted => boolean().withDefault(const Constant(false))();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get lastUpdatedAt =>
      dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {id};

  @override
  List<String> get customConstraints => ['UNIQUE (business_id, name)'];
}

@DataClassName('ExpenseData')
class Expenses extends Table {
  TextColumn get id => text().clientDefault(() => UuidV7.generate())();
  TextColumn get businessId => text().references(Businesses, #id)();
  TextColumn get categoryId =>
      text().nullable().references(ExpenseCategories, #id)();
  IntColumn get amountKobo => integer()();
  TextColumn get description => text()();
  TextColumn get paymentMethod => text().nullable()();
  TextColumn get recordedBy => text().nullable().references(Users, #id)();
  TextColumn get reference => text().nullable()();
  TextColumn get warehouseId => text().nullable().references(Warehouses, #id)();
  BoolColumn get isDeleted => boolean().withDefault(const Constant(false))();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get lastUpdatedAt =>
      dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {id};

  @override
  List<String> get customConstraints => [
    'CHECK (amount_kobo > 0)',
    "CHECK (payment_method IS NULL OR payment_method IN ('cash','transfer','card','pos','other'))",
  ];
}

@DataClassName('DriverData')
class Drivers extends Table {
  TextColumn get id => text().clientDefault(() => UuidV7.generate())();
  TextColumn get businessId => text().references(Businesses, #id)();
  TextColumn get name => text()();
  TextColumn get licenseNumber => text().nullable()();
  TextColumn get phone => text().nullable()();
  BoolColumn get isDeleted => boolean().withDefault(const Constant(false))();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get lastUpdatedAt =>
      dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('DeliveryReceiptData')
class DeliveryReceipts extends Table {
  TextColumn get id => text().clientDefault(() => UuidV7.generate())();
  TextColumn get businessId => text().references(Businesses, #id)();
  TextColumn get orderId => text().nullable().references(Orders, #id)();
  TextColumn get driverId => text().references(Drivers, #id)();
  TextColumn get status => text()();
  DateTimeColumn get deliveredAt => dateTime().nullable()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get lastUpdatedAt =>
      dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {id};

  @override
  List<String> get customConstraints => [
    "CHECK (status IN ('pending','dispatched','delivered','failed','returned'))",
  ];
}

@DataClassName('SavedCartData')
class SavedCarts extends Table {
  TextColumn get id => text().clientDefault(() => UuidV7.generate())();
  TextColumn get businessId => text().references(Businesses, #id)();
  TextColumn get name => text()();
  TextColumn get customerId => text().nullable().references(Customers, #id)();
  TextColumn get cartData => text()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get lastUpdatedAt =>
      dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {id};

  @override
  List<String> get customConstraints => ['CHECK (json_valid(cart_data))'];
}

@DataClassName('PendingCrateReturnData')
class PendingCrateReturns extends Table {
  TextColumn get id => text().clientDefault(() => UuidV7.generate())();
  TextColumn get businessId => text().references(Businesses, #id)();
  TextColumn get orderId => text().nullable().references(Orders, #id)();
  TextColumn get customerId => text().references(Customers, #id)();
  TextColumn get crateGroupId => text().references(CrateGroups, #id)();
  IntColumn get quantity => integer()();
  TextColumn get submittedBy => text().references(Users, #id)();
  DateTimeColumn get submittedAt =>
      dateTime().withDefault(currentDateAndTime)();
  TextColumn get approvedBy => text().nullable().references(Users, #id)();
  DateTimeColumn get approvedAt => dateTime().nullable()();
  TextColumn get status => text().withDefault(const Constant('pending'))();
  TextColumn get rejectionReason => text().nullable()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get lastUpdatedAt =>
      dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {id};

  @override
  List<String> get customConstraints => [
    'CHECK (quantity > 0)',
    "CHECK (status IN ('pending','approved','rejected'))",
  ];
}

// Append-only ledger.
@DataClassName('PaymentTransactionData')
class PaymentTransactions extends Table {
  TextColumn get id => text().clientDefault(() => UuidV7.generate())();
  TextColumn get businessId => text().references(Businesses, #id)();
  IntColumn get amountKobo => integer()();
  TextColumn get method => text()();
  TextColumn get type => text()();
  TextColumn get orderId => text().nullable().references(Orders, #id)();
  TextColumn get purchaseId => text().nullable().references(Purchases, #id)();
  TextColumn get expenseId => text().nullable().references(Expenses, #id)();
  TextColumn get walletTxnId =>
      text().nullable().references(WalletTransactions, #id)();
  TextColumn get deliveryId =>
      text().nullable().references(DeliveryReceipts, #id)();
  TextColumn get performedBy => text().nullable().references(Users, #id)();
  DateTimeColumn get voidedAt => dateTime().nullable()();
  TextColumn get voidedBy => text().nullable().references(Users, #id)();
  TextColumn get voidReason => text().nullable()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get lastUpdatedAt =>
      dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {id};

  @override
  List<String> get customConstraints => [
    "CHECK (method IN ('cash','transfer','card','wallet','pos','other'))",
    "CHECK (type IN ('sale','purchase','expense','refund','wallet_topup'))",
    '''CHECK (
          (CASE WHEN order_id IS NOT NULL THEN 1 ELSE 0 END) +
          (CASE WHEN purchase_id IS NOT NULL THEN 1 ELSE 0 END) +
          (CASE WHEN expense_id IS NOT NULL THEN 1 ELSE 0 END) +
          (CASE WHEN wallet_txn_id IS NOT NULL THEN 1 ELSE 0 END) +
          (CASE WHEN delivery_id IS NOT NULL THEN 1 ELSE 0 END) = 1
        )''',
  ];
}

// Append-only ledger.
@DataClassName('ActivityLogData')
class ActivityLogs extends Table {
  TextColumn get id => text().clientDefault(() => UuidV7.generate())();
  TextColumn get businessId => text().references(Businesses, #id)();
  TextColumn get userId => text().nullable().references(Users, #id)();
  TextColumn get action => text()();
  TextColumn get description => text()();
  TextColumn get orderId => text().nullable().references(Orders, #id)();
  TextColumn get productId => text().nullable().references(Products, #id)();
  TextColumn get customerId => text().nullable().references(Customers, #id)();
  TextColumn get expenseId => text().nullable().references(Expenses, #id)();
  TextColumn get deliveryId =>
      text().nullable().references(DeliveryReceipts, #id)();
  TextColumn get walletTxnId =>
      text().nullable().references(WalletTransactions, #id)();
  TextColumn get warehouseId => text().nullable().references(Warehouses, #id)();
  DateTimeColumn get voidedAt => dateTime().nullable()();
  TextColumn get voidedBy => text().nullable().references(Users, #id)();
  TextColumn get voidReason => text().nullable()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get lastUpdatedAt =>
      dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {id};

  @override
  List<String> get customConstraints => [
    '''CHECK (
          (CASE WHEN order_id IS NOT NULL THEN 1 ELSE 0 END) +
          (CASE WHEN product_id IS NOT NULL THEN 1 ELSE 0 END) +
          (CASE WHEN customer_id IS NOT NULL THEN 1 ELSE 0 END) +
          (CASE WHEN expense_id IS NOT NULL THEN 1 ELSE 0 END) +
          (CASE WHEN delivery_id IS NOT NULL THEN 1 ELSE 0 END) +
          (CASE WHEN wallet_txn_id IS NOT NULL THEN 1 ELSE 0 END) <= 1
        )''',
  ];
}

@DataClassName('NotificationData')
class Notifications extends Table {
  TextColumn get id => text().clientDefault(() => UuidV7.generate())();
  TextColumn get businessId => text().references(Businesses, #id)();
  TextColumn get type => text()();
  TextColumn get message => text()();
  BoolColumn get isRead => boolean().withDefault(const Constant(false))();
  TextColumn get linkedRecordId => text().nullable()();
  // NULL = broadcast (visible to every member); set = targeted at one user
  // (only visible to that user via NotificationsDao). Mirror of the cloud
  // column added in 0026_accept_invite_v3.sql.
  TextColumn get recipientUserId =>
      text().nullable().references(Users, #id)();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get lastUpdatedAt =>
      dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('SettingData')
class Settings extends Table {
  TextColumn get id => text().clientDefault(() => UuidV7.generate())();
  TextColumn get businessId => text().references(Businesses, #id)();
  TextColumn get key => text()();
  TextColumn get value => text()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get lastUpdatedAt =>
      dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {id};

  @override
  List<String> get customConstraints => ['UNIQUE (business_id, "key")'];
}

@DataClassName('SessionData')
class Sessions extends Table {
  TextColumn get id => text().clientDefault(() => UuidV7.generate())();
  TextColumn get businessId => text().references(Businesses, #id)();
  TextColumn get userId => text().references(Users, #id)();
  TextColumn get token => text().nullable()();
  DateTimeColumn get expiresAt => dateTime()();
  DateTimeColumn get revokedAt => dateTime().nullable()();
  TextColumn get userAgent => text().nullable()();
  TextColumn get ipAddress => text().nullable()();
  TextColumn get deviceId => text().nullable()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get lastUpdatedAt =>
      dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {id};
}

// Global (non-tenant) config — replaces sentinel-business-id pattern.
class SystemConfig extends Table {
  TextColumn get key => text()();
  TextColumn get value => text().nullable()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get lastUpdatedAt =>
      dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {key};
}

// ---------------------------------------------------------------------------
// Local-only tables (not synced to Supabase)
// ---------------------------------------------------------------------------

@DataClassName('SyncQueueData')
class SyncQueue extends Table {
  TextColumn get id => text().clientDefault(() => UuidV7.generate())();
  TextColumn get businessId => text().references(Businesses, #id)();
  TextColumn get actionType => text()();
  TextColumn get payload => text()();
  BoolColumn get isSynced => boolean().withDefault(const Constant(false))();
  TextColumn get status => text().withDefault(const Constant('pending'))();
  TextColumn get errorMessage => text().nullable()();
  IntColumn get attempts => integer().withDefault(const Constant(0))();
  DateTimeColumn get nextAttemptAt => dateTime().nullable()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  // Supabase auth.uid() at enqueue time. Dispatch refuses to push a row
  // whose tag does not match the current session's auth.uid(), so an
  // account-switch on the same device cannot flush the previous user's
  // queued writes under the new user's JWT. Nullable for two reasons:
  // (a) rows enqueued before v10 have no captured value, and (b) some
  // bootstrap enqueues (very early in onboarding) can race the Supabase
  // session-restore — null is treated as "trust the current user" by
  // dispatch, preserving today's behavior for those legacy rows.
  TextColumn get authUserId => text().nullable()();

  @override
  Set<Column> get primaryKey => {id};

  @override
  List<String> get customConstraints => [
    "CHECK (status IN ('pending','syncing','completed','failed'))",
  ];
}

@DataClassName('SyncQueueOrphanData')
class SyncQueueOrphans extends Table {
  TextColumn get id => text().clientDefault(() => UuidV7.generate())();
  TextColumn get originalId => text()();
  TextColumn get actionType => text()();
  TextColumn get payload => text()();
  TextColumn get reason => text()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get movedAt => dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('MigrationEventData')
class MigrationEvents extends Table {
  TextColumn get id => text().clientDefault(() => UuidV7.generate())();
  IntColumn get version => integer()();
  TextColumn get step => text()();
  TextColumn get severity => text()();
  TextColumn get errorMessage => text().nullable()();
  DateTimeColumn get occurredAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

// ---------------------------------------------------------------------------
// Database
// ---------------------------------------------------------------------------

@DriftDatabase(
  tables: [
    Businesses,
    CrateGroups,
    Manufacturers,
    Warehouses,
    Users,
    Categories,
    Suppliers,
    Products,
    PriceLists,
    Customers,
    CustomerWallets,
    WalletTransactions,
    CustomerCrateBalances,
    ManufacturerCrateBalances,
    CrateLedger,
    Inventory,
    StockTransfers,
    StockAdjustments,
    StockTransactions,
    Orders,
    OrderItems,
    Purchases,
    PurchaseItems,
    ExpenseCategories,
    Expenses,
    Drivers,
    DeliveryReceipts,
    SavedCarts,
    PendingCrateReturns,
    PaymentTransactions,
    ActivityLogs,
    Notifications,
    Settings,
    Sessions,
    SystemConfig,
    SyncQueue,
    SyncQueueOrphans,
    MigrationEvents,
  ],
  daos: [
    CatalogDao,
    InventoryDao,
    OrdersDao,
    CustomersDao,
    DeliveriesDao,
    ExpensesDao,
    SyncDao,
    ActivityLogDao,
    NotificationsDao,
    WarehousesDao,
    StockLedgerDao,
    StockTransferDao,
    PendingCrateReturnsDao,
    SessionsDao,
    WalletTransactionsDao,
    CustomerWalletsDao,
    CrateGroupsDao,
    CustomerCrateBalancesDao,
    ManufacturerCrateBalancesDao,
    CrateLedgerDao,
    SettingsDao,
    SystemConfigDao,
  ],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase() : super(_openConnection());

  /// Test-only constructor: lets unit tests pass an in-memory `NativeDatabase`
  /// (or any `QueryExecutor`) without touching disk.
  AppDatabase.forTesting(super.executor);

  /// Set once at login (and cleared on logout) by AuthService. DAOs that
  /// participate in the multi-tenant filter read through this so they don't
  /// have to depend on Riverpod or pass businessId explicitly.
  String? Function() businessIdResolver = () => null;
  String? get currentBusinessId => businessIdResolver();

  /// Set alongside [businessIdResolver] by AuthService. DAOs that need to
  /// scope queries to the current user (e.g. notifications with a
  /// `recipient_user_id` filter) read through this for the same reasons.
  String? Function() userIdResolver = () => null;
  String? get currentUserId => userIdResolver();

  /// Supabase auth.uid() for the active session, read directly from the
  /// SDK so it tracks the cloud identity independent of any local `users`
  /// row. SyncDao stamps every enqueued row with this so dispatch can
  /// reject pushes after an account switch on the same device.
  ///
  /// Returns null before AuthService binds the closure (cold start) and
  /// during the brief window between Supabase init and session restore.
  /// Null at enqueue time is treated as "trust the current user" at
  /// dispatch — see [SyncQueue.authUserId] for the full contract.
  String? Function() authUserIdResolver = () => null;
  String? get currentAuthUserId => authUserIdResolver();

  @override
  int get schemaVersion => 12;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) async {
      debugPrint('[AppDatabase] onCreate: Creating database tables...');
      await transaction(() async {
        await m.createAll();
        for (final stmt in _postCreateStatements) {
          await customStatement(stmt);
        }
      });
      debugPrint('[AppDatabase] onCreate: DB setup complete.');
    },
    onUpgrade: (m, from, to) async {
      debugPrint('[AppDatabase] onUpgrade: v$from → v$to');
      if (from < 3) {
        // v3: businesses.onboarding_complete. Existing rows are from
        // already-onboarded businesses (anything in Drift at v2 came
        // through a completed flow), so default them to true to match
        // the SQL back-fill in supabase/migrations/0004_onboarding_resume.sql.
        await m.addColumn(businesses, businesses.onboardingComplete);
        await customStatement(
          'UPDATE businesses SET onboarding_complete = 1',
        );
      }
      if (from < 4) {
        // v4: enqueue-time coalescing. Adds a partial unique index on
        // sync_queue keyed on (action_type, payload->id) WHERE status =
        // 'pending'. Before adding it, collapse any duplicate pending rows
        // that may already exist — keep the latest by created_at and mark
        // the rest as completed so the index can be created without
        // violating uniqueness. Domain actions (action_type LIKE 'domain:%')
        // are exempt since each is an independent atomic envelope.
        await customStatement(
          "UPDATE sync_queue SET status = 'completed', is_synced = 1 "
          "WHERE id IN ("
          "  SELECT id FROM ("
          "    SELECT id, ROW_NUMBER() OVER ("
          "      PARTITION BY action_type, json_extract(payload, '\$.id') "
          "      ORDER BY created_at DESC"
          "    ) AS rn "
          "    FROM sync_queue "
          "    WHERE status = 'pending' "
          "      AND action_type NOT LIKE 'domain:%' "
          "      AND json_extract(payload, '\$.id') IS NOT NULL"
          "  ) WHERE rn > 1"
          ")",
        );
        await customStatement(
          "CREATE UNIQUE INDEX IF NOT EXISTS idx_sync_queue_dedup_pending "
          "ON sync_queue (action_type, json_extract(payload, '\$.id')) "
          "WHERE status = 'pending' "
          "  AND action_type NOT LIKE 'domain:%' "
          "  AND json_extract(payload, '\$.id') IS NOT NULL",
        );
      }
      if (from < 5) {
        // v5 (phase D §6.3 + §4.5):
        //   * Drop the unused `crates` table. It was never written by
        //     any live code path; the cloud counterpart drops in
        //     `0016_drop_crates.sql`.
        //   * Wipe the cache tables so the cloud's authoritative state
        //     re-populates on the next pull. Stops local LWW-derived
        //     drift between the cache and the underlying ledger now
        //     that domain RPCs are the sole writers.
        //   * Purge pending cache writebacks from `sync_queue`. With
        //     phase D §6.3, caches are no longer in `_syncedTenantTables`
        //     — but pre-upgrade `inventory:upsert` /
        //     `customer_crate_balances:upsert` /
        //     `manufacturer_crate_balances:upsert` rows would still
        //     drain after the upgrade and push stale derived values that
        //     race against the next domain-RPC `inventory_after`. Drop
        //     them. The cloud cache rehydrates naturally on the next
        //     domain-RPC response (every v2 RPC that touches a cache
        //     returns the canonical row).
        await customStatement('DROP TABLE IF EXISTS crates');
        await customStatement('DELETE FROM inventory');
        await customStatement('DELETE FROM customer_crate_balances');
        await customStatement('DELETE FROM manufacturer_crate_balances');
        await customStatement(
          "DELETE FROM sync_queue WHERE action_type IN ("
          "'inventory:upsert',"
          "'customer_crate_balances:upsert',"
          "'manufacturer_crate_balances:upsert'"
          ")",
        );
      }
      if (from < 6) {
        // v6 originally introduced the business_members table as part of
        // the staff-onboarding work. v12 drops that table entirely with
        // the removal of staff management, so creating it on the way up
        // (only to drop it later in the same upgrade) is wasted work.
        // No-op here. A v5 device upgrading straight to v12 simply never
        // sees the membership table.
      }
      if (from < 7) {
        // v7 originally added wizard-collected columns to business_members.
        // No-op since v12 drops the entire table.
      }
      if (from < 8) {
        // v8 (Task #18): mirror notifications.recipient_user_id from the
        // cloud (added in 0026_accept_invite_v3.sql). NULL = broadcast,
        // visible to every member; set = targeted at one user. Existing
        // local rows get NULL, which is the right default — pre-rev-3
        // notifications were effectively broadcasts.
        await m.addColumn(notifications, notifications.recipientUserId);
      }
      if (from < 9) {
        // v9 (role vocabulary refactor): mirror supabase/migrations/0030.
        //
        //   admin → ceo / tier 6
        //   staff → cashier / tier 3
        //   ceo:     tier 5 → 6
        //   manager: tier 4 → 5
        //   stock_keeper: new at tier 4
        //   rider: new app-user role at tier 2
        //
        // Data backfill runs BEFORE the table rebuild so the new CHECK
        // constraints don't reject the old-vocabulary rows during the
        // copy step. SQLite can't ALTER TABLE … DROP CONSTRAINT, so we
        // use Drift's TableMigration which does the new-table/copy/drop/
        // rename dance using the current Dart customConstraints lists
        // (which after this commit hold the new vocabulary).
        // v9 originally also rebuilt users / business_members / invites
        // via Drift's TableMigration to apply updated CHECK constraints.
        // Those alterTable calls are no longer issued here: v12 drops
        // business_members and invites entirely and strips role / role_tier
        // from users, so any constraint-shape rebuild between v9 and v12
        // is redundant work that's about to be undone. The data-vocabulary
        // UPDATEs above still run (they execute against whatever the v8
        // schema had), keeping any pre-v9 row vocabulary consistent until
        // v12 drops the columns.
        await customStatement(
          "UPDATE users SET role = 'ceo',     role_tier = 6 WHERE role = 'admin'",
        );
        await customStatement(
          "UPDATE users SET role = 'cashier', role_tier = 3 WHERE role = 'staff'",
        );
        await customStatement(
          "UPDATE business_members SET role = 'ceo',     role_tier = 6 WHERE role = 'admin'",
        );
        await customStatement(
          "UPDATE business_members SET role = 'cashier', role_tier = 3 WHERE role = 'staff'",
        );
        await customStatement(
          "UPDATE invites SET role = 'ceo'     WHERE role = 'admin'",
        );
        await customStatement(
          "UPDATE invites SET role = 'cashier' WHERE role = 'staff'",
        );
      }
      if (from < 10) {
        // v10 (L5 fix): tag every sync_queue row with the Supabase
        // auth.uid() that enqueued it so dispatch can refuse to push
        // another user's queued writes after an account switch. Existing
        // rows get NULL — dispatch treats null as "trust the current
        // user" to keep already-queued writes flowing through the upgrade
        // without losing pending sales.
        await m.addColumn(syncQueue, syncQueue.authUserId);
      }
      if (from < 11) {
        // v11 (staff-lifecycle six-rule refactor): mirror
        // supabase/migrations/0035_drop_legacy_soft_delete_columns.sql.
        // Fire is now a hard-delete of the business_members row (handled
        // by the cloud terminate_member(p_user_id, p_business_id) RPC,
        // see daos.dart::BusinessMembersDao.terminateMember); the users
        // row is anonymized in place by the same RPC for historical FK
        // reference on past orders/activity logs. The soft-delete state
        // (`users.is_deleted`, `business_members.{is_deleted, status,
        // removed_at, removed_by}`) and the (business_id, is_deleted)
        // indexes are removed.
        //
        // Order matters:
        //   1. Hard-delete any rows that were soft-deleted under the old
        //      regime, so the rebuilt tables don't carry tombstones the
        //      new code can't recognize. Cloud-side termination already
        //      hard-deletes; this catches anything that was soft-deleted
        //      pre-upgrade and never resynced.
        //   2. Drop pending sync_queue payloads for users / business_members
        //      that would push the now-gone columns to a cloud that has
        //      already had them dropped — those upserts would fail with
        //      "column does not exist". The next pull restores canonical
        //      state.
        //   3. Drop the (business_id, is_deleted) indexes so the column
        //      drop on the table rebuild doesn't hit a dangling reference.
        //   4. m.alterTable rebuilds the tables to match the current Dart
        //      definitions — Drift's TableMigration does the new-table /
        //      copy / drop / rename dance using the updated columns and
        //      customConstraints lists.
        // v11 originally cleared soft-delete tombstones and rebuilt the
        // users / business_members tables to drop the is_deleted / status
        // columns. Now redundant: the v12 block below drops
        // business_members + invites and strips role / role_tier from
        // users wholesale. We still scrub any pending sync queue rows
        // that referenced the about-to-disappear columns so the next
        // push doesn't error.
        try {
          await customStatement(
            "DELETE FROM business_members "
            "WHERE is_deleted = 1 OR status = 'removed'",
          );
        } catch (_) {/* table may already be gone or column missing */}
        try {
          await customStatement('DELETE FROM users WHERE is_deleted = 1');
        } catch (_) {/* column already dropped */}
        await customStatement(
          "DELETE FROM sync_queue "
          "WHERE action_type IN ('users:upsert', 'business_members:upsert')",
        );
        await customStatement(
          'DROP INDEX IF EXISTS idx_users_business_deleted',
        );
        await customStatement(
          'DROP INDEX IF EXISTS idx_business_members_business_deleted',
        );
      }
      if (from < 12) {
        // v12: staff management removed entirely. Drops the
        // business_members and invites tables, strips role / role_tier
        // from users (PIN columns kept — the lone owner still needs
        // PIN unlock). Mirrors supabase/migrations/0041_remove_staff_management.sql.
        //
        // Order:
        //   1. Drop any queued upserts targeting the dropping tables so
        //      the next push doesn't fail on the now-gone cloud tables.
        //   2. Drop the (business_id, *) indexes for the about-to-go
        //      tables / columns.
        //   3. Drop the tables.
        //   4. Drop role / role_tier columns from users via raw
        //      ALTER TABLE … DROP COLUMN.
        //
        // The earlier v12 implementation used `m.alterTable(TableMigration(users))`
        // to rebuild users without role/role_tier. That broke once schema
        // changes after v12 touched the users table — TableMigration uses
        // the CURRENT Drift schema to define the rebuilt table, so a
        // v11 → v14 upgrade tried to SELECT `store_id` (added in v14) from
        // the pre-rename users table that still had `warehouse_id`. Using
        // raw DROP COLUMN decouples this block from whatever the current
        // schema looks like; v14's column rename and any future column
        // adds/renames run cleanly afterwards.
        //
        // SQLite 3.35+ supports DROP COLUMN; bundled via
        // sqlite3_flutter_libs: ^0.5.15.
        await customStatement(
          "DELETE FROM sync_queue "
          "WHERE action_type IN ('business_members:upsert', "
          "'invites:upsert', 'business_members:delete', 'invites:delete')",
        );
        await customStatement(
          'DROP INDEX IF EXISTS idx_business_members_business_lua',
        );
        await customStatement(
          'DROP INDEX IF EXISTS idx_business_members_user',
        );
        await customStatement(
          'DROP INDEX IF EXISTS idx_invites_business_lua',
        );
        await customStatement(
          'DROP INDEX IF EXISTS uq_invites_pending_code',
        );
        await customStatement(
          'DROP INDEX IF EXISTS uq_invites_pending_human_code',
        );
        await customStatement('DROP TABLE IF EXISTS business_members');
        await customStatement('DROP TABLE IF EXISTS invites');
        // Try/catch wraps make this idempotent — re-running v12 against a
        // table where the column was already dropped (e.g. a half-completed
        // earlier attempt that aborted between the two statements) skips
        // rather than erroring. SQLite has no DROP COLUMN IF EXISTS.
        try {
          await customStatement('ALTER TABLE users DROP COLUMN role');
        } catch (_) {/* already gone */}
        try {
          await customStatement('ALTER TABLE users DROP COLUMN role_tier');
        } catch (_) {/* already gone */}
      }
    },
    beforeOpen: (details) async {
      await customStatement('PRAGMA foreign_keys = ON');
      await customStatement('PRAGMA journal_mode = WAL');
      await customStatement('PRAGMA synchronous = NORMAL');

      _lastSchemaAudit = await SchemaAudit(
        this,
        migratorFactory: () => createMigrator(),
      ).run(attemptHeal: true);
    },
  );

  SchemaAuditResult? _lastSchemaAudit;
  SchemaAuditResult? get lastSchemaAudit => _lastSchemaAudit;

  Future<void> clearAllData() async {
    // PRAGMA foreign_keys cannot be toggled inside a transaction — must run on
    // the executor before transaction() opens.
    await customStatement('PRAGMA foreign_keys = OFF');
    try {
      await transaction(() async {
        for (final table in allTables) {
          await delete(table).go();
        }
      });
    } finally {
      await customStatement('PRAGMA foreign_keys = ON');
    }
  }

  Future<void> resetDatabase() async {
    await clearAllData();
  }
}

final database = AppDatabase();

/// Completer-guarded DB readiness flag.
final Completer<void> _dbCompleter = Completer<void>();

Future<void> get dbReady => _dbCompleter.future;

void markDbReady() {
  if (!_dbCompleter.isCompleted) _dbCompleter.complete();
}

void markDbReadyWithError([Object? error]) {
  if (!_dbCompleter.isCompleted) {
    _dbCompleter.completeError(error ?? 'DB init failed');
  }
}

LazyDatabase _openConnection() {
  return LazyDatabase(() async {
    final dbFolder = await getApplicationDocumentsDirectory();
    final file = File(p.join(dbFolder.path, 'reebaplus_pos.sqlite'));

    return NativeDatabase(
      file,
      logStatements: false,
      setup: (db) {
        db.execute('PRAGMA journal_mode = WAL');
        db.execute('PRAGMA synchronous = NORMAL');
        db.execute('PRAGMA cache_size = -8000');
        db.execute('PRAGMA temp_store = MEMORY');
        db.execute('PRAGMA foreign_keys = ON');
      },
    );
  });
}

// ---------------------------------------------------------------------------
// Indexes + triggers — applied in onCreate after createAll().
// ---------------------------------------------------------------------------

// Phase D §6.3: caches (`inventory`, `customer_crate_balances`,
// `manufacturer_crate_balances`) are no longer pushed — domain RPCs are
// the sole writers cloud-side, and `_applyDomainResponse` /
// `_restoreTableData` write the cloud-authoritative values back locally.
// They're still real Drift tables (UI reads from them); they're just
// not in this set, so:
//   * no per-row `<table>:upsert` outbox rows are pushed,
//   * no `(business_id, last_updated_at)` index is created on
//     onCreate (caches don't drive incremental cursor pulls — they
//     arrive via snapshot or domain response),
//   * no `bump_<table>_last_updated_at` trigger is created (the only
//     local writers — _applyDomainResponse / _restoreTableData — set
//     last_updated_at explicitly to the cloud's value).
// `crates` is dropped entirely in v5; not in the set going forward.
const List<String> _syncedTenantTables = [
  'users',
  'sessions',
  'warehouses',
  'manufacturers',
  'crate_groups',
  'categories',
  'suppliers',
  'products',
  'price_lists',
  'customers',
  'customer_wallets',
  'wallet_transactions',
  'crate_ledger',
  'stock_transfers',
  'stock_adjustments',
  'stock_transactions',
  'orders',
  'order_items',
  'purchases',
  'purchase_items',
  'drivers',
  'delivery_receipts',
  'saved_carts',
  'pending_crate_returns',
  'payment_transactions',
  'expense_categories',
  'expenses',
  'activity_logs',
  'notifications',
  'settings',
];

// 0033_staff_lifecycle_hard_delete dropped soft-delete on users and
// business_members — both the columns and their (business_id, is_deleted)
// indexes are gone. Fire is now a hard-delete of the membership row; the
// users row persists for historical FK reference. Keep the other entries
// intact: products/customers/etc. still soft-delete normally.
const List<String> _softDeletableTables = [
  'warehouses',
  'manufacturers',
  'crate_groups',
  'categories',
  'suppliers',
  'products',
  'price_lists',
  'customers',
  'customer_wallets',
  'drivers',
  'expense_categories',
  'expenses',
];

class _LedgerImmutability {
  final String table;
  final List<String> immutableColumns;
  const _LedgerImmutability(this.table, this.immutableColumns);
}

const List<_LedgerImmutability> _ledgerTables = [
  _LedgerImmutability('stock_transactions', [
    'id',
    'business_id',
    'product_id',
    'location_id',
    'quantity_delta',
    'movement_type',
    'order_id',
    'transfer_id',
    'adjustment_id',
    'purchase_id',
    'performed_by',
    'created_at',
  ]),
  _LedgerImmutability('wallet_transactions', [
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
    'customer_verified',
    'created_at',
  ]),
  _LedgerImmutability('payment_transactions', [
    'id',
    'business_id',
    'amount_kobo',
    'method',
    'type',
    'order_id',
    'purchase_id',
    'expense_id',
    'wallet_txn_id',
    'delivery_id',
    'performed_by',
    'created_at',
  ]),
  _LedgerImmutability('activity_logs', [
    'id',
    'business_id',
    'user_id',
    'action',
    'description',
    'order_id',
    'product_id',
    'customer_id',
    'expense_id',
    'delivery_id',
    'wallet_txn_id',
    'warehouse_id',
    'created_at',
  ]),
  _LedgerImmutability('crate_ledger', [
    'id',
    'business_id',
    'customer_id',
    'manufacturer_id',
    'crate_group_id',
    'quantity_delta',
    'movement_type',
    'reference_order_id',
    'reference_return_id',
    'performed_by',
    'created_at',
  ]),
];

List<String> get _postCreateStatements {
  final stmts = <String>[];

  // -- Sync indexes --
  stmts.add(
    'CREATE INDEX idx_businesses_last_updated_at ON businesses (last_updated_at)',
  );
  for (final t in _syncedTenantTables) {
    stmts.add(
      'CREATE INDEX idx_${t}_business_lua ON $t (business_id, last_updated_at)',
    );
  }

  // -- Soft-delete indexes --
  for (final t in _softDeletableTables) {
    stmts.add(
      'CREATE INDEX idx_${t}_business_deleted ON $t (business_id, is_deleted)',
    );
  }

  // -- Hot-path indexes (mirror Supabase) --
  stmts.addAll([
    'CREATE INDEX idx_sessions_user_active ON sessions (user_id, revoked_at, expires_at)',
    'CREATE INDEX idx_products_category ON products (category_id)',
    'CREATE INDEX idx_products_name ON products (business_id, name)',
    'CREATE INDEX idx_price_lists_product ON price_lists (product_id, effective_from)',
    'CREATE INDEX idx_customers_business_phone ON customers (business_id, phone)',
    'CREATE INDEX idx_wallet_txn_business_cust_time ON wallet_transactions (business_id, customer_id, created_at)',
    'CREATE INDEX idx_crate_ledger_owner_group ON crate_ledger (business_id, customer_id, manufacturer_id, crate_group_id, created_at)',
    'CREATE INDEX idx_inventory_business_pw ON inventory (business_id, product_id, warehouse_id)',
    'CREATE INDEX idx_stock_txn_prod_loc_time ON stock_transactions (product_id, location_id, created_at)',
    'CREATE INDEX idx_orders_business_time ON orders (business_id, created_at)',
    'CREATE INDEX idx_orders_business_status ON orders (business_id, status)',
    'CREATE INDEX idx_order_items_order ON order_items (order_id)',
    'CREATE INDEX idx_order_items_product ON order_items (product_id)',
    'CREATE INDEX idx_purchase_items_purchase ON purchase_items (purchase_id)',
    'CREATE INDEX idx_pcr_business_status ON pending_crate_returns (business_id, status)',
    'CREATE INDEX idx_payment_txn_business_type ON payment_transactions (business_id, type, created_at)',
    'CREATE INDEX idx_expenses_business_time ON expenses (business_id, created_at)',
    'CREATE INDEX idx_activity_logs_business_time ON activity_logs (business_id, created_at)',
  ]);

  // Enqueue-time coalescing: at most one pending sync_queue row per
  // (action_type, payload.id). The trailing AND clause excludes domain
  // actions (each domain envelope is an independent atomic call) and
  // payloads without a top-level id (delete tombstones).
  stmts.add(
    "CREATE UNIQUE INDEX idx_sync_queue_dedup_pending "
    "ON sync_queue (action_type, json_extract(payload, '\$.id')) "
    "WHERE status = 'pending' "
    "  AND action_type NOT LIKE 'domain:%' "
    "  AND json_extract(payload, '\$.id') IS NOT NULL",
  );

  // -- bump_<table>_last_updated_at triggers --
  // Recursion guard: only bump when last_updated_at wasn't modified by the
  // caller. SQLite's `IS` is null-safe equality.
  stmts.add(
    'CREATE TRIGGER bump_businesses_last_updated_at '
    'AFTER UPDATE ON businesses '
    'FOR EACH ROW '
    'WHEN OLD.last_updated_at IS NEW.last_updated_at '
    'BEGIN '
    "UPDATE businesses SET last_updated_at = CAST(strftime('%s', 'now') AS INTEGER) WHERE id = OLD.id; "
    'END',
  );
  for (final t in _syncedTenantTables) {
    stmts.add(
      'CREATE TRIGGER bump_${t}_last_updated_at '
      'AFTER UPDATE ON $t '
      'FOR EACH ROW '
      'WHEN OLD.last_updated_at IS NEW.last_updated_at '
      'BEGIN '
      "UPDATE $t SET last_updated_at = CAST(strftime('%s', 'now') AS INTEGER) WHERE id = OLD.id; "
      'END',
    );
  }
  // system_config keys on `key`, not `id`.
  stmts.add(
    'CREATE TRIGGER bump_system_config_last_updated_at '
    'AFTER UPDATE ON system_config '
    'FOR EACH ROW '
    'WHEN OLD.last_updated_at IS NEW.last_updated_at '
    'BEGIN '
    "UPDATE system_config SET last_updated_at = CAST(strftime('%s', 'now') AS INTEGER) WHERE key = OLD.key; "
    'END',
  );

  // -- bump_products_version --
  stmts.add(
    'CREATE TRIGGER bump_products_version '
    'AFTER UPDATE ON products '
    'FOR EACH ROW '
    'WHEN OLD.version IS NEW.version '
    'BEGIN '
    'UPDATE products SET version = OLD.version + 1 WHERE id = OLD.id; '
    'END',
  );

  // -- Append-only enforcement on ledgers --
  for (final ledger in _ledgerTables) {
    final whenClause = ledger.immutableColumns
        .map((c) => 'NEW.$c IS NOT OLD.$c')
        .join(' OR ');
    stmts.add(
      'CREATE TRIGGER ${ledger.table}_immutable '
      'BEFORE UPDATE ON ${ledger.table} '
      'FOR EACH ROW '
      'WHEN $whenClause '
      'BEGIN '
      "SELECT RAISE(ABORT, 'append-only: only voided_at/voided_by/void_reason may change'); "
      'END',
    );
    stmts.add(
      'CREATE TRIGGER ${ledger.table}_no_delete '
      'BEFORE DELETE ON ${ledger.table} '
      'BEGIN '
      "SELECT RAISE(ABORT, 'append-only: deletion not permitted'); "
      'END',
    );
  }

  return stmts;
}
