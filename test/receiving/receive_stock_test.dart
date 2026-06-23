import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/features/receiving/state/receive_cart.dart';
import 'package:reebaplus_pos/shared/services/receive_stock_service.dart';
import 'package:reebaplus_pos/shared/services/supplier_account_service.dart';

void main() {
  late AppDatabase db;
  late ReceiveStockService service;

  const businessId = 'biz-1';
  const userId = 'user-1';
  const storeId = 'store-1';
  const manufacturerId = 'mfr-1';
  const supplierId = 'sup-1';
  const bottleProductId = 'prod-bottle';
  const plainProductId = 'prod-plain';

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    db.businessIdResolver = () => businessId;
    service = ReceiveStockService(db, SupplierAccountService(db));

    await db.into(db.businesses).insert(
        BusinessesCompanion.insert(id: const Value(businessId), name: 'Biz'));
    await db.into(db.users).insert(UsersCompanion.insert(
          id: const Value(userId),
          businessId: businessId,
          name: 'Staff',
          pin: '1234',
        ));
    await db.into(db.stores).insert(StoresCompanion.insert(
        id: const Value(storeId), businessId: businessId, name: 'Main Store'));
    await db.into(db.manufacturers).insert(ManufacturersCompanion.insert(
        id: const Value(manufacturerId),
        businessId: businessId,
        name: 'Star Lager'));
    await db.into(db.suppliers).insert(SuppliersCompanion.insert(
        id: const Value(supplierId),
        businessId: businessId,
        name: 'Acme Distributors'));
    await db.into(db.products).insert(ProductsCompanion.insert(
          id: const Value(bottleProductId),
          businessId: businessId,
          name: 'Star 60cl',
          unit: const Value('Bottle'),
          buyingPriceKobo: const Value(10000),
          manufacturerId: const Value(manufacturerId),
          trackEmpties: const Value(true),
        ));
    await db.into(db.products).insert(ProductsCompanion.insert(
          id: const Value(plainProductId),
          businessId: businessId,
          name: 'Bottled Water',
          unit: const Value('Pack'),
          buyingPriceKobo: const Value(20000),
        ));
  });

  tearDown(() async {
    await db.close();
  });

  Future<int> stockOf(String productId) async {
    final row = await db.customSelect(
      'SELECT quantity FROM inventory WHERE product_id = ? AND store_id = ?',
      variables: [Variable(productId), const Variable(storeId)],
    ).getSingleOrNull();
    return row?.read<int>('quantity') ?? 0;
  }

  Future<int> activityCount(String action) async {
    final row = await db.customSelect(
      'SELECT COUNT(*) AS c FROM activity_logs WHERE action = ?',
      variables: [Variable(action)],
    ).getSingle();
    return row.read<int>('c');
  }

  group('ReceiveCartNotifier', () {
    late ProviderContainer container;
    late ReceiveCartNotifier cart;
    late ProductData bottle;

    setUp(() async {
      container = ProviderContainer();
      cart = container.read(receiveCartProvider.notifier);
      final products = await db.catalogDao.watchAvailableProductDatas().first;
      bottle = products.firstWhere((p) => p.id == bottleProductId);
    });

    tearDown(() => container.dispose());

    test('addOrIncrement adds a line then combines by product id', () {
      cart.addOrIncrement(bottle);
      cart.addOrIncrement(bottle);
      final lines = container.read(receiveCartProvider);
      expect(lines.length, 1);
      expect(lines.first.qty, 2);
    });

    test('setProductQty sets the exact quantity, adding it if not present, and overwriting if present', () {
      // Not present initially
      cart.setProductQty(bottle, 5);
      expect(container.read(receiveCartProvider).length, 1);
      expect(container.read(receiveCartProvider).first.qty, 5);

      // Overwriting existing quantity
      cart.setProductQty(bottle, 12);
      expect(container.read(receiveCartProvider).length, 1);
      expect(container.read(receiveCartProvider).first.qty, 12);

      // Setting to 0 removes the line
      cart.setProductQty(bottle, 0);
      expect(container.read(receiveCartProvider), isEmpty);
    });

    test('tap-to-increment has no stock ceiling', () {
      for (var i = 0; i < 25; i++) {
        cart.addOrIncrement(bottle);
      }
      expect(container.read(receiveCartProvider).first.qty, 25);
    });

    test('setQty to 0 removes the line', () {
      cart.addOrIncrement(bottle);
      cart.setQty(bottleProductId, 0);
      expect(container.read(receiveCartProvider), isEmpty);
    });

    test('invoiceTotalKobo sums buying price × qty', () {
      cart.addOrIncrement(bottle, amount: 3); // 3 × 10000 = 30000
      expect(cart.invoiceTotalKobo, 30000);
      expect(cart.totalUnits, 3);
    });

    test('setRetailPrice and setWholesalePrice updates values in cart line', () {
      cart.addOrIncrement(bottle);
      cart.setRetailPrice(bottleProductId, 15000);
      cart.setWholesalePrice(bottleProductId, 14000);
      final lines = container.read(receiveCartProvider);
      expect(lines.first.retailKobo, 15000);
      expect(lines.first.wholesaleKobo, 14000);
    });
  });

  group('ReceiveStockService.confirmReceipt', () {
    test('increments stock, posts one invoice, nets crates, logs activity',
        () async {
      final lines = <ReceiveCartLine>[
        const ReceiveCartLine(
          productId: bottleProductId,
          productName: 'Star 60cl',
          unit: 'Bottle',
          qty: 5,
          buyingPriceKobo: 10000,
          retailKobo: 12000,
          wholesaleKobo: 11000,
          manufacturerId: manufacturerId,
          trackEmpties: true,
        ),
        const ReceiveCartLine(
          productId: plainProductId,
          productName: 'Bottled Water',
          unit: 'Pack',
          qty: 3,
          buyingPriceKobo: 20000,
          retailKobo: 24000,
          wholesaleKobo: 22000,
          manufacturerId: null,
          trackEmpties: false,
        ),
      ];

      await service.confirmReceipt(
        supplierId: supplierId,
        supplierName: 'Acme Distributors',
        storeId: storeId,
        dateReceived: DateTime(2026, 6, 1),
        staffId: userId,
        lines: lines,
        emptiesReturnedByManufacturer: const {manufacturerId: 2},
        note: 'Inv #42',
      );

      // Stock incremented per line.
      expect(await stockOf(bottleProductId), 5);
      expect(await stockOf(plainProductId), 3);

      // One supplier invoice posted: balance is negative (we owe).
      // 5×10000 + 3×20000 = 110000.
      expect(await db.supplierLedgerDao.getBalanceKobo(supplierId), -110000);

      // Empties returned to the supplier reduce the crate balance by 2.
      expect(
        await db.storeCrateBalancesDao.getBalance(
          storeId: storeId,
          manufacturerId: manufacturerId,
        ),
        -2,
      );

      // Summary activity row written.
      expect(await activityCount('stock.received'), 1);
    });

    test('rejects an empty cart', () async {
      expect(
        () => service.confirmReceipt(
          supplierId: supplierId,
          supplierName: 'Acme Distributors',
          storeId: storeId,
          dateReceived: DateTime(2026, 6, 1),
          staffId: userId,
          lines: const [],
          emptiesReturnedByManufacturer: const {},
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('is atomic — a failing crate write rolls back stock + invoice',
        () async {
      // A trackEmpties line whose manufacturer does not exist, combined with an
      // empties return, forces an FK violation on the crate-return write AFTER
      // the invoice + stock writes inside the transaction.
      final lines = <ReceiveCartLine>[
        const ReceiveCartLine(
          productId: bottleProductId,
          productName: 'Star 60cl',
          unit: 'Bottle',
          qty: 5,
          buyingPriceKobo: 10000,
          retailKobo: 12000,
          wholesaleKobo: 11000,
          manufacturerId: 'mfr-does-not-exist',
          trackEmpties: true,
        ),
      ];

      await expectLater(
        service.confirmReceipt(
          supplierId: supplierId,
          supplierName: 'Acme Distributors',
          storeId: storeId,
          dateReceived: DateTime(2026, 6, 1),
          staffId: userId,
          lines: lines,
          emptiesReturnedByManufacturer: const {'mfr-does-not-exist': 1},
        ),
        throwsA(anything),
      );

      // Nothing partially committed.
      expect(await stockOf(bottleProductId), 0);
      expect(await db.supplierLedgerDao.getBalanceKobo(supplierId), 0);
      expect(await activityCount('stock.received'), 0);
    });

    test('price persistence updates catalog prices on confirmReceipt', () async {
      final lines = [
        const ReceiveCartLine(
          productId: bottleProductId,
          productName: 'Star 60cl',
          unit: 'Bottle',
          qty: 5,
          buyingPriceKobo: 12000,
          retailKobo: 18000,
          wholesaleKobo: 16000,
          manufacturerId: manufacturerId,
          trackEmpties: true,
        ),
      ];

      await service.confirmReceipt(
        supplierId: supplierId,
        supplierName: 'Acme Distributors',
        storeId: storeId,
        dateReceived: DateTime(2026, 6, 1),
        staffId: userId,
        lines: lines,
        emptiesReturnedByManufacturer: const {},
      );

      final p = await (db.select(db.products)..where((t) => t.id.equals(bottleProductId))).getSingle();
      expect(p.buyingPriceKobo, 12000);
      expect(p.retailerPriceKobo, 18000);
      expect(p.wholesalerPriceKobo, 16000);
    });

    test('supplier payment on zero-value invoice does not get dropped', () async {
      final lines = [
        const ReceiveCartLine(
          productId: bottleProductId,
          productName: 'Star 60cl',
          unit: 'Bottle',
          qty: 5,
          buyingPriceKobo: 0,
          retailKobo: 10000,
          wholesaleKobo: 9000,
          manufacturerId: manufacturerId,
          trackEmpties: true,
        ),
      ];

      await service.confirmReceipt(
        supplierId: supplierId,
        supplierName: 'Acme Distributors',
        storeId: storeId,
        dateReceived: DateTime(2026, 6, 1),
        staffId: userId,
        lines: lines,
        emptiesReturnedByManufacturer: const {},
        amountPaidKobo: 5000,
        paymentMethod: 'cash',
      );

      // Ledger balance should be +5000 (we paid supplier 5000 for a 0 invoice, so supplier owes us 5000)
      expect(await db.supplierLedgerDao.getBalanceKobo(supplierId), 5000);
    });
  });
}
