@Tags(['integration'])
library;

import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/core/utils/factory_barcode.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../helpers/supabase_test_clients.dart';
import '../../helpers/supabase_test_env.dart';

/// Tier-2 integration tests for shared catalogue reports (#335, ADR 0029 §6,
/// migration 0183). Hits real dev Supabase.
///
/// Verifies `public.report_barcode_catalogue_entry`:
/// - a report lands with the caller's business and users row;
/// - a repeat from the same business for the same GTIN updates the open
///   report; another business gets its own row;
/// - a non-member business, a non-GTIN code, empty and unknown reasons are
///   each rejected;
/// - anon can't call it; an authenticated client can't select the table;
/// - deleting a business keeps its reports with business_id and reported_by
///   set to null.
///
/// A second signed-in shop is made on the fly: a fresh business, an auth
/// user (admin API), its profile and users rows, signed in through a
/// magic-link token hash. Everything is deleted in tearDown.
final String? _skipReason = (() {
  try {
    TestEnv.load();
    return null;
  } on StateError catch (e) {
    return e.message;
  }
})();

final _random = Random.secure();

/// A random, valid EAN-13 under the Nigerian 615 prefix, so a run never
/// collides with another run's open report.
String _randomGtin() {
  final body = '615${List.generate(9, (_) => _random.nextInt(10)).join()}';
  for (var check = 0; check < 10; check++) {
    final code = '$body$check';
    if (FactoryBarcode.isFactoryGtin(code)) return code;
  }
  throw StateError('no check digit for $body');
}

typedef _Shop = ({
  String businessId,
  String userId,
  String authUserId,
  SupabaseClient client,
});

