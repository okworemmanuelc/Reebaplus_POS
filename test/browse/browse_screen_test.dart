import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/storefront/browse_switch.dart';
import 'package:reebaplus_pos/features/auth/screens/login_screen.dart';
import 'package:reebaplus_pos/features/auth/screens/welcome_screen.dart';
import 'package:reebaplus_pos/features/browse/screens/browse_screen.dart';
import 'package:reebaplus_pos/features/browse/screens/storefront_store_screen.dart';
import 'package:reebaplus_pos/main.dart';

import 'browse_fixtures.dart';
import 'package:reebaplus_pos/core/storefront/online_ordering_switch.dart';

void main() {
  // Online ordering ships switched off; these tests cover it switched on.
  setUpAll(() => debugOverrideOnlineOrderingEnabled(true));
  tearDownAll(() => debugOverrideOnlineOrderingEnabled(null));
  tearDown(() => debugOverrideBrowseFirstEnabled(null));

  group('entry routing (#425)', () {
    test('a business phone always opens on the PIN screen', () {
      for (final browseFirst in [true, false]) {
        expect(
          entryScreenWithoutSignedInUser(hasDeviceUser: true, browseFirst: browseFirst),
          isA<LoginScreen>(),
        );
      }
    });

    test('no business user: Browse when the switch is on, else Welcome', () {
      expect(entryScreenWithoutSignedInUser(hasDeviceUser: false, browseFirst: true),
          isA<BrowseScreen>());
      expect(entryScreenWithoutSignedInUser(hasDeviceUser: false, browseFirst: false),
          isA<WelcomeScreen>());
    });

    test('the switch ships off until ordering works (#426/#427)', () {
      expect(kBrowseFirstEnabled, isFalse);
      expect(entryScreenWithoutSignedInUser(hasDeviceUser: false), isA<WelcomeScreen>());
      debugOverrideBrowseFirstEnabled(true);
      expect(entryScreenWithoutSignedInUser(hasDeviceUser: false), isA<BrowseScreen>());
      expect(entryScreenWithoutSignedInUser(hasDeviceUser: true), isA<LoginScreen>());
    });
  });

  testWidgets('feed shows ranked cards with "Business · LGA", stock words and notes',
      (tester) async {
    final backend = FakeStorefront();
    await pumpBrowse(tester, screen: const BrowseScreen(), backend: backend);

    expect(find.textContaining('Keffi, Nasarawa'), findsWidgets);
    expect(find.text('Star Lager'), findsOneWidget);
    expect(find.text('Stallion Global · Nasarawa'), findsWidgets);
    expect(find.text('Keffi Drinks · Keffi'), findsOneWidget);
    expect(find.text('Low stock'), findsOneWidget);
    expect(find.text('Only 2 left'), findsOneWidget);
    expect(find.text('18+'), findsOneWidget);
    expect(find.textContaining('deposit per crate'), findsOneWidget);
    expect(find.text('Stock may be out of date'), findsOneWidget);
    expect(backend.calls.first.$1, 'storefront_feed');
    expect(backend.calls.first.$2['p_lga'], 'Keffi');
  });

  testWidgets('card opens product details with listing content (#473)',
      (tester) async {
    await pumpBrowse(tester, screen: const BrowseScreen(), backend: FakeStorefront());
    expect(find.text('Nigerian Breweries'), findsOneWidget);
    await tester.tap(find.text('Star Lager'));
    await tester.pumpAndSettle();
    final sheet = find.byKey(const Key('browse-product-sheet'));
    expect(find.descendant(of: sheet,
        matching: find.text('Chilled on request. 60cl returnable bottles.')), findsOneWidget);
    expect(find.descendant(of: sheet,
        matching: find.text('Order at least 2, in steps of 2, up to 20')), findsOneWidget);
    await tester.tap(find.text('See this store'));
    await tester.pumpAndSettle();
    expect(find.byType(StorefrontStoreScreen), findsOneWidget);
  });

  testWidgets('category chip filters the feed', (tester) async {
    final backend = FakeStorefront();
    await pumpBrowse(tester, screen: const BrowseScreen(), backend: backend);
    await tester.tap(find.byKey(const ValueKey('browse-category-beverages')));
    await tester.pumpAndSettle();
    expect(backend.calls.last.$1, 'storefront_feed');
    expect(backend.calls.last.$2['p_category'], 'beverages');
  });

  testWidgets('search shows out-of-stock items greyed and not orderable',
      (tester) async {
    final backend = FakeStorefront();
    await pumpBrowse(tester, screen: const BrowseScreen(), backend: backend);
    await tester.enterText(find.byKey(const Key('browse-search')), 'star');
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    expect(backend.calls.last.$1, 'storefront_search');
    expect(backend.calls.last.$2['p_query'], 'star');
    expect(find.text('Star Radler'), findsOneWidget);
    expect(find.text('Out of stock'), findsOneWidget);
    final dimmed = tester.widget<Opacity>(find.descendant(
      of: find.byKey(const ValueKey('browse-card-p5')),
      matching: find.byType(Opacity),
    ).first);
    expect(dimmed.opacity, lessThan(1));
    expect(
      tester.getSemantics(find.byKey(const ValueKey('browse-card-p5'))).label,
      startsWith('Star Radler, out of stock'),
    );
    // Nothing on a card adds to a cart in this slice (ordering is #426).
    expect(find.descendant(
      of: find.byKey(const ValueKey('browse-card-p5')),
      matching: find.byWidgetPredicate((w) => w is ButtonStyleButton || w is IconButton),
    ), findsNothing);
  });

  testWidgets('Sell on Reebaplus opens the Welcome screen', (tester) async {
    await pumpBrowse(tester, screen: const BrowseScreen(), backend: FakeStorefront());
    await tester.tap(find.byKey(const Key('browse-sell-on-reebaplus')));
    await tester.pumpAndSettle();
    expect(find.byType(WelcomeScreen), findsOneWidget);
  });

  testWidgets('offline: connect message, Sell on Reebaplus still works',
      (tester) async {
    final backend = FakeStorefront(online: false);
    await pumpBrowse(tester, screen: const BrowseScreen(), backend: backend);
    expect(find.text('Connect to the internet to browse'), findsOneWidget);
    expect(backend.calls, isEmpty);

    backend.online = true;
    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();
    expect(find.text('Star Lager'), findsOneWidget);

    backend.online = false;
    await tester.tap(find.byKey(const Key('browse-sell-on-reebaplus')));
    await tester.pumpAndSettle();
    expect(find.byType(WelcomeScreen), findsOneWidget);
  });

  testWidgets('first Browse asks for the area; "all of Nigeria" loads the feed',
      (tester) async {
    final backend = FakeStorefront();
    await pumpBrowse(tester, screen: const BrowseScreen(), backend: backend, area: null);
    expect(find.text('Where should we deliver?'), findsOneWidget);
    expect(backend.calls, isEmpty);
    await tester.tap(find.text('Browse all of Nigeria'));
    await tester.pumpAndSettle();
    expect(backend.calls.single.$2['p_state'], isNull);
    expect(find.text('Star Lager'), findsOneWidget);
  });

  testWidgets('empty feed says no shops deliver here yet', (tester) async {
    final backend = FakeStorefront()..feed = [];
    await pumpBrowse(tester, screen: const BrowseScreen(), backend: backend);
    expect(find.text('No shops deliver here yet'), findsOneWidget);
  });

  testWidgets('tapping the business opens its store page', (tester) async {
    final backend = FakeStorefront();
    await pumpBrowse(tester, screen: const BrowseScreen(), backend: backend);
    await tester.tap(find.text('Keffi Drinks · Keffi'));
    await tester.pumpAndSettle();
    expect(find.byType(StorefrontStoreScreen), findsOneWidget);
    final storeCall = backend.calls.firstWhere((c) => c.$1 == 'storefront_store');
    expect(storeCall.$2['p_store_id'], 'store-2');
    expect(storeCall.$2['p_lga'], 'Keffi');
  });

  testWidgets('store outside the area: browsable with the no-delivery notice',
      (tester) async {
    final backend = FakeStorefront();
    await pumpBrowse(tester,
        screen: const StorefrontStoreScreen(storeId: 'store-9'), backend: backend);
    expect(find.text('Far Away Ventures'), findsOneWidget);
    expect(find.text("This store doesn't deliver to your area"), findsOneWidget);
    expect(find.text('Star Radler'), findsOneWidget);
    expect(find.text('Out of stock'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('store-search')), 'radler');
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    final last = backend.calls.last;
    expect(last.$1, 'storefront_store_products');
    expect(last.$2['p_query'], 'radler');
  });

  testWidgets('unlisted store says it is not taking online orders', (tester) async {
    final backend = FakeStorefront()..store = [];
    await pumpBrowse(tester,
        screen: const StorefrontStoreScreen(storeId: 'gone'), backend: backend);
    expect(find.text("This store isn't taking online orders"), findsOneWidget);
  });

  group('keyboard up (search fields)', () {
    for (final size in const [Size(360, 640), Size(390, 844)]) {
      testWidgets('Browse search stays reachable at ${size.width.toInt()}', (tester) async {
        await pumpBrowse(tester, screen: const BrowseScreen(),
            backend: FakeStorefront(), size: size, textScale: 1.15);
        tester.view.viewInsets = const FakeViewPadding(bottom: 300);
        addTearDown(tester.view.resetViewInsets);
        await tester.showKeyboard(find.byKey(const Key('browse-search')));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.byKey(const Key('browse-search')).hitTestable(), findsOneWidget);
      });

      testWidgets('store search stays reachable at ${size.width.toInt()}', (tester) async {
        await pumpBrowse(tester, screen: const StorefrontStoreScreen(storeId: 'store-9'),
            backend: FakeStorefront(), size: size, textScale: 1.15);
        tester.view.viewInsets = const FakeViewPadding(bottom: 300);
        addTearDown(tester.view.resetViewInsets);
        await tester.showKeyboard(find.byKey(const Key('store-search')));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.byKey(const Key('store-search')).hitTestable(), findsOneWidget);
      });
    }
  });

  testWidgets('no overflow at 844x390 and text scale 1.3', (tester) async {
    await pumpBrowse(tester, screen: const BrowseScreen(), backend: FakeStorefront(),
        size: const Size(844, 390), padding: const EdgeInsets.only(top: 24, right: 48));
    expect(tester.takeException(), isNull);
    await pumpBrowse(tester, screen: const BrowseScreen(), backend: FakeStorefront(),
        size: const Size(360, 640), textScale: 1.3);
    expect(tester.takeException(), isNull);
  });
}
