// #477 Shopper data rights: export, marketing consent, privacy note.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/storefront/shopper_models.dart';
import 'package:reebaplus_pos/core/storefront/shopper_providers.dart';
import 'package:reebaplus_pos/core/storefront/shopper_service.dart';
import 'package:reebaplus_pos/features/browse/screens/shopper_account_screen.dart';

import 'shopper_fixtures.dart';

Future<void> tapKey(WidgetTester tester, Key key) async {
  await tester.ensureVisible(find.byKey(key));
  await tester.tap(find.byKey(key));
  await tester.pumpAndSettle();
}

void main() {
  group('service', () {
    test('exportData calls shopper_export with no parameters', () async {
      final backend = FakeShopperBackend()..profile = {...kProfileJson};
      final data = await backend.service.exportData();
      expect(backend.calls.single.$1, 'shopper_export');
      expect(backend.calls.single.$2, isEmpty);
      expect((data['profile']! as Map)['name'], 'Ada Obi');
    });

    test('setMarketingOptIn sends the flag and returns the stored value',
        () async {
      final backend = FakeShopperBackend()..profile = {...kProfileJson};
      expect(await backend.service.setMarketingOptIn(true), isTrue);
      expect(backend.calls.single.$1, 'shopper_set_marketing_opt_in');
      expect(backend.calls.single.$2, {'p_opt_in': true});
    });

    test('a refused export is a ShopperException', () async {
      final service = ShopperService.withRpc(
        rpc: (fn, params) async => throw Exception('sign in to continue'),
      );
      expect(
        service.exportData(),
        throwsA(isA<ShopperException>().having(
            (e) => e.failure, 'failure', ShopperFailure.signedOut)),
      );
    });

    test('marketing opt-in defaults to off when absent', () {
      expect(ShopperProfile.fromJson(kProfileJson).marketingOptIn, isFalse);
      expect(
        ShopperProfile.fromJson({...kProfileJson, 'marketing_opt_in': true})
            .marketingOptIn,
        isTrue,
      );
    });
  });

  group('account screen', () {
    testWidgets('shows the privacy note, switch off by default', (tester) async {
      final backend = FakeShopperBackend()..profile = {...kProfileJson};
      await pumpShopper(tester,
          screen: const ShopperAccountScreen(),
          backend: backend,
          size: const Size(390, 1200),
          auth: FakeShopperAuth(email: 'ada@example.com'));
      expect(find.byKey(const Key('shopper-privacy-notice')), findsOneWidget);
      expect(find.textContaining('become responsible'), findsOneWidget);
      final sw = tester.widget<SwitchListTile>(
          find.byKey(const Key('shopper-marketing-switch')));
      expect(sw.value, isFalse);
    });

    testWidgets('turning the switch on saves consent', (tester) async {
      final backend = FakeShopperBackend()..profile = {...kProfileJson};
      await pumpShopper(tester,
          screen: const ShopperAccountScreen(),
          backend: backend,
          size: const Size(390, 1200),
          auth: FakeShopperAuth(email: 'ada@example.com'));
      await tapKey(tester, const Key('shopper-marketing-switch'));
      expect(backend.calls.where((c) => c.$1 == 'shopper_set_marketing_opt_in'),
          hasLength(1));
      final sw = tester.widget<SwitchListTile>(
          find.byKey(const Key('shopper-marketing-switch')));
      expect(sw.value, isTrue);
    });

    testWidgets('Download my data fetches the export and shares it',
        (tester) async {
      final backend = FakeShopperBackend()..profile = {...kProfileJson};
      Map<String, Object?>? shared;
      await pumpShopper(tester,
          screen: const ShopperAccountScreen(),
          backend: backend,
          size: const Size(390, 1200),
          auth: FakeShopperAuth(email: 'ada@example.com'),
          extraOverrides: [
            shopperExportSharerProvider.overrideWithValue((d) async {
              shared = d;
            }),
          ]);
      await tapKey(tester, const Key('shopper-download-data'));
      expect(backend.calls.any((c) => c.$1 == 'shopper_export'), isTrue);
      expect((shared!['profile']! as Map)['name'], 'Ada Obi');
    });

    testWidgets('a failed export shows a message and shares nothing',
        (tester) async {
      var shared = false;
      final backend = FakeShopperBackend()..profile = {...kProfileJson};
      await pumpShopper(tester,
          screen: const ShopperAccountScreen(),
          backend: backend,
          size: const Size(390, 1200),
          auth: FakeShopperAuth(email: 'ada@example.com'),
          extraOverrides: [
            shopperExportSharerProvider.overrideWithValue((d) async {
              shared = true;
              throw Exception('boom');
            }),
          ]);
      await tapKey(tester, const Key('shopper-download-data'));
      expect(shared, isTrue);
      expect(find.textContaining("Couldn't get your data"), findsOneWidget);
    });
  });
}
