// saved_cart_store_gating_test.dart
//
// Pins store-gating for saved carts (§12.1 + §13.5). A saved cart is stamped
// with the store it was saved under so:
//   (a) the Recall list (watchSavedCarts) is confined to the active store, with
//       null-store legacy/All-Stores rows visible from every store;
//   (b) "All Stores" (null filter) sees every store's saved carts;
//   (c) recalling a cart (CartService.loadCart) switches the side-bar store to
//       the cart's origin store and restores the lines into THAT store's bucket,
//       so a store-A cart never leaks into store B.

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/core/services/supabase_sync_service.dart';
import 'package:reebaplus_pos/shared/services/auth_service.dart';
import 'package:reebaplus_pos/shared/services/cart_service.dart';
import 'package:reebaplus_pos/shared/services/navigation_service.dart';
import 'package:reebaplus_pos/shared/services/secure_storage_service.dart';

void main() {
  late AppDatabase db;
  late NavigationService nav;
  late CartService cart;
  late String businessId;
  late String storeA;
  late String storeB;

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
    await db.into(db.businesses).insert(
          BusinessesCompanion.insert(id: Value(businessId), name: 'Cart Biz'),
        );

    storeA = UuidV7.generate();
    storeB = UuidV7.generate();
    await db.into(db.stores).insert(
          StoresCompanion.insert(
            id: Value(storeA),
            businessId: businessId,
            name: 'Store A',
          ),
        );
    await db.into(db.stores).insert(
          StoresCompanion.insert(
            id: Value(storeB),
            businessId: businessId,
            name: 'Store B',
          ),
        );

    final client = Supabase.instance.client;
    nav = NavigationService();
    final auth = AuthService(
      db,
      nav,
      SecureStorageService(),
      SupabaseSyncService(db, client),
      client,
    );
    cart = CartService(auth, nav);
    db.businessIdResolver = () => businessId;
  });

  tearDown(() async {
    await db.close();
  });

  Future<void> seedSavedCart(String name, String? storeId) async {
    await db.ordersDao.saveCart(
      SavedCartsCompanion.insert(
        name: name,
        cartData: '[]',
        businessId: businessId,
        storeId: Value(storeId),
      ),
    );
  }

  test('(a) watchSavedCarts confines to the active store, keeping null-store '
      'legacy rows', () async {
    await seedSavedCart('A cart', storeA);
    await seedSavedCart('B cart', storeB);
    await seedSavedCart('Legacy cart', null);

    final forA = await db.ordersDao.watchSavedCarts(null, storeId: storeA).first;
    final names = forA.map((c) => c.name).toSet();
    expect(names, {'A cart', 'Legacy cart'});
    expect(names.contains('B cart'), isFalse);
  });

  test('(b) a null store filter ("All Stores") sees every saved cart',
      () async {
    await seedSavedCart('A cart', storeA);
    await seedSavedCart('B cart', storeB);
    await seedSavedCart('Legacy cart', null);

    final all = await db.ordersDao.watchSavedCarts(null).first;
    expect(all.map((c) => c.name).toSet(),
        {'A cart', 'B cart', 'Legacy cart'});
  });

  test('(c) loadCart switches to the cart\'s origin store and isolates the '
      'lines to that store\'s bucket', () async {
    // Active store is B; recall a cart that was saved under A.
    nav.setLockedStore(storeB);
    final items = [
      {'id': 'p1', 'name': 'Beer', 'qty': 2.0},
    ];

    cart.loadCart(items, null, storeId: storeA);

    // The side-bar store followed the cart, and the lines are live.
    expect(nav.lockedStoreId.value, storeA);
    expect(cart.value.single['name'], 'Beer');

    // Switching to B shows B's (empty) bucket — no leak.
    nav.setLockedStore(storeB);
    expect(cart.value, isEmpty);

    // Switching back to A restores the recalled cart.
    nav.setLockedStore(storeA);
    expect(cart.value.single['name'], 'Beer');
  });
}