void main() {
  late TestClients clients;
  late String testUserRowId;
  final gtins = <String>[];
  final businessIds = <String>[];
  final authUserIds = <String>[];
  final shopClients = <SupabaseClient>[];

  setUpAll(() async {
    if (_skipReason != null) return;
    clients = await TestClients.setUp();
    final row = await clients.adminClient
        .from('users')
        .select('id')
        .eq('auth_user_id', clients.userClient.auth.currentUser!.id)
        .eq('business_id', clients.env.businessId)
        .single();
    testUserRowId = row['id'] as String;
  });

  tearDown(() async {
    if (_skipReason != null) return;
    final admin = clients.adminClient;
    for (final code in gtins) {
      await admin
          .from('barcode_catalogue_reports')
          .delete()
          .eq('gtin14', FactoryBarcode.padToGtin14(code)!);
    }
    gtins.clear();
    for (final c in shopClients) {
      await c.dispose();
    }
    shopClients.clear();
    for (final id in businessIds) {
      await admin.from('businesses').delete().eq('id', id);
    }
    businessIds.clear();
    for (final id in authUserIds) {
      await admin.auth.admin.deleteUser(id);
    }
    authUserIds.clear();
  });

  tearDownAll(() async {
    if (_skipReason != null) return;
    await clients.dispose();
  });

  String newGtin() {
    final code = _randomGtin();
    gtins.add(code);
    return code;
  }

  Future<String> newBusiness(String name) async {
    final id = UuidV7.generate();
    await clients.adminClient.from('businesses').insert({
      'id': id,
      'name': name,
    });
    businessIds.add(id);
    return id;
  }

  /// A second shop with its own signed-in staff member.
  Future<_Shop> newShop() async {
    final admin = clients.adminClient;
    final businessId = await newBusiness('Report Shop ${UuidV7.generate()}');
    final email = 'catalogue-report-${UuidV7.generate()}@example.com';
    final created = await admin.auth.admin.createUser(
      AdminUserAttributes(email: email, emailConfirm: true),
    );
    final authUserId = created.user!.id;
    authUserIds.add(authUserId);

    await admin.from('profiles').upsert({
      'id': authUserId,
      'business_id': businessId,
      'name': 'Report Tester',
    });
    final userId = UuidV7.generate();
    await admin.from('users').insert({
      'id': userId,
      'business_id': businessId,
      'auth_user_id': authUserId,
      'name': 'Report Tester',
    });

    final link = await admin.auth.admin.generateLink(
      type: GenerateLinkType.magiclink,
      email: email,
    );
    final client = SupabaseClient(clients.env.url, clients.env.anonKey);
    shopClients.add(client);
    await client.auth.verifyOTP(
      tokenHash: link.properties.hashedToken,
      type: OtpType.magiclink,
    );
    expect(client.auth.currentUser?.id, authUserId);
    return (
      businessId: businessId,
      userId: userId,
      authUserId: authUserId,
      client: client,
    );
  }

  Future<void> report(
    SupabaseClient client, {
    required String businessId,
    required String barcode,
    List<String> reasons = const ['wrong_name'],
    String? note,
    String? shownName = 'Peak Milk 400g',
    String? shownUnit = 'Tin',
    String? shownPhotoUrl,
  }) async {
    await client.rpc(
      'report_barcode_catalogue_entry',
      params: {
        'p_business_id': businessId,
        'p_barcode': barcode,
        'p_reasons': reasons,
        'p_note': note,
        'p_shown_name': shownName,
        'p_shown_unit': shownUnit,
        'p_shown_photo_url': shownPhotoUrl,
      },
    );
  }

  Future<List<Map<String, dynamic>>> rowsFor(String code) async {
    final rows = await clients.adminClient
        .from('barcode_catalogue_reports')
        .select()
        .eq('gtin14', FactoryBarcode.padToGtin14(code)!)
        .order('created_at');
    return rows;
  }

  Matcher rejectedWith(String code) => throwsA(
    isA<PostgrestException>().having((e) => e.code, 'code', code),
  );

  group('report_barcode_catalogue_entry (Tier 2)', () {
    test('a report lands with the caller business and users row', () async {
      final code = newGtin();
      await report(
        clients.userClient,
        businessId: clients.env.businessId,
        barcode: code,
        reasons: ['bad_photo', 'wrong_name', 'wrong_name'],
        note: '  photo shows a receipt  ',
        shownPhotoUrl: 'https://x.test/p.jpg',
      );

      final rows = await rowsFor(code);
      expect(rows, hasLength(1));
      final row = rows.single;
      expect(row['gtin14'], FactoryBarcode.padToGtin14(code));
      expect(row['business_id'], clients.env.businessId);
      expect(row['reported_by'], testUserRowId);
      expect(row['reasons'], ['bad_photo', 'wrong_name']);
      expect(row['note'], 'photo shows a receipt');
      expect(row['shown_name'], 'Peak Milk 400g');
      expect(row['shown_unit'], 'Tin');
      expect(row['shown_photo_url'], 'https://x.test/p.jpg');
      expect(row['status'], 'open');
      expect(row['resolved_at'], isNull);
    }, skip: _skipReason);

    test('a repeat updates the open report; another business adds its own',
        () async {
      final code = newGtin();
      await report(
        clients.userClient,
        businessId: clients.env.businessId,
        barcode: code,
        note: 'first',
      );
      final firstId = (await rowsFor(code)).single['id'];

      await report(
        clients.userClient,
        businessId: clients.env.businessId,
        barcode: code,
        reasons: ['wrong_unit'],
        note: 'second',
        shownName: 'Peak Milk',
        shownUnit: 'Can',
      );
      var rows = await rowsFor(code);
      expect(rows, hasLength(1));
      expect(rows.single['id'], firstId);
      expect(rows.single['reasons'], ['wrong_unit']);
      expect(rows.single['note'], 'second');
      expect(rows.single['shown_name'], 'Peak Milk');
      expect(rows.single['shown_unit'], 'Can');

      final shop = await newShop();
      await report(shop.client, businessId: shop.businessId, barcode: code);
      rows = await rowsFor(code);
      expect(rows, hasLength(2));
      final theirs = rows.singleWhere((r) => r['id'] != firstId);
      expect(theirs['business_id'], shop.businessId);
      expect(theirs['reported_by'], shop.userId);

      // Once resolved, a new report from the first business opens a new row.
      await clients.adminClient
          .from('barcode_catalogue_reports')
          .update({
            'status': 'resolved',
            'resolved_at': DateTime.now().toUtc().toIso8601String(),
          })
          .eq('id', firstId as String);
      await report(
        clients.userClient,
        businessId: clients.env.businessId,
        barcode: code,
      );
      expect(await rowsFor(code), hasLength(3));
    }, skip: _skipReason);

    test('a business the caller is not a member of is rejected', () async {
      final code = newGtin();
      final otherBusiness = await newBusiness('Not My Shop');
      await expectLater(
        report(clients.userClient, businessId: otherBusiness, barcode: code),
        rejectedWith('42501'),
      );
      expect(await rowsFor(code), isEmpty);
    }, skip: _skipReason);

    test('a non-GTIN code, empty reasons and unknown reasons are rejected',
        () async {
      final code = newGtin();
      final business = clients.env.businessId;
      for (final bad in ['SCAN-1', '6150001234562', '2001234567893', '']) {
        await expectLater(
          report(clients.userClient, businessId: business, barcode: bad),
          rejectedWith('22023'),
          reason: 'barcode "$bad"',
        );
      }
      await expectLater(
        report(
          clients.userClient,
          businessId: business,
          barcode: code,
          reasons: const [],
        ),
        rejectedWith('22023'),
      );
      await expectLater(
        report(
          clients.userClient,
          businessId: business,
          barcode: code,
          reasons: const ['wrong_name', 'too_expensive'],
        ),
        rejectedWith('22023'),
      );
      await expectLater(
        report(
          clients.userClient,
          businessId: business,
          barcode: code,
          note: 'x' * 501,
        ),
        rejectedWith('22023'),
      );
      expect(await rowsFor(code), isEmpty);
    }, skip: _skipReason);

    test('anon cannot call it; an authenticated client cannot read reports',
        () async {
      final code = newGtin();
      final anon = SupabaseClient(clients.env.url, clients.env.anonKey);
      try {
        await expectLater(
          report(anon, businessId: clients.env.businessId, barcode: code),
          throwsA(isA<PostgrestException>()),
        );
      } finally {
        await anon.dispose();
      }
      expect(await rowsFor(code), isEmpty);

      await report(
        clients.userClient,
        businessId: clients.env.businessId,
        barcode: code,
      );
      await expectLater(
        clients.userClient.from('barcode_catalogue_reports').select(),
        throwsA(isA<PostgrestException>()),
      );
    }, skip: _skipReason);

    test('deleting a business keeps its reports, unlinked', () async {
      final code = newGtin();
      final shop = await newShop();
      await report(shop.client, businessId: shop.businessId, barcode: code);
      expect((await rowsFor(code)).single['reported_by'], shop.userId);

      await clients.adminClient
          .from('businesses')
          .delete()
          .eq('id', shop.businessId);

      final rows = await rowsFor(code);
      expect(rows, hasLength(1));
      expect(rows.single['business_id'], isNull);
      expect(rows.single['reported_by'], isNull);
      expect(rows.single['status'], 'open');
    }, skip: _skipReason);
  });
}
