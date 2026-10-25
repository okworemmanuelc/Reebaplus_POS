// #479: the 18+ confirmation — phone memory, cloud copy, and the gate dialog.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:reebaplus_pos/core/storefront/shopper_age_confirmation.dart';
import 'package:reebaplus_pos/core/storefront/storefront_service.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/features/browse/widgets/age_confirmation_dialog.dart';

class FakeAgeCloud {
  FakeAgeCloud({this.signedIn = false, this.confirmed = false, this.fail = false});
  bool signedIn;
  bool confirmed;
  bool fail;
  final calls = <String>[];

  late final service = ShopperAgeService.withRpc(
    isSignedIn: () => signedIn,
    rpc: (fn, params) async {
      calls.add(fn);
      if (fail) throw Exception('boom');
      if (fn == 'shopper_confirm_age') {
        confirmed = true;
        return '2026-10-25T00:00:00Z';
      }
      return confirmed ? '2026-10-25T00:00:00Z' : null;
    },
  );
}

ProviderContainer _container(FakeAgeCloud cloud) {
  final c = ProviderContainer(
    overrides: [shopperAgeServiceProvider.overrideWithValue(cloud.service)],
  );
  addTearDown(c.dispose);
  return c;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('ShopperAgeConfirmationNotifier', () {
    test('starts unconfirmed; signed-out confirm stays on the phone', () async {
      final cloud = FakeAgeCloud();
      final c = _container(cloud);
      expect(await c.read(shopperAgeConfirmationProvider.future), isFalse);
      await c.read(shopperAgeConfirmationProvider.notifier).confirm();
      expect(c.read(shopperAgeConfirmationProvider).value, isTrue);
      expect(cloud.calls, isEmpty);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(ShopperAgeConfirmationNotifier.prefKey), isTrue);
    });

    test('remembered across restarts', () async {
      SharedPreferences.setMockInitialValues(
          {ShopperAgeConfirmationNotifier.prefKey: true});
      final c = _container(FakeAgeCloud());
      expect(await c.read(shopperAgeConfirmationProvider.future), isTrue);
    });

    test('signed-in confirm is copied to the login', () async {
      final cloud = FakeAgeCloud(signedIn: true);
      final c = _container(cloud);
      await c.read(shopperAgeConfirmationProvider.future);
      await c.read(shopperAgeConfirmationProvider.notifier).confirm();
      expect(cloud.calls, ['shopper_confirm_age']);
      expect(cloud.confirmed, isTrue);
    });

    test('a failed cloud copy never blocks confirming', () async {
      final cloud = FakeAgeCloud(signedIn: true, fail: true);
      final c = _container(cloud);
      await c.read(shopperAgeConfirmationProvider.future);
      await c.read(shopperAgeConfirmationProvider.notifier).confirm();
      expect(c.read(shopperAgeConfirmationProvider).value, isTrue);
    });

    test('syncToCloud: signed out → false, no call', () async {
      final cloud = FakeAgeCloud();
      final c = _container(cloud);
      expect(await c.read(shopperAgeConfirmationProvider.notifier).syncToCloud(),
          isFalse);
      expect(cloud.calls, isEmpty);
    });

    test('syncToCloud copies a signed-out phone confirmation to the login', () async {
      SharedPreferences.setMockInitialValues(
          {ShopperAgeConfirmationNotifier.prefKey: true});
      final cloud = FakeAgeCloud(signedIn: true);
      final c = _container(cloud);
      expect(await c.read(shopperAgeConfirmationProvider.notifier).syncToCloud(),
          isTrue);
      expect(cloud.calls, ['shopper_confirm_age']);
    });

    test('syncToCloud adopts a confirmation made on another phone', () async {
      final cloud = FakeAgeCloud(signedIn: true, confirmed: true);
      final c = _container(cloud);
      expect(await c.read(shopperAgeConfirmationProvider.notifier).syncToCloud(),
          isTrue);
      expect(c.read(shopperAgeConfirmationProvider).value, isTrue);
      expect(cloud.calls, ['shopper_age_confirmed_at']);
    });

    test('syncToCloud: never confirmed → false', () async {
      final cloud = FakeAgeCloud(signedIn: true);
      final c = _container(cloud);
      expect(await c.read(shopperAgeConfirmationProvider.notifier).syncToCloud(),
          isFalse);
    });

    test('syncToCloud surfaces an unreachable cloud', () async {
      SharedPreferences.setMockInitialValues(
          {ShopperAgeConfirmationNotifier.prefKey: true});
      final cloud = FakeAgeCloud(signedIn: true, fail: true);
      final c = _container(cloud);
      await expectLater(
        c.read(shopperAgeConfirmationProvider.notifier).syncToCloud(),
        throwsA(isA<StorefrontException>()),
      );
    });
  });

  group('ensureShopperAgeConfirmed', () {
    Future<List<bool>> pumpGate(WidgetTester tester, FakeAgeCloud cloud) async {
      final results = <bool>[];
      await tester.pumpWidget(ProviderScope(
        overrides: [shopperAgeServiceProvider.overrideWithValue(cloud.service)],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: Consumer(
            builder: (context, ref, _) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () async =>
                      results.add(await ensureShopperAgeConfirmed(context, ref)),
                  child: const Text('Add beer'),
                ),
              ),
            ),
          ),
        ),
      ));
      return results;
    }

    testWidgets('asks once; confirming lets the item in', (tester) async {
      final results = await pumpGate(tester, FakeAgeCloud());
      await tester.tap(find.text('Add beer'));
      await tester.pumpAndSettle();
      expect(find.text(AgeConfirmationDialog.title), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('age-confirm')));
      await tester.pumpAndSettle();
      expect(results, [true]);

      await tester.tap(find.text('Add beer'));
      await tester.pumpAndSettle();
      expect(find.text(AgeConfirmationDialog.title), findsNothing,
          reason: 'asked only the first time');
      expect(results, [true, true]);
    });

    testWidgets('declining keeps the item out and asks again next time',
        (tester) async {
      final results = await pumpGate(tester, FakeAgeCloud());
      await tester.tap(find.text('Add beer'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('age-decline')));
      await tester.pumpAndSettle();
      expect(results, [false]);
      await tester.tap(find.text('Add beer'));
      await tester.pumpAndSettle();
      expect(find.text(AgeConfirmationDialog.title), findsOneWidget);
    });
  });
}
