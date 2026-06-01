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

@DataClassName('CrateSizeGroupData')
class CrateSizeGroups extends Table {
  TextColumn get id => text().clientDefault(() => UuidV7.generate())();
  TextColumn get businessId => text().references(Businesses, #id)();
  TextColumn get name => text()();
  // Crate size is a category (Big / Medium / Small), not a bottle count.
  // Column name matches the cloud's existing `crate_size_label` text column.
  TextColumn get crateSizeLabel =>
      text().withDefault(const Constant('medium'))();
  IntColumn get emptyCrateStock => integer().withDefault(const Constant(0))();
  IntColumn get depositAmountKobo => integer().withDefault(const Constant(0))();
  BoolColumn get isDeleted => boolean().withDefault(const Constant(false))();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get lastUpdatedAt =>
      dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {id};

  @override
  List<String> get customConstraints => [
    "CHECK (crate_size_label IN ('big','medium','small'))",
  ];
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

@DataClassName('StoreData')
class Stores extends Table {
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
  TextColumn get storeId => text().nullable().references(Stores, #id)();
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
  TextColumn get crateSizeGroupId =>
      text().nullable().references(CrateSizeGroups, #id)();
  BoolColumn get isDeleted => boolean().withDefault(const Constant(false))();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get lastUpdatedAt =>
      dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {id};
}

/// The unit types a product can be measured / sold in — the single source of
/// truth for the Add / Edit Product dropdowns AND the `products.unit` CHECK
/// constraint on the [Products] table below. Kept in lock-step so the UI can
/// never offer a value the database rejects (the old mismatch silently failed
/// the insert for Can / Keg products — they never reached inventory). See
/// §16.5. Widening this is a schema change: also widen the CHECK below, bump
/// `schemaVersion`, add the matching `onUpgrade` table rebuild, and ship the
/// cloud migration that widens the Supabase CHECK.
const List<String> kProductUnits = [
  'Bottle', 'Can', 'PET', 'Sachet', 'Keg',
  'Crate', 'Pack', 'Carton', 'Piece', 'Bag',
  'Box', 'Tin', 'Other',
];

@DataClassName('ProductData')
class Products extends Table {
  TextColumn get id => text().clientDefault(() => UuidV7.generate())();
  TextColumn get businessId => text().references(Businesses, #id)();
  TextColumn get categoryId => text().nullable().references(Categories, #id)();
  TextColumn get crateSizeGroupId =>
      text().nullable().references(CrateSizeGroups, #id)();
  TextColumn get supplierId => text().nullable().references(Suppliers, #id)();
  TextColumn get manufacturerId =>
      text().nullable().references(Manufacturers, #id)();
  TextColumn get name => text()();
  TextColumn get subtitle => text().nullable()();
  TextColumn get sku => text().nullable()();
  TextColumn get size => text().nullable()();
  TextColumn get unit => text().withDefault(const Constant('Bottle'))();
  // Reebaplus pivot step 14 (schema v18): the four legacy price columns
  // (retail / bulk breaker / distributor / selling) were dropped; products
  // now hold exactly three prices — buying (already here), retailer,
  // wholesaler. See master plan §16.5.
  IntColumn get retailerPriceKobo =>
      integer().withDefault(const Constant(0))();
  IntColumn get wholesalerPriceKobo =>
      integer().withDefault(const Constant(0))();
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
  BoolColumn get allowFractionalSales =>
      boolean().withDefault(const Constant(false))();
  // Optional product barcode (schema v18). Surfaced in the UI only for
  // Pharmacy / Supermarket businesses — that UI lands with the barcode
  // scanner work (pivot step 30); the column ships now with the price drop.
  TextColumn get barcode => text().nullable()();
  // Optional single expiry date per product (schema v19, master plan §16.5).
  // Not per-batch/FIFO (that stays Phase 2) — one date used to flag and
  // sell-down the stock closest to expiry. Available for all business types;
  // businesses that don't track expiry simply leave it null.
  DateTimeColumn get expiryDate => dateTime().nullable()();
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
    // Keep in lock-step with [kProductUnits] above.
    "CHECK (unit IN ('Bottle','Can','PET','Sachet','Keg','Crate','Pack','Carton','Piece','Bag','Box','Tin','Other'))",
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
  TextColumn get storeId => text().nullable().references(Stores, #id)();
  TextColumn get name => text()();
  TextColumn get phone => text().nullable()();
  TextColumn get email => text().nullable()();
  TextColumn get address => text().nullable()();
  TextColumn get googleMapsLocation => text().nullable()();
  TextColumn get priceTier =>
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
    "CHECK (price_tier IN ('retailer','wholesaler'))",
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

// ── Funds Register (master plan §23) ─────────────────────────────────────────
// Per-store money accounts (Cash Till / POS machine / Bank), a daily open/close
// header that gates the till, and an append-only ledger of money movements.
@DataClassName('FundsAccountData')
class FundsAccounts extends Table {
  TextColumn get id => text().clientDefault(() => UuidV7.generate())();
  TextColumn get businessId => text().references(Businesses, #id)();
  TextColumn get storeId => text().references(Stores, #id)();
  TextColumn get accountType => text()(); // cash_till | pos_machine | bank
  TextColumn get name => text()();
  TextColumn get accountNumber => text().nullable()(); // POS terminal / bank acct no.
  BoolColumn get isActive => boolean().withDefault(const Constant(true))();
  BoolColumn get isDeleted => boolean().withDefault(const Constant(false))();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get lastUpdatedAt =>
      dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {id};

  @override
  List<String> get customConstraints => [
    "CHECK (account_type IN ('cash_till','pos_machine','bank'))",
    'UNIQUE (store_id, account_type, name)',
  ];
}

// Daily open/close header — one row per (store, business_date). Existence with
// status='open' is the POS Opening-Cash gate (hard rule #10). Mutable on close
// (Phase 1 Close Day, §23.6/§23.8 — sets status='closed' + closedBy/closedAt),
// so NOT a ledger.
@DataClassName('FundDayData')
class FundDays extends Table {
  TextColumn get id => text().clientDefault(() => UuidV7.generate())();
  TextColumn get businessId => text().references(Businesses, #id)();
  TextColumn get storeId => text().references(Stores, #id)();
  TextColumn get businessDate => text()(); // YYYY-MM-DD, local business day
  TextColumn get status => text().withDefault(const Constant('open'))();
  TextColumn get openedBy => text().nullable().references(Users, #id)();
  DateTimeColumn get openedAt => dateTime().nullable()();
  TextColumn get closedBy => text().nullable().references(Users, #id)();
  DateTimeColumn get closedAt => dateTime().nullable()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get lastUpdatedAt =>
      dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {id};

  @override
  List<String> get customConstraints => [
    "CHECK (status IN ('open','closed'))",
    'UNIQUE (store_id, business_date)',
  ];
}

// Append-only ledger. Account balance for a day = SUM(signed_amount_kobo) of
// non-voided rows. Opening balance is the day's first 'opening' credit.
@DataClassName('FundTransactionData')
class FundTransactions extends Table {
  TextColumn get id => text().clientDefault(() => UuidV7.generate())();
  TextColumn get businessId => text().references(Businesses, #id)();
  TextColumn get fundsAccountId => text().references(FundsAccounts, #id)();
  TextColumn get storeId => text().references(Stores, #id)();
  TextColumn get businessDate => text()(); // YYYY-MM-DD
  TextColumn get type => text()(); // credit | debit
  IntColumn get amountKobo => integer()();
  IntColumn get signedAmountKobo => integer()();
  TextColumn get referenceType => text()(); // opening | sale | void | topup
  TextColumn get orderId => text().nullable().references(Orders, #id)();
  TextColumn get paymentId =>
      text().nullable().references(PaymentTransactions, #id)();
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
    "CHECK (type IN ('credit','debit'))",
    'CHECK (amount_kobo >= 0)',
    "CHECK (reference_type IN ('opening','sale','void','topup'))",
    "CHECK ((type = 'credit' AND signed_amount_kobo >= 0) OR "
        "(type = 'debit' AND signed_amount_kobo <= 0))",
  ];
}

// Per-account Close Day reconciliation snapshot (§23.6/§25.2). One row per
// (fund_day, account), written when the day is closed. `expected_kobo` is the
// account's running balance (SUM signed_amount_kobo) at close; `counted_kobo`
// is the actual the user entered (cash counted for the till, amount withdrawn
// for POS/bank); `variance_kobo` = counted − expected (a non-zero value is a
// shortage/surplus that flags a mismatch). This is the cash-audit half the
// Daily Reconciliation Report (Ring 3, §25.9) reads. Written once per close
// (closeDay throws if the day is already closed), so it's a normal synced
// table, not an append-only ledger.
@DataClassName('FundDayClosingData')
class FundDayClosings extends Table {
  TextColumn get id => text().clientDefault(() => UuidV7.generate())();
  TextColumn get businessId => text().references(Businesses, #id)();
  TextColumn get fundDayId => text().references(FundDays, #id)();
  TextColumn get fundsAccountId => text().references(FundsAccounts, #id)();
  TextColumn get storeId => text().references(Stores, #id)();
  TextColumn get businessDate => text()(); // YYYY-MM-DD
  TextColumn get accountType => text()(); // cash_till | pos_machine | bank
  IntColumn get expectedKobo => integer()();
  IntColumn get countedKobo => integer()();
  IntColumn get varianceKobo => integer()(); // counted − expected
  TextColumn get performedBy => text().nullable().references(Users, #id)();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get lastUpdatedAt =>
      dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {id};

  @override
  List<String> get customConstraints => [
    "CHECK (account_type IN ('cash_till','pos_machine','bank'))",
    'UNIQUE (fund_day_id, funds_account_id)',
  ];
}

class CustomerCrateBalances extends Table {
  TextColumn get id => text().clientDefault(() => UuidV7.generate())();
  TextColumn get businessId => text().references(Businesses, #id)();
  TextColumn get customerId => text().references(Customers, #id)();
  TextColumn get crateSizeGroupId => text().references(CrateSizeGroups, #id)();
  IntColumn get balance => integer().withDefault(const Constant(0))();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get lastUpdatedAt =>
      dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {id};

  @override
  List<String> get customConstraints => [
    'UNIQUE (business_id, customer_id, crate_size_group_id)',
  ];
}

class ManufacturerCrateBalances extends Table {
  TextColumn get id => text().clientDefault(() => UuidV7.generate())();
  TextColumn get businessId => text().references(Businesses, #id)();
  TextColumn get manufacturerId => text().references(Manufacturers, #id)();
  TextColumn get crateSizeGroupId => text().references(CrateSizeGroups, #id)();
  IntColumn get balance => integer().withDefault(const Constant(0))();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get lastUpdatedAt =>
      dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {id};

  @override
  List<String> get customConstraints => [
    'UNIQUE (business_id, manufacturer_id, crate_size_group_id)',
  ];
}

// Append-only ledger of crate movements.
class CrateLedger extends Table {
  TextColumn get id => text().clientDefault(() => UuidV7.generate())();
  TextColumn get businessId => text().references(Businesses, #id)();
  TextColumn get customerId => text().nullable().references(Customers, #id)();
  TextColumn get manufacturerId =>
      text().nullable().references(Manufacturers, #id)();
  TextColumn get crateSizeGroupId => text().references(CrateSizeGroups, #id)();
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
  TextColumn get storeId => text().references(Stores, #id)();
  IntColumn get quantity => integer().withDefault(const Constant(0))();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get lastUpdatedAt =>
      dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {id};

  @override
  List<String> get customConstraints => [
    'UNIQUE (business_id, product_id, store_id)',
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
  TextColumn get fromLocationId => text().references(Stores, #id)();
  TextColumn get toLocationId => text().references(Stores, #id)();
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
  TextColumn get storeId => text().references(Stores, #id)();
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
  TextColumn get locationId => text().references(Stores, #id)();
  IntColumn get quantityDelta => integer()();
  TextColumn get movementType => text()();
  TextColumn get orderId => text().nullable().references(Orders, #id)();
  TextColumn get transferId =>
      text().nullable().references(StockTransfers, #id)();
  TextColumn get adjustmentId =>
      text().nullable().references(StockAdjustments, #id)();
  TextColumn get shipmentId => text().nullable().references(Shipments, #id)();
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
          (CASE WHEN shipment_id IS NOT NULL THEN 1 ELSE 0 END) = 1
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
  TextColumn get storeId => text().nullable().references(Stores, #id)();
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
  TextColumn get storeId => text().references(Stores, #id)();
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

@DataClassName('ShipmentData')
class Shipments extends Table {
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
  TextColumn get purchaseId => text().references(Shipments, #id)();
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
  TextColumn get storeId => text().nullable().references(Stores, #id)();
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
  TextColumn get cashierId => text().nullable()();
  DateTimeColumn get expiresAt => dateTime().nullable()();
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
  TextColumn get crateSizeGroupId => text().references(CrateSizeGroups, #id)();
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
  TextColumn get shipmentId => text().nullable().references(Shipments, #id)();
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
          (CASE WHEN shipment_id IS NOT NULL THEN 1 ELSE 0 END) +
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
  // Generic entity reference (§24.4): which record this log is about, by type
  // + id. Replaces the six per-entity FK columns (order/product/customer/
  // expense/delivery/wallet_txn) so any future feature logs against one shape.
  // entity_id is polymorphic — intentionally NOT a foreign key. store_id stays
  // a real FK because the §24.2 Activity Logs store filter reads it.
  TextColumn get entityType => text().nullable()();
  TextColumn get entityId => text().nullable()();
  // Before/after snapshots (JSON) for the §24.4 detail view.
  TextColumn get beforeJson => text().nullable()();
  TextColumn get afterJson => text().nullable()();
  TextColumn get storeId => text().nullable().references(Stores, #id)();
  DateTimeColumn get voidedAt => dateTime().nullable()();
  TextColumn get voidedBy => text().nullable().references(Users, #id)();
  TextColumn get voidReason => text().nullable()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get lastUpdatedAt =>
      dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('NotificationData')
class Notifications extends Table {
  TextColumn get id => text().clientDefault(() => UuidV7.generate())();
  TextColumn get businessId => text().references(Businesses, #id)();
  TextColumn get type => text()();
  TextColumn get message => text()();
  // §26.2 / §1.3 card colour: blue 'info' / yellow 'warning' / red 'alert'.
  // Replaces overloading `type` for severity. Defaults to 'info'.
  TextColumn get severity => text().withDefault(const Constant('info'))();
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

  @override
  List<String> get customConstraints =>
      ["CHECK (severity IN ('info', 'warning', 'alert'))"];
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

// ---------------------------------------------------------------------------
// Master plan §2.4 — roles, permissions, and membership (schema v13)
// ---------------------------------------------------------------------------
//
// Six tenant-scoped synced tables (roles, role_permissions, role_settings,
// user_businesses, invite_codes, user_stores) plus one global static-config
// table (permissions). The cloud's `complete_onboarding` RPC seeds the four
// default roles + 63 role_permissions + 8 role_settings + the CEO's
// membership on new business creation; pre-existing businesses are
// backfilled by cloud migration 0043. Local devices receive the seeded rows
// via the next sync pull. Local seeding happens only for the global
// `permissions` table (identical on every device).

/// Global static config. One row per permission key. NOT in
/// `_syncedTenantTables` — the keys are identical on every device and
/// every business; cloud and local are seeded by migration. The cloud's
/// `permissions` table mirrors the same rows for RLS / RPC reference.
@DataClassName('PermissionData')
class Permissions extends Table {
  TextColumn get key => text()();
  TextColumn get description => text()();
  TextColumn get category => text()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get lastUpdatedAt =>
      dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {key};
}

@DataClassName('RoleData')
class Roles extends Table {
  TextColumn get id => text().clientDefault(() => UuidV7.generate())();
  TextColumn get businessId => text().references(Businesses, #id)();
  TextColumn get name => text()();
  // Lowercase machine identifier. Code branching on role identity uses
  // this column (`ceo`, `manager`, `cashier`, `stock_keeper`), never
  // `name`. The four system defaults always carry these four slugs;
  // Phase 2 custom roles will derive slugs from their names.
  TextColumn get slug => text()();
  BoolColumn get isSystemDefault =>
      boolean().withDefault(const Constant(false))();
  BoolColumn get isDeleted => boolean().withDefault(const Constant(false))();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get lastUpdatedAt =>
      dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {id};

  @override
  List<String> get customConstraints => [
    'UNIQUE (business_id, name)',
    'UNIQUE (business_id, slug)',
  ];
}

@DataClassName('RolePermissionData')
class RolePermissions extends Table {
  TextColumn get id => text().clientDefault(() => UuidV7.generate())();
  TextColumn get businessId => text().references(Businesses, #id)();
  TextColumn get roleId => text().references(Roles, #id)();
  TextColumn get permissionKey => text()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get lastUpdatedAt =>
      dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {id};

  @override
  List<String> get customConstraints => [
    'UNIQUE (role_id, permission_key)',
  ];
}

@DataClassName('RoleSettingData')
class RoleSettings extends Table {
  TextColumn get id => text().clientDefault(() => UuidV7.generate())();
  TextColumn get businessId => text().references(Businesses, #id)();
  TextColumn get roleId => text().references(Roles, #id)();
  TextColumn get settingKey => text()();
  // TEXT — string/JSON-encoded value. NULL is meaningful for
  // unlimited-style settings (e.g. CEO's max_expense_approval_kobo).
  TextColumn get settingValue => text().nullable()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get lastUpdatedAt =>
      dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {id};

  @override
  List<String> get customConstraints => [
    'UNIQUE (role_id, setting_key)',
  ];
}

@DataClassName('UserBusinessData')
class UserBusinesses extends Table {
  TextColumn get id => text().clientDefault(() => UuidV7.generate())();
  TextColumn get businessId => text().references(Businesses, #id)();
  TextColumn get userId => text().references(Users, #id)();
  TextColumn get roleId => text().references(Roles, #id)();
  TextColumn get status => text().withDefault(const Constant('active'))();
  DateTimeColumn get lastLoginAt => dateTime().nullable()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get lastUpdatedAt =>
      dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {id};

  @override
  List<String> get customConstraints => [
    "CHECK (status IN ('active','suspended'))",
    'UNIQUE (user_id, business_id)',
  ];
}

@DataClassName('InviteCodeData')
class InviteCodes extends Table {
  TextColumn get id => text().clientDefault(() => UuidV7.generate())();
  TextColumn get businessId => text().references(Businesses, #id)();
  TextColumn get roleId => text().references(Roles, #id)();
  // 8-char uppercase alphanumeric, e.g. "K7M2QXP9".
  TextColumn get code => text().withLength(min: 8, max: 8)();
  // The email the invite was generated for. Staff Sign Up requires
  // a match (master plan §6).
  TextColumn get email => text()();
  // The store the invitee will be assigned to on acceptance
  // (master plan §6.2).
  TextColumn get storeId => text().references(Stores, #id)();
  TextColumn get generatedByUserId => text().references(Users, #id)();
  DateTimeColumn get expiresAt => dateTime()();
  TextColumn get usedByUserId => text().nullable().references(Users, #id)();
  DateTimeColumn get usedAt => dateTime().nullable()();
  DateTimeColumn get revokedAt => dateTime().nullable()();
  BoolColumn get isDeleted => boolean().withDefault(const Constant(false))();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get lastUpdatedAt =>
      dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('UserStoreData')
class UserStores extends Table {
  TextColumn get id => text().clientDefault(() => UuidV7.generate())();
  TextColumn get businessId => text().references(Businesses, #id)();
  TextColumn get userId => text().references(Users, #id)();
  TextColumn get storeId => text().references(Stores, #id)();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get lastUpdatedAt =>
      dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {id};

  @override
  List<String> get customConstraints => [
    'UNIQUE (user_id, store_id)',
  ];
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
    CrateSizeGroups,
    Manufacturers,
    Stores,
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
    Shipments,
    PurchaseItems,
    ExpenseCategories,
    Expenses,
    Drivers,
    DeliveryReceipts,
    SavedCarts,
    PendingCrateReturns,
    PaymentTransactions,
    FundsAccounts,
    FundDays,
    FundTransactions,
    FundDayClosings,
    ActivityLogs,
    Notifications,
    Settings,
    Sessions,
    Permissions,
    Roles,
    RolePermissions,
    RoleSettings,
    UserBusinesses,
    InviteCodes,
    UserStores,
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
    ShipmentsDao,
    ExpensesDao,
    SyncDao,
    ActivityLogDao,
    NotificationsDao,
    StoresDao,
    StockLedgerDao,
    StockTransferDao,
    PendingCrateReturnsDao,
    SessionsDao,
    WalletTransactionsDao,
    FundsAccountsDao,
    FundDaysDao,
    FundTransactionsDao,
    FundDayClosingsDao,
    CustomerWalletsDao,
    CrateSizeGroupsDao,
    CustomerCrateBalancesDao,
    ManufacturerCrateBalancesDao,
    CrateLedgerDao,
    SettingsDao,
    BusinessesDao,
    SystemConfigDao,
    PermissionsDao,
    RolesDao,
    RolePermissionsDao,
    RoleSettingsDao,
    UserBusinessesDao,
    InviteCodesDao,
    UserStoresDao,
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
  int get schemaVersion => 27;

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
      if (from < 13) {
        // v13 (Reebaplus master plan §2.4): data-driven roles +
        // permissions + membership. Adds seven tables — six tenant-
        // scoped synced tables and one global static-config table
        // (permissions). The cloud's matching migrations
        // (0042/0043/0044) create the same tables server-side, seed
        // permission keys, and update the `complete_onboarding` RPC
        // to seed default roles on every new business. Pre-existing
        // businesses are backfilled by cloud 0043; this local block
        // only creates empty tables and seeds the global permissions
        // rows. Tenant rows arrive via the next sync pull.
        await m.createTable(permissions);
        await m.createTable(roles);
        await m.createTable(rolePermissions);
        await m.createTable(roleSettings);
        await m.createTable(userBusinesses);
        await m.createTable(inviteCodes);
        await m.createTable(userStores);

        // Sync indexes for the six new synced tenant tables.
        for (final t in _v13NewSyncedTables) {
          await customStatement(
            'CREATE INDEX idx_${t}_business_lua ON $t (business_id, last_updated_at)',
          );
        }

        // Soft-delete indexes for the soft-deletable additions.
        for (final t in const ['roles', 'invite_codes']) {
          await customStatement(
            'CREATE INDEX idx_${t}_business_deleted ON $t (business_id, is_deleted)',
          );
        }

        // Hot-path indexes specific to the new tables.
        for (final stmt in _v13HotPathIndexStatements) {
          await customStatement(stmt);
        }

        // bump_<table>_last_updated_at triggers for the new synced
        // tenant tables. Same shape as the loop in
        // `_postCreateStatements` so fresh installs and upgrades end
        // up with identical triggers.
        for (final t in _v13NewSyncedTables) {
          await customStatement(
            'CREATE TRIGGER bump_${t}_last_updated_at '
            'AFTER UPDATE ON $t '
            'FOR EACH ROW '
            'WHEN OLD.last_updated_at IS NEW.last_updated_at '
            'BEGIN '
            "UPDATE $t SET last_updated_at = CAST(strftime('%s', 'now') AS INTEGER) WHERE id = OLD.id; "
            'END',
          );
        }

        // Seed the global permissions table. Static config — same on
        // every device and the cloud (cloud 0043 inserts the same
        // rows). Never changes at runtime.
        for (final stmt in _permissionsSeedStatements) {
          await customStatement(stmt);
        }
      }
      if (from < 14) {
        // v14 (Reebaplus pivot step 3): rename warehouses → stores
        // throughout the schema. Mirrors supabase/migrations/
        // 0045_rename_warehouses_to_stores.sql.
        //
        // SQLite ≥ 3.25 auto-updates FK definitions, trigger bodies,
        // and index column references through ALTER TABLE ... RENAME TO
        // and RENAME COLUMN. Index NAMES and trigger NAMES that embed
        // the old name (idx_warehouses_*, bump_warehouses_*,
        // idx_inventory_business_pw) must still be rebuilt explicitly.
        //
        // The v13-era `invite_codes.warehouse_id` and
        // `user_stores.warehouse_id` placeholder columns are renamed
        // here in the same pass.

        // 1. Rename the table.
        await customStatement('ALTER TABLE warehouses RENAME TO stores');

        // 2. Rename warehouse_id columns to store_id everywhere.
        //    invite_codes and user_stores are created by the v13 block via
        //    m.createTable, which builds them from the CURRENT Drift schema
        //    (already store_id). So a device upgrading FROM < 13 gets those
        //    two tables with store_id and no warehouse_id to rename — an
        //    unconditional RENAME COLUMN then throws "no such column:
        //    warehouse_id". (The v13→v14 path wasn't exercised until a real
        //    device hit it.) Guard each rename on the old column actually
        //    existing, which also makes the loop idempotent on retry.
        for (final t in const [
          'users',
          'customers',
          'inventory',
          'stock_adjustments',
          'orders',
          'order_items',
          'expenses',
          'activity_logs',
          'invite_codes',
          'user_stores',
        ]) {
          final hasOldColumn = await customSelect(
            "SELECT 1 FROM pragma_table_info('$t') WHERE name = 'warehouse_id'",
          ).get();
          if (hasOldColumn.isNotEmpty) {
            await customStatement(
              'ALTER TABLE $t RENAME COLUMN warehouse_id TO store_id',
            );
          }
        }

        // 3. Rename the sync + soft-delete indexes on the renamed table.
        await customStatement(
          'DROP INDEX IF EXISTS idx_warehouses_business_lua',
        );
        await customStatement(
          'DROP INDEX IF EXISTS idx_warehouses_business_deleted',
        );
        await customStatement(
          'CREATE INDEX idx_stores_business_lua '
          'ON stores (business_id, last_updated_at)',
        );
        await customStatement(
          'CREATE INDEX idx_stores_business_deleted '
          'ON stores (business_id, is_deleted)',
        );

        // 4. Rebuild the inventory hot-path index with the new name.
        await customStatement('DROP INDEX IF EXISTS idx_inventory_business_pw');
        await customStatement(
          'CREATE INDEX idx_inventory_business_ps '
          'ON inventory (business_id, product_id, store_id)',
        );

        // 5. Rename the bump trigger on the renamed table.
        await customStatement(
          'DROP TRIGGER IF EXISTS bump_warehouses_last_updated_at',
        );
        await customStatement(
          'CREATE TRIGGER bump_stores_last_updated_at '
          'AFTER UPDATE ON stores '
          'FOR EACH ROW '
          'WHEN OLD.last_updated_at IS NEW.last_updated_at '
          'BEGIN '
          "UPDATE stores SET last_updated_at = CAST(strftime('%s', 'now') AS INTEGER) WHERE id = OLD.id; "
          'END',
        );

        // 6. Forward any pending sync_queue rows that target the old
        //    table name. (Writes to the renamed table itself.)
        await customStatement(
          "UPDATE sync_queue SET action_type = 'stores:upsert' "
          "WHERE action_type = 'warehouses:upsert' AND status = 'pending'",
        );
        await customStatement(
          "UPDATE sync_queue SET action_type = 'stores:delete' "
          "WHERE action_type = 'warehouses:delete' AND status = 'pending'",
        );

        // 7. Rewrite pending sync_queue payload keys. Pre-v14 enqueued
        //    writes for tables that reference the renamed table carry
        //    `warehouse_id` in their JSON payload (e.g. users:upsert,
        //    customers:upsert, inventory:upsert, …). After cloud 0045
        //    deploys, those keys either get silently stripped by the
        //    push-time column whitelist (users) or hard-fail with
        //    PostgREST 42703 "column warehouse_id does not exist"
        //    (every other table). Same problem at the domain RPC layer:
        //    envelopes enqueued before v14 pass `p_warehouse_id` at the
        //    top of their payload, and the cloud's renamed RPCs expect
        //    `p_store_id`. Rewrite both shapes in place.
        //
        //    LIMITATION: this rewrites only TOP-LEVEL keys. Domain RPC
        //    envelopes for pos_record_sale_v2 / pos_inventory_delta_v2
        //    embed `warehouse_id` / `location_id` inside nested arrays
        //    (`p_items`, `p_movements`). Those nested keys are NOT
        //    rewritten — SQLite's json_set can't recurse, and the
        //    nested shape is RPC-specific. If a v13 device upgrades
        //    with pending domain envelopes that have nested
        //    `warehouse_id` keys, those envelopes will fail loudly on
        //    push and need to be replayed (or sync_queue cleared).
        //    Practical risk: low — domain envelopes drain quickly and
        //    are typically empty at app-restart time.
        await customStatement(
          "UPDATE sync_queue "
          "SET payload = json_remove("
          "  json_set(payload, '\$.store_id', json_extract(payload, '\$.warehouse_id')), "
          "  '\$.warehouse_id'"
          ") "
          "WHERE status = 'pending' "
          "  AND json_extract(payload, '\$.warehouse_id') IS NOT NULL",
        );
        await customStatement(
          "UPDATE sync_queue "
          "SET payload = json_remove("
          "  json_set(payload, '\$.p_store_id', json_extract(payload, '\$.p_warehouse_id')), "
          "  '\$.p_warehouse_id'"
          ") "
          "WHERE status = 'pending' "
          "  AND json_extract(payload, '\$.p_warehouse_id') IS NOT NULL",
        );
      }
      if (from < 15) {
        // v15 (Reebaplus pivot step 4): small renames pass. Mirrors
        // supabase/migrations/0046_pivot_small_renames.sql.
        //   (a) customers.customer_group → price_tier + CHECK
        //       tightened to ('retailer','wholesaler') + data
        //       migration                                    [done]
        //   (b) purchases → shipments (table) +
        //       stock_transactions/payment_transactions
        //       .purchase_id → .shipment_id                   [done]
        //   (c) drop purchase_items   — DEFERRED to step 25 (Track
        //       Shipments rebuild). purchase_items still backs the
        //       product-detail "Last Delivery" card via
        //       ShipmentsDao.getLastShipmentForProduct; dropping it now
        //       would orphan that feature with no replacement.
        //   (d) crate_groups → crate_size_groups — done in v16 below
        //       (its own focused session, schema v16 + cloud 0047).

        // (a) Rename customers.customer_group → price_tier. SQLite
        //     ≥ 3.25 rewrites the CHECK constraint expression that
        //     references the renamed column automatically.
        await customStatement(
          'ALTER TABLE customers RENAME COLUMN customer_group TO price_tier',
        );
        // Master plan §16/§21: Price Tier is Retailer / Wholesaler only.
        // Migrate the two legacy values off before tightening the CHECK
        // (the table rebuild below copies under the new 2-value CHECK,
        // so any 'distributor'/'walk_in' row would fail the copy).
        await customStatement(
          "UPDATE customers SET price_tier = 'wholesaler' WHERE price_tier = 'distributor'",
        );
        await customStatement(
          "UPDATE customers SET price_tier = 'retailer' WHERE price_tier = 'walk_in'",
        );
        // SQLite can't ALTER a CHECK constraint, so rebuild the table to
        // narrow it from the 4-value legacy CHECK to the 2-value one
        // (the current Drift schema's customConstraints). TableMigration
        // copies all rows 1:1 (column set is unchanged — price_tier
        // already exists after the RENAME above). Rebuilding drops the
        // table's indexes + bump trigger, so recreate them to match
        // onCreate exactly.
        await m.alterTable(TableMigration(customers));
        await customStatement(
          'CREATE INDEX idx_customers_business_lua ON customers (business_id, last_updated_at)',
        );
        await customStatement(
          'CREATE INDEX idx_customers_business_deleted ON customers (business_id, is_deleted)',
        );
        await customStatement(
          'CREATE INDEX idx_customers_business_phone ON customers (business_id, phone)',
        );
        await customStatement(
          'CREATE TRIGGER bump_customers_last_updated_at '
          'AFTER UPDATE ON customers '
          'FOR EACH ROW '
          'WHEN OLD.last_updated_at IS NEW.last_updated_at '
          'BEGIN '
          "UPDATE customers SET last_updated_at = CAST(strftime('%s', 'now') AS INTEGER) WHERE id = OLD.id; "
          'END',
        );
        // Rewrite pending sync_queue payloads. Table-upsert envelopes
        // carry top-level $.customer_group; the pos_create_customer
        // domain envelope carries $.p_customer_group. Cloud 0046
        // renames both the column and the RPC parameter, so pre-v15
        // queued writes must forward their keys or they hard-fail with
        // PostgREST 42703 (every other table) on push.
        await customStatement(
          "UPDATE sync_queue "
          "SET payload = json_remove("
          "  json_set(payload, '\$.price_tier', json_extract(payload, '\$.customer_group')), "
          "  '\$.customer_group'"
          ") "
          "WHERE status = 'pending' "
          "  AND json_extract(payload, '\$.customer_group') IS NOT NULL",
        );
        await customStatement(
          "UPDATE sync_queue "
          "SET payload = json_remove("
          "  json_set(payload, '\$.p_price_tier', json_extract(payload, '\$.p_customer_group')), "
          "  '\$.p_customer_group'"
          ") "
          "WHERE status = 'pending' "
          "  AND json_extract(payload, '\$.p_customer_group') IS NOT NULL",
        );

        // (b) Rename purchases → shipments. SQLite ≥ 3.25 auto-updates
        //     the FK target on referencing tables (purchase_items,
        //     stock_transactions, payment_transactions) through the
        //     table rename. The FK *column* names on the two permanent
        //     ledger tables are renamed to shipment_id for consistency;
        //     purchase_items keeps purchase_id (that table is slated for
        //     removal in step 25).
        await customStatement('ALTER TABLE purchases RENAME TO shipments');
        await customStatement(
          'ALTER TABLE stock_transactions RENAME COLUMN purchase_id TO shipment_id',
        );
        await customStatement(
          'ALTER TABLE payment_transactions RENAME COLUMN purchase_id TO shipment_id',
        );
        // Forward pending sync_queue rows targeting the old table name.
        await customStatement(
          "UPDATE sync_queue SET action_type = 'shipments:upsert' "
          "WHERE action_type = 'purchases:upsert' AND status = 'pending'",
        );
        await customStatement(
          "UPDATE sync_queue SET action_type = 'shipments:delete' "
          "WHERE action_type = 'purchases:delete' AND status = 'pending'",
        );
        // Rewrite pending payload keys: stock_transactions /
        // payment_transactions upserts carry top-level $.purchase_id;
        // cloud 0046 renames the column, so forward it or the push
        // 42703s. Scoped to those two tables only — purchase_items
        // KEEPS its purchase_id column, so its payloads must not be
        // rewritten.
        await customStatement(
          "UPDATE sync_queue "
          "SET payload = json_remove("
          "  json_set(payload, '\$.shipment_id', json_extract(payload, '\$.purchase_id')), "
          "  '\$.purchase_id'"
          ") "
          "WHERE status = 'pending' "
          "  AND action_type IN ('stock_transactions:upsert', 'payment_transactions:upsert') "
          "  AND json_extract(payload, '\$.purchase_id') IS NOT NULL",
        );
      }
      if (from < 16) {
        // v16 (Reebaplus pivot: Crate Size Groups). Mirrors
        // supabase/migrations/0047_crate_size_groups.sql.
        //   - crate_groups → crate_size_groups (table + Drift classes)
        //   - crate_group_id → crate_size_group_id on the 6 FK tables
        //     (suppliers, products, customer_crate_balances,
        //     manufacturer_crate_balances, crate_ledger,
        //     pending_crate_returns)
        //   - size INT (12/20/24) → crate_size_label TEXT
        //     (big/medium/small) — the numeric size was display-only and
        //     fed no crate math; the new column name matches the cloud's
        //     existing crate_size_label text column so the value syncs.

        // 1. Rename the table. SQLite ≥ 3.25 auto-rewrites the FK *target*
        //    table-name references on the 6 dependents through this rename.
        await customStatement(
          'ALTER TABLE crate_groups RENAME TO crate_size_groups',
        );

        // 2. Rename the FK *column* on each dependent. RENAME COLUMN
        //    auto-updates that table's own indexes / triggers / CHECK / FK
        //    that reference the column (so crate_ledger's immutability
        //    trigger and idx_crate_ledger_owner_group follow automatically).
        for (final t in const [
          'suppliers',
          'products',
          'customer_crate_balances',
          'manufacturer_crate_balances',
          'crate_ledger',
          'pending_crate_returns',
        ]) {
          await customStatement(
            'ALTER TABLE $t RENAME COLUMN crate_group_id TO crate_size_group_id',
          );
        }

        // 3. Convert size INT → crate_size_label TEXT. SQLite can't change
        //    a column's type or CHECK in place, so rebuild the (now
        //    renamed) table from the current Drift schema. The
        //    columnTransformer derives the text category from the old
        //    numeric size (12→small, 20→medium, 24→big; any other value,
        //    incl. NULL, → medium). Rebuilding drops the table's indexes +
        //    bump trigger, so recreate them under the new table name to
        //    match onCreate exactly. (FK enforcement is OFF during
        //    onUpgrade, so the dependents' FKs survive the rebuild.)
        await m.alterTable(
          TableMigration(
            crateSizeGroups,
            columnTransformer: {
              crateSizeGroups.crateSizeLabel: const CustomExpression<String>(
                "CASE size "
                "WHEN 12 THEN 'small' "
                "WHEN 20 THEN 'medium' "
                "WHEN 24 THEN 'big' "
                "ELSE 'medium' END",
              ),
            },
          ),
        );
        await customStatement(
          'CREATE INDEX idx_crate_size_groups_business_lua ON crate_size_groups (business_id, last_updated_at)',
        );
        await customStatement(
          'CREATE INDEX idx_crate_size_groups_business_deleted ON crate_size_groups (business_id, is_deleted)',
        );
        await customStatement(
          'CREATE TRIGGER bump_crate_size_groups_last_updated_at '
          'AFTER UPDATE ON crate_size_groups '
          'FOR EACH ROW '
          'WHEN OLD.last_updated_at IS NEW.last_updated_at '
          'BEGIN '
          "UPDATE crate_size_groups SET last_updated_at = CAST(strftime('%s', 'now') AS INTEGER) WHERE id = OLD.id; "
          'END',
        );

        // 4. Forward pending sync_queue rows: table action types + payload
        //    keys. Cloud 0047 renames the table, the FK columns, and the
        //    RPC parameter p_crate_group_id, so pre-v16 queued writes must
        //    forward their keys or they hard-fail with PostgREST 42703.
        await customStatement(
          "UPDATE sync_queue SET action_type = 'crate_size_groups:upsert' "
          "WHERE action_type = 'crate_groups:upsert' AND status = 'pending'",
        );
        await customStatement(
          "UPDATE sync_queue SET action_type = 'crate_size_groups:delete' "
          "WHERE action_type = 'crate_groups:delete' AND status = 'pending'",
        );
        // Table-upsert envelopes (products, suppliers, the two crate-balance
        // caches, pending_crate_returns) carry top-level $.crate_group_id.
        await customStatement(
          "UPDATE sync_queue "
          "SET payload = json_remove("
          "  json_set(payload, '\$.crate_size_group_id', json_extract(payload, '\$.crate_group_id')), "
          "  '\$.crate_group_id'"
          ") "
          "WHERE status = 'pending' "
          "  AND json_extract(payload, '\$.crate_group_id') IS NOT NULL",
        );
        // Domain envelopes (pos_create_product, pos_record_crate_return)
        // carry top-level $.p_crate_group_id.
        await customStatement(
          "UPDATE sync_queue "
          "SET payload = json_remove("
          "  json_set(payload, '\$.p_crate_size_group_id', json_extract(payload, '\$.p_crate_group_id')), "
          "  '\$.p_crate_group_id'"
          ") "
          "WHERE status = 'pending' "
          "  AND json_extract(payload, '\$.p_crate_group_id') IS NOT NULL",
        );
      }
      if (from < 17) {
        // v17 (Reebaplus pivot step 13: Cart). Mirrors
        // supabase/migrations/0053_cart_step13.sql.
        //   - products.allow_fractional_sales: gates the ±0.5 qty chips in
        //     the Edit Quantity modal (§13.2). Defaults false.
        //   - saved_carts.cashier_id / expires_at: per-cashier scoping and
        //     24h auto-expire for Save Cart / Recall (§13.5). Both nullable
        //     so pre-v17 saved carts survive (treated as un-expiring,
        //     un-scoped legacy rows until overwritten).
        await m.addColumn(products, products.allowFractionalSales);
        await m.addColumn(savedCarts, savedCarts.cashierId);
        await m.addColumn(savedCarts, savedCarts.expiresAt);
      }
      if (from < 18) {
        // v18 (Reebaplus pivot step 14: product price columns). Mirrors
        // supabase/migrations/0055_product_price_columns.sql.
        //   - Drop the four legacy price columns (retail / bulk breaker /
        //     distributor / selling). Products now hold three prices:
        //     buying (already present), retailer, wholesaler.
        //   - Salvage-map the data (decision Q4 revised 2026-05-30): copy
        //     retail → retailer and coalesce(distributor, retail) →
        //     wholesaler. selling + bulk breaker have no new equivalent and
        //     are dropped. No manual re-entry needed.
        //   - Add nullable `barcode` (UI lands with pivot step 30).
        //
        // Raw DROP COLUMN (not a TableMigration rebuild) keeps this block
        // decoupled from the current Drift schema and leaves the products
        // indexes / bump_products_version trigger untouched (none of them
        // reference a price column). SQLite 3.35+ supports DROP COLUMN;
        // bundled via sqlite3_flutter_libs. Same approach as the v12 users
        // column drops above.

        // 1. Add the new columns (they exist in the current Drift schema).
        await m.addColumn(products, products.retailerPriceKobo);
        await m.addColumn(products, products.wholesalerPriceKobo);
        await m.addColumn(products, products.barcode);

        // 2. Carry the old prices over before dropping them.
        await customStatement(
          'UPDATE products SET '
          'retailer_price_kobo = retail_price_kobo, '
          'wholesaler_price_kobo = COALESCE(distributor_price_kobo, retail_price_kobo)',
        );

        // 3. Drop the legacy columns. Try/catch each so a half-completed
        //    earlier attempt re-runs cleanly (SQLite has no
        //    DROP COLUMN IF EXISTS).
        for (final col in const [
          'retail_price_kobo',
          'bulk_breaker_price_kobo',
          'distributor_price_kobo',
          'selling_price_kobo',
        ]) {
          try {
            await customStatement('ALTER TABLE products DROP COLUMN $col');
          } catch (_) {/* already gone */}
        }

        // 4. Forward pending sync_queue payloads so a push after the cloud
        //    0055 deploy doesn't 42703 on the now-gone columns. Cloud 0055
        //    renames retail→retailer and distributor→wholesaler and drops
        //    selling / bulk breaker on both the products table and the
        //    pos_create_product_v2 RPC params.
        //    (a) per-table products upserts carry top-level snake_case cols.
        await customStatement(
          "UPDATE sync_queue "
          "SET payload = json_remove("
          "  json_set("
          "    json_set(payload, '\$.retailer_price_kobo', "
          "      COALESCE(json_extract(payload, '\$.retail_price_kobo'), 0)), "
          "    '\$.wholesaler_price_kobo', "
          "      COALESCE(json_extract(payload, '\$.distributor_price_kobo'), json_extract(payload, '\$.retail_price_kobo'), 0)), "
          "  '\$.retail_price_kobo', '\$.bulk_breaker_price_kobo', '\$.distributor_price_kobo', '\$.selling_price_kobo'"
          ") "
          "WHERE status = 'pending' AND action_type = 'products:upsert' "
          "  AND json_extract(payload, '\$.retail_price_kobo') IS NOT NULL",
        );
        //    (b) pos_create_product_v2 domain envelopes carry p_-prefixed args.
        await customStatement(
          "UPDATE sync_queue "
          "SET payload = json_remove("
          "  json_set("
          "    json_set(payload, '\$.p_retailer_price_kobo', "
          "      COALESCE(json_extract(payload, '\$.p_retail_price_kobo'), 0)), "
          "    '\$.p_wholesaler_price_kobo', "
          "      COALESCE(json_extract(payload, '\$.p_distributor_price_kobo'), json_extract(payload, '\$.p_retail_price_kobo'), 0)), "
          "  '\$.p_retail_price_kobo', '\$.p_bulk_breaker_price_kobo', '\$.p_distributor_price_kobo', '\$.p_selling_price_kobo'"
          ") "
          "WHERE status = 'pending' AND action_type = 'domain:pos_create_product_v2' "
          "  AND json_extract(payload, '\$.p_retail_price_kobo') IS NOT NULL",
        );
      }
      if (from < 19) {
        // v19 (Reebaplus pivot step 15, master plan §16.5): optional single
        // product expiry date. Mirrors supabase/migrations/0056_product_expiry.sql.
        // One nullable column, no rebuild and no data backfill.
        await m.addColumn(products, products.expiryDate);
      }
      if (from < 20) {
        // v20 (Reebaplus master plan §23: Funds Register). Three synced
        // tenant tables. Mirrors supabase/migrations/0057_funds_register.sql.
        // Same index/trigger shapes as the `_postCreateStatements` loops so a
        // fresh install (onCreate) and an upgrade end up identical.
        const newSynced = ['funds_accounts', 'fund_days', 'fund_transactions'];
        await m.createTable(fundsAccounts);
        await m.createTable(fundDays);
        await m.createTable(fundTransactions);

        for (final t in newSynced) {
          await customStatement(
            'CREATE INDEX idx_${t}_business_lua ON $t (business_id, last_updated_at)',
          );
        }
        // funds_accounts is soft-deletable.
        await customStatement(
          'CREATE INDEX idx_funds_accounts_business_deleted ON funds_accounts (business_id, is_deleted)',
        );
        // Per-feature hot-path indexes (gate lookup + balance sums).
        await customStatement(
          'CREATE INDEX idx_funds_accounts_store ON funds_accounts (store_id)',
        );
        await customStatement(
          'CREATE INDEX idx_fund_days_store_date ON fund_days (store_id, business_date)',
        );
        await customStatement(
          'CREATE INDEX idx_fund_txn_account_date ON fund_transactions (funds_account_id, business_date)',
        );

        for (final t in newSynced) {
          await customStatement(
            'CREATE TRIGGER bump_${t}_last_updated_at '
            'AFTER UPDATE ON $t '
            'FOR EACH ROW '
            'WHEN OLD.last_updated_at IS NEW.last_updated_at '
            'BEGIN '
            "UPDATE $t SET last_updated_at = CAST(strftime('%s', 'now') AS INTEGER) WHERE id = OLD.id; "
            'END',
          );
        }

        // Append-only enforcement on the fund_transactions ledger — same
        // immutable column set as the `_ledgerTables` entry above.
        await customStatement(
          'CREATE TRIGGER fund_transactions_immutable '
          'BEFORE UPDATE ON fund_transactions '
          'FOR EACH ROW '
          'WHEN NEW.id IS NOT OLD.id OR NEW.business_id IS NOT OLD.business_id '
          'OR NEW.funds_account_id IS NOT OLD.funds_account_id '
          'OR NEW.store_id IS NOT OLD.store_id '
          'OR NEW.business_date IS NOT OLD.business_date '
          'OR NEW.type IS NOT OLD.type OR NEW.amount_kobo IS NOT OLD.amount_kobo '
          'OR NEW.signed_amount_kobo IS NOT OLD.signed_amount_kobo '
          'OR NEW.reference_type IS NOT OLD.reference_type '
          'OR NEW.order_id IS NOT OLD.order_id '
          'OR NEW.payment_id IS NOT OLD.payment_id '
          'OR NEW.performed_by IS NOT OLD.performed_by '
          'OR NEW.created_at IS NOT OLD.created_at '
          'BEGIN '
          "SELECT RAISE(ABORT, 'append-only: only voided_at/voided_by/void_reason may change'); "
          'END',
        );
        await customStatement(
          'CREATE TRIGGER fund_transactions_no_delete '
          'BEFORE DELETE ON fund_transactions '
          'BEGIN '
          "SELECT RAISE(ABORT, 'append-only: deletion not permitted'); "
          'END',
        );
      }
      if (from < 21) {
        // v21 (Funds Register): optional account number / terminal id on POS
        // and Bank accounts. Mirrors supabase/migrations/0059_funds_account_number.sql.
        //
        // Idempotency guard: for a device coming from < 20, the `from < 20` block
        // above already created funds_accounts via `m.createTable(fundsAccounts)`,
        // which builds the table from the CURRENT schema — so account_number is
        // already present and a blind addColumn would throw "duplicate column".
        // Only add it for a device genuinely at v20 (funds_accounts created
        // before this column existed). Covered by migration_upgrade_test.dart.
        final info =
            await customSelect('PRAGMA table_info(funds_accounts)').get();
        final hasAccountNumber =
            info.any((r) => r.read<String>('name') == 'account_number');
        if (!hasAccountNumber) {
          await m.addColumn(fundsAccounts, fundsAccounts.accountNumber);
        }
      }
      if (from < 22) {
        // v22 (§18.4): add the customers.set_debt_limit permission to the local
        // catalog so the Roles & Permissions settings screen lists it. The
        // actual role grants arrive from the cloud via pull (the CEO/Manager
        // backfill in supabase/migrations/0061). Idempotent — key is the PK.
        await customStatement(
          "INSERT OR IGNORE INTO permissions (key, description, category) "
          "VALUES ('customers.set_debt_limit', "
          "'Set a customer''s debt limit', 'Customers')",
        );
      }
      if (from < 23) {
        // v23 (§18 Add Funds → Funds Register): a wallet top-up now credits the
        // chosen funds account, so fund_transactions.reference_type must allow
        // 'topup'. SQLite can't ALTER a CHECK in place — rebuild the table from
        // the current Drift schema (new CHECK included) and copy every row.
        // alterTable preserves the table's indexes and the bump/append-only
        // triggers (re-creates them from sqlite_master), so — unlike the v16
        // block which renamed the table — nothing here needs manual recreation.
        // Mirrors supabase/migrations/0063_fund_transactions_topup_reference_type.sql.
        await m.alterTable(TableMigration(fundTransactions));
      }
      if (from < 24) {
        // v24 (§16.5): widen products.unit so non-bottle units (Can, PET,
        // Sachet, Keg, Box, Tin, …) can be saved. The Add / Edit Product
        // dropdown offered units the old CHECK rejected, so creating a
        // non-bottle product silently failed the insert and the product never
        // reached inventory. SQLite can't ALTER a CHECK in place — rebuild the
        // table from the current Drift schema (new CHECK included) and copy
        // every row. alterTable preserves the table's indexes and the
        // bump_products_version trigger (re-creates them from sqlite_master),
        // so nothing here needs manual recreation. Mirrors
        // supabase/migrations/0065_widen_product_unit_check.sql.
        await m.alterTable(TableMigration(products));
      }
      if (from < 25) {
        // v25 (Ring 0 #2, §24.4/§26.2): activity_logs generic shape +
        // notifications.severity. Mirrors supabase/migrations/0066.
        //
        // Drop the append-only triggers FIRST: alterTable re-creates a table's
        // triggers from sqlite_master, and the old `activity_logs_immutable`
        // trigger references the per-entity FK columns we're about to drop, so
        // it would fail to re-create. Rebuild activity_logs (drop the 6 FK
        // columns + the "<=1 set" CHECK, add entity_type/entity_id/before_json/
        // after_json, keep store_id) backfilling entity_type/entity_id from
        // whichever FK was set, then re-create the triggers from the NEW
        // immutable column set.
        // Each rebuild is guarded on the OLD shape still being present, so the
        // block is idempotent — safe when a DB is already partly on the new
        // shape (e.g. the revert-then-re-upgrade migration tests, which revert
        // only specific deltas and leave activity_logs/notifications current).
        Future<bool> hasColumn(String table, String col) async {
          final rows = await customSelect('PRAGMA table_info($table)').get();
          return rows.any((r) => r.read<String>('name') == col);
        }

        if (await hasColumn('activity_logs', 'order_id')) {
          await customStatement(
              'DROP TRIGGER IF EXISTS activity_logs_immutable');
          await customStatement(
              'DROP TRIGGER IF EXISTS activity_logs_no_delete');
          await m.alterTable(TableMigration(
            activityLogs,
            columnTransformer: {
              activityLogs.entityType: const CustomExpression<String>(
                "CASE "
                "WHEN order_id IS NOT NULL THEN 'order' "
                "WHEN product_id IS NOT NULL THEN 'product' "
                "WHEN customer_id IS NOT NULL THEN 'customer' "
                "WHEN expense_id IS NOT NULL THEN 'expense' "
                "WHEN delivery_id IS NOT NULL THEN 'delivery' "
                "WHEN wallet_txn_id IS NOT NULL THEN 'wallet_transaction' "
                "END",
              ),
              activityLogs.entityId: const CustomExpression<String>(
                "COALESCE(order_id, product_id, customer_id, expense_id, "
                "delivery_id, wallet_txn_id)",
              ),
            },
            newColumns: [
              activityLogs.entityType,
              activityLogs.entityId,
              activityLogs.beforeJson,
              activityLogs.afterJson,
            ],
          ));
          for (final stmt in _ledgerTriggerStatements(
            _ledgerTables.firstWhere((l) => l.table == 'activity_logs'),
          )) {
            await customStatement(stmt);
          }
        }
        // notifications: add severity (default 'info') + its CHECK via rebuild.
        if (!await hasColumn('notifications', 'severity')) {
          await m.alterTable(TableMigration(
            notifications,
            newColumns: [notifications.severity],
          ));
        }
      }
      if (from < 26) {
        // v26 (Sync Issues access): add the sync.view permission to the local
        // catalog so the Roles & Permissions list + the Sync Issues access
        // screen show it. The CEO always has Sync Issues access via a role
        // check in code; other roles get it through the per-role toggle (a
        // synced role_permissions grant). Idempotent — key is the PK.
        await customStatement(
          "INSERT OR IGNORE INTO permissions (key, description, category) "
          "VALUES ('sync.view', 'View sync issues', 'System')",
        );
      }
      if (from < 27) {
        // v27 (master plan §23.6 Close Day): the per-account reconciliation
        // snapshot table. One new synced tenant table. Mirrors
        // supabase/migrations/0068_fund_day_closings.sql. Same index/trigger
        // shapes as the `_postCreateStatements` loops so a fresh install
        // (onCreate) and an upgrade end up identical.
        //
        // Idempotency guard (like the v21 block): the revert-then-re-upgrade
        // migration tests revert only specific deltas, so a DB stepped back to
        // < 27 may still carry fund_day_closings; a blind createTable would
        // throw "table already exists". Only build it when genuinely absent.
        final exists = await customSelect(
          "SELECT 1 FROM sqlite_master WHERE type='table' "
          "AND name='fund_day_closings'",
        ).get();
        if (exists.isEmpty) {
          await m.createTable(fundDayClosings);
          await customStatement(
            'CREATE INDEX idx_fund_day_closings_business_lua '
            'ON fund_day_closings (business_id, last_updated_at)',
          );
          await customStatement(
            'CREATE INDEX idx_fund_day_closings_store_date '
            'ON fund_day_closings (store_id, business_date)',
          );
          await customStatement(
            'CREATE TRIGGER bump_fund_day_closings_last_updated_at '
            'AFTER UPDATE ON fund_day_closings '
            'FOR EACH ROW '
            'WHEN OLD.last_updated_at IS NEW.last_updated_at '
            'BEGIN '
            "UPDATE fund_day_closings SET last_updated_at = CAST(strftime('%s', 'now') AS INTEGER) WHERE id = OLD.id; "
            'END',
          );
        }
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
  'stores',
  'manufacturers',
  'crate_size_groups',
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
  'shipments',
  'purchase_items',
  'drivers',
  'delivery_receipts',
  'saved_carts',
  'pending_crate_returns',
  'payment_transactions',
  // v20 (master plan §23 Funds Register).
  'funds_accounts',
  'fund_days',
  'fund_transactions',
  // v27 (master plan §23.6 Close Day reconciliation).
  'fund_day_closings',
  'expense_categories',
  'expenses',
  'activity_logs',
  'notifications',
  'settings',
  // v13 (master plan §2.4). `permissions` is intentionally absent —
  // it's global static config, identical on every device and seeded
  // by migration on both client and cloud.
  'roles',
  'role_permissions',
  'role_settings',
  'user_businesses',
  'invite_codes',
  'user_stores',
];

// Subset of `_syncedTenantTables` introduced in schema v13. Used by
// the v13 upgrade block to create the matching indexes + bump triggers
// for devices upgrading from v12. Fresh installs get the same shape
// via the global `_syncedTenantTables` loop in `_postCreateStatements`.
const List<String> _v13NewSyncedTables = [
  'roles',
  'role_permissions',
  'role_settings',
  'user_businesses',
  'invite_codes',
  'user_stores',
];

// Hot-path indexes for the v13 tables. Applied during both onCreate
// (via `_postCreateStatements`) and the v13 upgrade block.
const List<String> _v13HotPathIndexStatements = [
  'CREATE INDEX idx_role_permissions_role ON role_permissions (role_id)',
  'CREATE INDEX idx_role_settings_role ON role_settings (role_id)',
  'CREATE INDEX idx_user_businesses_user ON user_businesses (user_id)',
  'CREATE INDEX idx_user_stores_user ON user_stores (user_id)',
  // Only one active code per `code` value at a time. Used codes and
  // revoked/deleted codes drop out so the same code value could in
  // principle be reused (the 8-char alphanumeric keyspace is large
  // enough that this never matters in practice).
  'CREATE UNIQUE INDEX uq_invite_codes_active ON invite_codes (code) '
      'WHERE used_at IS NULL AND revoked_at IS NULL AND is_deleted = 0',
];

// Default permission keys seeded into the global `permissions` table.
// Identical on every device and on the cloud (mirror this list in
// supabase/migrations/0043_seed_permissions_and_backfill_businesses.sql).
// Each row: (key, description, category). Category groups toggles in
// the CEO Settings > Roles & Permissions sub-page. 30 keys total.
const List<List<String>> _defaultPermissionRows = [
  // Sales
  ['sales.make', 'Make a sale', 'Sales'],
  ['sales.cancel', 'Cancel a sale', 'Sales'],
  ['sales.discount.give', 'Give a discount on a sale', 'Sales'],
  // Products
  ['products.add', 'Add a new product', 'Products'],
  ['products.edit_price', 'Edit product prices', 'Products'],
  ['products.edit_buying_price', 'Edit product buying price', 'Products'],
  ['products.delete', 'Delete a product', 'Products'],
  // Stock
  ['stock.add', 'Add stock to existing products', 'Stock'],
  ['stock.view', 'View stock levels', 'Stock'],
  ['stock.adjust', 'Adjust stock quantities (damages, theft, count)', 'Stock'],
  // Expenses
  ['expenses.create', 'Record a new expense', 'Expenses'],
  ['expenses.approve', 'Approve or reject pending expenses', 'Expenses'],
  // Reports
  ['reports.see_sales', 'See sales reports', 'Reports'],
  ['reports.see_profit', 'See profit reports', 'Reports'],
  ['reports.see_cost_prices', 'See buying prices in reports', 'Reports'],
  ['reports.see_expenses', 'See expense reports', 'Reports'],
  // Customers
  ['customers.add', 'Add a new customer', 'Customers'],
  ['customers.update', 'Update customer details', 'Customers'],
  ['customers.delete', 'Soft-delete a customer', 'Customers'],
  ['customers.wallet.update', 'Add funds to customer wallets', 'Customers'],
  ['customers.set_debt_limit', 'Set a customer\'s debt limit', 'Customers'],
  // Suppliers / Shipments
  ['suppliers.manage', 'Manage suppliers and payments', 'Suppliers'],
  ['shipments.manage', 'Manage incoming shipments', 'Suppliers'],
  // Staff
  ['staff.invite', 'Generate staff invite codes', 'Staff'],
  ['staff.suspend', 'Suspend or reactivate staff', 'Staff'],
  ['staff.change_role', 'Change a staff member\'s role', 'Staff'],
  // System
  ['activity_logs.view', 'View activity logs', 'System'],
  ['sync.view', 'View sync issues', 'System'],
  ['settings.manage', 'Manage business settings', 'System'],
  // Funds Register
  ['funds.open_day', 'Open the day in Funds Register', 'Funds'],
  ['funds.close_day', 'Close the day in Funds Register', 'Funds'],
  ['funds.view', 'View Funds Register balances', 'Funds'],
];

// SQL statements that seed the global permissions table. Built once
// at app start (top-level final). Used by both `_postCreateStatements`
// (fresh installs) and the v13 upgrade block.
final List<String> _permissionsSeedStatements = _defaultPermissionRows
    .map(
      (row) => "INSERT INTO permissions (key, description, category) "
          "VALUES ('${_sqlEscape(row[0])}', '${_sqlEscape(row[1])}', '${_sqlEscape(row[2])}')",
    )
    .toList(growable: false);

String _sqlEscape(String s) => s.replaceAll("'", "''");

// 0033_staff_lifecycle_hard_delete dropped soft-delete on users and
// business_members — both the columns and their (business_id, is_deleted)
// indexes are gone. Fire is now a hard-delete of the membership row; the
// users row persists for historical FK reference. Keep the other entries
// intact: products/customers/etc. still soft-delete normally.
const List<String> _softDeletableTables = [
  'stores',
  'manufacturers',
  'crate_size_groups',
  'categories',
  'suppliers',
  'products',
  'price_lists',
  'customers',
  'customer_wallets',
  'drivers',
  'expense_categories',
  'expenses',
  // v13 additions.
  'roles',
  'invite_codes',
  // v20 (Funds Register). Accounts soft-delete; fund_days / fund_transactions
  // are not soft-deletable.
  'funds_accounts',
];

class _LedgerImmutability {
  final String table;
  final List<String> immutableColumns;
  const _LedgerImmutability(this.table, this.immutableColumns);
}

/// The two append-only triggers for a ledger table: an immutable-columns guard
/// (only voided_at/voided_by/void_reason may change) and a no-delete guard.
/// Shared by `_postCreateStatements` and the v25 activity_logs rebuild so the
/// trigger SQL can't drift between the two sites.
List<String> _ledgerTriggerStatements(_LedgerImmutability ledger) {
  final whenClause = ledger.immutableColumns
      .map((c) => 'NEW.$c IS NOT OLD.$c')
      .join(' OR ');
  return [
    'CREATE TRIGGER ${ledger.table}_immutable '
    'BEFORE UPDATE ON ${ledger.table} '
    'FOR EACH ROW '
    'WHEN $whenClause '
    'BEGIN '
    "SELECT RAISE(ABORT, 'append-only: only voided_at/voided_by/void_reason may change'); "
    'END',
    'CREATE TRIGGER ${ledger.table}_no_delete '
    'BEFORE DELETE ON ${ledger.table} '
    'BEGIN '
    "SELECT RAISE(ABORT, 'append-only: deletion not permitted'); "
    'END',
  ];
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
    'shipment_id',
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
    'shipment_id',
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
    'entity_type',
    'entity_id',
    'before_json',
    'after_json',
    'store_id',
    'created_at',
  ]),
  _LedgerImmutability('crate_ledger', [
    'id',
    'business_id',
    'customer_id',
    'manufacturer_id',
    'crate_size_group_id',
    'quantity_delta',
    'movement_type',
    'reference_order_id',
    'reference_return_id',
    'performed_by',
    'created_at',
  ]),
  // v20 (Funds Register). Everything except the void columns + last_updated_at.
  _LedgerImmutability('fund_transactions', [
    'id',
    'business_id',
    'funds_account_id',
    'store_id',
    'business_date',
    'type',
    'amount_kobo',
    'signed_amount_kobo',
    'reference_type',
    'order_id',
    'payment_id',
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
    'CREATE INDEX idx_crate_ledger_owner_group ON crate_ledger (business_id, customer_id, manufacturer_id, crate_size_group_id, created_at)',
    'CREATE INDEX idx_inventory_business_ps ON inventory (business_id, product_id, store_id)',
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
    // v20 (Funds Register) — gate lookup + per-account/day balance sums.
    'CREATE INDEX idx_funds_accounts_store ON funds_accounts (store_id)',
    'CREATE INDEX idx_fund_days_store_date ON fund_days (store_id, business_date)',
    'CREATE INDEX idx_fund_txn_account_date ON fund_transactions (funds_account_id, business_date)',
    // v27 (Close Day) — read closings per store/day for the reconciliation report.
    'CREATE INDEX idx_fund_day_closings_store_date ON fund_day_closings (store_id, business_date)',
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
    stmts.addAll(_ledgerTriggerStatements(ledger));
  }

  // -- v13 (master plan §2.4) hot-path indexes for the new tables.
  // The (business_id, last_updated_at) and (business_id, is_deleted)
  // indexes for the v13 synced tables are already created by the
  // loops above (the tables are in `_syncedTenantTables` and
  // `_softDeletableTables`). These are the per-feature indexes that
  // those loops don't cover.
  stmts.addAll(_v13HotPathIndexStatements);

  // -- v13 seed: global `permissions` table. Static config, identical
  // on every device and the cloud (cloud 0043 inserts the same rows).
  // No sync involvement.
  stmts.addAll(_permissionsSeedStatements);

  return stmts;
}
