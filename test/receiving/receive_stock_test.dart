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
  });

  group('ReceiveStockService.confirmReceipt', () {
    test('increments stock, posts one invoice, nets crates, logs activity',
        () async {
      final lines = [
        const ReceiveCartLine(
          productId: bottleProductId,
          productName: 'Star 60cl',
          unit: 'Bottle',
          qty: 5,
          buyingPriceKobo: 10000,
          manufacturerId: manufacturerId,
          trackEmpties: true,
        ),
        const ReceiveCartLine(
          productId: plainProductId,
          productName: 'Bottled Water',
          unit: 'Pack',
          qty: 3,
          buyingPriceKobo: 20000,
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
        emptiesReturnedByProduct: const {bottleProductId: 2},
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
          emptiesReturnedByProduct: const {},
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('is atomic — a failing crate write rolls back stock + invoice',
        () async {
      // A trackEmpties line whose manufacturer does not exist, combined with an
      // empties return, forces an FK violation on the crate-return write AFTER
      // the invoice + stock writes inside the transaction.
      final lines = [
        const ReceiveCartLine(
          productId: bottleProductId,
          productName: 'Star 60cl',
          unit: 'Bottle',
          qty: 5,
          buyingPriceKobo: 10000,
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
          emptiesReturnedByProduct: const {bottleProductId: 1},
        ),
        throwsA(anything),
      );

      // Nothing partially committed.
      expect(await stockOf(bottleProductId), 0);
      expect(await db.supplierLedgerDao.getBalanceKobo(supplierId), 0);
      expect(await activityCount('stock.received'), 0);
    });
  });
}
