// selling_in_parts_test.dart
//
// #628 — the Cart's side of selling in parts (#620 decisions 1, 4, 6, 7):
// quarters on a product whose switch is on, whole numbers on one whose switch is
// off, the stock cap in parts, and line money through the one shared rule.

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/core/services/supabase_cloud_transport.dart';
import 'package:reebaplus_pos/core/services/supabase_sync_service.dart';
import 'package:reebaplus_pos/features/customers/data/models/customer.dart';
import 'package:reebaplus_pos/features/pos/services/barcode_scan_resolver.dart';
import 'package:reebaplus_pos/features/pos/widgets/quick_sale_modal.dart';
import 'package:reebaplus_pos/shared/services/auth_service.dart';
import 'package:reebaplus_pos/shared/services/cart_service.dart';
import 'package:reebaplus_pos/shared/services/navigation_service.dart';
import 'package:reebaplus_pos/shared/services/secure_storage_service.dart';
import 'package:reebaplus_pos/shared/utils/quantity.dart';

void main() {
  late AppDatabase db;
  late CartService cart;
  late String businessId;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(
      url: 'https://placeholder.supabase.co',
      anonKey: 'placeholder',
    );
  });

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    businessId = UuidV7.generate();
    await db
        .into(db.businesses)
        .insert(
          BusinessesCompanion.insert(id: Value(businessId), name: 'Parts Biz'),
        );
    final client = Supabase.instance.client;
    final nav = NavigationService();
    final auth = AuthService(
      db,
      nav,
      SecureStorageService(),
      SupabaseSyncService(db, SupabaseCloudTransport(client)),
      client,
    );
    cart = CartService(auth, nav);
    db.businessIdResolver = () => businessId;
  });

  tearDown(() => db.close());

  Future<ProductData> product({
    String name = 'Star',
    int priceKobo = 100000,
    bool? allowParts,
  }) async {
    final id = UuidV7.generate();
    await db
        .into(db.products)
        .insert(
          ProductsCompanion.insert(
            id: Value(id),
            businessId: businessId,
            name: name,
            retailerPriceKobo: Value(priceKobo),
            allowFractionalSales: allowParts == null
                ? const Value.absent()
                : Value(allowParts),
          ),
        );
    return (db.select(db.products)..where((p) => p.id.equals(id))).getSingle();
  }

  test('a new product sells in parts by default (decision 4)', () async {
    expect((await product()).allowFractionalSales, isTrue);
  });

  group('switch on', () {
    test('takes quarter quantities', () async {
      final p = await product();
      expect(cart.addItem(p, qty: 0.5, maxStock: 10), isTrue);
      expect(cart.value.single['qty'], 0.5);
      expect(cart.updateQty(p.name, 0.25), isTrue);
      expect(cart.value.single['qty'], 0.25);
      expect(cart.updateQty(p.name, 1.75), isTrue);
      expect(cart.value.single['qty'], 1.75);
    });

    test('a value off the grid snaps down, and says it changed', () async {
      final p = await product();
      cart.addItem(p, qty: 1, maxStock: 10);
      expect(cart.updateQty(p.name, 1.3), isFalse);
      expect(cart.value.single['qty'], 1.25);
    });

    test('stock in parts is sellable: 1.5 in stock, 1.5 in the cart', () async {
      final p = await product();
      expect(cart.addItem(p, qty: 1, maxStock: 1.5), isTrue);
      expect(cart.addItem(p, qty: 1, maxStock: 1.5), isFalse);
      expect(cart.value.single['qty'], 1.5);
      expect(cart.updateQty(p.name, 3), isFalse);
      expect(cart.value.single['qty'], 1.5);
    });

    test('tapping a product with 0.5 left adds the 0.5', () async {
      final p = await product();
      expect(cart.addItem(p, qty: 1, maxStock: 0.5), isFalse);
      expect(cart.value.single['qty'], 0.5);
    });
  });

  group('switch off', () {
    test('takes whole numbers only', () async {
      final p = await product(allowParts: false);
      expect(cart.addItem(p, qty: 1.5, maxStock: 10), isFalse);
      expect(cart.value.single['qty'], 1);
      expect(cart.updateQty(p.name, 2.5), isFalse);
      expect(cart.value.single['qty'], 2);
    });

    test('a part below one keeps the line at one, never removes it', () async {
      final p = await product(allowParts: false);
      cart.addItem(p, qty: 2, maxStock: 10);
      expect(cart.updateQty(p.name, 0.5), isFalse);
      expect(cart.value.single['qty'], 1);
    });

    test('only the whole units of the stock can be sold', () async {
      final p = await product(allowParts: false);
      expect(cart.addItem(p, qty: 2, maxStock: 1.5), isFalse);
      expect(cart.value.single['qty'], 1);
      expect(cart.addItem(p, qty: 1, maxStock: 1.5), isFalse);
      expect(cart.value.single['qty'], 1);
    });

    test('0.5 in stock scans as out of stock', () async {
      final p = await product(allowParts: false);
      final outcome = resolveProduct(
        product: p,
        storeProducts: [ProductDataWithStock(product: p, totalStock: 0.5)],
        cartQty: 0,
        tier: PriceTier.retailer,
      );
      expect(outcome, isA<ScanOutOfStockHere>());
    });
  });

  test('a scan on a product in parts keeps the part of its stock', () async {
    final p = await product();
    final outcome = resolveProduct(
      product: p,
      storeProducts: [ProductDataWithStock(product: p, totalStock: 1.5)],
      cartQty: 1,
      tier: PriceTier.retailer,
    );
    expect((outcome as ScanAddSheet).stock, 1.5);
  });

  test('a Quick Sale takes parts', () {
    cart.addItem(buildQuickSaleProduct('Ice', 100), qty: 0.5);
    expect(cart.value.single['qty'], 0.5);
  });

  group('money (decision 6)', () {
    test('the line rounds half a kobo up, and the subtotal adds the lines', () async {
      final a = await product(name: 'A', priceKobo: 33334);
      final b = await product(name: 'B', priceKobo: 15002);
      cart.addItem(a, qty: 0.25, maxStock: 10);
      cart.addItem(b, qty: 0.25, maxStock: 10);
      expect(CartService.lineGrossKobo(cart.value[0]), 8334);
      expect(CartService.lineGrossKobo(cart.value[1]), 3751);
      // 83.335 + 37.505 as naira doubles would give 12084 kobo.
      expect(cart.subtotal, 120.85);
    });

    test('a part line clamps its discount to the part total', () async {
      final p = await product();
      cart.addItem(p, qty: 1, maxStock: 10);
      cart.setLineDiscount(
        p.name,
        kind: 'naira',
        enteredValue: 900,
        discountKobo: 90000,
      );
      cart.updateQty(p.name, 0.5);
      expect(cart.value.single['discountKobo'], 50000);
    });
  });

  group('Qty sale helpers', () {
    test('parseSale respects the switch', () {
      expect(Qty.parseSale('0.25', allowParts: true), 0.25);
      expect(Qty.parseSale('1.', allowParts: true), 1);
      expect(Qty.parseSale('0.3', allowParts: true), isNull);
      expect(Qty.parseSale('0', allowParts: true), isNull);
      expect(Qty.parseSale('1.5', allowParts: false), isNull);
      expect(Qty.parseSale('2', allowParts: false), 2);
    });

    test('sellable and snapDown', () {
      expect(Qty.sellable(1.75, allowParts: true), 1.75);
      expect(Qty.sellable(1.75, allowParts: false), 1);
      expect(Qty.snapDown(1.3, allowParts: true), 1.25);
    });

    test('grouped display', () {
      expect(formatQtyGrouped(1250.5), '1,250.5');
      expect(formatQtyGrouped(1250), '1,250');
      expect(formatQtyGrouped(0.25), '0.25');
      expect(formatQtyGrouped(0), '0');
    });
  });
}
