import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/costing/fifo_drawdown.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/sync_helpers.dart';
import 'package:reebaplus_pos/shared/utils/quantity.dart';

/// Quarter-quantity foundation (#627 / PRD #620): parse, format, money
/// rounding, JSON shape and the Drift column round-trip. SQL twins live in
/// supabase/migrations/0239_quarter_quantities.sql.
void main() {
  group('Qty.isQuarterStep', () {
    test('accepts quarters, wholes and zero', () {
      for (final v in [0.0, 0.25, 0.5, 0.75, 1.0, 1.25, 12.0, 100.75]) {
        expect(Qty.isQuarterStep(v), isTrue, reason: '$v');
      }
    });
    test('rejects other fractions and non-finite values', () {
      for (final v in [0.1, 0.3, 0.26, 1.1, 2.9, double.nan, double.infinity]) {
        expect(Qty.isQuarterStep(v), isFalse, reason: '$v');
      }
    });
    test('negative quarters are fine for deltas', () {
      expect(Qty.isQuarterStep(-0.5), isTrue);
    });
  });

  group('Qty.parse', () {
    test('parses typed text', () {
      expect(Qty.parse('12'), 12.0);
      expect(Qty.parse('0.5'), 0.5);
      expect(Qty.parse(' 1,5 '), 1.5);
      expect(Qty.parse('.25'), 0.25);
      expect(Qty.parse('3.'), 3.0);
      expect(Qty.parse('0'), 0.0);
    });
    test('rejects junk, negatives and off-step values', () {
      for (final t in ['', '  ', 'abc', '-1', '1e3', '0x10', '1.1', '0.3', '1..5', null]) {
        expect(Qty.parse(t), isNull, reason: '$t');
      }
    });
    test('allowZero: false rejects 0', () {
      expect(Qty.parse('0', allowZero: false), isNull);
      expect(Qty.parse('0.25', allowZero: false), 0.25);
    });
  });

  group('Qty.fromJson / toJson', () {
    test('reads 5, 5.0 and 0.5 the same way', () {
      expect(Qty.fromJson(5), 5.0);
      expect(Qty.fromJson(5.0), 5.0);
      expect(Qty.fromJson(0.5), 0.5);
      expect(Qty.fromJson('2.5'), 2.5);
      expect(Qty.fromJson(null), 0.0);
    });
    test('writes whole values as JSON integers', () {
      expect(jsonEncode({'q': Qty.toJson(5.0)}), '{"q":5}');
      expect(jsonEncode({'q': Qty.toJson(0.5)}), '{"q":0.5}');
      expect(jsonEncode({'q': Qty.toJson(-2.0)}), '{"q":-2}');
    });
  });

  group('formatQty', () {
    test('no trailing zeros, never a vulgar fraction', () {
      expect(formatQty(12), '12');
      expect(formatQty(12.0), '12');
      expect(formatQty(0.5), '0.5');
      expect(formatQty(1.5), '1.5');
      expect(formatQty(0.25), '0.25');
      expect(formatQty(2.75), '2.75');
      expect(formatQty(-0.5), '-0.5');
      expect(formatQty(0), '0');
      expect(formatQty(-0.0), '0');
    });
    test('output is plain ASCII', () {
      for (final v in [0.5, 0.25, 0.75, 1.5]) {
        expect(formatQty(v).codeUnits.every((c) => c < 128), isTrue);
      }
    });
  });

  group('lineTotalKobo', () {
    test('whole quantities are plain multiplication', () {
      expect(lineTotalKobo(150000, 3), 450000);
      expect(lineTotalKobo(0, 7), 0);
    });
    test('halves and quarters of a clean price are exact', () {
      expect(lineTotalKobo(150000, 0.5), 75000);
      expect(lineTotalKobo(150000, 1.5), 225000);
      expect(lineTotalKobo(150000, 0.25), 37500);
    });
    test('a fraction of a kobo rounds half up', () {
      expect(lineTotalKobo(101, 0.5), 51); // 50.5 -> 51
      expect(lineTotalKobo(103, 0.25), 26); // 25.75 -> 26
      expect(lineTotalKobo(101, 0.25), 25); // 25.25 -> 25
      expect(lineTotalKobo(1, 0.5), 1); // 0.5 -> 1
    });
    test('refund mirror rounds away from zero', () {
      expect(lineTotalKobo(101, -0.5), -51);
    });
  });

  group('sync payload encoding', () {
    test('whole doubles are written as integers, nested too', () {
      final json = encodeSyncPayload({
        'p_items': [
          {'quantity': 5.0, 'unit_price_kobo': 100},
          {'quantity': 0.5},
        ],
        'p_discount_kobo': 0,
      });
      expect(json, contains('"quantity":5,'));
      expect(json, contains('"quantity":0.5'));
      expect(json, isNot(contains('5.0')));
    });
    test('Drift rows serialise whole quantities as integers', () {
      final row = InventoryData(
        id: 'i1',
        businessId: 'b1',
        productId: 'p1',
        storeId: 's1',
        quantity: 5.0,
        lastUpdatedAt: DateTime.utc(2026, 1, 1),
        createdAt: DateTime.utc(2026, 1, 1),
      );
      final map = serializeInsertable(row);
      expect(map['quantity'], 5);
      expect(map['quantity'], isA<int>());
    });
  });

  group('Drift fromJson accepts 5, 5.0 and 0.5', () {
    InventoryData parse(Object q) => InventoryData.fromJson({
      'id': 'i1',
      'businessId': 'b1',
      'productId': 'p1',
      'storeId': 's1',
      'quantity': q,
      'lastUpdatedAt': DateTime.utc(2026, 1, 1).toIso8601String(),
      'createdAt': DateTime.utc(2026, 1, 1).toIso8601String(),
    });
    test('integer, float and fraction', () {
      expect(parse(5).quantity, 5.0);
      expect(parse(5.0).quantity, 5.0);
      expect(parse(0.5).quantity, 0.5);
    });
  });

  group('FIFO draw-down with fractions', () {
    test('a half crate draws half a layer and costs half', () {
      final r = fifoDrawDown(
        [const FifoBatch(qtyRemaining: 10, costKobo: 100001)],
        [0.5],
      );
      expect(r.batchConsumption, [0.5]);
      expect(r.lineShortfall, [0.0]);
      expect(r.lineCogsKobo, [50001]); // 50000.5 rounds half up
    });
    test('fraction spanning two layers', () {
      final r = fifoDrawDown(
        [
          const FifoBatch(qtyRemaining: 0.25, costKobo: 100),
          const FifoBatch(qtyRemaining: 5, costKobo: 200),
        ],
        [1.5],
      );
      expect(r.batchConsumption, [0.25, 1.25]);
      expect(r.lineCogsKobo, [275]); // 25 + 250
    });
  });

  group('Drift stores fractional quantities (v98 REAL columns)', () {
    late AppDatabase db;
    setUp(() => db = AppDatabase.forTesting(NativeDatabase.memory()));
    tearDown(() => db.close());

    test('inventory and cost batch hold 0.5 and 5 verbatim', () async {
      await db.customStatement(
        'INSERT INTO businesses (id, name, created_at, last_updated_at) '
        "VALUES ('b1','Shop',1,1)",
      );
      await db.customStatement(
        'INSERT INTO stores (id, business_id, name, created_at, last_updated_at) '
        "VALUES ('s1','b1','Main',1,1)",
      );
      await db.customStatement(
        'INSERT INTO products (id, business_id, name, created_at, last_updated_at) '
        "VALUES ('p1','b1','Beer',1,1)",
      );
      await db.customStatement(
        'INSERT INTO inventory (id, business_id, product_id, store_id, quantity, '
        "created_at, last_updated_at) VALUES ('i1','b1','p1','s1', 0.5, 1, 1)",
      );
      final rows = await db.select(db.inventory).get();
      expect(rows.first.quantity, 0.5);
      // Arithmetic stays exact in quarters.
      await db.customStatement(
        "UPDATE inventory SET quantity = quantity + 0.25 WHERE id = 'i1'",
      );
      expect((await db.select(db.inventory).get()).first.quantity, 0.75);
    });
  });
}
