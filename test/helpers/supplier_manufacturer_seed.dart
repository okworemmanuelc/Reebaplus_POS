// Sample data for the Supplier Detail, Manufacturer and crate-sheet tests and
// goldens (#392 PR 4): business "Stallion Global", store "Abuja HQ", made-up
// people. Run after `setupScreenTestEnvironment(productCount: 0,
// businessType: 'Beverage distributor')`. Every date is pinned, so nothing in
// a golden depends on today.

import 'package:drift/drift.dart' show Value;

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';

import 'screen_harness.dart';

/// The permissions the Manufacturer screen, Supplier Detail and their sheets
/// read.
const kSupplierManufacturerGrants = <String>{
  'sales.make',
  'stock.view',
  'stock.add',
  'products.add',
  'products.edit_price',
  'suppliers.manage',
  'expenses.approve',
  'settings.manage',
};

/// The ledger period the sample opens on: "To Date" has no start, so the
/// March 2025 rows show whenever the suite runs.
const kSampleLedgerPeriod = 'To Date';

class SupplierManufacturerSample {
  SupplierManufacturerSample({
    required this.business,
    required this.guinness,
    required this.breweries,
    required this.supplierId,
  });

  final BusinessData business;
  final ManufacturerData guinness;
  final ManufacturerData breweries;
  final String supplierId;
}

Future<SupplierManufacturerSample> seedSupplierManufacturerSample(
  ScreenTestEnvironment env,
) async {
  final db = env.db;
  final b = env.businessId;
  const staffId = 'test-user-id';

  await db.customStatement(
    "UPDATE stores SET name = 'Abuja HQ' WHERE id = '${env.storeId}'",
  );
  await db
      .update(db.businesses)
      .write(
        const BusinessesCompanion(
          type: Value('Beverage distributor'),
          tracksEmptyCrates: Value(true),
        ),
      );
  final business = await (db.select(
    db.businesses,
  )..where((t) => t.id.equals(b))).getSingle();

  await db
      .into(db.users)
      .insert(
        UsersCompanion.insert(
          id: const Value(staffId),
          businessId: b,
          name: 'Aisha Bello',
          pin: '1234',
        ),
      );

  Future<ManufacturerData> brand(
    String id,
    String name,
    int kobo,
    String product,
  ) async {
    await db
        .into(db.manufacturers)
        .insert(
          ManufacturersCompanion.insert(
            id: Value(id),
            businessId: b,
            name: name,
            depositAmountKobo: Value(kobo),
          ),
        );
    await db
        .into(db.products)
        .insert(
          ProductsCompanion.insert(
            id: Value(UuidV7.generate()),
            businessId: b,
            manufacturerId: Value(id),
            name: product,
            size: const Value('big'),
            unit: const Value('Bottle'),
            trackEmpties: const Value(true),
            retailerPriceKobo: const Value(60000),
          ),
        );
    return (db.select(
      db.manufacturers,
    )..where((m) => m.id.equals(id))).getSingle();
  }

  // Fixed ids: some lists group by manufacturer, and a random id would shuffle
  // them between runs (a golden must not).
  final guinness = await brand(
    '01900000-0000-7000-8000-000000000001',
    'Guinness Nigeria',
    150000,
    'Guinness Foreign Extra',
  );
  final breweries = await brand(
    '01900000-0000-7000-8000-000000000002',
    'Nigerian Breweries',
    120000,
    'Gulder Lager',
  );

  Future<void> crates(String mfrId, int delta, String type) => db
      .into(db.crateLedger)
      .insert(
        CrateLedgerCompanion.insert(
          id: Value(UuidV7.generate()),
          businessId: b,
          manufacturerId: Value(mfrId),
          storeId: Value(env.storeId),
          quantityDelta: delta,
          movementType: type,
          performedBy: const Value(staffId),
          createdAt: Value(DateTime(2025, 3, 12, 9, 30)),
        ),
      );
  await crates(guinness.id, 40, 'transferred_in');
  await crates(guinness.id, -3, 'damaged');
  await crates(breweries.id, 24, 'transferred_in');

  // A supplier with every contact line filled in.
  final supplierId = await db.catalogDao.insertSupplier(
    SuppliersCompanion.insert(
      businessId: b,
      name: 'Adamu Distribution Ltd',
      phone: const Value('0803 555 0100'),
      email: const Value('orders@adamu-dist.example'),
      address: const Value('Plot 12, Wuse Zone 4, Abuja'),
      bankName: const Value('Sample Bank'),
      bankAccountNumber: const Value('0123456789'),
      bankAccountName: const Value('Adamu Distribution Ltd'),
      notes: const Value('Delivers Tuesdays and Fridays'),
    ),
  );
  var i = 0;
  for (final (isInvoice, kobo, day) in const [
    (true, 25000000, 3),
    (false, 10000000, 6),
    (true, 18000000, 11),
    (false, 15000000, 17),
    (true, 9000000, 21),
  ]) {
    i++;
    await db
        .into(db.supplierLedgerEntries)
        .insert(
          SupplierLedgerEntriesCompanion.insert(
            id: Value(UuidV7.generate()),
            businessId: b,
            supplierId: supplierId,
            storeId: Value(env.storeId),
            type: isInvoice ? 'debit' : 'credit',
            amountKobo: kobo,
            signedAmountKobo: isInvoice ? -kobo : kobo,
            referenceType: isInvoice ? 'invoice' : 'payment_cash',
            activityDate: DateTime(2025, 3, day, 10, i),
          ),
        );
  }
  // Crates the supplier delivered and we still owe empties for.
  await db.supplierCrateLedgerDao.recordCrateReceiptFromSupplier(
    supplierId: supplierId,
    manufacturerId: guinness.id,
    quantity: 30,
    performedBy: staffId,
    storeId: env.storeId,
    depositPaidKobo: 0,
  );
  await db.supplierCrateLedgerDao.recordCrateReturnToSupplier(
    supplierId: supplierId,
    manufacturerId: guinness.id,
    quantity: 10,
    performedBy: staffId,
    storeId: env.storeId,
    depositRefundedKobo: 0,
  );
  await db.supplierCrateLedgerDao.recordCrateReceiptFromSupplier(
    supplierId: supplierId,
    manufacturerId: breweries.id,
    quantity: 12,
    performedBy: staffId,
    storeId: env.storeId,
    depositPaidKobo: 0,
  );

  return SupplierManufacturerSample(
    business: business,
    guinness: guinness,
    breweries: breweries,
    supplierId: supplierId,
  );
}
