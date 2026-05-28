// price_tier_check_test.dart
//
// Verifies the v15 (pivot step 4, slice a) tightening of the customers
// price_tier CHECK constraint to the two master-plan values
// (§16/§21: Retailer / Wholesaler). A fresh database (onCreate) builds
// the table from the current Drift schema, so this asserts the
// post-tighten guarantee:
//
//   * 'retailer' and 'wholesaler' are accepted,
//   * the legacy 'distributor' / 'walk_in' values are now rejected,
//   * omitting price_tier still defaults to 'retailer'.
//
// The distributor→wholesaler / walk_in→retailer data migration that
// runs on upgrade is exercised by the migration block itself; this test
// pins the constraint that the migration narrows the schema to.

import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';

void main() {
  late AppDatabase db;
  late String businessId;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    await db.customSelect('SELECT 1').get();
    businessId = UuidV7.generate();
    await db.customStatement(
      'INSERT INTO businesses (id, name) VALUES (?, ?)',
      [businessId, 'Test Business'],
    );
  });

  tearDown(() => db.close());

  Future<void> insertCustomer(String id, String? priceTier) async {
    if (priceTier == null) {
      await db.customStatement(
        'INSERT INTO customers (id, business_id, name) VALUES (?, ?, ?)',
        [id, businessId, 'C-$id'],
      );
    } else {
      await db.customStatement(
        'INSERT INTO customers (id, business_id, name, price_tier) VALUES (?, ?, ?, ?)',
        [id, businessId, 'C-$id', priceTier],
      );
    }
  }

  Future<String> readTier(String id) async {
    final row = await db
        .customSelect(
          'SELECT price_tier FROM customers WHERE id = ? LIMIT 1',
          variables: [Variable<String>(id)],
        )
        .getSingle();
    return row.read<String>('price_tier');
  }

  group('Schema v15 — customers.price_tier CHECK (retailer/wholesaler only)', () {
    test('accepts retailer', () async {
      await insertCustomer('r1', 'retailer');
      expect(await readTier('r1'), 'retailer');
    });

    test('accepts wholesaler', () async {
      await insertCustomer('w1', 'wholesaler');
      expect(await readTier('w1'), 'wholesaler');
    });

    test('defaults to retailer when omitted', () async {
      await insertCustomer('d1', null);
      expect(await readTier('d1'), 'retailer');
    });

    test('rejects legacy distributor', () async {
      await expectLater(
        insertCustomer('x1', 'distributor'),
        throwsA(isA<Exception>()),
      );
    });

    test('rejects legacy walk_in', () async {
      await expectLater(
        insertCustomer('x2', 'walk_in'),
        throwsA(isA<Exception>()),
      );
    });
  });
}
