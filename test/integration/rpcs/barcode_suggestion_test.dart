@Tags(['integration'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/core/utils/factory_barcode.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../helpers/supabase_test_clients.dart';
import '../../helpers/supabase_test_env.dart';

/// Tier-2 integration tests for the shared barcode catalogue (#330, ADR 0029).
///
/// Hits real dev Supabase. Verifies:
/// 1. SQL factory-barcode functions (is_factory_gtin, gtin14) agree with
///    Dart FactoryBarcode on every vector in `test/fixtures/gtin_vectors.json`.
/// 2. public.barcode_suggestion RPC over >=3 businesses:
///    - majority wins
///    - tie goes to most recent
///    - case/spacing variants count as one name
///    - business with duplicate products votes once (most recent)
///    - deleted product doesn't vote
///    - blocked name is skipped
///    - unit vote ignores nulls
///    - non-GTIN and unknown code return zero rows
///    - kill switch off returns zero rows
/// 3. Response shape carries NO business id, product id, or vote count.
/// 4. anon cannot execute the RPC; authenticated user cannot read another
///    business's products rows.
final String? _skipReason = (() {
  try {
    TestEnv.load();
    return null;
  } on StateError catch (e) {
    return e.message;
  }
})();

List<Map<String, dynamic>> _loadVectors() {
  final raw = File('test/fixtures/gtin_vectors.json').readAsStringSync();
  final decoded = jsonDecode(raw) as Map<String, dynamic>;
  final list = decoded['vectors']! as List<dynamic>;
  return list.cast<Map<String, dynamic>>();
}

void main() {
  late TestClients clients;
  final createdBusinessIds = <String>[];
  final createdProductIds = <String>[];

  setUpAll(() async {
    if (_skipReason != null) return;
    clients = await TestClients.setUp();
  });

  tearDown(() async {
    if (_skipReason != null) return;

    // Clean up created products and businesses
    if (createdProductIds.isNotEmpty) {
      await clients.adminClient
          .from('products')
          .delete()
          .filter('id', 'in', createdProductIds);
      createdProductIds.clear();
    }

    for (final bid in createdBusinessIds) {
      await clients.adminClient.from('businesses').delete().eq('id', bid);
    }
    createdBusinessIds.clear();

    // Ensure kill switch is enabled after tests
    await clients.adminClient.from('platform_settings').upsert({
      'key': 'barcode_catalogue.suggestions_enabled',
      'value': true,
      'updated_at': DateTime.now().toIso8601String(),
    });
  });

  tearDownAll(() async {
    if (_skipReason != null) return;
    await clients.dispose();
  });

  group('SQL factory-barcode functions agree with Dart parser', () {
    final vectors = _loadVectors();

    test('is_factory_gtin and gtin14 match on every vector', () async {
      for (final v in vectors) {
        final code = v['code'] as String;
        final expectedFactory = v['factory'] as bool;
        final expectedGtin14 = v['gtin14'] as String?;

        final sqlFactory = await clients.userClient.rpc(
          'is_factory_gtin',
          params: {'p_code': code},
        );
        expect(
          sqlFactory,
          expectedFactory,
          reason: 'is_factory_gtin failed for $code (${v['note']})',
        );

        final sqlGtin14 = await clients.userClient.rpc(
          'gtin14',
          params: {'p_code': code},
        );
        expect(
          sqlGtin14,
          expectedGtin14,
          reason: 'gtin14 failed for $code (${v['note']})',
        );

        // Also assert against the Dart parser in the same loop
        expect(FactoryBarcode.isFactoryGtin(code), expectedFactory);
        expect(FactoryBarcode.padToGtin14(code), expectedGtin14);
      }
    });
  });

  group('public.barcode_suggestion RPC (Tier 2)', () {
    // A valid factory GTIN for voting tests
    const testBarcode = '6150001234561'; // EAN-13, Nigeria prefix
    final testGtin14 = FactoryBarcode.padToGtin14(testBarcode)!;

    Future<String> createTestBusiness(String name) async {
      final bid = UuidV7.generate();
      await clients.adminClient.from('businesses').insert({
        'id': bid,
        'name': name,
      });
      createdBusinessIds.add(bid);
      return bid;
    }

    Future<String> insertProduct({
      required String businessId,
      required String name,
      required String barcode,
      String? unit,
      bool isDeleted = false,
      DateTime? updatedAt,
    }) async {
      final pid = UuidV7.generate();
      createdProductIds.add(pid);
      final data = <String, dynamic>{
        'id': pid,
        'business_id': businessId,
        'name': name,
        'barcode': barcode,
        'unit': unit,
        'is_deleted': isDeleted,
      };
      if (updatedAt != null) {
        data['last_updated_at'] = updatedAt.toUtc().toIso8601String();
      }
      await clients.adminClient.from('products').insert(data);
      return pid;
    }

    test('non-GTIN and unknown code return zero rows', () async {
      // Non-GTIN
      final resNonGtin = await clients.userClient.rpc(
        'barcode_suggestion',
        params: {'p_barcode': '123'},
      );
      expect(resNonGtin, isEmpty);

      // Unknown GTIN
      final resUnknown = await clients.userClient.rpc(
        'barcode_suggestion',
        params: {'p_barcode': '5000112637922'},
      );
      expect(resUnknown, isEmpty);
    });

    test(
      'voting across 3 businesses: majority wins, case/spacing variants group, duplicate product votes once',
      () async {
        final b1 = await createTestBusiness('Biz 1');
        final b2 = await createTestBusiness('Biz 2');
        final b3 = await createTestBusiness('Biz 3');

        // Biz 1 votes "Coca-Cola 50cl" (Bottle)
        await insertProduct(
          businessId: b1,
          name: 'Coca-Cola 50cl',
          barcode: testBarcode,
          unit: 'Bottle',
          updatedAt: DateTime.utc(2026, 1, 1),
        );

        // Biz 2 votes "coca-cola   50cl" (bottle) - case & spacing variant
        await insertProduct(
          businessId: b2,
          name: 'coca-cola   50cl',
          barcode: testBarcode,
          unit: 'Bottle',
          updatedAt: DateTime.utc(2026, 1, 2),
        );

        // Biz 3 votes "Pepsi 50cl" (Can)
        await insertProduct(
          businessId: b3,
          name: 'Pepsi 50cl',
          barcode: testBarcode,
          unit: 'Can',
          updatedAt: DateTime.utc(2026, 1, 3),
        );

        // Biz 1 also has an older product with a different name - duplicate check!
        await insertProduct(
          businessId: b1,
          name: 'Old Coke',
          barcode: testBarcode,
          unit: 'Pack',
          updatedAt: DateTime.utc(2025, 1, 1),
        );

        final res = await clients.userClient.rpc(
          'barcode_suggestion',
          params: {'p_barcode': testBarcode},
        );

        expect(res, isA<List>());
        final list = res as List;
        expect(list.length, 1);

        final row = list.first as Map<String, dynamic>;
        // Response carries exactly name, unit, photo_url — NO business_id or product_id or votes
        expect(row.keys.toSet(), {'name', 'unit', 'photo_url'});

        // Majority (2 businesses vs 1) wins.
        // Spelling is normalized whitespace: 'Coca-Cola 50cl' vs 'coca-cola 50cl'.
        expect(row['name']!.toString().toLowerCase(), 'coca-cola 50cl');
        expect(row['unit'], 'Bottle');
      },
    );

    test('tie-break goes to the most recent last_updated_at', () async {
      final b1 = await createTestBusiness('Tie Biz 1');
      final b2 = await createTestBusiness('Tie Biz 2');

      final timeOld = DateTime.utc(2026, 1, 1, 10, 0);
      final timeNew = DateTime.utc(2026, 1, 2, 10, 0);

      await insertProduct(
        businessId: b1,
        name: 'Brand Alpha',
        barcode: testBarcode,
        unit: 'Bottle',
        updatedAt: timeOld,
      );

      await insertProduct(
        businessId: b2,
        name: 'Brand Beta',
        barcode: testBarcode,
        unit: 'Can',
        updatedAt: timeNew,
      );

      final res = await clients.userClient.rpc(
        'barcode_suggestion',
        params: {'p_barcode': testBarcode},
      );

      final list = res as List;
      expect(list.length, 1);
      final row = list.first as Map<String, dynamic>;
      expect(row['name'], 'Brand Beta');
      expect(row['unit'], 'Can');
    });

    test('deleted product does not vote', () async {
      final b1 = await createTestBusiness('Del Biz 1');
      final b2 = await createTestBusiness('Del Biz 2');

      // Biz 1 is active with Name A
      await insertProduct(
        businessId: b1,
        name: 'Active Product',
        barcode: testBarcode,
        unit: 'Piece',
        isDeleted: false,
      );

      // Biz 2 is deleted with Name B
      await insertProduct(
        businessId: b2,
        name: 'Deleted Product',
        barcode: testBarcode,
        unit: 'Carton',
        isDeleted: true,
      );

      final res = await clients.userClient.rpc(
        'barcode_suggestion',
        params: {'p_barcode': testBarcode},
      );

      final list = res as List;
      expect(list.length, 1);
      final row = list.first as Map<String, dynamic>;
      expect(row['name'], 'Active Product');
      expect(row['unit'], 'Piece');
    });

    test('blocked name is skipped and falls to the next candidate', () async {
      final b1 = await createTestBusiness('Block Biz 1');
      final b2 = await createTestBusiness('Block Biz 2');

      await insertProduct(
        businessId: b1,
        name: 'Profane Name',
        barcode: testBarcode,
        unit: 'Bottle',
        updatedAt: DateTime.utc(2026, 2, 1),
      );

      await insertProduct(
        businessId: b2,
        name: 'Clean Name',
        barcode: testBarcode,
        unit: 'Pack',
        updatedAt: DateTime.utc(2026, 1, 1),
      );

      // Block 'profane name'
      await clients.adminClient.from('barcode_catalogue_name_blocks').insert({
        'gtin14': testGtin14,
        'normalised_name': 'profane name',
      });

      try {
        final res = await clients.userClient.rpc(
          'barcode_suggestion',
          params: {'p_barcode': testBarcode},
        );

        final list = res as List;
        expect(list.length, 1);
        final row = list.first as Map<String, dynamic>;
        expect(row['name'], 'Clean Name');
        // Unit vote is separate (ADR 0029 §3) - Biz 1's unit is not blocked and wins tie-break
        expect(row['unit'], 'Bottle');
      } finally {
        await clients.adminClient
            .from('barcode_catalogue_name_blocks')
            .delete()
            .eq('gtin14', testGtin14)
            .eq('normalised_name', 'profane name');
      }
    });

    test('unit vote ignores null units', () async {
      final b1 = await createTestBusiness('Unit Biz 1');
      final b2 = await createTestBusiness('Unit Biz 2');

      // Biz 1 has no unit
      await insertProduct(
        businessId: b1,
        name: 'No Unit Drink',
        barcode: testBarcode,
        unit: null,
      );

      // Biz 2 has unit 'Crate'
      await insertProduct(
        businessId: b2,
        name: 'No Unit Drink',
        barcode: testBarcode,
        unit: 'Crate',
      );

      final res = await clients.userClient.rpc(
        'barcode_suggestion',
        params: {'p_barcode': testBarcode},
      );

      final list = res as List;
      expect(list.length, 1);
      final row = list.first as Map<String, dynamic>;
      expect(row['name'], 'No Unit Drink');
      expect(row['unit'], 'Crate');
    });

    test('kill switch off returns zero rows', () async {
      final b1 = await createTestBusiness('Switch Biz');
      await insertProduct(
        businessId: b1,
        name: 'Switch Drink',
        barcode: testBarcode,
        unit: 'Bottle',
      );

      // Sanity: with switch on, it returns 1 row
      final before = await clients.userClient.rpc(
        'barcode_suggestion',
        params: {'p_barcode': testBarcode},
      );
      expect(before, isNotEmpty);

      // Turn kill switch off
      await clients.adminClient.from('platform_settings').update({
        'value': false,
        'updated_at': DateTime.now().toIso8601String(),
      }).eq('key', 'barcode_catalogue.suggestions_enabled');

      final after = await clients.userClient.rpc(
        'barcode_suggestion',
        params: {'p_barcode': testBarcode},
      );
      expect(after, isEmpty);
    });
  });

  group('Permissions & RLS safety', () {
    test('anon cannot execute barcode_suggestion', () async {
      final anonClient = SupabaseClient(
        clients.env.url,
        clients.env.anonKey,
      );
      expect(
        () => anonClient.rpc(
          'barcode_suggestion',
          params: {'p_barcode': '6150001234561'},
        ),
        throwsA(isA<PostgrestException>()),
      );
      await anonClient.dispose();
    });

    test(
      'authenticated client cannot select another business products rows (RLS unchanged)',
      () async {
        final foreignBizId = UuidV7.generate();
        await clients.adminClient.from('businesses').insert({
          'id': foreignBizId,
          'name': 'Foreign Business',
        });
        createdBusinessIds.add(foreignBizId);

        final foreignProductId = UuidV7.generate();
        createdProductIds.add(foreignProductId);
        await clients.adminClient.from('products').insert({
          'id': foreignProductId,
          'business_id': foreignBizId,
          'name': 'Foreign Secret Product',
        });

        // User client belongs to clients.env.businessId != foreignBizId.
        // Direct SELECT must return empty list due to RLS.
        final rows = await clients.userClient
            .from('products')
            .select()
            .eq('id', foreignProductId);
        expect(rows, isEmpty);
      },
    );
  });
}
