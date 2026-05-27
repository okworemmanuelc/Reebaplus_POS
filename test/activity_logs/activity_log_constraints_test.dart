import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';

void main() {
  late AppDatabase db;
  late String businessId;
  late String storeId;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    businessId = UuidV7.generate();
    storeId = UuidV7.generate();
    db.businessIdResolver = () => businessId;

    await db.into(db.businesses).insert(BusinessesCompanion.insert(
          id: Value(businessId),
          name: 'Test Biz',
        ));
        
    await db.into(db.stores).insert(StoresCompanion.insert(
          id: Value(storeId),
          businessId: businessId,
          name: 'Main Store',
        ));
  });

  tearDown(() => db.close());

  group('ActivityLog CHECK constraints', () {
    test('Succeeds with zero FKs set', () async {
      await db.activityLogDao.log(
        action: 'test_action',
        description: 'No FKs set',
      );
      
      final logs = await db.select(db.activityLogs).get();
      expect(logs.length, equals(1));
      expect(logs.first.orderId, isNull);
      expect(logs.first.productId, isNull);
    });

    test('Succeeds with exactly one FK set (e.g. orderId)', () async {
      final orderId = UuidV7.generate();
      // Insert dummy order to satisfy FK
      await db.into(db.orders).insert(OrdersCompanion.insert(
        id: Value(orderId),
        businessId: businessId,
        orderNumber: 'ORD-1',
        totalAmountKobo: 0,
        netAmountKobo: 0,
        paymentType: 'cash',
        status: 'pending',
      ));

      await db.activityLogDao.log(
        action: 'order_action',
        description: 'One FK set',
        orderId: orderId,
      );

      final log = await db.select(db.activityLogs).getSingle();
      expect(log.orderId, equals(orderId));
      expect(log.productId, isNull);
    });

    test('Succeeds with exactly one FK set (e.g. productId)', () async {
      final productId = UuidV7.generate();
      // Insert dummy product to satisfy FK
      await db.into(db.products).insert(ProductsCompanion.insert(
        id: Value(productId),
        businessId: businessId,
        name: 'Test Product',
      ));

      await db.activityLogDao.log(
        action: 'product_action',
        description: 'One FK set',
        productId: productId,
      );

      final log = await db.select(db.activityLogs).getSingle();
      expect(log.productId, equals(productId));
      expect(log.orderId, isNull);
    });

    test('Fails with two FKs set (orderId + productId)', () async {
      final orderId = UuidV7.generate();
      final productId = UuidV7.generate();
      
      // Insert both to satisfy FKs (so only CHECK constraint fails)
      await db.into(db.orders).insert(OrdersCompanion.insert(
        id: Value(orderId),
        businessId: businessId,
        orderNumber: 'ORD-2',
        totalAmountKobo: 0,
        netAmountKobo: 0,
        paymentType: 'cash',
        status: 'pending',
      ));
      await db.into(db.products).insert(ProductsCompanion.insert(
        id: Value(productId),
        businessId: businessId,
        name: 'Test Product 2',
      ));

      try {
        await db.activityLogDao.log(
          action: 'bad_action',
          description: 'Two FKs set',
          orderId: orderId,
          productId: productId,
        );
        fail('Should have thrown SqliteException due to CHECK constraint');
      } catch (e) {
        // We want to ensure it's a CHECK constraint failure, not FK
        expect(e.toString(), contains('CHECK constraint failed'));
      }
    });
  });
}
