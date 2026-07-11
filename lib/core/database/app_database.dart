import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:flutter/foundation.dart';
import 'package:reebaplus_pos/core/database/daos.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/core/diagnostics/schema_audit.dart';
import 'package:reebaplus_pos/core/services/first_load_marker_service.dart';
import 'package:reebaplus_pos/core/services/sync_cursor_reset_service.dart';
export 'daos.dart';

part 'app_database.g.dart';
part 'sync_registry.dart';

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
  // Mirrors public.businesses.owner_id — the auth_user_id of the business
  // creator. Set locally during onboarding and backfilled from cloud on pull.
  // Used to prevent any CEO (including added ones) from changing the owner's role.
  TextColumn get ownerId => text().nullable()();
  // Opt-in flag for empty-crate / returnable-case tracking. Only meaningful
  // when isCrateBusiness(type) is true (Bar / Beverage distributor). Default
  // true so existing tenants keep their crate features after the migration.
  // Set explicitly at onboarding and editable via CEO Settings → Business Info.
  BoolColumn get tracksEmptyCrates =>
      boolean().withDefault(const Constant(true))();
  // Subscription / access gating (master plan §32). Set by the web admin
  // console in the cloud; CLOUD-AUTHORITATIVE / APP-READ-ONLY — these columns
  // are deliberately omitted from the businesses push whitelist
  // (_pushableColumns in supabase_sync_service.dart), so the device can never
  // push them. Default 'trial' is a local-only grace value for a not-yet-synced
  // row; the first pull replaces it with the cloud truth. See migration
  // 0101_business_subscription.sql.
  TextColumn get subscriptionStatus =>
      text().withDefault(const Constant('trial'))();
  TextColumn get subscriptionPlan => text().nullable()();
  DateTimeColumn get trialEndsAt => dateTime().nullable()();
  DateTimeColumn get currentPeriodEnd => dateTime().nullable()();

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
  TextColumn get phone => text().nullable()();
  TextColumn get address => text().nullable()();
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
  // Supplier bank details + notes (§21.5). All nullable — no backfill.
  TextColumn get bankAccountName => text().nullable()();
  TextColumn get bankAccountNumber => text().nullable()();
  TextColumn get bankName => text().nullable()();
  TextColumn get notes => text().nullable()();
  BoolColumn get isDeleted => boolean().withDefault(const Constant(false))();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get lastUpdatedAt =>
      dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {id};
}

