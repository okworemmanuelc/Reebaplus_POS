// #437 — the side menu's Shop entry. Behind the marketplace switch; opens
// Browse over the till with this phone's business sign-in; leaving it locks
// the till so the PIN is needed to get back.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/storefront/browse_switch.dart';
import 'package:reebaplus_pos/core/storefront/shopper_session.dart';
import 'package:reebaplus_pos/core/storefront/storefront_providers.dart';
import 'package:reebaplus_pos/features/browse/screens/browse_screen.dart';
import 'package:reebaplus_pos/shared/services/navigation_service.dart';
import 'package:reebaplus_pos/shared/widgets/app_drawer_parts.dart';

import '../browse/browse_fixtures.dart';
import '../helpers/drawer_harness.dart';
import '../helpers/screen_harness.dart';
import '../shopper/shopper_fixtures.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ScreenTestEnvironment env;

  setUpAll(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('dev.fluttercommunity.plus/connectivity'),
      (call) async => <String>['wifi'],
    );
    messenger.setMockStreamHandler(
      const EventChannel('dev.fluttercommunity.plus/connectivity_status'),
      MockStreamHandler.inline(
        onListen: (arguments, events) => events.success(<String>['wifi']),
      ),
    );
  });

  setUp(() async {
    env = await setupScreenTestEnvironment(
      productCount: 2,
      businessName: kDrawerSampleBusiness,
    );
    NavigationService().resetNavigation();
  });

  tearDown(() async {
    debugOverrideBrowseFirstEnabled(null);
    await env.dispose();
    NavigationService().resetNavigation();
  });

  final shopperOverrides = <Override>[
    storefrontServiceProvider.overrideWithValue(FakeStorefront().service),
    shopperAuthPortProvider.overrideWithValue(
      FakeShopperAuth(email: 'emeka@stallion.ng'),
    ),
  ];

  testWidgets('switch off: no Shop entry', (tester) async {
    debugOverrideBrowseFirstEnabled(false);
    await pumpOpenDrawer(tester, env: env, size: const Size(390, 844));
    expect(
      find.byKey(AppDrawerKeys.shop, skipOffstage: false),
      findsNothing,
    );
    await disposeScreen(tester);
  });

  for (final role in const [
    (slug: 'ceo', name: 'CEO', rank: 4, grants: kDrawerCeoGrants),
    (slug: 'cashier', name: 'Cashier', rank: 2, grants: {'sales.make'}),
  ]) {
    testWidgets('switch on: Shop is the last item for ${role.name}', (
      tester,
    ) async {
      debugOverrideBrowseFirstEnabled(true);
      await pumpOpenDrawer(
        tester,
        env: env,
        size: const Size(390, 844),
        roleSlug: role.slug,
        roleName: role.name,
        roleRank: role.rank,
        grants: role.grants,
      );
      final labels = tester
          .widgetList<DrawerNavTile>(
            find.byType(DrawerNavTile, skipOffstage: false),
          )
          .map((t) => t.label)
          .toList();
      expect(labels.last, 'Shop');
      await disposeScreen(tester);
    });
  }

  testWidgets('Shop opens Browse unlocked; leaving it asks for the PIN', (
    tester,
  ) async {
    debugOverrideBrowseFirstEnabled(true);
    final context = await pumpOpenDrawer(
      tester,
      env: env,
      size: const Size(390, 844),
      overrides: shopperOverrides,
    );
    final container = ProviderScope.containerOf(context, listen: false);
    final auth = container.read(authProvider);
    expect(auth.currentUser, isNotNull);

    await tester.dragUntilVisible(
      find.byKey(AppDrawerKeys.shop),
      find.byKey(AppDrawerKeys.list),
      const Offset(0, -200),
    );
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tap(find.byKey(AppDrawerKeys.shop));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }

    // Browse from the till, with the business sign-in as the Shopper login.
    final browse = tester.widget<BrowseScreen>(find.byType(BrowseScreen));
    expect(browse.fromTill, isTrue);
    expect(find.byKey(const Key('browse-sell-on-reebaplus')), findsNothing);
    // Still unlocked while shopping — the till underneath is untouched.
    expect(auth.currentUser, isNotNull);

    await tester.tap(find.byKey(const Key('browse-back-to-till')));
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 200));
    }

    // Locked: the app's router now shows the PIN screen (LoginScreen).
    expect(find.byType(BrowseScreen), findsNothing);
    expect(auth.currentUser, isNull);
    await disposeScreen(tester);
  });
}
