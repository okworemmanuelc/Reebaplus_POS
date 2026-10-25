// Stores list + Add / Edit / Delete sheets + CEO Settings > Stores (#441,
// PRD #346 Wave 2 C, PR 1): each control renders, the main actions still
// work, permission-hidden controls stay hidden, and nothing overflows at the
// phone, sideways and tablet sizes (with realistic insets and the keyboard up).

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/core/permissions/gate.dart';
import 'package:reebaplus_pos/core/settings/stores_settings_screen.dart';
import 'package:reebaplus_pos/features/stores/screens/stores_screen.dart';
import 'package:reebaplus_pos/features/stores/widgets/stores_parts.dart';

import 'package:reebaplus_pos/shared/services/navigation_service.dart';
import '../helpers/screen_harness.dart';

const _manage = {'stores.manage'};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ScreenTestEnvironment env;
  late String lagosId;

  setUp(() async {
    env = await setupScreenTestEnvironment(
      productCount: 2,
      businessName: 'Stallion Global',
    );
    await env.db.customStatement(
      "UPDATE stores SET name = 'Abuja HQ', location = '14 Wuse Road, Nigeria' "
      "WHERE id = '${env.storeId}'",
    );
    env.db.userIdResolver = () => 'test-user-id';
    // The activity log row of a store write points at the signed-in user.
    await env.db
        .into(env.db.users)
        .insert(
          UsersCompanion.insert(
            id: const Value('test-user-id'),
            businessId: env.businessId,
            name: 'Test Admin',
            pin: '0000',
          ),
        );
    lagosId = UuidV7.generate();
    await env.db
        .into(env.db.stores)
        .insert(
          StoresCompanion.insert(
            id: Value(lagosId),
            businessId: env.businessId,
            name: 'Lagos Island Annex With A Very Long Store Name',
            location: const Value('3 Marina Street, Lagos, Nigeria'),
          ),
        );
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

  Future<void> pumpStores(
    WidgetTester tester, {
    Size size = const Size(390, 844),
    EdgeInsets padding = const EdgeInsets.only(top: 24, bottom: 24),
    Set<String> grants = _manage,
    int rank = GateTier.ceo,
    String slug = 'ceo',
    Widget screen = const StoresScreen(),
    double textScale = 1.0,
    bool followView = false,
  }) async {
    await pumpScreen(
      tester,
      env: env,
      size: size,
      padding: padding,
      screen: screen,
      bottomNavHeight: size.width >= 600 ? kBottomNavBodyHeight : 0,
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

  group('Stores list', () {
    testWidgets('renders a card per store with figures and CEO actions', (
      tester,
    ) async {
      await pumpStores(tester);
      expect(find.byKey(StoresKeys.topBar), findsOneWidget);
      expect(find.text('Stores'), findsWidgets);
      expect(find.byKey(StoresKeys.card(env.storeId)), findsOneWidget);
      expect(find.byKey(StoresKeys.card(lagosId)), findsOneWidget);
      expect(find.text('Total Units'), findsNWidgets(2));
      expect(find.text('Products'), findsNWidgets(2));
      expect(find.text('Add Store'), findsOneWidget);
      expect(find.byKey(StoresKeys.edit(env.storeId)), findsOneWidget);
      expect(find.byKey(StoresKeys.delete(env.storeId)), findsOneWidget);
      expect(tester.takeException(), isNull);
      await disposeScreen(tester);
    });

    testWidgets('browse-only viewers see no Add / Edit / Delete', (
      tester,
    ) async {
      await pumpStores(
        tester,
        grants: const {'stores.request_transfer'},
        rank: GateTier.cashier,
        slug: 'cashier',
      );
      expect(find.byKey(StoresKeys.card(env.storeId)), findsOneWidget);
      expect(find.text('Add Store'), findsNothing);
      expect(find.text('Edit'), findsNothing);
      expect(find.text('Delete'), findsNothing);
      await disposeScreen(tester);
    });

    testWidgets('a viewer with no store access sees the no-access text', (
      tester,
    ) async {
      await pumpStores(
        tester,
        grants: const {},
        rank: GateTier.cashier,
        slug: 'cashier',
      );
      expect(find.byKey(StoresKeys.noAccess), findsOneWidget);
      expect(find.text('You don’t have access to Stores.'), findsOneWidget);
      expect(find.byKey(StoresKeys.card(env.storeId)), findsNothing);
      await disposeScreen(tester);
    });

    testWidgets('Add Store saves a new store', (tester) async {
      await pumpStores(tester);
      await tester.tap(find.text('Add Store'));
      await tester.pumpAndSettle();
      expect(find.text('New Store'), findsOneWidget);
      final fields = find.descendant(
        of: find.byType(BottomSheet),
        matching: find.byType(TextFormField),
      );
      await tester.enterText(fields.at(0), 'Kano Depot');
      await tester.enterText(fields.at(1), '9 Zoo Road');
      // #423: the store's state + LGA is required.
      await tester.tap(find.byKey(const ValueKey<String>('new-store-area')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('area-search-state')), 'Kano');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('area-option-Kano')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('area-search-lga')), 'Dala');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('area-option-Dala')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Save Store'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save Store'));
      await tester.pumpAndSettle();
      await deliver(tester);
      final all = await env.db.storesDao.getActiveStores();
      expect(all.any((s) => s.name == 'Kano Depot' && s.lga == 'Dala'), isTrue);
      await disposeScreen(tester);
    });

    testWidgets('Add Store validates the required fields', (tester) async {
      await pumpStores(tester);
      await tester.tap(find.text('Add Store'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save Store'));
      await tester.pumpAndSettle();
      expect(find.text('Name is required'), findsOneWidget);
      expect(find.text('Street Address is required'), findsOneWidget);
      await disposeScreen(tester);
    });

    testWidgets('Edit Store renames a store', (tester) async {
      await pumpStores(tester);
      await tester.tap(find.byKey(StoresKeys.edit(env.storeId)));
      await tester.pumpAndSettle();
      expect(find.text('Edit Store'), findsOneWidget);
      final fields = find.descendant(
        of: find.byType(BottomSheet),
        matching: find.byType(TextFormField),
      );
      await tester.enterText(fields.at(0), 'Abuja Central');
      await tester.tap(find.text('Save Changes'));
      await tester.pumpAndSettle();
      final all = await env.db.storesDao.getActiveStores();
      expect(all.any((s) => s.name == 'Abuja Central'), isTrue);
      await disposeScreen(tester);
    });

    testWidgets('Delete asks first, Cancel keeps the store', (tester) async {
      await pumpStores(tester);
      await tester.tap(find.byKey(StoresKeys.delete(lagosId)));
      await tester.pumpAndSettle();
      expect(find.text('Delete Store'), findsOneWidget);
      expect(
        find.text(
          'Delete "Lagos Island Annex With A Very Long Store Name"? It will no longer appear in your stores. Its past sales and records are kept.',
        ),
        findsOneWidget,
      );
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      final all = await env.db.storesDao.getActiveStores();
      expect(all.any((s) => s.id == lagosId), isTrue);
      await disposeScreen(tester);
    });

    testWidgets(
      'Delete confirms and soft-deletes the store, clearing locked store',
      (tester) async {
        await pumpStores(tester);
        final nav = NavigationService();
        nav.setLockedStore(lagosId);
        expect(nav.lockedStoreId.value, lagosId);
        await tester.tap(find.byKey(StoresKeys.delete(lagosId)));
        await tester.pumpAndSettle();
        expect(
          find.text(
            'Delete "Lagos Island Annex With A Very Long Store Name"? It will no longer appear in your stores. Its past sales and records are kept.',
          ),
          findsOneWidget,
        );
        await tester.tap(find.widgetWithText(InkWell, 'Delete').last);
        await tester.pumpAndSettle();
        await deliver(tester);
        final all = await env.db.storesDao.getActiveStores();
        expect(all.any((s) => s.id == lagosId), isFalse);
        expect(nav.lockedStoreId.value, isNull);
        await disposeScreen(tester);
      },
    );

    testWidgets(
      'Delete blocked by guard shows Cannot Delete Store dialog with reason',
      (tester) async {
        // Give lagosId inventory
        final products = await env.db.select(env.db.products).get();
        await env.db
            .into(env.db.inventory)
            .insert(
              InventoryCompanion.insert(
                id: Value(UuidV7.generate()),
                businessId: env.businessId,
                productId: products.first.id,
                storeId: lagosId,
                quantity: const Value(5),
                lastUpdatedAt: Value(DateTime.now()),
              ),
            );

        await pumpStores(tester);
        await tester.tap(find.byKey(StoresKeys.delete(lagosId)));
        await tester.pumpAndSettle();

        expect(find.text('Cannot Delete Store'), findsOneWidget);
        expect(
          find.text(
            'This store still has stock on hand. Transfer or write off all inventory before deleting.',
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: find.byType(AlertDialog),
            matching: find.text('Delete'),
          ),
          findsNothing,
        );
        expect(
          find.descendant(
            of: find.byType(AlertDialog),
            matching: find.text('OK'),
          ),
          findsOneWidget,
        );

        await tester.tap(find.text('OK'));
        await tester.pumpAndSettle();

        final all = await env.db.storesDao.getActiveStores();
        expect(all.any((s) => s.id == lagosId), isTrue);
        await disposeScreen(tester);
      },
    );

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
      testWidgets('no overflow at $name', (tester) async {
        await pumpStores(
          tester,
          size: size,
          padding: padding,
          textScale: scale,
        );
        expect(find.byKey(StoresKeys.card(env.storeId)), findsOneWidget);
        expect(tester.takeException(), isNull);
        await disposeScreen(tester);
      });
    }

    testWidgets('list is capped at 720 on a wide screen', (tester) async {
      await pumpStores(
        tester,
        size: const Size(1280, 800),
        padding: EdgeInsets.zero,
      );
      final w = tester.getSize(find.byKey(StoresKeys.card(env.storeId))).width;
      expect(w, lessThanOrEqualTo(720));
      await disposeScreen(tester);
    });

    testWidgets('empty state when there are no stores', (tester) async {
      await env.db.customStatement('UPDATE stores SET is_deleted = 1');
      await pumpStores(tester);
      expect(find.byKey(StoresKeys.empty), findsOneWidget);
      expect(find.text('No Stores Yet'), findsOneWidget);
      await disposeScreen(tester);
    });
  });

  group('keyboard up', () {
    for (final (name, size, keyboard) in const <(String, Size, double)>[
      ('390x844', Size(390, 844), 340.0),
      ('360x640', Size(360, 640), 280.0),
    ]) {
      testWidgets('Add Store sheet fits above the keyboard $name', (
        tester,
      ) async {
        await pumpStores(tester, size: size, followView: true, textScale: 1.15);
        await tester.tap(find.text('Add Store'));
        await tester.pumpAndSettle();
        tester.view.viewInsets = FakeViewPadding(bottom: keyboard);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        tester.view.resetViewInsets();
        await disposeScreen(tester);
      });

      testWidgets('Edit Store sheet fits above the keyboard $name', (
        tester,
      ) async {
        await pumpStores(tester, size: size, followView: true, textScale: 1.15);
        await tester.tap(find.byKey(StoresKeys.edit(env.storeId)));
        await tester.pumpAndSettle();
        tester.view.viewInsets = FakeViewPadding(bottom: keyboard);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        tester.view.resetViewInsets();
        await disposeScreen(tester);
      });

      testWidgets('Settings add-store sheet fits above the keyboard $name', (
        tester,
      ) async {
        await pumpStores(
          tester,
          size: size,
          followView: true,
          textScale: 1.15,
          screen: const StoresSettingsScreen(),
        );
        await tester.tap(find.text('Add a store'));
        await tester.pumpAndSettle();
        tester.view.viewInsets = FakeViewPadding(bottom: keyboard);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        tester.view.resetViewInsets();
        await disposeScreen(tester);
      });
    }
  });

  group('CEO Settings > Stores', () {
    testWidgets('renders a card per store, with the add button', (
      tester,
    ) async {
      await pumpStores(tester, screen: const StoresSettingsScreen());
      expect(find.byKey(StoresKeys.settingsList), findsOneWidget);
      expect(find.text('Store name'), findsWidgets);
      expect(find.text('Save changes'), findsWidgets);
      expect(find.text('Add a store'), findsOneWidget);
      // Vans are their own axis (van.manage): hidden for a stores-only role.
      expect(find.text('Vans'), findsNothing);
      await disposeScreen(tester);
    });

    testWidgets('a role without stores.manage sees no access', (tester) async {
      await pumpStores(
        tester,
        screen: const StoresSettingsScreen(),
        grants: const {},
        rank: GateTier.cashier,
        slug: 'cashier',
      );
      expect(find.byKey(StoresKeys.noAccess), findsOneWidget);
      expect(find.text('Add a store'), findsNothing);
      await disposeScreen(tester);
    });

    testWidgets('Save changes writes the edited name', (tester) async {
      await pumpStores(tester, screen: const StoresSettingsScreen());
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Abuja HQ'),
        'Abuja Main',
      );
      await tester.tap(find.text('Save changes').first);
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 5));
      final all = await env.db.storesDao.getActiveStores();
      expect(all.any((s) => s.name == 'Abuja Main'), isTrue);
      await disposeScreen(tester);
    });

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
      testWidgets('no overflow at $name', (tester) async {
        await pumpStores(
          tester,
          size: size,
          padding: padding,
          textScale: scale,
          screen: const StoresSettingsScreen(),
        );
        expect(tester.takeException(), isNull);
        await disposeScreen(tester);
      });
    }
  });
}
