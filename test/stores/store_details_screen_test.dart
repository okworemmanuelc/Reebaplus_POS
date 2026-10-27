// Store Details + the Transfer hub + the Dispatch dialog (#441, PRD #346 Wave
// 2 C, PR 2): each control renders, the main actions still work, permission-
// hidden controls stay hidden, the wide layout pairs the header cards, and
// nothing overflows at the phone, sideways and tablet sizes (keyboard up in
// the Dispatch dialog).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/permissions/gate.dart';
import 'package:reebaplus_pos/features/stores/screens/store_details_screen.dart';
import 'package:reebaplus_pos/features/stores/screens/stores_screen.dart';
import 'package:reebaplus_pos/features/stores/widgets/stores_parts.dart';

import '../helpers/screen_harness.dart';
import 'store_details_fixture.dart';

const _all = {
  'stores.request_transfer',
  'stores.dispatch_transfer',
  'stores.receive_transfer',
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ScreenTestEnvironment env;
  late StoreDetailsSeed seed;

  setUp(() async {
    env = await setupScreenTestEnvironment(
      productCount: 3,
      businessName: 'Stallion Global',
    );
    seed = await seedStoreDetails(env);
  });

  tearDown(() => env.dispose());

  Future<void> deliver(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 250));
    }
  }

  Future<void> pumpDetails(
    WidgetTester tester, {
    Size size = const Size(390, 844),
    EdgeInsets padding = const EdgeInsets.only(top: 24, bottom: 24),
    Set<String> grants = _all,
    int rank = GateTier.ceo,
    String slug = 'ceo',
    double textScale = 1.0,
    bool followView = false,
    Widget? screen,
  }) async {
    final store = (await env.db.storesDao.getStore(env.storeId))!;
    await pumpScreen(
      tester,
      env: env,
      size: size,
      padding: padding,
      screen: screen ?? StoreDetailsScreen(store: store),
      bottomNavHeight: 0,
      grantedKeys: grants,
      roleRank: rank,
      roleSlug: slug,
      roleName: slug,
      textScaler: TextScaler.linear(textScale),
      followView: followView,
      settle: false,
    );
    await deliver(tester);
  }

  /// Scrolls [finder] fully into view (the hub sits far below the fold).
  Future<void> reveal(WidgetTester tester, Finder finder) async {
    await tester.scrollUntilVisible(
      finder,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.ensureVisible(finder);
    await tester.pump();
  }

  Future<StockTransferData> transferRow(String key) => (env.db.select(
    env.db.stockTransfers,
  )..where((t) => t.id.equals(seed.ids[key]!))).getSingle();

  group('full view', () {
    testWidgets('renders the header cards, inventory, actions and hub', (
      tester,
    ) async {
      await pumpDetails(tester);
      expect(find.byKey(StoresKeys.detailsTopBar), findsOneWidget);
      expect(find.text('Abuja HQ'), findsWidgets);
      expect(find.text('14 Wuse Road, Nigeria'), findsOneWidget);
      expect(find.text('Store Value'), findsOneWidget);
      expect(find.text('Total Units'), findsOneWidget);
      expect(find.text('Products'), findsOneWidget);
      expect(find.text('Low Stock'), findsOneWidget);
      expect(find.text('Customers'), findsOneWidget);
      expect(find.byKey(StoresKeys.inventoryCard), findsOneWidget);
      expect(find.text('Inventory'), findsOneWidget);
      expect(find.text('Request Stock'), findsOneWidget);
      expect(find.text('Quick Actions'), findsOneWidget);
      expect(find.text('View Inventory'), findsOneWidget);
      expect(find.text('Stock Transfers'), findsOneWidget);
      for (final title in [
        'REQUESTS TO FULFIL',
        'INCOMING STOCK',
        'YOUR REQUESTS',
        'DISPATCHED OUT',
        'Transfer history',
      ]) {
        await tester.scrollUntilVisible(
          find.text(title),
          200,
          scrollable: find.byType(Scrollable).first,
        );
        expect(find.text(title), findsOneWidget);
      }
      expect(tester.takeException(), isNull);
      await disposeScreen(tester);
    });

    testWidgets('Transfer history expands to the past transfers', (
      tester,
    ) async {
      await pumpDetails(tester);
      await reveal(tester, find.text('Transfer history'));
      await tester.tap(find.text('Transfer history'));
      await tester.pumpAndSettle();
      await reveal(tester, find.text('CANCELLED'));
      expect(find.text('RECEIVED'), findsOneWidget);
      expect(find.text('CANCELLED'), findsOneWidget);
      expect(find.text('IN'), findsOneWidget);
      expect(find.text('OUT'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await disposeScreen(tester);
    });

    testWidgets('permission-hidden controls stay hidden', (tester) async {
      await pumpDetails(tester, grants: const {});
      expect(find.text('Request Stock'), findsNothing);
      for (final label in [
        'Accept & Dispatch',
        'Reject',
        'Confirm Receipt',
        'Cancel Transfer',
      ]) {
        await reveal(tester, find.text('Transfer history'));
        expect(find.text(label), findsNothing);
      }
      await disposeScreen(tester);
    });

    testWidgets('the hub buttons show with their gates', (tester) async {
      await pumpDetails(tester);
      for (final label in [
        'Accept & Dispatch',
        'Reject',
        'Confirm Receipt',
        'Cancel Transfer',
      ]) {
        await tester.scrollUntilVisible(
          find.text(label),
          200,
          scrollable: find.byType(Scrollable).first,
        );
        expect(find.text(label), findsOneWidget);
      }
      await disposeScreen(tester);
    });

    testWidgets('Confirm Receipt receives the transfer', (tester) async {
      await pumpDetails(tester);
      await reveal(tester, find.text('Confirm Receipt'));
      await tester.tap(find.text('Confirm Receipt'));
      await deliver(tester);
      await tester.pump(const Duration(seconds: 5));
      expect((await transferRow('receive')).status, 'received');
      await disposeScreen(tester);
    });

    testWidgets('Reject declines the request', (tester) async {
      await pumpDetails(tester);
      await reveal(tester, find.text('Reject'));
      await tester.tap(find.text('Reject'));
      await deliver(tester);
      await tester.pump(const Duration(seconds: 5));
      expect((await transferRow('fulfil')).status, 'cancelled');
      await disposeScreen(tester);
    });

    testWidgets('Cancel Transfer restores the dispatched stock', (
      tester,
    ) async {
      await pumpDetails(tester);
      await reveal(tester, find.text('Cancel Transfer'));
      await tester.tap(find.text('Cancel Transfer'));
      await deliver(tester);
      await tester.pump(const Duration(seconds: 5));
      expect((await transferRow('dispatched')).status, 'cancelled');
      await disposeScreen(tester);
    });

    testWidgets('Accept & Dispatch asks for the quantity first', (
      tester,
    ) async {
      await pumpDetails(tester);
      await reveal(tester, find.text('Accept & Dispatch'));
      await tester.tap(find.text('Accept & Dispatch'));
      await tester.pumpAndSettle();
      expect(find.text('Dispatch quantity'), findsOneWidget);
      expect(find.text('Quantity to send'), findsOneWidget);
      // A zero quantity is refused and the dialog stays open.
      await tester.enterText(find.byType(TextFormField), '0');
      await tester.tap(find.text('Dispatch'));
      await tester.pumpAndSettle();
      expect(find.text('Enter a quantity above 0.'), findsOneWidget);
      expect(find.text('Dispatch quantity'), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.text('Dispatch quantity'), findsNothing);
      expect((await transferRow('fulfil')).status, 'pending');
      await disposeScreen(tester);
    });

    testWidgets('Dispatch sends the transfer', (tester) async {
      await pumpDetails(tester);
      await reveal(tester, find.text('Accept & Dispatch'));
      await tester.tap(find.text('Accept & Dispatch'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Dispatch'));
      await deliver(tester);
      await tester.pump(const Duration(seconds: 5));
      expect((await transferRow('fulfil')).status, 'in_transit');
      await disposeScreen(tester);
    });

    testWidgets('the Request Stock button opens the request screen', (
      tester,
    ) async {
      await pumpDetails(tester);
      await tester.ensureVisible(find.byKey(StoresKeys.requestStock));
      await tester.pump();
      await tester.tap(find.byKey(StoresKeys.requestStock));
      await tester.pumpAndSettle();
      expect(find.text('Deliver to store'), findsWidgets);
      await disposeScreen(tester);
    });
  });

  group('restricted view', () {
    testWidgets('a viewer not assigned to the store can browse and request', (
      tester,
    ) async {
      await pumpDetails(
        tester,
        grants: const {'stores.request_transfer'},
        rank: GateTier.cashier,
        slug: 'cashier',
      );
      expect(find.byKey(StoresKeys.restricted), findsOneWidget);
      expect(find.textContaining('You can browse this store'), findsOneWidget);
      expect(find.text('Request Stock from this store'), findsOneWidget);
      expect(find.text('Store Value'), findsNothing);
      expect(find.text('Stock Transfers'), findsNothing);
      expect(find.text('Quick Actions'), findsNothing);
      await disposeScreen(tester);
    });

    testWidgets('without the request gate there is no request button', (
      tester,
    ) async {
      await pumpDetails(
        tester,
        grants: const {},
        rank: GateTier.cashier,
        slug: 'cashier',
      );
      expect(find.byKey(StoresKeys.restricted), findsOneWidget);
      expect(find.text('Request Stock from this store'), findsNothing);
      await disposeScreen(tester);
    });
  });

  group('navigation', () {
    testWidgets('a Stores card opens Store Details and back returns', (
      tester,
    ) async {
      await pumpDetails(tester, screen: const StoresScreen());
      await tester.tap(
        find.descendant(
          of: find.byKey(StoresKeys.card(env.storeId)),
          matching: find.text('Abuja Hq'), // card name-cases (#507)
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(StoreDetailsScreen), findsOneWidget);
      await deliver(tester);
      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      expect(find.byType(StoreDetailsScreen), findsNothing);
      expect(find.byType(StoresScreen), findsOneWidget);
      await disposeScreen(tester);
    });

    testWidgets('the Customers tile focuses this store and goes back', (
      tester,
    ) async {
      await pumpDetails(tester, screen: const StoresScreen());
      await tester.tap(
        find.descendant(
          of: find.byKey(StoresKeys.card(env.storeId)),
          matching: find.text('Abuja Hq'), // card name-cases (#507)
        ),
      );
      await tester.pumpAndSettle();
      await deliver(tester);
      await tester.tap(find.byKey(StoresKeys.customersTile));
      await tester.pumpAndSettle();
      expect(find.byType(StoreDetailsScreen), findsNothing);
      await disposeScreen(tester);
    });
  });

  group('wide layout', () {
    testWidgets('header cards stack at 800 wide', (tester) async {
      await pumpDetails(
        tester,
        size: const Size(800, 1280),
        padding: EdgeInsets.zero,
      );
      final value = tester.getRect(find.byKey(StoresKeys.storeValue));
      final tile = tester.getRect(find.text('Products'));
      expect(value.bottom, lessThanOrEqualTo(tile.top));
      await disposeScreen(tester);
    });

    testWidgets('header cards sit side by side at 1280 wide, capped at 960', (
      tester,
    ) async {
      await pumpDetails(
        tester,
        size: const Size(1280, 800),
        padding: EdgeInsets.zero,
      );
      final value = tester.getRect(find.byKey(StoresKeys.storeValue));
      final tile = tester.getRect(find.text('Products'));
      expect(tile.left, greaterThan(value.right));
      expect(tile.top, lessThan(value.bottom));
      final body = tester.getRect(find.byKey(StoresKeys.inventoryCard));
      expect(body.width, lessThanOrEqualTo(kStoreDetailsMaxContentWidth));
      await disposeScreen(tester);
    });
  });

  group('no overflow', () {
    for (final (name, size, padding, scale)
        in <(String, Size, EdgeInsets, double)>[
          (
            '360x640 @1.3',
            const Size(360, 640),
            const EdgeInsets.only(top: 24, bottom: 48),
            1.3,
          ),
          (
            '390x844',
            const Size(390, 844),
            const EdgeInsets.only(top: 24, bottom: 24),
            1.0,
          ),
          (
            '844x390',
            const Size(844, 390),
            const EdgeInsets.only(top: 24, right: 48),
            1.0,
          ),
          ('800x1280', const Size(800, 1280), EdgeInsets.zero, 1.0),
          ('1280x800', const Size(1280, 800), EdgeInsets.zero, 1.0),
        ]) {
      testWidgets('full view at $name', (tester) async {
        await pumpDetails(
          tester,
          size: size,
          padding: padding,
          textScale: scale,
        );
        expect(tester.takeException(), isNull);
        await disposeScreen(tester);
      });

      testWidgets('restricted view at $name', (tester) async {
        await pumpDetails(
          tester,
          size: size,
          padding: padding,
          textScale: scale,
          grants: const {'stores.request_transfer'},
          rank: GateTier.cashier,
          slug: 'cashier',
        );
        expect(tester.takeException(), isNull);
        await disposeScreen(tester);
      });
    }
  });

  group('Dispatch dialog keyboard', () {
    for (final (name, size, keyboard) in const <(String, Size, double)>[
      ('390x844', Size(390, 844), 340.0),
      ('360x640', Size(360, 640), 280.0),
    ]) {
      testWidgets('fits above the keyboard $name', (tester) async {
        await pumpDetails(
          tester,
          size: size,
          followView: true,
          textScale: 1.15,
        );
        await reveal(tester, find.text('Accept & Dispatch'));
        await tester.tap(find.text('Accept & Dispatch'));
        await tester.pumpAndSettle();
        tester.view.viewInsets = FakeViewPadding(bottom: keyboard);
        await tester.pumpAndSettle();
        expect(find.text('Dispatch quantity'), findsOneWidget);
        expect(tester.takeException(), isNull);
        tester.view.resetViewInsets();
        await disposeScreen(tester);
      });
    }
  });
}
