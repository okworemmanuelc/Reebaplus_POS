// Owner screenshot (PR #379 build, phone 1440x3120, light, gesture nav):
// Request Stock opened from Home's Stock Transfer tile; with the product
// field focused and the keyboard up, the form was cut off just under
// "Product" ("Quantity requested" clipped) and a large empty band sat between
// it and the keyboard.
//
// Cause (fixed by #378, cc557eaa, before this screen was rebuilt): the old
// `MainLayout._insetContent` (main_layout.dart:693 at 84a267aa) called
// `MediaQuery.removePadding(context: context, …)` with MainLayout's OWN
// context, above its Scaffold. That rebuilt the tabs' MediaQuery from data
// that still carried the keyboard inset the frame Scaffold had already taken
// out, so Request Stock's own Scaffold (GlassyScaffold) resized for the
// keyboard a second time: the form ended one keyboard-height above the
// keyboard. Measured with this test's old form: the scroll area ended at
// 244dp on a 390x844 screen with a 300dp keyboard (844 − 2 × 300) instead
// of 544dp.
//
// This pins the path the owner took: the real MainLayout on Home, the tile
// pushes Request Stock on the Home tab's navigator, a field is focused and
// only then does the keyboard come up. The screen's scroll area must end at
// the keyboard's top edge (no band) with the focused field on screen.

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/core/providers/first_run_tour_state.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/features/dashboard/widgets/home_parts.dart';
import 'package:reebaplus_pos/features/stores/screens/request_stock_screen.dart';
import 'package:reebaplus_pos/features/stores/widgets/request_product_grid.dart';
import 'package:reebaplus_pos/shared/services/navigation_service.dart';
import 'package:reebaplus_pos/shared/widgets/main_layout.dart';

import '../helpers/screen_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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

  late ScreenTestEnvironment env;
  late StoreData ikeja;

  setUp(() async {
    env = await setupScreenTestEnvironment(
      productCount: 2,
      sharedPreferences: const {'push_soft_ask_shown_v1': true},
    );
    final db = env.db;
    final ikejaId = UuidV7.generate();
    await db
        .into(db.stores)
        .insert(
          StoresCompanion.insert(
            id: Value(ikejaId),
            businessId: env.businessId,
            name: 'Ikeja',
          ),
        );
    for (final p in env.products) {
      await db
          .into(db.inventory)
          .insert(
            InventoryCompanion.insert(
              id: Value(UuidV7.generate()),
              businessId: env.businessId,
              storeId: ikejaId,
              productId: p.id,
              quantity: const Value(30),
            ),
          );
    }
    ikeja = (await db.storesDao.getStore(ikejaId))!;
    NavigationService()
      ..resetNavigation()
      ..beginSessionLanding();
  });

  tearDown(() async {
    await env.dispose();
    NavigationService().resetNavigation();
  });

  Future<void> deliver(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 250));
    }
  }

  for (final (name, size, insets, keyboard) in [
    // Upright phone, gesture navigation (the owner's phone).
    (
      '390x844 gesture nav',
      const Size(390, 844),
      const FakeViewPadding(top: 24, bottom: 24),
      300.0,
    ),
    // Sideways phone: status bar on top, 3-button navigation on the right.
    (
      '844x390 sideways',
      const Size(844, 390),
      const FakeViewPadding(top: 24, right: 48),
      180.0,
    ),
  ]) {
    testWidgets('$name, light: from Home, search focused, then the keyboard '
        '— the screen ends at the keyboard, no band', (tester) async {
      tester.view.padding = insets;
      tester.view.viewPadding = insets;
      addTearDown(tester.view.resetPadding);
      addTearDown(tester.view.resetViewPadding);
      addTearDown(tester.view.resetViewInsets);
      NavigationService().setIndex(NavigationService.homeTab);
      await pumpScreen(
        tester,
        env: env,
        size: size,
        screen: const MainLayout(),
        bottomNavHeight: 0,
        followView: true,
        theme: AppTheme.light(),
        grantedKeys: const {
          'stores.request_transfer',
          'stock.view',
          'reports.see_sales',
        },
        roleSlug: 'manager',
        roleName: 'Manager',
        roleRank: 3,
        selectableStores: [env.store, ikeja],
        overrides: [firstRunTourStopProvider.overrideWithValue(TourStop.none)],
        settle: false,
      );
      await deliver(tester);

      // Home pushes Request Stock exactly as the owner did.
      await tester.tap(find.byKey(HomeKeys.quickStockTransfer));
      await deliver(tester);
      expect(find.byType(RequestStockScreen), findsOneWidget);

      // Pick the source and put a product on the request.
      await tester.tap(
        find
            .descendant(
              of: find.ancestor(
                of: find.text('Request from store'),
                matching: find.byWidgetPredicate((w) => w is FormField),
              ),
              matching: find.byType(GestureDetector),
            )
            .first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Ikeja').last);
      await deliver(tester);
      final tile = find.byKey(requestProductTileKey(env.products[0].id));
      await tester.ensureVisible(tile);
      await tester.pumpAndSettle();
      await tester.tap(tile);
      await deliver(tester);
      final bar = find.byKey(RequestStockKeys.reviewBar);
      expect(bar, findsOneWidget);

      // Focus the search field, THEN the keyboard comes up.
      final search = find.descendant(
        of: find.byKey(RequestStockKeys.search),
        matching: find.byType(EditableText),
      );
      await tester.tap(search);
      await tester.pump();
      tester.view.viewInsets = FakeViewPadding(bottom: keyboard);
      // The engine reports the padding the keyboard covers as 0.
      tester.view.padding = FakeViewPadding(
        top: insets.top,
        right: insets.right,
      );
      await tester.pump();
      await tester.pumpAndSettle();

      final keyboardTop = size.height - keyboard;
      final scroll = tester.getRect(find.byKey(RequestStockKeys.scroll));
      expect(
        scroll.bottom,
        moreOrLessEquals(keyboardTop, epsilon: 0.5),
        reason:
            'the screen must run down to the keyboard, not stop a '
            'keyboard-height short of it',
      );
      final field = tester.getRect(search);
      expect(field.top, greaterThanOrEqualTo(scroll.top));
      expect(field.bottom, lessThanOrEqualTo(keyboardTop));
      // The review bar steps aside while typing, like POS's View Cart bar.
      expect(bar, findsNothing);

      // Keyboard down: the bar is back and the screen ends on it.
      tester.view.resetViewInsets();
      tester.view.padding = insets;
      await tester.pump();
      await tester.pumpAndSettle();
      expect(bar, findsOneWidget);
      expect(
        tester.getRect(find.byKey(RequestStockKeys.scroll)).bottom,
        lessThanOrEqualTo(tester.getRect(bar).top),
      );
      expect(tester.takeException(), isNull);
      await disposeScreen(tester);
    });
  }
}
