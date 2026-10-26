// #438 Shopper account deletion: service call, confirm pop-up, sign-out and
// local wipe.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:reebaplus_pos/core/storefront/shopper_age_confirmation.dart';
import 'package:reebaplus_pos/core/storefront/shopper_cart.dart';
import 'package:reebaplus_pos/features/browse/screens/shopper_account_screen.dart';

import 'shopper_fixtures.dart';

Future<void> tapKey(WidgetTester tester, Key key) async {
  await tester.ensureVisible(find.byKey(key));
  await tester.tap(find.byKey(key));
  await tester.pumpAndSettle();
}

int deleteCalls(FakeShopperBackend b) =>
    b.calls.where((c) => c.$1 == 'shopper_delete_account').length;

void main() {
  test('deleteAccount calls shopper_delete_account with no parameters',
      () async {
    final backend = FakeShopperBackend()..profile = {...kProfileJson};
    await backend.service.deleteAccount();
    expect(backend.calls.single.$1, 'shopper_delete_account');
    expect(backend.calls.single.$2, isEmpty);
  });

  testWidgets('cancel in the pop-up deletes nothing', (tester) async {
    final backend = FakeShopperBackend()..profile = {...kProfileJson};
    final auth = FakeShopperAuth(email: 'ada@example.com');
    await pumpShopper(tester,
        screen: const ShopperAccountScreen(),
        backend: backend,
        size: const Size(390, 1200),
        auth: auth);
    await tapKey(tester, const Key('shopper-delete-account'));
    expect(find.text('Delete your account?'), findsOneWidget);
    await tester.tap(find.text('Keep account'));
    await tester.pumpAndSettle();
    expect(deleteCalls(backend), 0);
    expect(auth.signOuts, 0);
  });

  testWidgets('confirm deletes, clears the cart and signs out',
      (tester) async {
    final backend = FakeShopperBackend()..profile = {...kProfileJson};
    final auth = FakeShopperAuth(email: 'ada@example.com');
    final push = FakePush();
    await pumpShopper(tester,
        screen: const ShopperAccountScreen(),
        backend: backend,
        size: const Size(390, 1200),
        auth: auth,
        push: push,
        cartJson: twoShopCartJson());
    await tapKey(tester, const Key('shopper-delete-account'));
    await tapKey(tester, const Key('shopper-delete-account-confirm'));
    expect(deleteCalls(backend), 1);
    expect(auth.signOuts, 1);
    expect(push.signedOut, 1);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(ShopperCartNotifier.prefKey), '[]');
    expect(prefs.getBool(ShopperAgeConfirmationNotifier.prefKey), isNull);
    expect(find.text('Your account has been deleted.'), findsOneWidget);
    expect(find.byKey(const Key('shopper-account-signed-out')), findsOneWidget);
  });

  testWidgets('a business phone deletes shopper data but stays signed in',
      (tester) async {
    final backend = FakeShopperBackend()..profile = {...kProfileJson};
    final auth = FakeShopperAuth(email: 'ceo@example.com');
    await pumpShopper(tester,
        screen: const ShopperAccountScreen(),
        backend: backend,
        size: const Size(390, 1200),
        auth: auth,
        deviceUserId: 'user-1');
    await tapKey(tester, const Key('shopper-delete-account'));
    await tapKey(tester, const Key('shopper-delete-account-confirm'));
    expect(deleteCalls(backend), 1);
    expect(auth.signOuts, 0);
    expect(find.text("You haven't added your details yet."), findsOneWidget);
  });

  testWidgets('a failed delete keeps the Shopper signed in', (tester) async {
    final backend = FakeShopperBackend()
      ..profile = {...kProfileJson}
      ..failDelete = true;
    final auth = FakeShopperAuth(email: 'ada@example.com');
    await pumpShopper(tester,
        screen: const ShopperAccountScreen(),
        backend: backend,
        size: const Size(390, 1200),
        auth: auth);
    await tapKey(tester, const Key('shopper-delete-account'));
    await tapKey(tester, const Key('shopper-delete-account-confirm'));
    expect(auth.signOuts, 0);
    expect(find.textContaining("Couldn't delete your account"), findsOneWidget);
  });
}
