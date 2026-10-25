import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show AuthException;

import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/storefront/shopper_age_confirmation.dart';
import 'package:reebaplus_pos/core/storefront/shopper_cart.dart';
import 'package:reebaplus_pos/core/storefront/shopper_providers.dart';
import 'package:reebaplus_pos/core/storefront/shopper_service.dart';
import 'package:reebaplus_pos/core/storefront/shopper_session.dart';
import 'package:reebaplus_pos/core/storefront/storefront_models.dart';
import 'package:reebaplus_pos/core/storefront/storefront_providers.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/shared/services/push_notification_service.dart';

import '../browse/browse_fixtures.dart';

/// A fake Supabase auth: any 6-digit code of '123456' signs in.
class FakeShopperAuth implements ShopperAuthPort {
  FakeShopperAuth({this.email});

  String? email;
  final sent = <String>[];
  int signOuts = 0;
  final _changes = StreamController<void>.broadcast();

  @override
  String? get currentEmail => email;

  @override
  Stream<void> get changes => _changes.stream;

  @override
  Future<void> sendCode(String email) async => sent.add(email);

  @override
  Future<void> verifyCode(String email, String code) async {
    if (code != '123456') throw const AuthException('Token has expired or is invalid');
    this.email = email;
  }

  @override
  Future<void> signOut() async {
    signOuts++;
    email = null;
  }
}

/// Records the Shopper push hooks (#476); nothing else may be called.
class FakePush implements PushNotificationService {
  int signedIn = 0;
  int signedOut = 0;

  @override
  Future<void> onShopperSignedIn() async => signedIn++;

  @override
  Future<void> onShopperSignedOut() async => signedOut++;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

/// The shopper_* RPCs in memory.
class FakeShopperBackend {
  Map<String, Object?>? profile;
  final calls = <(String, Map<String, Object?>)>[];
  final orders = <Map<String, Object?>>[];

  /// store id → failure code for shopper_place_orders.
  final failStores = <String, String>{};

  /// What shopper_report_listing answers (#478).
  Map<String, Object?> reportResult = {'ok': true};

  late final service = ShopperService.withRpc(
    rpc: (fn, params) async {
      calls.add((fn, params));
      switch (fn) {
        case 'shopper_get_profile':
          return profile;
        case 'shopper_save_profile':
          profile = {
            'name': params['p_name'],
            'phones': [
              {'id': 'ph1', 'phone': params['p_phone'], 'is_default': true},
            ],
            'addresses': [
              {
                'id': 'ad1',
                'country': params['p_country'],
                'state': params['p_state'],
                'lga': params['p_lga'],
                'street': params['p_street'],
                'is_default': true,
              },
            ],
          };
          return profile;
        case 'shopper_export':
          return {'profile': profile, 'orders': orders};
        case 'shopper_set_marketing_opt_in':
          profile = {...?profile, 'marketing_opt_in': params['p_opt_in']};
          return params['p_opt_in'];
        case 'shopper_report_listing':
          return reportResult;
        case 'shopper_save_phone':
        case 'shopper_save_address':
          return 'id';
        case 'shopper_place_orders':
          final results = <Map<String, Object?>>[];
          for (final o in params['p_orders']! as List) {
            final order = o as Map<String, Object?>;
            final store = order['store_id']! as String;
            final fail = failStores[store];
            if (fail != null) {
              results.add({'id': order['id'], 'store_id': store, 'ok': false,
                  'code': fail});
              continue;
            }
            final ref = 'ON-${orders.length + 1}';
            orders.insert(0, {
              'id': order['id'],
              'store_id': store,
              'business_name': store == 'store-2' ? 'Keffi Drinks' : 'Stallion Global',
              'store_lga': 'Keffi',
              'reference': ref,
              'status': 'new',
              'currency': 'NGN',
              'total_kobo': 900000,
              'placed_at': DateTime.utc(2026, 10, 25, 9).toIso8601String(),
              'lines': [
                for (final l in order['lines']! as List)
                  {
                    'product_id': (l as Map)['product_id'],
                    'name': 'Item',
                    'unit_price_kobo': 450000,
                    'requested_qty': l['quantity'],
                    'accepted_qty': null,
                  },
              ],
            });
            results.add({'id': order['id'], 'store_id': store, 'ok': true,
                'reference': ref, 'status': 'new', 'total_kobo': 900000,
                'currency': 'NGN'});
          }
          return results;
        case 'shopper_my_orders':
          return orders;
        case 'shopper_cancel_order':
          final row = orders.firstWhere((o) => o['id'] == params['p_order_id']);
          if (row['status'] != 'new') {
            throw Exception('order_not_cancellable');
          }
          row['status'] = 'cancelled_by_customer';
          return 'cancelled_by_customer';
      }
      throw StateError('unexpected $fn');
    },
  );
}

/// A saved cart with Star Lager (store-1, min 2 step 2) and Eva Water
/// (store-2) — two shops.
String twoShopCartJson() => jsonEncode([
  ShopperCartLine.fromCard(StorefrontCard.fromRow(kFeedRows[0]), 2).toJson(),
  ShopperCartLine.fromCard(StorefrontCard.fromRow(kFeedRows[1]), 1).toJson(),
]);

const kProfileJson = <String, Object?>{
  'name': 'Ada Obi',
  'phones': [
    {'id': 'ph1', 'phone': '08030000000', 'is_default': true},
  ],
  'addresses': [
    {
      'id': 'ad1',
      'country': 'Nigeria',
      'state': 'Nasarawa',
      'lga': 'Keffi',
      'street': '1 Road',
      'is_default': true,
    },
  ],
};

Future<void> pumpShopper(
  WidgetTester tester, {
  required Widget screen,
  FakeStorefront? storefront,
  FakeShopperBackend? backend,
  FakeShopperAuth? auth,
  FakePush? push,
  ShopperAgeService? age,
  String? cartJson,
  String? deviceUserId,
  List<Override> extraOverrides = const [],
  Size size = const Size(390, 844),
  Brightness brightness = Brightness.light,
  EdgeInsets padding = EdgeInsets.zero,
}) async {
  SharedPreferences.setMockInitialValues({
    ShopperAreaNotifier.prefKey: jsonEncode(kTestArea.toJson()),
    if (cartJson != null) ShopperCartNotifier.prefKey: cartJson,
  });
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  if (padding != EdgeInsets.zero) {
    tester.view.padding = FakeViewPadding(
      top: padding.top, right: padding.right, left: padding.left);
    tester.view.viewPadding = FakeViewPadding(
      top: padding.top, right: padding.right, left: padding.left);
  }
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        storefrontServiceProvider
            .overrideWithValue((storefront ?? FakeStorefront()).service),
        shopperServiceProvider
            .overrideWithValue((backend ?? FakeShopperBackend()).service),
        shopperAgeServiceProvider.overrideWithValue(
          age ??
              ShopperAgeService.withRpc(
                isSignedIn: () => false,
                rpc: (fn, params) async => null,
              ),
        ),
        shopperAuthPortProvider.overrideWithValue(auth ?? FakeShopperAuth()),
        pushNotificationServiceProvider.overrideWithValue(push ?? FakePush()),
        deviceUserIdProvider
            .overrideWith((ref) => ValueNotifier<String?>(deviceUserId)),
        ...extraOverrides,
      ],
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: brightness == Brightness.light ? AppTheme.light() : AppTheme.dark(),
        home: screen,
      ),
    ),
  );
  await tester.pumpAndSettle();
}