/// Append-only supplier ledger (§21.10). Mirrors [WalletTransactions] but
/// inverted: an `invoice` is a debit (we owe the supplier, shown red/negative),
/// a `payment_*` is a credit (we paid them). Balance = SUM(signed_amount_kobo);
/// negative = we owe. Entries are never edited or hard-deleted — corrections are
/// a `void` compensating entry. Payment proof is a local receipt file path OR a
/// reference/note (one is required at the service/UI boundary). Receipts do not
/// cross-sync (local path, like expenses); everything else syncs.
@DataClassName('SupplierLedgerEntryData')
class SupplierLedgerEntries extends Table {
  TextColumn get id => text().clientDefault(() => UuidV7.generate())();
  TextColumn get businessId => text().references(Businesses, #id)();
  TextColumn get supplierId => text().references(Suppliers, #id)();
  // §21.11 — the store this entry was recorded against. Nullable: legacy entries
  // (pre-v47) and onboarding-era writes carry none → shown only in "All Stores".
  TextColumn get storeId => text().nullable().references(Stores, #id)();
  TextColumn get type => text()(); // credit | debit
  IntColumn get amountKobo => integer()();
  IntColumn get signedAmountKobo => integer()();
  TextColumn get referenceType => text()();
  TextColumn get paymentMethod => text().nullable()(); // payments only
  TextColumn get receiptPath => text().nullable()(); // local file path (proof)
  TextColumn get referenceNote =>
      text().nullable()(); // bank ref / cheque no / note (proof)
  // Goods-received date (invoice) | paid-on date (payment).
  DateTimeColumn get activityDate => dateTime()();
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
    "CHECK (reference_type IN ('invoice','payment_cash','payment_transfer',"
        "'payment_pos','payment_other','void'))",
    "CHECK ((type = 'credit' AND signed_amount_kobo >= 0) OR "
        "(type = 'debit' AND signed_amount_kobo <= 0))",
  ];
}

/// Append-only ledger of empty-crate movements between the store and a SUPPLIER
/// (§3.13). The supplier-side mirror of the customer's [CrateLedger]: a customer
/// owes US empties (tracked in [CustomerCrateBalances]); here WE owe the SUPPLIER
/// empties for the full crates they delivered. `quantity_delta` is +N on a
/// `received` row (full crates arrived → we now owe N empties) and −N on a
/// `returned` row (empties handed back). `deposit_paid_kobo` is the refundable
/// deposit money that moved on that row (paid out on a receipt, refunded back to
/// us on a return). Never edited or hard-deleted — corrections are new rows.
@DataClassName('SupplierCrateLedgerEntryData')
class SupplierCrateLedger extends Table {
  TextColumn get id => text().clientDefault(() => UuidV7.generate())();
  TextColumn get businessId => text().references(Businesses, #id)();
  TextColumn get supplierId => text().references(Suppliers, #id)();
  TextColumn get manufacturerId => text().references(Manufacturers, #id)();
  // The store the movement is attributed to (active-store picker, §21.11).
  // Nullable: onboarding-era writes carry none → shown only in "All Stores".
  TextColumn get storeId => text().nullable().references(Stores, #id)();
  IntColumn get quantityDelta => integer()();
  // 'received' (+) | 'returned' (−) | 'adjusted' (manual correction).
  TextColumn get movementType => text().withLength(min: 1, max: 32)();
  // Refundable deposit money that moved on this row (kobo). Always >= 0; the
  // sign of the cash flow is implied by movementType (out on received, back on
  // returned). Net deposit still held by the supplier = SUM over received −
  // SUM over returned.
  IntColumn get depositPaidKobo => integer().withDefault(const Constant(0))();
  TextColumn get note => text().nullable()();
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
    "CHECK (movement_type IN ('received','returned','adjusted'))",
    'CHECK (deposit_paid_kobo >= 0)',
  ];
}

/// Per-(supplier, manufacturer) empty-crate balance cache (§3.13) — the
/// supplier-side mirror of [CustomerCrateBalances]. Source of truth is
/// [SupplierCrateLedger]: balance = SUM(quantity_delta). A positive balance =
/// WE owe the supplier that many empties; negative = the supplier owes us (we
/// returned more than we received — a crate credit). Registered in
/// kSyncCacheTables; rehydratable from the ledger.
@DataClassName('SupplierCrateBalanceData')
class SupplierCrateBalances extends Table {
  TextColumn get id => text().clientDefault(() => UuidV7.generate())();
  TextColumn get businessId => text().references(Businesses, #id)();
  TextColumn get supplierId => text().references(Suppliers, #id)();
  TextColumn get manufacturerId => text().references(Manufacturers, #id)();
  IntColumn get balance => integer().withDefault(const Constant(0))();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get lastUpdatedAt =>
      dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {id};

  @override
  List<String> get customConstraints => [
    'UNIQUE (business_id, supplier_id, manufacturer_id)',
  ];
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
  'Bottle',
  'Can',
  'PET',
  'Sachet',
  'Keg',
  'Crate',
  'Pack',
  'Carton',
  'Piece',
  'Bag',
  'Box',
  'Tin',
  'Other',
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
  // Nullable (#108): a product may have NO unit. When absent it renders nothing
  // anywhere (inventory, POS grid, receipts, product/category detail) — just the
  // name — and crate-eligibility treats it as "not a bottle". The Add/Edit form
  // pre-fills the trade's Lexicon unit as a CLEARABLE suggestion; clearing it
  // saves null. No DB default: absence is a real "no unit" state, never a silent
  // 'Bottle'. See supabase/migrations/0151_products_unit_nullable.sql.
  TextColumn get unit => text().nullable()();
  // Reebaplus pivot step 14 (schema v18): the four legacy price columns
  // (retail / bulk breaker / distributor / selling) were dropped; products
  // now hold exactly three prices — buying (already here), retailer,
  // wholesaler. See master plan §16.5.
  IntColumn get retailerPriceKobo => integer().withDefault(const Constant(0))();
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
  // Optional cloud image URL for the product photo (schema v59, #78 / PRD #76).
  // Synced cross-device via the normal outbox/pull path (products is a
  // pass-through push table) so every device shows the same picture; the local
  // [imagePath] continues to serve offline render. Null = no photo.
  TextColumn get imageUrl => text().nullable()();
  IntColumn get version => integer().withDefault(const Constant(1))();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get lastUpdatedAt =>
      dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {id};

  @override
  List<String> get customConstraints => [
    "CHECK (size IS NULL OR size IN ('big','medium','small'))",
    // Keep in lock-step with [kProductUnits] above. NULL allowed (#108): a
    // product may have no unit.
    "CHECK (unit IS NULL OR unit IN ('Bottle','Can','PET','Sachet','Keg','Crate','Pack','Carton','Piece','Bag','Box','Tin','Other'))",
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
  TextColumn get priceTier => text().withDefault(const Constant('retailer'))();
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
    // §13.4 crate deposits: the deposit family ('crate_deposit' = held,
    // '..._refunded'/'..._forfeited' = the debit legs that drop "held",
    // 'crate_refund' = a spendable credit). Excluded from the spendable balance
    // SUM; summed on its own for "deposits held".
    "CHECK (reference_type IN ('topup_cash','topup_transfer','order_payment','refund','reward','fee','adjustment','void',"
        "'crate_deposit','crate_deposit_refunded','crate_deposit_forfeited','crate_refund'))",
    "CHECK ((type = 'credit' AND signed_amount_kobo >= 0) OR "
        "(type = 'debit' AND signed_amount_kobo <= 0))",
  ];
}

/// §13.4 — wallet `reference_type` values that are crate-deposit MONEY held for
/// the customer (refundable), NOT spendable. The single source of truth for the
/// netting split (decision 13): "deposits held" = SUM(signed) over these;
/// "spendable balance" = SUM(signed) over everything NOT in this set. Note
/// `crate_refund` is a general/spendable credit and is deliberately absent.
const List<String> kCrateDepositReferenceTypes = [
  'crate_deposit',
  'crate_deposit_refunded',
  'crate_deposit_forfeited',
];

// Funds Register tables removed 2026-06-04 (master plan §23 — gateless POS).

// Daily Stock Count session snapshot (§17). One row per saved count (Save
// Count). `products_counted` is how many products were in the session;
// `shortage_*`/`surplus_*` are the roll-up the Daily Reconciliation Report
// (Ring 3, §25.9) reads; `lines_json` is the itemized CHANGED products
// [{p,n,s,a,d}] = product id / name / system / actual / diff (matched lines
// are omitted to bound size — productsCounted still records the full total).
// This is the stock-audit half of that report. Written once per Save Count, so a normal synced
// table, not an append-only ledger. store_id is nullable: an all-stores count
// (the grouped view) has no single store. Mirrors
// supabase/migrations/0072_stock_counts.sql.
@DataClassName('StockCountData')
class StockCounts extends Table {
  TextColumn get id => text().clientDefault(() => UuidV7.generate())();
  TextColumn get businessId => text().references(Businesses, #id)();
  TextColumn get storeId => text().nullable().references(Stores, #id)();
  TextColumn get businessDate => text()(); // YYYY-MM-DD
  IntColumn get productsCounted => integer()();
  IntColumn get shortageCount => integer()(); // # products short (diff<0)
  IntColumn get surplusCount => integer()(); // # products over (diff>0)
  IntColumn get shortageUnits => integer()(); // sum |diff| where diff<0
  IntColumn get surplusUnits => integer()(); // sum  diff  where diff>0
  TextColumn get linesJson => text()(); // [{p,n,s,a,d}] changed lines
  TextColumn get countedBy => text().nullable().references(Users, #id)();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get lastUpdatedAt =>
      dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {id};
}

class CustomerCrateBalances extends Table {
  TextColumn get id => text().clientDefault(() => UuidV7.generate())();
  TextColumn get businessId => text().references(Businesses, #id)();
  TextColumn get customerId => text().references(Customers, #id)();
  // v28: crate tracking re-keyed from crate size group to manufacturer
  // (§13.4). A customer's crate debt is one balance per manufacturer.
  TextColumn get manufacturerId => text().references(Manufacturers, #id)();
  IntColumn get balance => integer().withDefault(const Constant(0))();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get lastUpdatedAt =>
      dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {id};

  @override
  List<String> get customConstraints => [
    'UNIQUE (business_id, customer_id, manufacturer_id)',
  ];
}

class ManufacturerCrateBalances extends Table {
  TextColumn get id => text().clientDefault(() => UuidV7.generate())();
  TextColumn get businessId => text().references(Businesses, #id)();
  TextColumn get manufacturerId => text().references(Manufacturers, #id)();
  // v28: the crate-size-group dimension was dropped — one balance per
  // manufacturer (§13.4).
  IntColumn get balance => integer().withDefault(const Constant(0))();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get lastUpdatedAt =>
      dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {id};

  @override
  List<String> get customConstraints => [
    'UNIQUE (business_id, manufacturer_id)',
  ];
}

/// v44 (§16.8.1): per-store business-held empty-crate balance cache.
/// Mirrors manufacturer_crate_balances but adds the store dimension so crates
/// can be transferred between stores. Customer crate debt stays in
/// customer_crate_balances (customer owes the business, not a store).
/// Registered in kSyncCacheTables (source of truth = crate_ledger rows with
/// store_id set); NOT in _syncedTenantTables (same class as mfr_crate_balances).
@DataClassName('StoreCrateBalanceData')
class StoreCrateBalances extends Table {
  TextColumn get id => text().clientDefault(() => UuidV7.generate())();
  TextColumn get businessId => text().references(Businesses, #id)();
  TextColumn get storeId => text().references(Stores, #id)();
  TextColumn get manufacturerId => text().references(Manufacturers, #id)();
  IntColumn get balance => integer().withDefault(const Constant(0))();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get lastUpdatedAt =>
      dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {id};

  @override
  List<String> get customConstraints => [
    'UNIQUE (business_id, store_id, manufacturer_id)',
  ];
}

// Append-only ledger of crate movements.
class CrateLedger extends Table {
  TextColumn get id => text().clientDefault(() => UuidV7.generate())();
  TextColumn get businessId => text().references(Businesses, #id)();
  TextColumn get customerId => text().nullable().references(Customers, #id)();
  TextColumn get manufacturerId =>
      text().nullable().references(Manufacturers, #id)();
  // v28: crate tracking re-keyed to manufacturer (§13.4). For a CUSTOMER crate
  // movement, customer_id is the owner AND manufacturer_id names whose crates
  // they hold (both set). For a business/manufacturer-stock movement, only
  // manufacturer_id is set. crate_size_group_id is now nullable + vestigial
  // (the size-group table stays for inventory display, but no longer keys
  // tracking — products were never assigned one, which left the §19.5 modal
  // empty).
  TextColumn get crateSizeGroupId =>
      text().nullable().references(CrateSizeGroups, #id)();
  IntColumn get quantityDelta => integer()();
  TextColumn get movementType => text().withLength(min: 1, max: 32)();
  TextColumn get referenceOrderId =>
      text().nullable().references(Orders, #id)();
  TextColumn get referenceReturnId =>
      text().nullable().references(PendingCrateReturns, #id)();
  // v44 (§16.8.1): which store a business-held crate movement belongs to.
  // Null for all pre-v44 rows and for customer crate movements (those are
  // customer-scoped, not store-scoped).
  TextColumn get storeId => text().nullable().references(Stores, #id)();
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
    // v28: relaxed from a customer⊕manufacturer XOR to "at least one owner".
    // A customer crate row now sets BOTH customer_id (owner) and
    // manufacturer_id (whose crates); a business/manufacturer-stock row sets
    // only manufacturer_id. Neither-set is still rejected.
    '''CHECK (customer_id IS NOT NULL OR manufacturer_id IS NOT NULL)''',
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

/// Epic 2 (FIFO batch costing — ADR 0005): the per-(product, store) FIFO cost
/// queue. Each Receive Stock (and Add Product's opening stock) pushes one batch
/// `{qtyRemaining, qtyOriginal, costKobo, receivedAt}`; sales draw it down
/// oldest-first by `receivedAt`. `costKobo == 0` marks an UNCOSTED batch (sales
/// from it snapshot 0 and are excluded from COGS until a cost is backfilled).
///
/// This is a normal MUTABLE synced tenant table — `qty_remaining` is drawn down
/// in place — NOT an append-only ledger and NOT hard-deleted (a spent batch
/// stays at qty 0 for history). Issue #37 (Epic 2, F1) lands the table, its
/// migration seed, and its sync membership only; the draw-down / server-
/// authoritative consumption logic is a later Epic 2 issue.
@DataClassName('CostBatchData')
class CostBatches extends Table {
  TextColumn get id => text().clientDefault(() => UuidV7.generate())();
  TextColumn get businessId => text().references(Businesses, #id)();
  TextColumn get productId => text().references(Products, #id)();
  TextColumn get storeId => text().references(Stores, #id)();
  // Units still on the shelf from this batch; drawn down oldest-first by FIFO.
  IntColumn get qtyRemaining => integer()();
  // Units this batch started with — kept so a partially-consumed batch still
  // reports what it originally held.
  IntColumn get qtyOriginal => integer()();
  // Per-unit cost for this batch, in kobo. 0 == uncosted (see class doc). Cloud
  // side MUST be bigint (money column rule).
  IntColumn get costKobo => integer().withDefault(const Constant(0))();
  // FIFO ordering key: when this stock was received. The migration-seeded
  // opening batch inherits the product's created_at so it always sorts oldest.
  DateTimeColumn get receivedAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get lastUpdatedAt =>
      dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {id};

  @override
  List<String> get customConstraints => [
    'CHECK (qty_remaining >= 0)',
    'CHECK (qty_original >= 0)',
    'CHECK (cost_kobo >= 0)',
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

// Approval queue for stock-keeper stock adjustments (master plan §16.6.1).
// A stock keeper's Add/Remove does NOT touch inventory directly — it lands here
// as a `pending` request. The affected store's Manager(s) and the CEO approve in
// the Reports hub; on approval the real adjustment runs via `adjustStock` (so
// the atomic pos_inventory_delta_v2 envelope still applies the inventory +
// ledger). `reason` is the note carried into the eventual adjustment; `summary`
// is a denormalised human headline (like notifications.message) so the approval
// card renders without cross-table joins. Direct Manager/CEO adjustments never
// pass through here.
@DataClassName('StockAdjustmentRequestData')
class StockAdjustmentRequests extends Table {
  TextColumn get id => text().clientDefault(() => UuidV7.generate())();
  TextColumn get businessId => text().references(Businesses, #id)();
  TextColumn get productId => text().references(Products, #id)();
  TextColumn get storeId => text().references(Stores, #id)();
  // Signed: positive = add, negative = remove.
  IntColumn get quantityDiff => integer()();
  TextColumn get reason => text()();
  // Denormalised headline ("Akin added 5 bottle(s) of Star (Main Store)").
  TextColumn get summary => text()();
  TextColumn get requestedBy => text().nullable().references(Users, #id)();
  TextColumn get status => text().withDefault(const Constant('pending'))();
  TextColumn get approvedBy => text().nullable().references(Users, #id)();
  DateTimeColumn get approvedAt => dateTime().nullable()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get lastUpdatedAt =>
      dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {id};

  @override
  List<String> get customConstraints => [
    "CHECK (status IN ('pending','approved','rejected'))",
  ];
}

// Approval queue for cashier Quick Sales (master plan §12.3.1). A role below
// Manager (Cashier) can no longer drop a Quick Sale straight into the cart — it
// lands here as a `pending` request that the active selling store's Manager(s)
// and the CEO approve in the Reports → Approvals card (§25.2). On approval the
// cashier's device drops the item into the cart. A Quick Sale bypasses inventory
// (§26.4), so approval moves NO stock — flipping the status is the whole action;
// the cart-add happens client-side when the cashier's device sees the approval.
// `cancelled` = the cashier withdrew the request before a decision. `summary` is
// a denormalised human headline (like notifications.message) so the approval
// card renders without cross-table joins. CEO/Manager Quick Sales add directly
// and never pass through here.
@DataClassName('QuickSaleRequestData')
class QuickSaleRequests extends Table {
  TextColumn get id => text().clientDefault(() => UuidV7.generate())();
  TextColumn get businessId => text().references(Businesses, #id)();
  // The active selling store, for approver scoping (a Manager only sees their
  // store's requests — same rule as stock approvals, §16.6.1).
  TextColumn get storeId => text().references(Stores, #id)();
  TextColumn get itemName => text()();
  // Fractional quantity allowed (mirrors the Quick Sale qty field).
  RealColumn get quantity => real()();
  IntColumn get unitPriceKobo => integer()();
  // Denormalised headline ("3 × Bottled Water @ ₦500 = ₦1,500").
  TextColumn get summary => text()();
  TextColumn get requestedBy => text().nullable().references(Users, #id)();
  TextColumn get status => text().withDefault(const Constant('pending'))();
  TextColumn get approvedBy => text().nullable().references(Users, #id)();
  DateTimeColumn get approvedAt => dateTime().nullable()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get lastUpdatedAt =>
      dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {id};

  @override
  List<String> get customConstraints => [
    "CHECK (status IN ('pending','approved','rejected','cancelled'))",
  ];
}

// §13.4 crate deposits — one row per (order, manufacturer/brand) for any order
// carrying tracked crate items. The Confirm Crate Returns modal reads this to
// know, per brand: crates taken, the deposit rate snapshot at sale, and the
// deposit actually paid (which decides full / part / no-deposit). `crates_taken`
// is the source for "expected" returns; `order_items.product_id` is now
// nullable (v35) so per-brand crates can't be re-derived reliably. Written once
// at sale, then `deposit_paid_kobo` may be edited — a normal synced table, not
// an append-only ledger. Mirrors supabase/migrations/0093_order_crate_lines.sql.
@DataClassName('OrderCrateLineData')
class OrderCrateLines extends Table {
  TextColumn get id => text().clientDefault(() => UuidV7.generate())();
  TextColumn get businessId => text().references(Businesses, #id)();
  TextColumn get orderId => text().references(Orders, #id)();
  TextColumn get manufacturerId => text().references(Manufacturers, #id)();
  IntColumn get cratesTaken => integer()();
  // Deposit rate per crate, snapshotted from Manufacturers.depositAmountKobo at
  // sale time so a later CEO rate edit doesn't change historic settlements.
  IntColumn get depositRateKobo => integer().withDefault(const Constant(0))();
  IntColumn get depositPaidKobo => integer().withDefault(const Constant(0))();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get lastUpdatedAt =>
      dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {id};

  @override
  List<String> get customConstraints => [
    'UNIQUE (business_id, order_id, manufacturer_id)',
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
  // Nullable since v35 (§12.3): a Quick Sale line is an item not in inventory,
  // so it has no product. Its display name lives in [priceSnapshot]. Quick-sale
  // lines bypass inventory (§26.4) — no stock_transactions / inventory rows.
  TextColumn get productId => text().nullable().references(Products, #id)();
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
  // §20.4 approval flow. 'approved' (CEO, or Manager within limit — counts in
  // budget), 'pending' (Manager over limit — awaits CEO), 'rejected' (CEO
  // declined — never counts). (Funds Register debit removed 2026-06-04, §23.)
  TextColumn get status => text().withDefault(const Constant('approved'))();
  TextColumn get rejectionReason => text().nullable()();
  TextColumn get approvedBy => text().nullable().references(Users, #id)();
  DateTimeColumn get approvedAt => dateTime().nullable()();
  // The user-picked expense date (§20.2 date picker), distinct from createdAt.
  // Display/reporting only.
  DateTimeColumn get expenseDate =>
      dateTime().withDefault(currentDateAndTime)();
  // Local file path of the receipt photo (§20.2). Phase 1 is local-only; cloud
  // upload + cross-device sync of the image is deferred.
  TextColumn get receiptPath => text().nullable()();
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
    "CHECK (status IN ('approved','pending','rejected'))",
  ];
}

// §20.1/§20.3 monthly budget goal. One row per (business, store-or-null):
// store_id NULL = the business-wide monthly goal; a store_id = that store's
// goal. The Expenses budget bar resolves by the viewer's scope, falling back
// to the business-wide goal when a store has none. Uniqueness is enforced by
// the two partial indexes in `_postCreateStatements`; the DAO upserts by
// looking up the existing (business, store) row.
@DataClassName('ExpenseBudgetData')
class ExpenseBudgets extends Table {
  TextColumn get id => text().clientDefault(() => UuidV7.generate())();
  TextColumn get businessId => text().references(Businesses, #id)();
  TextColumn get storeId => text().nullable().references(Stores, #id)();
  IntColumn get amountKobo => integer()();
  BoolColumn get isDeleted => boolean().withDefault(const Constant(false))();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get lastUpdatedAt =>
      dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {id};

  @override
  List<String> get customConstraints => ['CHECK (amount_kobo >= 0)'];
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
  // Store the cart was saved under (§12.1, side-bar store picker). Nullable: a
  // null means the cart was saved in "All Stores" mode (or is a pre-v55 legacy
  // row). On recall the cart is restored into its origin store's bucket so a
  // store-A cart never leaks into store B. Recall is also filtered by the active
  // store so each store sees only its own saved carts.
  TextColumn get storeId => text().nullable().references(Stores, #id)();
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
  // v28: re-keyed from crate size group to manufacturer (§13.4) — which
  // manufacturer's crates the customer is returning.
  TextColumn get manufacturerId => text().references(Manufacturers, #id)();
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

// v46 (master plan §33 — Reliability and Crash Handling). Append-only
// diagnostic log of caught/uncaught errors. A normal synced tenant table
// (business-scoped, enqueued through ErrorLogDao) so the CEO/operator can
// review crashes across every till in the business's own Supabase — no
// third-party crash service. PII-minimal by design (§33.1): no customer
// names/phones/amounts. `businessId` is nullable: a crash before a business
// is bound (pre-login) has no tenant to scope to, so that row stays
// local-only and is never enqueued (§33.3). Not soft-deletable and not a
// financial ledger — no is_deleted column, no no-delete trigger.
@DataClassName('ErrorLogData')
class ErrorLogs extends Table {
  TextColumn get id => text().clientDefault(() => UuidV7.generate())();
  TextColumn get businessId => text().nullable().references(Businesses, #id)();
  TextColumn get userId => text().nullable().references(Users, #id)();
  // Active user's role at crash time (CEO / Manager / Cashier / Stock keeper).
  // Role, not name — triage without identifying anyone.
  TextColumn get role => text().nullable()();
  // Where it happened: a route/screen name or logical tag ("pos.checkout").
  TextColumn get context => text().nullable()();
  // Exception runtimeType (e.g. "StateError").
  TextColumn get errorType => text()();
  // Short, truncated error message (§33.1 — not user field values).
  TextColumn get message => text()();
  TextColumn get stackTrace => text().nullable()();
  // true = uncaught (global handler) | false = caught by a guarded boundary.
  BoolColumn get isFatal => boolean().withDefault(const Constant(false))();
  TextColumn get appVersion => text().nullable()();
  TextColumn get platform => text().nullable()();
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
  TextColumn get recipientUserId => text().nullable().references(Users, #id)();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get lastUpdatedAt =>
      dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {id};

  @override
  List<String> get customConstraints => [
    "CHECK (severity IN ('info', 'warning', 'alert'))",
  ];
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
  List<String> get customConstraints => ['UNIQUE (role_id, permission_key)'];
}

/// Per-staff permission override (master plan §10.2.1). A row means this user's
/// effective permission for `permissionKey` is forced: `isGranted` true =
/// force-grant, false = force-revoke. No row = inherit the role default. The
/// runtime resolver applies these on top of the role's grants (CEO is skipped —
/// always all-on). Scoped per business so a multi-business user's overrides
/// don't leak across businesses.
@DataClassName('UserPermissionOverrideData')
class UserPermissionOverrides extends Table {
  TextColumn get id => text().clientDefault(() => UuidV7.generate())();
  TextColumn get businessId => text().references(Businesses, #id)();
  TextColumn get userId => text().references(Users, #id)();
  TextColumn get permissionKey => text()();
  BoolColumn get isGranted => boolean()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get lastUpdatedAt =>
      dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {id};

  @override
  List<String> get customConstraints => [
    'UNIQUE (business_id, user_id, permission_key)',
  ];
}

/// Per-store permission override (master plan §10.2.1, Store scope). A row means
/// a role's effective permission for `permissionKey` is forced for everyone
/// working in `storeId`: `isGranted` true = force-grant, false = force-revoke.
/// No row = inherit the role's business default. Same override shape as
/// [UserPermissionOverrides] but keyed by store+role. The runtime resolver
/// applies these between the business (role) grants and the per-user overrides —
/// most-specific wins, User > Store > Business (CEO is skipped, always all-on).
/// Scoped per business so a multi-business user's stores don't leak across
/// businesses.
@DataClassName('StoreRolePermissionData')
class StoreRolePermissions extends Table {
  TextColumn get id => text().clientDefault(() => UuidV7.generate())();
  TextColumn get businessId => text().references(Businesses, #id)();
  TextColumn get storeId => text().references(Stores, #id)();
  TextColumn get roleId => text().references(Roles, #id)();
  TextColumn get permissionKey => text()();
  BoolColumn get isGranted => boolean()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get lastUpdatedAt =>
      dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {id};

  @override
  List<String> get customConstraints => [
    'UNIQUE (store_id, role_id, permission_key)',
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
  List<String> get customConstraints => ['UNIQUE (role_id, setting_key)'];
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
    // #107 staff offboarding added the terminal `removed` status. Widening this
    // CHECK is a runtime-resolved change (customConstraints is not baked into
    // the generated code), so no build_runner regen is needed; existing installs
    // rebuild the table under the new CHECK via the schemaVersion 61 upgrade step.
    "CHECK (status IN ('active','suspended','removed'))",
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
  List<String> get customConstraints => ['UNIQUE (user_id, store_id)'];
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
  // §6.8.1 automatic orphan recovery: how many times this row was re-enqueued
  // by the auto-recovery sweep. Rides the queue row so the per-orphan auto-
  // retry cap survives a re-orphan — `markFailed` copies it onto the new
  // orphan row, and the sweep stamps `count + 1` when it re-enqueues. 0 for a
  // normal first-time write.
  IntColumn get autoRetryCount => integer().withDefault(const Constant(0))();
  // Oversell recovery: a v2 sale's child rows (cost_batches, crate rows, wallet
  // legs) are enqueued HELD by their order id — the drain skips them until the
  // guarded `pos_record_sale_v2` envelope for that order CONFIRMS (then they're
  // released → pushed) or is REJECTED (then they're discarded → never leak to
  // the cloud). Null = a normal, immediately-drainable row. Device-local only
  // (sync_queue never syncs), so no cloud column.
  TextColumn get heldByOrderId => text().nullable()();

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
  // §6.8.1: how many times the automatic recovery sweep has already
  // re-enqueued this orphan. Carried forward from the queue row when
  // `markFailed` re-orphans, so the allowlist cap holds across re-orphan
  // cycles instead of resetting to 0 each time.
  IntColumn get autoRetryCount => integer().withDefault(const Constant(0))();

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
    SupplierLedgerEntries,
    SupplierCrateLedger,
    SupplierCrateBalances,
    Products,
    PriceLists,
    Customers,
    CustomerWallets,
    WalletTransactions,
    CustomerCrateBalances,
    ManufacturerCrateBalances,
    StoreCrateBalances,
    CrateLedger,
    Inventory,
    CostBatches,
    StockTransfers,
    StockAdjustments,
    StockTransactions,
    StockAdjustmentRequests,
    QuickSaleRequests,
    Orders,
    OrderItems,
    OrderCrateLines,
    Shipments,
    PurchaseItems,
    ExpenseCategories,
    Expenses,
    ExpenseBudgets,
    Drivers,
    DeliveryReceipts,
    SavedCarts,
    PendingCrateReturns,
    PaymentTransactions,
    StockCounts,
    ActivityLogs,
    ErrorLogs,
    Notifications,
    Settings,
    Sessions,
    Permissions,
    Roles,
    RolePermissions,
    UserPermissionOverrides,
    StoreRolePermissions,
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
    CostBatchesDao,
    OrdersDao,
    CustomersDao,
    ShipmentsDao,
    ExpensesDao,
    ExpenseBudgetsDao,
    SyncDao,
    ActivityLogDao,
    ErrorLogDao,
    NotificationsDao,
    StoresDao,
    StockLedgerDao,
    StockTransferDao,
    StockAdjustmentRequestsDao,
    QuickSaleRequestsDao,
    PendingCrateReturnsDao,
    SessionsDao,
    WalletTransactionsDao,
    SupplierLedgerDao,
    SupplierCrateLedgerDao,
    SupplierCrateBalancesDao,
    StockCountsDao,
    CustomerWalletsDao,
    CrateSizeGroupsDao,
    CustomerCrateBalancesDao,
    ManufacturerCrateBalancesDao,
    StoreCrateBalancesDao,
    OrderCrateLinesDao,
    CrateLedgerDao,
    SettingsDao,
    BusinessesDao,
    SystemConfigDao,
    PermissionsDao,
    RolesDao,
    RolePermissionsDao,
    UserPermissionOverridesDao,
    StoreRolePermissionsDao,
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
  int get schemaVersion => 62;

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
        await customStatement('UPDATE businesses SET onboarding_complete = 1');
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
        } catch (_) {
          /* table may already be gone or column missing */
        }
        try {
          await customStatement('DELETE FROM users WHERE is_deleted = 1');
        } catch (_) {
          /* column already dropped */
        }
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
        await customStatement('DROP INDEX IF EXISTS idx_business_members_user');
        await customStatement('DROP INDEX IF EXISTS idx_invites_business_lua');
        await customStatement('DROP INDEX IF EXISTS uq_invites_pending_code');
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
        } catch (_) {
          /* already gone */
        }
        try {
          await customStatement('ALTER TABLE users DROP COLUMN role_tier');
        } catch (_) {
          /* already gone */
        }
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
          } catch (_) {
            /* already gone */
          }
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
            'DROP TRIGGER IF EXISTS activity_logs_immutable',
          );
          await customStatement(
            'DROP TRIGGER IF EXISTS activity_logs_no_delete',
          );
          await m.alterTable(
            TableMigration(
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
            ),
          );
          for (final stmt in _ledgerTriggerStatements(
            _ledgerTables.firstWhere((l) => l.table == 'activity_logs'),
          )) {
            await customStatement(stmt);
          }
        }
        // notifications: add severity (default 'info') + its CHECK via rebuild.
        if (!await hasColumn('notifications', 'severity')) {
          await m.alterTable(
            TableMigration(notifications, newColumns: [notifications.severity]),
          );
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
      if (from < 28) {
        // v28 (§18.4): add the customers.wallet.totals.view permission to the
        // local catalog so the Roles & Permissions settings screen lists it.
        // Total In / Total Out on a customer's Wallet tab are hidden for roles
        // below Manager unless the CEO grants this key. Manager + CEO see the
        // tiles regardless (a role-rank check in code). The grants arrive from
        // the cloud via pull (CEO/Manager backfill in supabase/migrations/0069).
        // Idempotent — key is the PK.
        await customStatement(
          "INSERT OR IGNORE INTO permissions (key, description, category) "
          "VALUES ('customers.wallet.totals.view', "
          "'View wallet Total In / Total Out on a customer', 'Customers')",
        );
      }
      if (from < 29) {
        // v29 (§13.4): re-key empty-crate CUSTOMER tracking from crate size
        // group to MANUFACTURER. Products were never assigned a crate size
        // group, which left the §19.5 crate-return modal empty. Mirrors
        // supabase/migrations/0070_crate_tracking_by_manufacturer.sql.
        //   - customer_crate_balances: crate_size_group_id → manufacturer_id,
        //     UNIQUE (business, customer, manufacturer). CACHE → rebuilt empty.
        //   - manufacturer_crate_balances: drop crate_size_group_id,
        //     UNIQUE (business, manufacturer). CACHE → rebuilt empty.
        //   - pending_crate_returns: crate_size_group_id → manufacturer_id.
        //   - crate_ledger: crate_size_group_id NOT NULL → nullable, owner
        //     CHECK relaxed from customer⊕manufacturer to "at least one set" so
        //     a customer row can also name the manufacturer whose crates it
        //     holds. The crate_size_groups TABLE stays (it still powers the
        //     Empty Crates inventory tab + deliveries + suppliers).
        //
        // Idempotency-guarded on the OLD shape (revert-then-re-upgrade tests).
        Future<bool> hasCol(String table, String col) async {
          final rows = await customSelect('PRAGMA table_info($table)').get();
          return rows.any((r) => r.read<String>('name') == col);
        }

        // 1+2. The two balance CACHES are never pushed (not in
        // _syncedTenantTables) — written only by the cloud domain-response /
        // snapshot restore. No derivable size→manufacturer mapping and nothing
        // to preserve: drop + recreate fresh in the new shape; they rehydrate
        // from the cloud. No LUA index / bump trigger (caches).
        if (await hasCol('customer_crate_balances', 'crate_size_group_id')) {
          await customStatement('DROP TABLE IF EXISTS customer_crate_balances');
          await m.createTable(customerCrateBalances);
        }
        if (await hasCol(
          'manufacturer_crate_balances',
          'crate_size_group_id',
        )) {
          await customStatement(
            'DROP TABLE IF EXISTS manufacturer_crate_balances',
          );
          await m.createTable(manufacturerCrateBalances);
        }

        // 3. pending_crate_returns: re-key to manufacturer. Transient approval
        // requests; the size→manufacturer value isn't derivable, so clear them
        // (FK enforcement is OFF during onUpgrade). Recreate the LUA + status
        // indexes + bump trigger (synced table).
        if (await hasCol('pending_crate_returns', 'crate_size_group_id')) {
          await customStatement('DELETE FROM pending_crate_returns');
          await customStatement('DROP TABLE IF EXISTS pending_crate_returns');
          await m.createTable(pendingCrateReturns);
          await customStatement(
            'CREATE INDEX idx_pending_crate_returns_business_lua '
            'ON pending_crate_returns (business_id, last_updated_at)',
          );
          await customStatement(
            'CREATE INDEX idx_pcr_business_status '
            'ON pending_crate_returns (business_id, status)',
          );
          await customStatement(
            'CREATE TRIGGER bump_pending_crate_returns_last_updated_at '
            'AFTER UPDATE ON pending_crate_returns '
            'FOR EACH ROW '
            'WHEN OLD.last_updated_at IS NEW.last_updated_at '
            'BEGIN '
            "UPDATE pending_crate_returns SET last_updated_at = CAST(strftime('%s', 'now') AS INTEGER) WHERE id = OLD.id; "
            'END',
          );
        }

        // 4. crate_ledger (append-only): crate_size_group_id NOT NULL →
        // nullable + relaxed owner CHECK. Rebuild PRESERVES rows (they satisfy
        // the relaxed CHECK; the size group survives as a now-nullable value).
        // Drop the immutability + no-delete triggers first (alterTable
        // re-creates table triggers from sqlite_master), rebuild, then recreate
        // the LUA + owner-group indexes, the bump trigger, and the ledger
        // triggers from the (unchanged) _ledgerTables immutable column set.
        final cgInfo =
            (await customSelect('PRAGMA table_info(crate_ledger)').get())
                .where((r) => r.read<String>('name') == 'crate_size_group_id')
                .toList();
        final cgIsNotNull =
            cgInfo.isNotEmpty && cgInfo.first.read<int>('notnull') == 1;
        if (cgIsNotNull) {
          await customStatement(
            'DROP TRIGGER IF EXISTS crate_ledger_immutable',
          );
          await customStatement(
            'DROP TRIGGER IF EXISTS crate_ledger_no_delete',
          );
          // `store_id` was added to crate_ledger later (v44, guarded ALTER) but
          // the live table object already carries it, so the rebuild must treat
          // it as a NEW column (populated NULL) rather than copying it from the
          // pre-v44 table — otherwise the copy SELECTs a column that doesn't yet
          // exist. The v44 guarded ALTER then sees it present and skips. Without
          // this, a ≤v28→v29 upgrade crashes ("no such column store_id").
          await m.alterTable(
            TableMigration(crateLedger, newColumns: [crateLedger.storeId]),
          );
          // drift's alterTable re-applies the rebuilt table's existing indexes
          // (with their OLD definitions), so DROP-then-CREATE here: it makes the
          // CREATEs idempotent AND swaps idx_crate_ledger_owner_group to its new
          // shape (without crate_size_group_id). Triggers are NOT re-applied by
          // alterTable, but DROP IF EXISTS keeps a partial re-run safe.
          await customStatement(
            'DROP INDEX IF EXISTS idx_crate_ledger_business_lua',
          );
          await customStatement(
            'CREATE INDEX idx_crate_ledger_business_lua '
            'ON crate_ledger (business_id, last_updated_at)',
          );
          await customStatement(
            'DROP INDEX IF EXISTS idx_crate_ledger_owner_group',
          );
          await customStatement(
            'CREATE INDEX idx_crate_ledger_owner_group '
            'ON crate_ledger (business_id, customer_id, manufacturer_id, created_at)',
          );
          await customStatement(
            'DROP TRIGGER IF EXISTS bump_crate_ledger_last_updated_at',
          );
          await customStatement(
            'CREATE TRIGGER bump_crate_ledger_last_updated_at '
            'AFTER UPDATE ON crate_ledger '
            'FOR EACH ROW '
            'WHEN OLD.last_updated_at IS NEW.last_updated_at '
            'BEGIN '
            "UPDATE crate_ledger SET last_updated_at = CAST(strftime('%s', 'now') AS INTEGER) WHERE id = OLD.id; "
            'END',
          );
          await customStatement(
            'DROP TRIGGER IF EXISTS crate_ledger_immutable',
          );
          await customStatement(
            'DROP TRIGGER IF EXISTS crate_ledger_no_delete',
          );
          for (final stmt in _ledgerTriggerStatements(
            _ledgerTables.firstWhere((l) => l.table == 'crate_ledger'),
          )) {
            await customStatement(stmt);
          }
        }

        // 5. Drop stale pending sync_queue rows carrying the old crate-size
        // keying — the cloud RPCs (0070) now take p_manufacturer_id and
        // pending_crate_returns upserts no longer carry crate_size_group_id.
        // The size→manufacturer value isn't translatable; the crate flow was
        // broken so these are empty in practice.
        await customStatement(
          "DELETE FROM sync_queue WHERE status = 'pending' AND action_type IN ("
          "'pending_crate_returns:upsert', 'customer_crate_balances:upsert', "
          "'manufacturer_crate_balances:upsert', "
          "'domain:pos_record_crate_return', 'domain:pos_approve_crate_return')",
        );
      }
      if (from < 30) {
        // v30 (master plan §17 Daily Stock Count): the per-session stock-audit
        // snapshot table. One new synced tenant table. Mirrors
        // supabase/migrations/0072_stock_counts.sql. Same index/trigger shapes
        // as the `_postCreateStatements` loops so a fresh install (onCreate)
        // and an upgrade end up identical.
        //
        // Idempotency guard (like the v27 block): revert-then-re-upgrade tests
        // revert only specific deltas, so a DB stepped back to < 30 may still
        // carry stock_counts; a blind createTable would throw "table already
        // exists". Only build it when genuinely absent.
        final exists = await customSelect(
          "SELECT 1 FROM sqlite_master WHERE type='table' "
          "AND name='stock_counts'",
        ).get();
        if (exists.isEmpty) {
          await m.createTable(stockCounts);
          await customStatement(
            'CREATE INDEX idx_stock_counts_business_lua '
            'ON stock_counts (business_id, last_updated_at)',
          );
          await customStatement(
            'CREATE INDEX idx_stock_counts_store_date '
            'ON stock_counts (store_id, business_date)',
          );
          await customStatement(
            'CREATE TRIGGER bump_stock_counts_last_updated_at '
            'AFTER UPDATE ON stock_counts '
            'FOR EACH ROW '
            'WHEN OLD.last_updated_at IS NEW.last_updated_at '
            'BEGIN '
            "UPDATE stock_counts SET last_updated_at = CAST(strftime('%s', 'now') AS INTEGER) WHERE id = OLD.id; "
            'END',
          );
        }
      }
      if (from < 31) {
        // v31 (master plan §20 Expenses — full implementation). Mirrors
        // supabase/migrations/0073_expenses_full.sql. Two deltas (the original
        // third — widening fund_transactions.reference_type for the Funds
        // Register expense debit — was dropped with Funds Register, 2026-06-04):
        //   1. expenses: add the §20.4 approval columns (status / rejection /
        //      approver / approved_at), the §20.2 user-picked expense_date, and
        //      the §20.2 local receipt_path + a status CHECK.
        //   2. expense_budgets: new synced tenant table (§20.1/§20.3 budget).
        //
        // Each step is guarded so a revert-then-re-upgrade test (which reverts
        // only specific deltas) doesn't double-apply.
        Future<bool> hasCol(String table, String col) async {
          final rows = await customSelect('PRAGMA table_info($table)').get();
          return rows.any((r) => r.read<String>('name') == col);
        }

        // 1. expenses — add the approval / date / receipt columns. Rebuild
        // (rather than ADD COLUMN) so the new table-level status CHECK lands and
        // the live shape matches the Dart definition. drift's alterTable
        // re-applies the table's existing indexes; recreate the bump trigger
        // (alterTable does not re-apply triggers). Backfill the new
        // expense_date from the existing created_at.
        if (!await hasCol('expenses', 'status')) {
          await m.alterTable(
            TableMigration(
              expenses,
              newColumns: [
                expenses.status,
                expenses.rejectionReason,
                expenses.approvedBy,
                expenses.approvedAt,
                expenses.expenseDate,
                expenses.receiptPath,
              ],
              columnTransformer: {expenses.expenseDate: expenses.createdAt},
            ),
          );
          await customStatement(
            'DROP TRIGGER IF EXISTS bump_expenses_last_updated_at',
          );
          await customStatement(
            'CREATE TRIGGER bump_expenses_last_updated_at '
            'AFTER UPDATE ON expenses '
            'FOR EACH ROW '
            'WHEN OLD.last_updated_at IS NEW.last_updated_at '
            'BEGIN '
            "UPDATE expenses SET last_updated_at = CAST(strftime('%s', 'now') AS INTEGER) WHERE id = OLD.id; "
            'END',
          );
        }

        // 2. expense_budgets — new synced tenant table. Same index/trigger
        // shapes as the `_postCreateStatements` loops (LUA + soft-delete +
        // bump) plus the two partial unique indexes (one live goal per
        // business / store).
        final ebExists = await customSelect(
          "SELECT 1 FROM sqlite_master WHERE type='table' "
          "AND name='expense_budgets'",
        ).get();
        if (ebExists.isEmpty) {
          await m.createTable(expenseBudgets);
          await customStatement(
            'CREATE INDEX idx_expense_budgets_business_lua '
            'ON expense_budgets (business_id, last_updated_at)',
          );
          await customStatement(
            'CREATE INDEX idx_expense_budgets_business_deleted '
            'ON expense_budgets (business_id, is_deleted)',
          );
          await customStatement(
            'CREATE UNIQUE INDEX uq_expense_budgets_business '
            'ON expense_budgets (business_id) '
            'WHERE store_id IS NULL AND is_deleted = 0',
          );
          await customStatement(
            'CREATE UNIQUE INDEX uq_expense_budgets_store '
            'ON expense_budgets (business_id, store_id) '
            'WHERE store_id IS NOT NULL AND is_deleted = 0',
          );
          await customStatement(
            'CREATE TRIGGER bump_expense_budgets_last_updated_at '
            'AFTER UPDATE ON expense_budgets '
            'FOR EACH ROW '
            'WHEN OLD.last_updated_at IS NEW.last_updated_at '
            'BEGIN '
            "UPDATE expense_budgets SET last_updated_at = CAST(strftime('%s', 'now') AS INTEGER) WHERE id = OLD.id; "
            'END',
          );
        }
      }
      if (from < 32) {
        // v32 (label-only renames). Mirrors
        // supabase/migrations/0087_rename_permission_labels.sql. The
        // `permissions` catalogue is seeded once and never re-synced from the
        // cloud, so existing installs need these UPDATEs to show the new
        // labels. Enforcement is unchanged — only the displayed text differs.
        // Idempotent: re-running just re-sets the same descriptions.
        await customStatement(
          "UPDATE permissions SET description = 'Edit product' "
          "WHERE key = 'products.edit_price'",
        );
        await customStatement(
          "UPDATE permissions SET description = 'View buying price' "
          "WHERE key = 'products.edit_buying_price'",
        );
        await customStatement(
          "UPDATE permissions SET description = 'View Inventory' "
          "WHERE key = 'stock.view'",
        );
      }
      if (from < 33) {
        // v33 (master plan §10.2.1): per-staff permission overrides. One new
        // synced tenant table. Mirrors
        // supabase/migrations/0088_user_permission_overrides.sql. The
        // (business_id, last_updated_at) sync index and the bump trigger match
        // the generic `_postCreateStatements` loops so a fresh install
        // (onCreate) and an upgrade end up identical.
        //
        // Idempotency guard (like the v27/v30 blocks): a DB stepped back to
        // < 33 by the revert-then-re-upgrade tests may still carry the table;
        // a blind createTable would throw "table already exists".
        final exists = await customSelect(
          "SELECT 1 FROM sqlite_master WHERE type='table' "
          "AND name='user_permission_overrides'",
        ).get();
        if (exists.isEmpty) {
          await m.createTable(userPermissionOverrides);
          await customStatement(
            'CREATE INDEX idx_user_permission_overrides_business_lua '
            'ON user_permission_overrides (business_id, last_updated_at)',
          );
          await customStatement(
            'CREATE TRIGGER bump_user_permission_overrides_last_updated_at '
            'AFTER UPDATE ON user_permission_overrides '
            'FOR EACH ROW '
            'WHEN OLD.last_updated_at IS NEW.last_updated_at '
            'BEGIN '
            "UPDATE user_permission_overrides SET last_updated_at = CAST(strftime('%s', 'now') AS INTEGER) WHERE id = OLD.id; "
            'END',
          );
        }
      }
      if (from < 34) {
        // v34 (master plan §16.6.1): stock-keeper adjustment approval queue.
        // One new synced tenant table. Mirrors
        // supabase/migrations/0089_stock_adjustment_requests.sql. The
        // (business_id, last_updated_at) sync index and the bump trigger match
        // the generic `_postCreateStatements` loops so a fresh install
        // (onCreate) and an upgrade end up identical. Idempotency guard (like
        // v33) for a DB stepped back to < 34 by the revert-then-re-upgrade tests.
        final exists = await customSelect(
          "SELECT 1 FROM sqlite_master WHERE type='table' "
          "AND name='stock_adjustment_requests'",
        ).get();
        if (exists.isEmpty) {
          await m.createTable(stockAdjustmentRequests);
          await customStatement(
            'CREATE INDEX idx_stock_adjustment_requests_business_lua '
            'ON stock_adjustment_requests (business_id, last_updated_at)',
          );
          await customStatement(
            'CREATE TRIGGER bump_stock_adjustment_requests_last_updated_at '
            'AFTER UPDATE ON stock_adjustment_requests '
            'FOR EACH ROW '
            'WHEN OLD.last_updated_at IS NEW.last_updated_at '
            'BEGIN '
            "UPDATE stock_adjustment_requests SET last_updated_at = CAST(strftime('%s', 'now') AS INTEGER) WHERE id = OLD.id; "
            'END',
          );
        }
      }
      if (from < 35) {
        // v35 (master plan §12.3 quick sales): order_items.product_id becomes
        // nullable so a Quick Sale line (an item not in inventory) can be
        // recorded as a real order line with no product. Mirrors
        // supabase/migrations/0091_order_items_nullable_product.sql. The line's
        // name lives in price_snapshot; quick-sale lines bypass inventory
        // (§26.4) so no stock_transactions / inventory rows are written.
        // Rebuild via alterTable (no columns dropped, so the bump trigger
        // re-creates cleanly from sqlite_master). Idempotent: only rebuild
        // while product_id is still NOT NULL.
        final info = await customSelect('PRAGMA table_info(order_items)').get();
        final pidNotNull = info.any(
          (r) =>
              r.read<String>('name') == 'product_id' &&
              r.read<int>('notnull') == 1,
        );
        if (pidNotNull) {
          await m.alterTable(TableMigration(orderItems));
        }
      }
      if (from < 36) {
        // v36: REMOVE the Funds Register feature (master plan §23 — now a
        // tombstone). POS is gateless (no opening-cash gate). Drops the
        // expenses.funds_account_id column, the four funds tables, the three
        // funds permission keys, and any queued funds outbox rows. Mirrors
        // supabase/migrations/0092_drop_funds_register.sql.
        //
        // 0. FK enforcement is ON during onUpgrade (the connection setup enables
        //    it; only m.alterTable toggles it off around its own work). DROP TABLE
        //    runs an implicit DELETE that CHECKS foreign keys, and a till that
        //    also ran the parallel Supplier Accounts work carries a leftover
        //    supplier_payments.funds_account_id -> funds_accounts FK this branch's
        //    schema can't see — so the funds_accounts drop hits a 787 constraint
        //    failure. Disable FK for the whole teardown so the funds tables drop
        //    regardless of residual references (any orphan column is left dangling
        //    for the parallel work to clean up; SQLite does not recheck existing
        //    rows when FK is re-enabled). onUpgrade is not in a transaction, so the
        //    PRAGMA takes effect — the same mechanism m.alterTable relies on.
        await customStatement('PRAGMA foreign_keys = OFF');

        // 1. expenses.funds_account_id — rebuild expenses from the current Drift
        //    schema (no longer has the column) to drop it. alterTable re-applies
        //    indexes but not triggers, so recreate the bump trigger. Guarded so
        //    a revert-then-re-upgrade doesn't double-apply.
        final expHasFunds = await customSelect(
          "SELECT 1 FROM pragma_table_info('expenses') "
          "WHERE name='funds_account_id'",
        ).get();
        if (expHasFunds.isNotEmpty) {
          await m.alterTable(TableMigration(expenses));
          await customStatement(
            'DROP TRIGGER IF EXISTS bump_expenses_last_updated_at',
          );
          await customStatement(
            'CREATE TRIGGER bump_expenses_last_updated_at '
            'AFTER UPDATE ON expenses '
            'FOR EACH ROW '
            'WHEN OLD.last_updated_at IS NEW.last_updated_at '
            'BEGIN '
            "UPDATE expenses SET last_updated_at = CAST(strftime('%s', 'now') AS INTEGER) WHERE id = OLD.id; "
            'END',
          );
        }

        // 2. Drop the four funds tables. DROP TABLE removes their indexes +
        //    triggers; the append-only BEFORE DELETE trigger does not fire on a
        //    table drop. Order: closings -> ledger -> day header -> accounts.
        await customStatement('DROP TABLE IF EXISTS fund_day_closings');
        await customStatement('DROP TABLE IF EXISTS fund_transactions');
        await customStatement('DROP TABLE IF EXISTS fund_days');
        await customStatement('DROP TABLE IF EXISTS funds_accounts');

        // Restore FK enforcement for the rest of the session (beforeOpen also
        // re-enables it; this keeps the window tight).
        await customStatement('PRAGMA foreign_keys = ON');

        // 3. Drain any funds rows still pending in the outbox so they don't fail
        //    forever against the now-dropped cloud tables (action_type is
        //    '<table>:upsert' / '<table>:delete', see SyncDao.enqueueUpsert).
        await customStatement(
          "DELETE FROM sync_queue WHERE action_type IN ("
          "'funds_accounts:upsert','funds_accounts:delete',"
          "'fund_days:upsert','fund_days:delete',"
          "'fund_transactions:upsert','fund_transactions:delete',"
          "'fund_day_closings:upsert','fund_day_closings:delete')",
        );

        // 4. Remove the three funds permission keys from the local catalogue so
        //    the Roles & Permissions screen no longer lists a Funds category.
        //    role_permissions/user_permission_overrides reference the key by
        //    plain text (no FK), so any lingering grants are harmless orphans.
        await customStatement(
          "DELETE FROM permissions WHERE key IN "
          "('funds.view','funds.open_day','funds.close_day')",
        );
      }
      if (from < 37) {
        // v37 (master plan §13.4 crate deposits): one new synced table + a
        // wallet CHECK widen. Mirrors supabase/migrations/0093_order_crate_lines.sql
        // and 0094_wallet_reference_type_crate.sql.
        //
        // 1. order_crate_lines — per-order, per-brand crate count + deposit
        //    snapshot the Confirm Crate Returns modal reads. New synced tenant
        //    table; the (business_id, last_updated_at) index + bump trigger match
        //    the generic _postCreateStatements loop so onCreate and an upgrade
        //    end up identical. Idempotency guard (like v34) for the
        //    revert-then-re-upgrade tests.
        final oclExists = await customSelect(
          "SELECT 1 FROM sqlite_master WHERE type='table' "
          "AND name='order_crate_lines'",
        ).get();
        if (oclExists.isEmpty) {
          await m.createTable(orderCrateLines);
          await customStatement(
            'CREATE INDEX idx_order_crate_lines_business_lua '
            'ON order_crate_lines (business_id, last_updated_at)',
          );
          await customStatement(
            'CREATE TRIGGER bump_order_crate_lines_last_updated_at '
            'AFTER UPDATE ON order_crate_lines '
            'FOR EACH ROW '
            'WHEN OLD.last_updated_at IS NEW.last_updated_at '
            'BEGIN '
            "UPDATE order_crate_lines SET last_updated_at = CAST(strftime('%s', 'now') AS INTEGER) WHERE id = OLD.id; "
            'END',
          );
        }

        // 2. wallet_transactions.reference_type CHECK widen — add the crate
        //    deposit family. SQLite can't ALTER a CHECK in place; rebuild from
        //    the current Drift schema (new CHECK) and copy rows.
        //    wallet_transactions is append-only (_ledgerTables): drop its
        //    immutability triggers first (alterTable does NOT re-apply triggers),
        //    rebuild, then recreate the LUA index, the bump trigger, and the
        //    ledger triggers. Mirrors the v29 crate_ledger rebuild. Guarded so a
        //    revert-then-re-upgrade doesn't double-apply.
        final wtSql = await customSelect(
          "SELECT sql FROM sqlite_master WHERE type='table' "
          "AND name='wallet_transactions'",
        ).getSingleOrNull();
        final wtWidened =
            wtSql != null &&
            wtSql.read<String>('sql').contains('crate_deposit');
        if (!wtWidened) {
          await customStatement(
            'DROP TRIGGER IF EXISTS wallet_transactions_immutable',
          );
          await customStatement(
            'DROP TRIGGER IF EXISTS wallet_transactions_no_delete',
          );
          await m.alterTable(TableMigration(walletTransactions));
          await customStatement(
            'DROP INDEX IF EXISTS idx_wallet_transactions_business_lua',
          );
          await customStatement(
            'CREATE INDEX idx_wallet_transactions_business_lua '
            'ON wallet_transactions (business_id, last_updated_at)',
          );
          await customStatement(
            'DROP TRIGGER IF EXISTS bump_wallet_transactions_last_updated_at',
          );
          await customStatement(
            'CREATE TRIGGER bump_wallet_transactions_last_updated_at '
            'AFTER UPDATE ON wallet_transactions '
            'FOR EACH ROW '
            'WHEN OLD.last_updated_at IS NEW.last_updated_at '
            'BEGIN '
            "UPDATE wallet_transactions SET last_updated_at = CAST(strftime('%s', 'now') AS INTEGER) WHERE id = OLD.id; "
            'END',
          );
          await customStatement(
            'DROP TRIGGER IF EXISTS wallet_transactions_immutable',
          );
          await customStatement(
            'DROP TRIGGER IF EXISTS wallet_transactions_no_delete',
          );
          for (final stmt in _ledgerTriggerStatements(
            _ledgerTables.firstWhere((l) => l.table == 'wallet_transactions'),
          )) {
            await customStatement(stmt);
          }
        }
      }
      if (from < 38) {
        // v38 (master plan §10.2): add the stores.manage permission
        // ("Add, edit, and remove stores") to the local catalog so the Roles &
        // Permissions screen lists it in the Stores section. CEO-only by
        // default; the grants arrive from the cloud via pull (CEO backfill in
        // supabase/migrations/0095_add_stores_manage_permission.sql). Mirrors
        // the v22/v28 single-key re-seed. Idempotent — key is the PK.
        await customStatement(
          "INSERT OR IGNORE INTO permissions (key, description, category) "
          "VALUES ('stores.manage', 'Add, edit, and remove stores', 'Stores')",
        );
      }
      if (from < 39) {
        // v39 (master plan §9.5): add the staff.assign_stores permission
        // ("Assign staff to stores") so the Roles & Permissions screen lists it
        // in the Staff section. CEO-only by default; the grants arrive from the
        // cloud via pull (CEO backfill in
        // supabase/migrations/0096_add_staff_assign_stores_permission.sql).
        // Mirrors the v38 single-key re-seed. Idempotent — key is the PK.
        await customStatement(
          "INSERT OR IGNORE INTO permissions (key, description, category) "
          "VALUES ('staff.assign_stores', 'Assign staff to stores', 'Staff')",
        );
      }
      if (from < 40) {
        // v40 (master plan §18.3/§18.4): add the customers.wallet.withdraw
        // permission ("Refund cash from a customer wallet") so the Roles &
        // Permissions screen lists it in the Customers section. CEO + Manager by
        // default; the grants arrive from the cloud via pull (CEO/Manager
        // backfill in
        // supabase/migrations/0098_add_customers_wallet_withdraw_permission.sql).
        // Mirrors the v22/v28 single-key re-seed. Idempotent — key is the PK.
        await customStatement(
          "INSERT OR IGNORE INTO permissions (key, description, category) "
          "VALUES ('customers.wallet.withdraw', "
          "'Refund cash from a customer credit balance', 'Customers')",
        );
      }
      if (from < 41) {
        // v41 (master plan §10.2.1, Store scope): per-store role permission
        // overrides. One new synced tenant table. Mirrors
        // supabase/migrations/0099_store_role_permissions.sql. Same new-synced-
        // table shape as v33 (user_permission_overrides): the
        // (business_id, last_updated_at) sync index and the bump trigger match
        // the generic `_postCreateStatements` loops so a fresh install
        // (onCreate) and an upgrade end up identical.
        //
        // Idempotency guard (like the v33/v30 blocks): a DB stepped back to
        // < 41 by the revert-then-re-upgrade tests may still carry the table;
        // a blind createTable would throw "table already exists".
        final exists = await customSelect(
          "SELECT 1 FROM sqlite_master WHERE type='table' "
          "AND name='store_role_permissions'",
        ).get();
        if (exists.isEmpty) {
          await m.createTable(storeRolePermissions);
          await customStatement(
            'CREATE INDEX idx_store_role_permissions_business_lua '
            'ON store_role_permissions (business_id, last_updated_at)',
          );
          await customStatement(
            'CREATE TRIGGER bump_store_role_permissions_last_updated_at '
            'AFTER UPDATE ON store_role_permissions '
            'FOR EACH ROW '
            'WHEN OLD.last_updated_at IS NEW.last_updated_at '
            'BEGIN '
            "UPDATE store_role_permissions SET last_updated_at = CAST(strftime('%s', 'now') AS INTEGER) WHERE id = OLD.id; "
            'END',
          );
        }
      }
      if (from < 42) {
        // v42 (master plan §21): Supplier Accounts ledger + supplier bank/notes
        // columns. Mirrors supabase/migrations/0102_supplier_ledger_entries.sql.
        //
        // 1. New Suppliers columns (all nullable → no backfill). Guard each: a
        //    DB stepped back to < 42 by the revert-then-re-upgrade tests may
        //    already carry them.
        for (final col in const [
          'bank_account_name',
          'bank_account_number',
          'bank_name',
          'notes',
        ]) {
          final has = await customSelect(
            "SELECT 1 FROM pragma_table_info('suppliers') WHERE name = '$col'",
          ).get();
          if (has.isEmpty) {
            await customStatement('ALTER TABLE suppliers ADD COLUMN $col TEXT');
          }
        }

        // 2. New synced, append-only ledger table — same new-synced-table shape
        //    as the v41 block, plus the append-only ledger triggers (immutable
        //    + no-delete) emitted from the (unchanged) _ledgerTables set, so a
        //    fresh install (onCreate) and an upgrade end up identical.
        final exists = await customSelect(
          "SELECT 1 FROM sqlite_master WHERE type='table' "
          "AND name='supplier_ledger_entries'",
        ).get();
        if (exists.isEmpty) {
          await m.createTable(supplierLedgerEntries);
          await customStatement(
            'CREATE INDEX idx_supplier_ledger_entries_business_lua '
            'ON supplier_ledger_entries (business_id, last_updated_at)',
          );
          await customStatement(
            'CREATE INDEX idx_supplier_ledger_business_supplier_time '
            'ON supplier_ledger_entries (business_id, supplier_id, created_at)',
          );
          await customStatement(
            'CREATE TRIGGER bump_supplier_ledger_entries_last_updated_at '
            'AFTER UPDATE ON supplier_ledger_entries '
            'FOR EACH ROW '
            'WHEN OLD.last_updated_at IS NEW.last_updated_at '
            'BEGIN '
            "UPDATE supplier_ledger_entries SET last_updated_at = CAST(strftime('%s', 'now') AS INTEGER) WHERE id = OLD.id; "
            'END',
          );
          for (final stmt in _ledgerTriggerStatements(
            _ledgerTables.firstWhere(
              (l) => l.table == 'supplier_ledger_entries',
            ),
          )) {
            await customStatement(stmt);
          }
        }
      }
      if (from < 43) {
        // v43 (master plan §32): subscription / access-gating columns on
        // businesses. Mirrors supabase/migrations/0101_business_subscription.sql.
        // All four are cloud-authoritative / app-read-only (omitted from the
        // businesses push whitelist). Existing local rows take the column
        // defaults (subscriptionStatus 'trial', the rest null) → grace, so the
        // upgrade never locks anyone; the next pull supplies the real
        // trial_ends_at / status from the cloud. Guard each add: a DB stepped
        // back by the revert-then-re-upgrade tests may already carry the column.
        for (final spec in const [
          ['subscription_status', "TEXT NOT NULL DEFAULT 'trial'"],
          ['subscription_plan', 'TEXT'],
          ['trial_ends_at', 'INTEGER'],
          ['current_period_end', 'INTEGER'],
        ]) {
          final has = await customSelect(
            "SELECT 1 FROM pragma_table_info('businesses') WHERE name = '${spec[0]}'",
          ).get();
          if (has.isEmpty) {
            await customStatement(
              'ALTER TABLE businesses ADD COLUMN ${spec[0]} ${spec[1]}',
            );
          }
        }
      }
      if (from < 44) {
        // v44 (master plan §16.8.1): stock transfer between stores + per-store
        // empty-crate tracking.
        //
        // 1. New `stores.receive_transfer` permission — "Confirm receipt of
        //    incoming stock transfers". CEO-only by default; the grants arrive
        //    from the cloud via pull (CEO backfill in
        //    supabase/migrations/0103_add_stores_receive_transfer_permission.sql).
        //    Idempotent — key is the PK.
        await customStatement(
          "INSERT OR IGNORE INTO permissions (key, description, category) "
          "VALUES ('stores.receive_transfer', "
          "'Confirm receipt of incoming stock transfers', 'Stores')",
        );

        // 2. `StoreCrateBalances` — per-store business-held empty-crate balance
        //    cache (mirrors manufacturer_crate_balances, but keyed per store).
        //    Registered in kSyncCacheTables; its source of truth is crate_ledger.
        //    Mirrors supabase/migrations/0104_store_crate_balances.sql.
        final scbExists = await customSelect(
          "SELECT 1 FROM sqlite_master WHERE type='table' "
          "AND name='store_crate_balances'",
        ).get();
        if (scbExists.isEmpty) {
          await m.createTable(storeCrateBalances);
          await customStatement(
            'CREATE INDEX idx_store_crate_balances_business_lua '
            'ON store_crate_balances (business_id, last_updated_at)',
          );
          await customStatement(
            'CREATE TRIGGER bump_store_crate_balances_last_updated_at '
            'AFTER UPDATE ON store_crate_balances '
            'FOR EACH ROW '
            'WHEN OLD.last_updated_at IS NEW.last_updated_at '
            'BEGIN '
            "UPDATE store_crate_balances SET last_updated_at = CAST(strftime('%s', 'now') AS INTEGER) WHERE id = OLD.id; "
            'END',
          );

          // Backfill: fold each manufacturer's business-wide empty_crate_stock
          // into the primary store (= oldest non-deleted store by created_at).
          // Idempotent: only runs when the table was just created.
          await customStatement(
            "INSERT INTO store_crate_balances "
            "  (id, business_id, store_id, manufacturer_id, balance, "
            "   created_at, last_updated_at) "
            "SELECT "
            "  hex(randomblob(16)), "
            "  m.business_id, "
            "  (SELECT s.id FROM stores s "
            "   WHERE s.business_id = m.business_id "
            "     AND (s.is_deleted = 0 OR s.is_deleted IS NULL) "
            "   ORDER BY s.created_at ASC LIMIT 1), "
            "  m.id, "
            "  m.empty_crate_stock, "
            "  strftime('%s', 'now'), "
            "  strftime('%s', 'now') "
            "FROM manufacturers m "
            "WHERE m.empty_crate_stock > 0 "
            "  AND (m.is_deleted = 0 OR m.is_deleted IS NULL) "
            "  AND EXISTS ( "
            "    SELECT 1 FROM stores s "
            "    WHERE s.business_id = m.business_id "
            "      AND (s.is_deleted = 0 OR s.is_deleted IS NULL) "
            "  )",
          );
        }

        // 3. Add nullable store_id column to crate_ledger for business-held
        //    movements (customer rows stay null). Guard: a DB stepped back may
        //    already carry it.
        final clStoreId = await customSelect(
          "SELECT 1 FROM pragma_table_info('crate_ledger') WHERE name='store_id'",
        ).get();
        if (clStoreId.isEmpty) {
          await customStatement(
            'ALTER TABLE crate_ledger ADD COLUMN store_id TEXT REFERENCES stores(id)',
          );
        }
      }
      if (from < 45) {
        // v45 (master plan §12.3.1): cashier Quick Sale approval queue. One new
        // synced tenant table. Mirrors
        // supabase/migrations/0105_quick_sale_requests.sql. The
        // (business_id, last_updated_at) sync index and the bump trigger match
        // the generic `_postCreateStatements` loops so a fresh install
        // (onCreate) and an upgrade end up identical. Idempotency guard (like
        // v44) for a DB stepped back to < 45 by the revert-then-re-upgrade tests.
        final qsrExists = await customSelect(
          "SELECT 1 FROM sqlite_master WHERE type='table' "
          "AND name='quick_sale_requests'",
        ).get();
        if (qsrExists.isEmpty) {
          await m.createTable(quickSaleRequests);
          await customStatement(
            'CREATE INDEX idx_quick_sale_requests_business_lua '
            'ON quick_sale_requests (business_id, last_updated_at)',
          );
          await customStatement(
            'CREATE TRIGGER bump_quick_sale_requests_last_updated_at '
            'AFTER UPDATE ON quick_sale_requests '
            'FOR EACH ROW '
            'WHEN OLD.last_updated_at IS NEW.last_updated_at '
            'BEGIN '
            "UPDATE quick_sale_requests SET last_updated_at = CAST(strftime('%s', 'now') AS INTEGER) WHERE id = OLD.id; "
            'END',
          );
        }
      }
      if (from < 46) {
        // v46 (master plan §33): the crash/error diagnostic log. One new
        // synced tenant table. Mirrors supabase/migrations/0108_error_logs.sql.
        // The (business_id, last_updated_at) sync index and the bump trigger
        // match the generic `_postCreateStatements` loops so a fresh install
        // (onCreate) and an upgrade end up identical. Idempotency guard (like
        // v45) for a DB stepped back to < 46 by the revert-then-re-upgrade tests.
        final errExists = await customSelect(
          "SELECT 1 FROM sqlite_master WHERE type='table' "
          "AND name='error_logs'",
        ).get();
        if (errExists.isEmpty) {
          await m.createTable(errorLogs);
          await customStatement(
            'CREATE INDEX idx_error_logs_business_lua '
            'ON error_logs (business_id, last_updated_at)',
          );
          await customStatement(
            'CREATE TRIGGER bump_error_logs_last_updated_at '
            'AFTER UPDATE ON error_logs '
            'FOR EACH ROW '
            'WHEN OLD.last_updated_at IS NEW.last_updated_at '
            'BEGIN '
            "UPDATE error_logs SET last_updated_at = CAST(strftime('%s', 'now') AS INTEGER) WHERE id = OLD.id; "
            'END',
          );
        }
      }
      if (from < 47) {
        // v47 (§21.11): per-store supplier ledgers. Add the nullable store_id
        // to supplier_ledger_entries and fold it into the append-only immutable
        // guard. Mirrors supabase/migrations/0109_supplier_ledger_store_id.sql.
        //
        // 1. Add the column (guard: a DB stepped back to < 47 by the
        //    revert-then-re-upgrade tests may already carry it).
        final hasStore = await customSelect(
          "SELECT 1 FROM pragma_table_info('supplier_ledger_entries') "
          "WHERE name = 'store_id'",
        ).get();
        if (hasStore.isEmpty) {
          await customStatement(
            'ALTER TABLE supplier_ledger_entries ADD COLUMN store_id TEXT '
            'REFERENCES stores(id)',
          );
        }
        // 2. Per-store scan index (matches _postCreateStatements so onCreate ==
        //    onUpgrade).
        await customStatement(
          'CREATE INDEX IF NOT EXISTS idx_supplier_ledger_business_store_supplier '
          'ON supplier_ledger_entries (business_id, store_id, supplier_id)',
        );
        // 3. store_id is now in the immutable column list, so the immutable
        //    trigger's WHEN clause changed. Drop + recreate BOTH append-only
        //    triggers from the single `_ledgerTables` source so the rebuilt
        //    trigger SQL matches a fresh onCreate exactly.
        await customStatement(
          'DROP TRIGGER IF EXISTS supplier_ledger_entries_immutable',
        );
        await customStatement(
          'DROP TRIGGER IF EXISTS supplier_ledger_entries_no_delete',
        );
        for (final stmt in _ledgerTriggerStatements(
          _ledgerTables.firstWhere((l) => l.table == 'supplier_ledger_entries'),
        )) {
          await customStatement(stmt);
        }
      }
      if (from < 48) {
        // v48 (master plan §10.3): add the settings.delete_business permission
        // — gates the CEO-only "Delete Business & Account" Danger Zone. CEO-only
        // by default; the CEO grant arrives from the cloud via pull (CEO backfill
        // in supabase/migrations/0112_delete_business_and_account.sql). Hidden
        // from the per-role toggle list via kHiddenPermissionKeys. Idempotent —
        // key is the PK.
        await customStatement(
          "INSERT OR IGNORE INTO permissions (key, description, category) "
          "VALUES ('settings.delete_business', "
          "'Delete the business and account', 'System')",
        );
      }
      if (from < 49) {
        // v49: drop the dead `last_notification_sent_at` column from users. The
        // "Waiting for Assignment" screen and its 48h escalation-notification
        // system were removed; nothing reads or writes the column anymore.
        // Mirrors supabase/migrations/0115_drop_last_notification_sent_at.sql.
        //
        // Raw DROP COLUMN (not m.alterTable(TableMigration(users))) on purpose:
        // TableMigration rebuilds from the CURRENT Drift schema and couples this
        // block to it — exactly the trap the v12 users rebuild hit (see the
        // `from < 12` note above). DROP COLUMN is independent of the live shape.
        // SQLite 3.35+ supports it (bundled via sqlite3_flutter_libs). Wrapped in
        // try/catch for idempotency: the revert-then-re-upgrade migration tests
        // build users at the v49 shape (no column) before driving onUpgrade, so
        // the DROP would otherwise error with "no such column".
        try {
          await customStatement(
            'ALTER TABLE users DROP COLUMN last_notification_sent_at',
          );
        } catch (_) {
          /* already gone */
        }
      }
      if (from < 50) {
        // v50: add owner_id to businesses — mirrors the cloud's existing
        // owner_id column. Nullable so existing rows survive the upgrade;
        // they are backfilled from the cloud on the next pull, and new
        // onboarding writes it explicitly.
        try {
          await customStatement(
            'ALTER TABLE businesses ADD COLUMN owner_id TEXT',
          );
        } catch (_) {
          /* already present (idempotency guard) */
        }
      }
      if (from < 51) {
        // v51: add phone and address to users — collected during staff
        // sign-up (§6) and synced to the cloud. Nullable; existing rows
        // are left as NULL and may be filled by a future pull.
        // try/catch guards the revert-then-re-upgrade test pattern: the
        // migration test creates a v51 DB (with both columns), reverts the
        // user_version, then re-runs onUpgrade — the columns already exist.
        try {
          await customStatement('ALTER TABLE users ADD COLUMN phone TEXT');
        } catch (_) {
          /* already present (idempotency guard) */
        }
        try {
          await customStatement('ALTER TABLE users ADD COLUMN address TEXT');
        } catch (_) {
          /* already present (idempotency guard) */
        }
      }
      if (from < 52) {
        // v52 (§6.8.1 automatic orphan recovery): add auto_retry_count to the
        // device-local outbox tables. Tracks how many times the auto-recovery
        // sweep has re-enqueued a row so the per-orphan retry cap survives a
        // re-orphan. Local-only — sync_queue / sync_queue_orphans are never
        // pushed (they ARE the outbox), so there is no cloud migration. NOT
        // NULL DEFAULT 0 so existing rows read as "never auto-retried".
        // try/catch guards the revert-then-re-upgrade test pattern.
        try {
          await customStatement(
            'ALTER TABLE sync_queue ADD COLUMN auto_retry_count '
            'INTEGER NOT NULL DEFAULT 0',
          );
        } catch (_) {
          /* already present (idempotency guard) */
        }
        try {
          await customStatement(
            'ALTER TABLE sync_queue_orphans ADD COLUMN auto_retry_count '
            'INTEGER NOT NULL DEFAULT 0',
          );
        } catch (_) {
          /* already present (idempotency guard) */
        }
      }
      if (from < 53) {
        // v53 (§3.13 supplier empty-crate tracking): two new tables — the
        // supplier-side mirror of the customer crate ledger + balance cache.
        // Mirrors supabase/migrations/0117_supplier_crate_tracking.sql.
        //
        // 1. `supplier_crate_ledger` — a new synced, append-only ledger table
        //    (same new-synced-table shape as the v46 error_logs block, plus the
        //    append-only ledger triggers emitted from the single `_ledgerTables`
        //    source so a fresh install (onCreate) and an upgrade end up
        //    identical). Idempotency guard (like v44/v45/v46) for a DB stepped
        //    back to < 53 by the revert-then-re-upgrade tests.
        final sclExists = await customSelect(
          "SELECT 1 FROM sqlite_master WHERE type='table' "
          "AND name='supplier_crate_ledger'",
        ).get();
        if (sclExists.isEmpty) {
          await m.createTable(supplierCrateLedger);
          await customStatement(
            'CREATE INDEX idx_supplier_crate_ledger_business_lua '
            'ON supplier_crate_ledger (business_id, last_updated_at)',
          );
          await customStatement(
            'CREATE INDEX idx_supplier_crate_ledger_owner '
            'ON supplier_crate_ledger (business_id, supplier_id, manufacturer_id, created_at)',
          );
          await customStatement(
            'CREATE TRIGGER bump_supplier_crate_ledger_last_updated_at '
            'AFTER UPDATE ON supplier_crate_ledger '
            'FOR EACH ROW '
            'WHEN OLD.last_updated_at IS NEW.last_updated_at '
            'BEGIN '
            "UPDATE supplier_crate_ledger SET last_updated_at = CAST(strftime('%s', 'now') AS INTEGER) WHERE id = OLD.id; "
            'END',
          );
          for (final stmt in _ledgerTriggerStatements(
            _ledgerTables.firstWhere((l) => l.table == 'supplier_crate_ledger'),
          )) {
            await customStatement(stmt);
          }
        }

        // 2. `supplier_crate_balances` — per-(supplier, manufacturer) balance
        //    cache (mirrors customer_crate_balances). Registered in
        //    kSyncCacheTables; source of truth is supplier_crate_ledger. The
        //    DAO stamps last_updated_at on every upsert, but the bump trigger
        //    matches the store_crate_balances shape so onCreate == onUpgrade.
        final scbExists = await customSelect(
          "SELECT 1 FROM sqlite_master WHERE type='table' "
          "AND name='supplier_crate_balances'",
        ).get();
        if (scbExists.isEmpty) {
          await m.createTable(supplierCrateBalances);
          await customStatement(
            'CREATE INDEX idx_supplier_crate_balances_business_lua '
            'ON supplier_crate_balances (business_id, last_updated_at)',
          );
          await customStatement(
            'CREATE TRIGGER bump_supplier_crate_balances_last_updated_at '
            'AFTER UPDATE ON supplier_crate_balances '
            'FOR EACH ROW '
            'WHEN OLD.last_updated_at IS NEW.last_updated_at '
            'BEGIN '
            "UPDATE supplier_crate_balances SET last_updated_at = CAST(strftime('%s', 'now') AS INTEGER) WHERE id = OLD.id; "
            'END',
          );
        }
      }
      if (from < 54) {
        // v54: add the sales.set_custom_price permission — gates setting a custom
        // unit price on a cart line (a price other than the product's designated
        // selling price). CEO-only by default; the CEO can grant it to other
        // roles via CEO Settings → Roles & Permissions (it appears as a normal
        // toggle — it is NOT in kHiddenPermissionKeys). The CEO grant arrives
        // from the cloud via pull (CEO backfill in
        // supabase/migrations/0118_add_sales_custom_price_permission.sql).
        // Idempotent — key is the PK.
        await customStatement(
          "INSERT OR IGNORE INTO permissions (key, description, category) "
          "VALUES ('sales.set_custom_price', "
          "'Set a custom price on a cart item', 'Sales')",
        );
      }
      if (from < 55) {
        // v55: store-gate saved carts (§12.1). Tag each saved cart with the
        // store it was saved under so recall restores it into the right store's
        // cart bucket and the Recall list is filtered to the active store.
        // Nullable so pre-v55 rows survive as "All Stores" legacy carts. Mirrors
        // supabase/migrations/0119_saved_carts_store_id.sql.
        // Guarded so the ladder is replay-safe when the harness already built
        // the live schema (which carries store_id) before forcing an old
        // user_version — a real device upgrading from <55 lacks the column.
        final savedCartCols =
            await customSelect('PRAGMA table_info(saved_carts)').get();
        final hasStoreId =
            savedCartCols.any((r) => r.read<String>('name') == 'store_id');
        if (!hasStoreId) {
          await m.addColumn(savedCarts, savedCarts.storeId);
        }
      }
      if (from < 56) {
        // v56: two new store-transfer permissions for the requester-initiated
        // transfer flow — `stores.request_transfer` (raise a request from your
        // store) and `stores.dispatch_transfer` (approve & dispatch a request
        // from your store). CEO + Manager by default; the grants arrive from
        // the cloud via pull (CEO/Manager backfill in
        // supabase/migrations/0122_add_stores_transfer_permissions.sql, which
        // also grants the existing stores.receive_transfer to Manager).
        // Catalogue keys only locally — grants are never seeded on-device.
        // Idempotent — key is the PK.
        await customStatement(
          "INSERT OR IGNORE INTO permissions (key, description, category) "
          "VALUES ('stores.request_transfer', "
          "'Request stock from another store', 'Stores')",
        );
        await customStatement(
          "INSERT OR IGNORE INTO permissions (key, description, category) "
          "VALUES ('stores.dispatch_transfer', "
          "'Approve and dispatch stock requests from your store', 'Stores')",
        );
      }
      if (from < 57) {
        // v57: businesses.tracks_empty_crates — per-business opt-in for
        // empty-crate / returnable-case tracking (onboarding-time choice).
        // Default true so all existing crate-business tenants keep their
        // features after upgrade without any data change. Guard the add: a DB
        // stepped back by the revert-then-re-upgrade tests already carries the
        // column from onCreate (same pattern as v43 above).
        final has = await customSelect(
          "SELECT 1 FROM pragma_table_info('businesses') "
          "WHERE name = 'tracks_empty_crates'",
        ).get();
        if (has.isEmpty) {
          await m.addColumn(businesses, businesses.tracksEmptyCrates);
        }
      }
      if (from < 58) {
        // v58 (Epic 2 / FIFO batch costing — ADR 0005, issue #37): the
        // `cost_batches` per-(product, store) FIFO cost queue. One new synced
        // tenant table, seeded with one opening batch per (product, store) from
        // current stock at the product's existing scalar cost. Mirrors
        // supabase/migrations/0132_cost_batches.sql.
        //
        // 1. Create the table + its (business_id, last_updated_at) sync cursor
        //    index, the FIFO scan index, and the bump trigger — the SAME shapes
        //    the generic `_postCreateStatements` loops emit for a tenant table,
        //    so a fresh install (onCreate) and an upgrade end up identical.
        //    Idempotency guard (like v46/v53) for a DB stepped back to < 58 by
        //    the revert-then-re-upgrade tests.
        final cbExists = await customSelect(
          "SELECT 1 FROM sqlite_master WHERE type='table' "
          "AND name='cost_batches'",
        ).get();
        if (cbExists.isEmpty) {
          await m.createTable(costBatches);
          await customStatement(
            'CREATE INDEX idx_cost_batches_business_lua '
            'ON cost_batches (business_id, last_updated_at)',
          );
          await customStatement(
            'CREATE INDEX idx_cost_batches_product_store_received '
            'ON cost_batches (business_id, product_id, store_id, received_at)',
          );
          await customStatement(
            'CREATE TRIGGER bump_cost_batches_last_updated_at '
            'AFTER UPDATE ON cost_batches '
            'FOR EACH ROW '
            'WHEN OLD.last_updated_at IS NEW.last_updated_at '
            'BEGIN '
            "UPDATE cost_batches SET last_updated_at = CAST(strftime('%s', 'now') AS INTEGER) WHERE id = OLD.id; "
            'END',
          );

          // 2. Seed ONE opening batch per (product, store) from current stock at
          //    the product's existing scalar cost (buying_price_kobo). Zero-cost
          //    stock becomes an UNCOSTED batch (cost_kobo = 0). Only rows with
          //    stock on hand (quantity > 0) get a batch — an empty (product,
          //    store) has nothing to cost. received_at / created_at /
          //    last_updated_at all inherit the product's created_at so the row
          //    is byte-identical on every device and always sorts oldest.
          //
          //    The id is DETERMINISTIC (UuidV7.deterministic) so two devices
          //    that both run this migration mint the SAME opening-batch id — the
          //    rows converge via insertOnConflictUpdate on sync instead of
          //    duplicating once per device. Future receive batches use a fresh
          //    UuidV7 (one per receive).
          final stockRows = await customSelect(
            'SELECT i.business_id AS bid, i.product_id AS pid, '
            'i.store_id AS sid, i.quantity AS qty, '
            'p.buying_price_kobo AS cost, p.created_at AS rec '
            'FROM inventory i JOIN products p ON p.id = i.product_id '
            'WHERE i.quantity > 0',
          ).get();
          for (final r in stockRows) {
            final bid = r.read<String>('bid');
            final pid = r.read<String>('pid');
            final sid = r.read<String>('sid');
            final qty = r.read<int>('qty');
            final rec = r.read<int>('rec');
            final id = UuidV7.deterministic(
              'cost_batch_opening:$bid:$pid:$sid',
            );
            await customStatement(
              'INSERT INTO cost_batches '
              '(id, business_id, product_id, store_id, qty_remaining, '
              'qty_original, cost_kobo, received_at, created_at, '
              'last_updated_at) '
              'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
              [id, bid, pid, sid, qty, qty, r.read<int>('cost'), rec, rec, rec],
            );
          }
        }
      }
      if (from < 59) {
        // v59 (#78, PRD #76): products.image_url — the optional cloud image URL
        // for a product's photo, synced cross-device (the local `image_path`
        // continues to serve offline render). Nullable; photo-less products stay
        // null. Mirrors supabase/migrations/0143_product_image_url.sql. Idempotency
        // guard for a DB stepped back to < 59 by the revert-then-re-upgrade tests
        // (same pattern as v57).
        final has = await customSelect(
          "SELECT 1 FROM pragma_table_info('products') "
          "WHERE name = 'image_url'",
        ).get();
        if (has.isEmpty) {
          await m.addColumn(products, products.imageUrl);
        }
      }
      if (from < 60) {
        // v60 (oversell recovery): sync_queue.held_by_order_id — a v2 sale's
        // child rows (cost_batches / crate / wallet) are held until their
        // pos_record_sale_v2 envelope confirms, so a rejected sale never leaks
        // them to the cloud. Device-local only. Idempotency guard for a DB
        // stepped back to < 60 by the revert-then-re-upgrade tests.
        final has = await customSelect(
          "SELECT 1 FROM pragma_table_info('sync_queue') "
          "WHERE name = 'held_by_order_id'",
        ).get();
        if (has.isEmpty) {
          await m.addColumn(syncQueue, syncQueue.heldByOrderId);
        }
      }
      if (from < 61) {
        // v61 (#107 staff offboarding): widen the user_businesses.status CHECK to
        // admit the terminal `removed` state (was active/suspended only), and seed
        // the new `staff.remove` permission key into the local catalog. Mirrors
        // supabase/migrations/0149_remove_staff_member.sql.
        //
        // (1) SQLite can't ALTER a CHECK constraint, so rebuild user_businesses to
        //     pick up the 3-value CHECK from the current Drift customConstraints.
        //     TableMigration copies every row 1:1 — WIDENING keeps all existing
        //     active/suspended rows valid, so the copy never fails. drift's
        //     alterTable re-applies the table's EXISTING indexes (with their old
        //     definitions), so DROP-then-CREATE each AFTER the rebuild to stay
        //     idempotent (same fix as the v29 crate_ledger rebuild). Triggers are
        //     NOT re-applied by alterTable, but DROP IF EXISTS keeps a partial
        //     re-run (revert-then-re-upgrade migration tests) safe. The index +
        //     trigger definitions match onCreate exactly.
        await m.alterTable(TableMigration(userBusinesses));
        await customStatement(
          'DROP INDEX IF EXISTS idx_user_businesses_business_lua',
        );
        await customStatement(
          'CREATE INDEX idx_user_businesses_business_lua '
          'ON user_businesses (business_id, last_updated_at)',
        );
        await customStatement('DROP INDEX IF EXISTS idx_user_businesses_user');
        await customStatement(
          'CREATE INDEX idx_user_businesses_user ON user_businesses (user_id)',
        );
        await customStatement(
          'DROP TRIGGER IF EXISTS bump_user_businesses_last_updated_at',
        );
        await customStatement(
          'CREATE TRIGGER bump_user_businesses_last_updated_at '
          'AFTER UPDATE ON user_businesses '
          'FOR EACH ROW '
          'WHEN OLD.last_updated_at IS NEW.last_updated_at '
          'BEGIN '
          "UPDATE user_businesses SET last_updated_at = CAST(strftime('%s', 'now') AS INTEGER) WHERE id = OLD.id; "
          'END',
        );

        // (2) Seed the staff.remove permission key. CEO-only by default; the CEO
        //     grant arrives from the cloud via pull (CEO backfill in 0149). Hidden
        //     from nothing — it is a grantable Staff permission (the CEO can grant
        //     it to a Manager). Idempotent — key is the PK. Mirrors the v48
        //     settings.delete_business seed pattern.
        await customStatement(
          "INSERT OR IGNORE INTO permissions (key, description, category) "
          "VALUES ('staff.remove', "
          "'Permanently remove staff (frees their email)', 'Staff')",
        );
      }
      if (from < 62) {
        // v62 (#108 optional product units): products.unit becomes NULLABLE
        // with a relaxed CHECK (null allowed) and no DB default — a product may
        // have no unit. SQLite can't ALTER a column's NOT NULL / DEFAULT / CHECK
        // in place, so rebuild the table from the current Drift schema (nullable
        // unit, relaxed CHECK, no default) and copy every row. RELAXING keeps
        // every existing non-null unit valid, so the 1:1 copy never fails — no
        // backfill, existing units are unchanged. alterTable preserves the
        // table's indexes and the bump_products_version trigger (re-creates them
        // from sqlite_master), so nothing here needs manual recreation (same as
        // the v24 products rebuild). Mirrors
        // supabase/migrations/0151_products_unit_nullable.sql.
        await m.alterTable(TableMigration(products));
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

      // Heal a device whose global `permissions` catalogue was emptied by a
      // prior clearAllData (logout / business-delete / onboarding reset). The
      // catalogue is static config that is deliberately never synced from the
      // cloud, so an empty table has no other recovery path — Roles &
      // Permissions would show "N of 0" and the per-role editor would render no
      // toggles. Idempotent: a no-op once the catalogue is populated.
      await ensurePermissionsSeeded();
    },
  );

  SchemaAuditResult? _lastSchemaAudit;
  SchemaAuditResult? get lastSchemaAudit => _lastSchemaAudit;

  /// Re-seed the global `permissions` catalogue when it is empty.
  ///
  /// The catalogue is static config, identical on every device and the cloud,
  /// seeded at DB-create (`_postCreateStatements`) and the v13 upgrade, and is
  /// intentionally never pulled by the sync service. [clearAllData] wipes EVERY
  /// table — including this one — on logout, business-delete, and the
  /// onboarding reset; a subsequent login only re-pulls the tenant tables, so
  /// without this heal the catalogue stays empty forever. Called from
  /// `beforeOpen` (heals an already-broken device on next launch) and from
  /// [clearAllData] (re-seeds immediately so a same-session logout→login is
  /// fine). Plain INSERT is safe because we only seed when the table is empty.
  Future<void> ensurePermissionsSeeded() async {
    final row = await customSelect(
      'SELECT COUNT(*) AS c FROM permissions',
    ).getSingle();
    if (row.read<int>('c') > 0) return;
    await transaction(() async {
      for (final stmt in _permissionsSeedStatements) {
        await customStatement(stmt);
      }
    });
  }

  Future<void> clearAllData() async {
    // Append-only ledger tables carry BEFORE DELETE triggers that RAISE(ABORT)
    // (e.g. `crate_ledger_no_delete`, `<ledger>_no_delete`). PRAGMA
    // foreign_keys = OFF does NOT disable triggers, so on a real till — which
    // always has ledger rows (sales, stock movements) — the first ledger
    // delete aborts the whole transaction and NOTHING is wiped, leaving the
    // PIN-bearing `users` row behind. A full device wipe must legitimately drop
    // those guards: capture each delete-event trigger's DDL, drop it, wipe,
    // then recreate it verbatim (even if the wipe throws). The bump_* (UPDATE)
    // and _immutable (UPDATE) triggers don't fire on DELETE, so they're left.
    final triggers = await customSelect(
      "SELECT name, sql FROM sqlite_master WHERE type = 'trigger'",
    ).get();
    final deleteGuardRe = RegExp(
      r'(BEFORE|AFTER|INSTEAD\s+OF)\s+DELETE\s+ON',
      caseSensitive: false,
    );
    final deleteGuards = triggers.where((r) {
      final sql = r.read<String?>('sql') ?? '';
      return deleteGuardRe.hasMatch(sql);
    }).toList();

    // PRAGMA foreign_keys cannot be toggled inside a transaction — must run on
    // the executor before transaction() opens.
    await customStatement('PRAGMA foreign_keys = OFF');
    try {
      for (final r in deleteGuards) {
        await customStatement(
          'DROP TRIGGER IF EXISTS ${r.read<String>('name')}',
        );
      }
      await transaction(() async {
        for (final table in allTables) {
          await delete(table).go();
        }
      });
    } finally {
      // Recreate the guards from their own captured DDL — restores the
      // append-only protection even if the wipe above threw.
      for (final r in deleteGuards) {
        final sql = r.read<String?>('sql');
        if (sql != null && sql.isNotEmpty) {
          await customStatement(sql);
        }
      }
      await customStatement('PRAGMA foreign_keys = ON');
    }

    // The wipe above emptied the global `permissions` catalogue along with
    // everything else. It is static config that is never re-pulled by sync, so
    // re-seed it now — otherwise a same-session logout→login (which only
    // re-pulls tenant tables) lands on an empty catalogue and Roles &
    // Permissions shows "N of 0". Idempotent.
    await ensurePermissionsSeeded();

    // First-load overlay markers live in SharedPreferences (outside this DB) so
    // they survive the wipe above — which is exactly why they MUST be cleared
    // here. A logout / business-delete / onboarding-reset means the next pull is
    // a genuine first load again; a stale "first full pull completed" marker
    // would wrongly suppress the first-load overlay on the re-onboarded device.
    // See the documented clearAllData wipe-trap pattern (§4.2 / §7). Best-effort:
    // never let a prefs hiccup abort the wipe.
    try {
      await FirstLoadMarkerService.clearAllMarkers();
    } catch (_) {}

    // Same wipe-trap: the per-business pull cursor (`last_sync_timestamp::<biz>`)
    // and the other pull-state prefs live in SharedPreferences and survive the
    // Drift wipe above. If left behind, the next login reads the stale cursor
    // and runs an INCREMENTAL pull that skips every row created before it — the
    // catalogue, customers, and roles/permissions (and therefore the whole
    // permission-gated navigation) never re-download, leaving a re-onboarded
    // device on an almost-empty store. Reset them so the next pull runs full,
    // exactly like a brand-new device. Best-effort: never abort the wipe.
    try {
      await SyncCursorResetService.clearAll();
    } catch (_) {}
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

// ---------------------------------------------------------------------------
// Sync safeguard constants (CLAUDE.md §5). `kSyncedTenantTables`,
// `kSyncCacheTables`, and `kEnqueueableTables` are now DERIVED from the
// `SyncedTable` registry (see sync_registry.dart, part of this library) — the
// single ordered source of truth for every per-table sync fact (issue #15).
// The three guardrail layers (the SyncDao enqueue guard, the registration
// test, the raw-write leak scanner) read those derived accessors, so they
// cannot drift from the pull order / restore / push-whitelist facts.
//
// Phase D §6.3: caches (`inventory`, the `*_crate_balances`) are real Drift
// tables (UI reads from them) but are NOT tenant-scoped — domain RPCs are the
// sole cloud writers and the restore path writes the cloud-authoritative value
// back locally, so they get no `(business_id, last_updated_at)` cursor index
// and no `bump_<table>_last_updated_at` trigger at onCreate. In the registry
// they carry `isCache: true` (⇒ `kSyncCacheTables`); tenant tables carry
// `tenantScoped: true` (⇒ `kSyncedTenantTables`). `crates` was dropped in v5.

// Subset of `kSyncedTenantTables` introduced in schema v13. Used by
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
// the CEO Settings > Roles & Permissions sub-page. 39 keys total.
const List<List<String>> _defaultPermissionRows = [
  // Stores — rendered first on the role page (§10.2). CEO-only by default.
  ['stores.manage', 'Add, edit, and remove stores', 'Stores'],
  [
    'stores.receive_transfer',
    'Confirm receipt of incoming stock transfers',
    'Stores',
  ],
  [
    'stores.request_transfer',
    'Request stock from another store',
    'Stores',
  ],
  [
    'stores.dispatch_transfer',
    'Approve and dispatch stock requests from your store',
    'Stores',
  ],
  // Sales
  ['sales.make', 'Make a sale', 'Sales'],
  ['sales.cancel', 'Cancel a sale', 'Sales'],
  ['sales.discount.give', 'Give a discount on a sale', 'Sales'],
  ['sales.set_custom_price', 'Set a custom price on a cart item', 'Sales'],
  // Products
  ['products.add', 'Add a new product', 'Products'],
  ['products.edit_price', 'Edit product', 'Products'],
  ['products.edit_buying_price', 'View buying price', 'Products'],
  ['products.delete', 'Delete a product', 'Products'],
  // Stock
  ['stock.add', 'Add stock to existing products', 'Stock'],
  ['stock.view', 'View Inventory', 'Stock'],
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
  ['customers.wallet.update', 'Add credit to customer credit balances', 'Customers'],
  ['customers.set_debt_limit', 'Set a customer\'s debt limit', 'Customers'],
  [
    'customers.wallet.withdraw',
    'Refund cash from a customer credit balance',
    'Customers',
  ],
  [
    'customers.wallet.totals.view',
    'View credit balance Total In / Total Out on a customer',
    'Customers',
  ],
  // Suppliers / Shipments
  ['suppliers.manage', 'Manage suppliers and payments', 'Suppliers'],
  ['shipments.manage', 'Manage incoming shipments', 'Suppliers'],
  // Staff
  ['staff.invite', 'Generate staff invite codes', 'Staff'],
  ['staff.suspend', 'Suspend or reactivate staff', 'Staff'],
  ['staff.change_role', 'Change a staff member\'s role', 'Staff'],
  ['staff.assign_stores', 'Assign staff to stores', 'Staff'],
  // #107 staff offboarding. CEO-only by default; cloud catalog + CEO backfill:
  // 0149. The key exists everywhere before any grant syncs (role_permissions FK).
  ['staff.remove', 'Permanently remove staff (frees their email)', 'Staff'],
  // System
  ['activity_logs.view', 'View activity logs', 'System'],
  ['sync.view', 'View sync issues', 'System'],
  ['settings.manage', 'Manage business settings', 'System'],
  // §10.3 Danger Zone. CEO-only, hidden from the per-role toggle list
  // (kHiddenPermissionKeys). Cloud catalog + CEO backfill: 0112.
  ['settings.delete_business', 'Delete the business and account', 'System'],
];

// SQL statements that seed the global permissions table. Built once
// at app start (top-level final). Used by both `_postCreateStatements`
// (fresh installs) and the v13 upgrade block.
final List<String> _permissionsSeedStatements = _defaultPermissionRows
    .map(
      (row) =>
          "INSERT INTO permissions (key, description, category) "
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
  'expense_budgets',
  // v13 additions.
  'roles',
  'invite_codes',
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
  // v42 (§21.10) — supplier ledger: only the void columns + last_updated_at
  // may change after insert. v47 (§21.11) added the immutable store_id.
  _LedgerImmutability('supplier_ledger_entries', [
    'id',
    'business_id',
    'supplier_id',
    'store_id',
    'type',
    'amount_kobo',
    'signed_amount_kobo',
    'reference_type',
    'payment_method',
    'receipt_path',
    'reference_note',
    'activity_date',
    'performed_by',
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
  // v53 (§3.13) — supplier empty-crate ledger. Only the void columns +
  // last_updated_at may change after insert (same contract as crate_ledger).
  _LedgerImmutability('supplier_crate_ledger', [
    'id',
    'business_id',
    'supplier_id',
    'manufacturer_id',
    'store_id',
    'quantity_delta',
    'movement_type',
    'deposit_paid_kobo',
    'note',
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
  for (final t in kSyncedTenantTables) {
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
    // v42 (§21.10) — supplier ledger history per supplier, newest first.
    'CREATE INDEX idx_supplier_ledger_business_supplier_time ON supplier_ledger_entries (business_id, supplier_id, created_at)',
    // v47 (§21.11) — per-store balance/history scans (active-store filter).
    'CREATE INDEX idx_supplier_ledger_business_store_supplier ON supplier_ledger_entries (business_id, store_id, supplier_id)',
    // v53 (§3.13) — supplier crate ledger scans by (supplier, manufacturer).
    'CREATE INDEX idx_supplier_crate_ledger_owner ON supplier_crate_ledger (business_id, supplier_id, manufacturer_id, created_at)',
    'CREATE INDEX idx_crate_ledger_owner_group ON crate_ledger (business_id, customer_id, manufacturer_id, created_at)',
    'CREATE INDEX idx_inventory_business_ps ON inventory (business_id, product_id, store_id)',
    // v58 (Epic 2 / FIFO) — oldest-first batch scan per (product, store).
    'CREATE INDEX idx_cost_batches_product_store_received ON cost_batches (business_id, product_id, store_id, received_at)',
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
    // v30 (Daily Stock Count) — read counts per store/day for the reconciliation report.
    'CREATE INDEX idx_stock_counts_store_date ON stock_counts (store_id, business_date)',
    // v31 (Expenses budget) — one live goal per (business, store-or-null).
    'CREATE UNIQUE INDEX uq_expense_budgets_business ON expense_budgets '
        '(business_id) WHERE store_id IS NULL AND is_deleted = 0',
    'CREATE UNIQUE INDEX uq_expense_budgets_store ON expense_budgets '
        '(business_id, store_id) WHERE store_id IS NOT NULL AND is_deleted = 0',
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
  for (final t in kSyncedTenantTables) {
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
