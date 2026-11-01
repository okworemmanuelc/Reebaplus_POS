import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/features/receiving/state/receive_cart.dart';
import 'package:reebaplus_pos/shared/services/receive_stock_service.dart';
import 'package:reebaplus_pos/shared/services/supplier_account_service.dart';

/// Receive Stock in parts (#630): quarters land in stock, in the cost layer and
/// in the invoice (half up); a product whose parts switch is off takes whole
/// numbers only; whole-number receipts are unchanged.
void main() {
  late AppDatabase db;
  late ReceiveStockService service;

  const businessId = 'biz-1';
  const userId = 'user-1';
  const storeId = 'store-1';
  const supplierId = 'sup-1';
  const partsProduct = 'prod-parts'; // switch on
  const wholeProduct = 'prod-whole'; // switch off

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    db.businessIdResolver = () => businessId;
    service = ReceiveStockService(db, SupplierAccountService(db));
    await db
        .into(db.businesses)
        .insert(
          BusinessesCompanion.insert(id: const Value(businessId), name: 'Biz'),
        );
    await db
        .into(db.users)
        .insert(
          UsersCompanion.insert(
            id: const Value(userId),
            businessId: businessId,
            name: 'Staff',
            pin: '1234',
          ),
        );
    await db
        .into(db.stores)
        .insert(
          StoresCompanion.insert(
            id: const Value(storeId),
            businessId: businessId,
            name: 'Main',
          ),
        );
    await db
        .into(db.suppliers)
        .insert(
          SuppliersCompanion.insert(
            id: const Value(supplierId),
            businessId: businessId,
            name: 'Acme',
          ),
        );
    await db
        .into(db.products)
        .insert(
          ProductsCompanion.insert(
            id: const Value(partsProduct),
            businessId: businessId,
            name: 'Rice (bag)',
            unit: const Value('Bag'),
            buyingPriceKobo: const Value(1001),
            allowFractionalSales: const Value(true),
          ),
        );
    await db
        .into(db.products)
        .insert(
          ProductsCompanion.insert(
            id: const Value(wholeProduct),
            businessId: businessId,
            name: 'Single Bottle',
            unit: const Value('Bottle'),
            buyingPriceKobo: const Value(500),
          ),
        );
  });

  tearDown(() => db.close());

  Future<double> stockOf(String productId) async {
    final row = await db
        .customSelect(
          'SELECT quantity FROM inventory WHERE product_id = ? AND store_id = ?',
          variables: [Variable(productId), const Variable(storeId)],
        )
        .getSingleOrNull();
    return row?.read<double>('quantity') ?? 0;
  }

  ReceiveCartLine line(
    String id, {
    required double qty,
    required int price,
    bool parts = false,
  }) => ReceiveCartLine(
    productId: id,
    productName: id,
    unit: 'Bag',
    qty: qty,
    buyingPriceKobo: price,
    retailKobo: price * 2,
    wholesaleKobo: price * 2,
    trackEmpties: false,
    allowParts: parts,
  );

  Future<void> receive(List<ReceiveCartLine> lines, {String? supplier}) =>
      service.confirmReceipt(
        supplierId: supplier ?? supplierId,
        supplierName: 'Acme',
        storeId: storeId,
        dateReceived: DateTime(2026, 11, 1),
        staffId: userId,
        lines: lines,
        fullCratesReceivedByManufacturer: const {},
        emptiesReturnedByManufacturer: const {},
      );

  test(
    'a quarter lands in stock, the cost layer and the invoice (half up)',
    () async {
      await receive([line(partsProduct, qty: 1.5, price: 1001, parts: true)]);

      expect(await stockOf(partsProduct), 1.5);
      // 1001 x 1.5 = 1501.5 -> 1502 kobo owed.
      expect(await db.supplierLedgerDao.getBalanceKobo(supplierId), -1502);

      final batch = await db
          .customSelect(
            'SELECT qty_original, qty_remaining, cost_kobo FROM cost_batches '
            'WHERE product_id = ?',
            variables: [const Variable(partsProduct)],
          )
          .getSingle();
      expect(batch.read<double>('qty_original'), 1.5);
      expect(batch.read<double>('qty_remaining'), 1.5);
      expect(batch.read<int>('cost_kobo'), 1001); // per-unit cost stays exact

      final log = await db
          .customSelect(
            "SELECT description FROM activity_logs WHERE action = 'stock.received'",
          )
          .getSingle();
      expect(log.read<String>('description'), contains('1.5 unit(s)'));
    },
  );

  test('0.25 and 0.75 are accepted and sum exactly', () async {
    await receive([line(partsProduct, qty: 0.25, price: 400, parts: true)]);
    await receive([line(partsProduct, qty: 0.75, price: 400, parts: true)]);
    expect(await stockOf(partsProduct), 1.0);
    expect(await db.supplierLedgerDao.getBalanceKobo(supplierId), -(100 + 300));
  });

  test('a switched-off product rejects a part and writes nothing', () async {
    await expectLater(
      receive([line(wholeProduct, qty: 0.5, price: 500)]),
      throwsArgumentError,
    );
    expect(await stockOf(wholeProduct), 0);
    expect(await db.supplierLedgerDao.getBalanceKobo(supplierId), 0);
  });

  test('an off-quarter quantity is rejected even with the switch on', () async {
    await expectLater(
      receive([line(partsProduct, qty: 0.3, price: 500, parts: true)]),
      throwsArgumentError,
    );
    expect(await stockOf(partsProduct), 0);
  });

  test('whole-number receipts behave as before', () async {
    await receive([line(wholeProduct, qty: 5, price: 500)]);
    expect(await stockOf(wholeProduct), 5);
    expect(await db.supplierLedgerDao.getBalanceKobo(supplierId), -2500);
    final log = await db
        .customSelect(
          "SELECT description FROM activity_logs WHERE action = 'stock.received'",
        )
        .getSingle();
    expect(log.read<String>('description'), contains('5 unit(s)'));
  });

  group('ReceiveCartNotifier', () {
    late ProviderContainer container;
    late ReceiveCartNotifier cart;
    late ProductData parts;
    late ProductData whole;

    setUp(() async {
      container = ProviderContainer();
      cart = container.read(receiveCartProvider.notifier);
      final products = await db.catalogDao.watchAvailableProductDatas().first;
      parts = products.firstWhere((p) => p.id == partsProduct);
      whole = products.firstWhere((p) => p.id == wholeProduct);
    });
    tearDown(() => container.dispose());

    test('carries the product switch onto the line', () {
      cart.addOrIncrement(parts);
      cart.addOrIncrement(whole);
      final lines = container.read(receiveCartProvider);
      expect(
        lines.firstWhere((l) => l.productId == partsProduct).allowParts,
        isTrue,
      );
      expect(
        lines.firstWhere((l) => l.productId == wholeProduct).allowParts,
        isFalse,
      );
    });

    test('totals use lineTotalKobo and units show quarters', () {
      cart.setProductQty(parts, 2.5); // 1001 x 2.5 = 2502.5 -> 2503
      cart.setProductQty(whole, 3); // 500 x 3
      expect(cart.invoiceTotalKobo, 2503 + 1500);
      expect(cart.totalUnits, 5.5);
    });

    test('uncosted units add up in parts', () {
      cart.setProductQty(parts, 0.5);
      cart.setBuyingPrice(partsProduct, 0);
      expect(cart.uncostedUnits, 0.5);
      expect(cart.uncostedLineCount, 1);
    });
  });
}
