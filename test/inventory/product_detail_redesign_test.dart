// #487 PR 3: the redesigned Product Details. Every card's content, each
// permission combination, Archive / Unarchive, the Description and Sales Target
// pop-ups (with the keyboard up), the per-store rows, the labels, and the one,
// two and three column layouts.

import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/core/permissions/gate.dart';
import 'package:reebaplus_pos/core/theme/fixed_colors.dart';
import 'package:reebaplus_pos/features/inventory/screens/product_detail_screen.dart';
import 'package:reebaplus_pos/features/inventory/screens/product_stock_history_screen.dart';
import 'package:reebaplus_pos/features/inventory/widgets/product_sales_history_cards.dart';
import 'package:reebaplus_pos/features/inventory/widgets/product_detail_cards.dart';
import 'package:reebaplus_pos/features/inventory/screens/add_product_screen.dart';

import '../helpers/inventory_seed.dart';
import '../helpers/product_detail_seed.dart';
import '../helpers/screen_harness.dart';
import 'package:reebaplus_pos/core/storefront/online_ordering_switch.dart';

const _ceoKeys = {
  ...kInventorySampleGrants,
  'products.edit_buying_price',
  'products.delete',
  'products.manage_listing',
};

const _gesture = FakeViewPadding(top: 24, bottom: 24);
const _sideways = FakeViewPadding(top: 24, right: 48);

void main() {
  // Online ordering ships switched off; these tests cover it switched on.
  setUpAll(() => debugOverrideOnlineOrderingEnabled(true));
  tearDownAll(() => debugOverrideOnlineOrderingEnabled(null));
  TestWidgetsFlutterBinding.ensureInitialized();

  late ScreenTestEnvironment env;
  late InventorySample sample;
  late DetailSample detail;

  // The detail resolves the saved photo's device path while it loads.
  late Directory docs;
  const pathProvider = MethodChannel('plugins.flutter.io/path_provider');

  setUpAll(() {
    docs = Directory.systemTemp.createTempSync('product_detail_redesign');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProvider, (_) async => docs.path);
  });
  tearDownAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProvider, null);
    docs.deleteSync(recursive: true);
  });

  setUp(() async {
    env = await setupScreenTestEnvironment(
      productCount: 0,
      businessName: 'Stallion Global',
      businessType: 'Beverage distributor',
    );
    sample = await seedInventorySample(env);
  });

  tearDown(() => env.dispose());

  Future<void> deliver(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 250));
    }
  }

  /// Opens the screen on Gulder. [seed] false keeps the harness' bare product
  /// (no prices, description, target or count).
  Future<void> pump(
    WidgetTester tester, {
    Size size = const Size(390, 844),
    FakeViewPadding insets = _gesture,
    Set<String> grants = _ceoKeys,
    String roleSlug = 'ceo',
    int roleRank = GateTier.ceo,
    TextScaler? textScaler,
    bool seed = true,
    DetailSample? seeded,
  }) async {
    detail = seeded ?? await seedDetailSample(env, sample);
    tester.view.padding = insets;
    tester.view.viewPadding = insets;
    addTearDown(tester.view.resetPadding);
    addTearDown(tester.view.resetViewPadding);
    addTearDown(tester.view.resetViewInsets);
    await pumpScreen(
      tester,
      env: env,
      size: size,
      screen: ProductDetailScreen(
        item: detailItemFor(env, sample),
        onUpdateStock: () {},
        selectedStoreId: env.storeId,
      ),
      followView: true,
      settle: false,
      grantedKeys: grants,
      roleSlug: roleSlug,
      roleRank: roleRank,
      textScaler: textScaler,
    );
    await deliver(tester);
  }

  Future<ProductData> product() async =>
      (await env.db.catalogDao.findById(sample.productIds['Gulder']!))!;

  Future<void> showAllCards(WidgetTester tester) async {
    await tester.drag(
      find.byType(SingleChildScrollView).first,
      const Offset(0, -4000),
    );
    await tester.pump();
  }

  void expectTarget(WidgetTester tester, Finder f) {
    final size = tester.getSize(f);
    expect(size.width, greaterThanOrEqualTo(kMinInteractiveDimension));
    expect(size.height, greaterThanOrEqualTo(kMinInteractiveDimension));
  }

  Future<void> openMenu(WidgetTester tester) async {
    await tester.tap(find.byTooltip('More options'));
    await tester.pumpAndSettle();
  }

  group('Show online (#424)', () {
    final toggle = find.byKey(const ValueKey('product-show-online'));

    testWidgets('listing-only grant can toggle without changing till availability', (tester) async {
      await pump(tester, grants: const {'products.manage_listing'},
        roleSlug: 'cashier', roleRank: GateTier.cashier);
      expect(tester.widget<SwitchListTile>(toggle).value, isTrue);
      await tester.ensureVisible(toggle);
      await tester.tap(toggle);
      await deliver(tester);
      expect((await product()).showOnline, isFalse);
      expect((await product()).isAvailable, isTrue);
      expect(tester.widget<SwitchListTile>(toggle).value, isFalse);
      expect(find.text('Archive Product'), findsNothing);
      await disposeScreen(tester);
    });

    testWidgets('price-edit permission alone does not show the listing switch', (tester) async {
      await pump(tester, grants: const {'products.edit_price'});
      expect(toggle, findsNothing);
      await disposeScreen(tester);
    });

    testWidgets('a stale callback rechecks revoked listing permission before writing', (tester) async {
      final grants = {'products.manage_listing'};
      await pump(tester, grants: grants);
      final callback = tester.widget<SwitchListTile>(toggle).onChanged!;
      final before = (await env.db.select(env.db.syncQueue).get()).length;
      grants.clear();
      callback(false);
      await deliver(tester);
      expect((await product()).showOnline, isTrue);
      expect((await env.db.select(env.db.syncQueue).get()).length, before);
      expect(find.text('You no longer have access to Manage online listings.'),
        findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      await disposeScreen(tester);
    });

    testWidgets('a synced listing preference updates the open product', (tester) async {
      await pump(tester);
      await (env.db.update(env.db.products)..where((p) =>
        p.id.equals(sample.productIds['Gulder']!)))
        .write(const ProductsCompanion(showOnline: Value(false)));
      await deliver(tester);
      expect(tester.widget<SwitchListTile>(toggle).value, isFalse);
      await disposeScreen(tester);
    });

    testWidgets('archived listing preference cannot put the product back on sale', (tester) async {
      final seeded = await seedDetailSample(env, sample, archived: true);
      await pump(tester, seeded: seeded);
      expect(find.text('Archived products stay hidden online.'), findsOneWidget);
      await tester.ensureVisible(toggle);
      await tester.tap(toggle);
      await deliver(tester);
      expect((await product()).showOnline, isFalse);
      expect((await product()).isAvailable, isFalse);
      await disposeScreen(tester);
    });
  });

  group('Online listing (#473)', () {
    final card = find.byKey(const ValueKey('product-listing-card'));

    Future<void> openListing(WidgetTester tester) async {
      await tester.ensureVisible(find.byTooltip('Edit online listing'));
      await tester.pump();
      await tester.tap(find.byTooltip('Edit online listing'));
      await tester.pumpAndSettle();
    }

    testWidgets('shown after Prices only with the listing grant', (tester) async {
      await pump(tester, grants: const {'products.edit_price'});
      expect(card, findsNothing);
      await disposeScreen(tester);
    });

    group('listing checklist + shared photo (#475)', () {
      final checklist = find.byKey(const ValueKey('listing-quality-checklist'));
      final shared = find.byKey(const ValueKey('use-shared-photo'));

      testWidgets('shows the gaps with the listing grant', (tester) async {
        await pump(tester, grants: const {'products.manage_listing'},
          roleSlug: 'cashier', roleRank: GateTier.cashier);
        expect(checklist, findsOneWidget);
        expect(find.byKey(const ValueKey('listing-gap-description')), findsOneWidget);
        expect(find.byKey(const ValueKey('listing-gap-photo')), findsOneWidget);
        await disposeScreen(tester);
      });

      testWidgets('hidden without the listing grant', (tester) async {
        await pump(tester, grants: const {'products.edit_price'});
        expect(checklist, findsNothing);
        await disposeScreen(tester);
      });

      testWidgets('shared photo button needs a factory barcode and no photo',
          (tester) async {
        await pump(tester, grants: const {'products.manage_listing'},
          roleSlug: 'cashier', roleRank: GateTier.cashier);
        expect(shared, findsNothing); // no barcode yet
        await disposeScreen(tester);
      });

      testWidgets('shared photo button shows with a factory barcode',
          (tester) async {
        detail = await seedDetailSample(env, sample, barcode: '5449000000996');
        await pump(tester, grants: const {'products.manage_listing'},
          roleSlug: 'cashier', roleRank: GateTier.cashier, seeded: detail);
        expect(shared, findsOneWidget);
        await disposeScreen(tester);
      });

      testWidgets('a price-only user never sees the shared photo button',
          (tester) async {
        detail = await seedDetailSample(env, sample, barcode: '5449000000996');
        await pump(tester, grants: const {'products.edit_price'}, seeded: detail);
        expect(shared, findsNothing);
        await disposeScreen(tester);
      });
    });

    testWidgets('edits description, brand and order limits', (tester) async {
      await pump(tester, grants: const {'products.manage_listing'},
        roleSlug: 'cashier', roleRank: GateTier.cashier);
      expect(find.text('No online description yet'), findsOneWidget);
      expect(find.text('Any amount'), findsOneWidget);
      await openListing(tester);
      await tester.enterText(find.byKey(const ValueKey('listing-description')),
        'Cold lager in returnable bottles');
      await tester.enterText(find.byKey(const ValueKey('listing-brand')), 'Gulder');
      await tester.enterText(find.byKey(const ValueKey('listing-min-order')), '12');
      await tester.enterText(find.byKey(const ValueKey('listing-order-step')), '12');
      await tester.enterText(find.byKey(const ValueKey('listing-max-order')), '48');
      await tester.tap(find.byKey(const ValueKey('listing-save')));
      await deliver(tester);
      final p = await product();
      expect(p.onlineDescription, 'Cold lager in returnable bottles');
      expect(p.brand, 'Gulder');
      expect((p.minOrderQty, p.orderStep, p.maxOrderQty), (12, 12, 48));
      expect(p.isAvailable, isTrue);
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text('At least 12 · In steps of 12 · Up to 48'), findsOneWidget);
      await disposeScreen(tester);
    });

    testWidgets('a largest order under the smallest is refused, nothing saved', (tester) async {
      await pump(tester);
      final before = (await env.db.select(env.db.syncQueue).get()).length;
      await openListing(tester);
      await tester.enterText(find.byKey(const ValueKey('listing-min-order')), '10');
      await tester.enterText(find.byKey(const ValueKey('listing-max-order')), '5');
      await tester.tap(find.byKey(const ValueKey('listing-save')));
      await deliver(tester);
      expect(find.byKey(const ValueKey('listing-error')), findsOneWidget);
      expect((await product()).minOrderQty, 1);
      expect((await env.db.select(env.db.syncQueue).get()).length, before);
      await disposeScreen(tester);
    });

    for (final (name, size, insets, keyboard)
        in <(String, Size, FakeViewPadding, double)>[
          ('390x844', const Size(390, 844), _gesture, 300.0),
          ('844x390 sideways', const Size(844, 390), _sideways, 180.0),
        ]) {
      testWidgets('pop-up at $name scrolls with the keyboard up', (tester) async {
        await pump(tester, size: size, insets: insets);
        await openListing(tester);
        expect(tester.widget<AlertDialog>(find.byType(AlertDialog)).scrollable,
          isTrue);
        tester.view.viewInsets = FakeViewPadding(bottom: keyboard);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(tester.getRect(find.byKey(const ValueKey('listing-description'))).top,
          lessThan(size.height - keyboard));
        await tester.drag(find.byType(SingleChildScrollView).last,
          const Offset(0, -600));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(tester.getRect(find.byKey(const ValueKey('listing-save'))).bottom,
          lessThanOrEqualTo(size.height - keyboard));
        await disposeScreen(tester);
      });
    }
  });

  group('renders its cards', () {
    testWidgets('top bar, hero, and every card in the phone order', (
      tester,
    ) async {
      await pump(tester);
      expect(find.text('Product Details'), findsOneWidget);
      expect(find.text('Inventory'), findsOneWidget);
      // Hero.
      expect(find.text('Gulder'), findsOneWidget);
      expect(find.text('Beer'), findsOneWidget);
      expect(find.text('32 crates in stock'), findsOneWidget);
      expect(
        find.text('Nigerian Breweries · Crate of 12 bottles'),
        findsOneWidget,
      );
      expect(find.text('No barcode yet'), findsOneWidget);
      expect(find.text('retail, per crate'), findsOneWidget);
      expect(find.text('List Online'), findsNothing);
      // Cards, top to bottom.
      final titles = [
        'Description',
        'Prices & Profit',
        'Online listing',
        'Stock by Store',
        'Sales Target',
        'Sales',
        'Stock History',
        'Manage Product',
      ];
      var lastY = -1.0;
      for (final t in titles) {
        final y = tester.getTopLeft(find.text(t)).dy;
        expect(y, greaterThan(lastY), reason: t);
        lastY = y;
      }
      await disposeScreen(tester);
    });

    testWidgets('hero shows the barcode, and no expiry pill without a date', (
      tester,
    ) async {
      detail = await seedDetailSample(env, sample, barcode: '5449000000996');
      await pump(tester, seeded: detail);
      expect(find.text('5449000000996'), findsOneWidget);
      expect(find.text('No barcode yet'), findsNothing);
      expect(find.textContaining('Expire'), findsNothing);
      await disposeScreen(tester);
    });

    testWidgets('an expiry date shows its pill', (tester) async {
      detail = await seedDetailSample(env, sample);
      final soon = DateTime.now().add(const Duration(days: 10));
      await (env.db.update(
        env.db.products,
      )..where((p) => p.id.equals(sample.productIds['Gulder']!))).write(
        ProductsCompanion(
          expiryDate: Value(DateTime(soon.year, soon.month, soon.day)),
        ),
      );
      await pump(tester, seeded: detail);
      expect(find.text('Expires in 10d'), findsOneWidget);
      await disposeScreen(tester);
    });

    testWidgets('description empty reads "No description yet"', (tester) async {
      detail = await seedDetailSample(env, sample, description: null);
      await pump(tester, seeded: detail);
      expect(find.text('No description yet'), findsOneWidget);
      await disposeScreen(tester);
    });

    testWidgets(
      '"Bottle Crate" with no count, "Crate of 12 bottles" with one',
      (tester) async {
        detail = await seedDetailSample(env, sample, unitsPerPack: null);
        await pump(tester, seeded: detail);
        expect(find.text('Nigerian Breweries · Bottle Crate'), findsOneWidget);
        expect(find.textContaining('Crate of'), findsNothing);
        await disposeScreen(tester);
      },
    );

    testWidgets('back and the menu are 48dp targets', (tester) async {
      await pump(tester);
      expectTarget(tester, find.byTooltip('Back'));
      expectTarget(tester, find.byTooltip('More options'));
      await disposeScreen(tester);
    });
  });

  group('a shop that does not count crates', () {
    testWidgets('a Bottle product reads Bottle and bottles, never crate', (
      tester,
    ) async {
      detail = await seedDetailSample(
        env,
        sample,
        description: 'Syrup in glass bottles.',
        businessType: 'Pharmacy',
        tracksCrates: false,
      );
      await pump(tester, seeded: detail);
      expect(find.text('Nigerian Breweries · Bottle'), findsOneWidget);
      expect(find.text('32 bottles in stock'), findsOneWidget);
      expect(find.text('retail, per bottle'), findsOneWidget);
      expect(find.text('All prices are per bottle.'), findsOneWidget);
      expect(find.text('32 bottles'), findsOneWidget);
      expect(find.text('Alert at 5 bottles'), findsOneWidget);
      expect(find.text('of 200 bottles sold'), findsOneWidget);
      expect(find.textContaining('bottles to go'), findsOneWidget);
      expect(find.textContaining('0 bottles sold'), findsOneWidget); // Sales
      expect(
        find.textContaining(RegExp('crate', caseSensitive: false)),
        findsNothing,
      );
      await disposeScreen(tester);
    });
  });

  group('Prices & Profit', () {
    testWidgets('shows cost, retail, wholesale and the two profit rows', (
      tester,
    ) async {
      await pump(tester);
      expect(find.text('All prices are per crate.'), findsOneWidget);
      for (final l in ['Cost', 'Retail', 'Wholesale']) {
        expect(find.text(l), findsOneWidget, reason: l);
      }
      expect(find.text('Retail profit'), findsOneWidget);
      expect(find.text('10% of selling price'), findsOneWidget);
      expect(find.text('Wholesale profit'), findsOneWidget);
      expect(find.text('5% of selling price'), findsOneWidget);
      await disposeScreen(tester);
    });

    testWidgets('without the buying-price permission: no cost, no profit', (
      tester,
    ) async {
      await pump(
        tester,
        grants: {..._ceoKeys}..remove('products.edit_buying_price'),
      );
      expect(find.text('Cost'), findsNothing);
      expect(find.text('Retail profit'), findsNothing);
      expect(find.text('Wholesale profit'), findsNothing);
      expect(find.text('Retail'), findsOneWidget);
      expect(find.text('Wholesale'), findsOneWidget);
      await disposeScreen(tester);
    });

    testWidgets('a cost of 0 shows the Cost tile but no profit rows', (
      tester,
    ) async {
      detail = await seedDetailSample(env, sample, costKobo: 0);
      await pump(tester, seeded: detail);
      expect(find.text('Cost'), findsOneWidget);
      expect(find.text('Retail profit'), findsNothing);
      await disposeScreen(tester);
    });

    testWidgets('a loss shows in the danger colour', (tester) async {
      detail = await seedDetailSample(
        env,
        sample,
        costKobo: 1600000,
        retailKobo: 1500000,
        wholesaleKobo: 1420000,
      );
      await pump(tester, seeded: detail);
      expect(find.text('-7% of selling price'), findsOneWidget);
      final amount = tester.widget<Text>(find.text('-₦1,000'));
      expect(amount.style?.color, AppFixedColors.light.danger);
      await disposeScreen(tester);
    });
  });

  group('Stock by Store', () {
    testWidgets('one row per store with its pill or alert line', (
      tester,
    ) async {
      await pump(tester);
      expect(find.text('32 crates'), findsOneWidget);
      expect(find.text('Abuja HQ'), findsOneWidget);
      expect(find.text('Low stock, alert at 5'), findsOneWidget);
      expect(find.text('Warehouse'), findsOneWidget);
      expect(find.text('Alert at 5 crates'), findsOneWidget);
      await disposeScreen(tester);
    });

    testWidgets('an empty store reads "Out of stock" and the total follows', (
      tester,
    ) async {
      await pump(tester);
      await (env.db.update(env.db.inventory)
            ..where((i) => i.storeId.equals(detail.warehouseId)))
          .write(const InventoryCompanion(quantity: Value(0)));
      await deliver(tester);
      // Warehouse 0 + Abuja HQ 4: the page stays live without a reopen.
      expect(find.text('Out of stock'), findsWidgets);
      expect(find.text('4 crates'), findsOneWidget);
      expect(find.text('4 crates in stock'), findsOneWidget);
      await disposeScreen(tester);
    });

    testWidgets('a fine store shows the plain alert line', (tester) async {
      await pump(tester);
      await (env.db.update(env.db.inventory)
            ..where((i) => i.storeId.equals(env.storeId)))
          .write(const InventoryCompanion(quantity: Value(9)));
      await deliver(tester);
      expect(find.text('Low stock, alert at 5'), findsNothing);
      expect(find.text('Alert at 5 crates'), findsNWidgets(2));
      await disposeScreen(tester);
    });
  });

  group('Sales Target', () {
    testWidgets('no sales yet: 0 of the target, crates to go', (tester) async {
      await pump(tester);
      expect(find.text('of 200 crates sold'), findsOneWidget);
      expect(find.text('0%'), findsOneWidget);
      expect(
        find.textContaining('200 crates to go. That is about'),
        findsOneWidget,
      );
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      await disposeScreen(tester);
    });

    testWidgets('counts the crates sold this month', (tester) async {
      final productId = sample.productIds['Gulder']!;
      final orderId = UuidV7.generate();
      await env.db
          .into(env.db.orders)
          .insert(
            OrdersCompanion.insert(
              id: Value(orderId),
              businessId: env.businessId,
              orderNumber: 'ORD-$orderId',
              totalAmountKobo: 7500000,
              netAmountKobo: 7500000,
              paymentType: 'cash',
              status: 'pending',
              storeId: Value(env.storeId),
              createdAt: Value(DateTime.now()),
            ),
          );
      await env.db
          .into(env.db.orderItems)
          .insert(
            OrderItemsCompanion.insert(
              id: Value(UuidV7.generate()),
              businessId: env.businessId,
              orderId: orderId,
              productId: Value(productId),
              storeId: env.storeId,
              quantity: 5,
              unitPriceKobo: 1500000,
              totalKobo: 7500000,
            ),
          );
      await pump(tester);
      expect(find.text('5'), findsWidgets);
      expect(find.text('3%'), findsOneWidget);
      expect(find.textContaining('195 crates to go'), findsOneWidget);
      await disposeScreen(tester);
    });

    testWidgets('no target: "No target set" and no bar', (tester) async {
      detail = await seedDetailSample(env, sample, targetUnits: 0);
      await pump(tester, seeded: detail);
      expect(find.text('No target set'), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsNothing);
      expect(find.textContaining('to go'), findsNothing);
      await disposeScreen(tester);
    });

    testWidgets('the pencil is for the CEO only', (tester) async {
      await pump(tester);
      expect(find.byTooltip('Set sales target'), findsOneWidget);
      await disposeScreen(tester);
      await pump(
        tester,
        roleSlug: 'manager',
        roleRank: GateTier.manager,
        seeded: detail,
      );
      expect(find.byTooltip('Set sales target'), findsNothing);
      await disposeScreen(tester);
    });

    testWidgets('the pencil saves the new target', (tester) async {
      await pump(tester);
      await tester.ensureVisible(find.byTooltip('Set sales target'));
      await tester.pump();
      await tester.tap(find.byTooltip('Set sales target'));
      await tester.pumpAndSettle();
      expect(find.text('Sales Target'), findsNWidgets(2));
      await tester.enterText(find.byType(TextField), '300');
      await tester.tap(find.text('Save'));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pumpAndSettle();
      expect((await product()).monthlyTargetUnits, 300);
      expect(find.text('of 300 crates sold'), findsOneWidget);
      await disposeScreen(tester);
    });
  });

  group('Description', () {
    testWidgets('the pencil saves the new text', (tester) async {
      await pump(tester);
      await tester.ensureVisible(find.byTooltip('Edit description'));
      await tester.pump();
      await tester.tap(find.byTooltip('Edit description'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Cold and crisp.');
      await tester.tap(find.text('Save'));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pumpAndSettle();
      final saved = await product();
      expect(saved.subtitle, 'Cold and crisp.');
      // The rest of the row is written back as it was.
      expect(saved.retailerPriceKobo, 1500000);
      expect(saved.buyingPriceKobo, 1350000);
      expect(saved.name, 'Gulder');
      expect(find.text('Cold and crisp.'), findsOneWidget);
      await disposeScreen(tester);
    });

    testWidgets('clearing the text reads "No description yet"', (tester) async {
      await pump(tester);
      await tester.ensureVisible(find.byTooltip('Edit description'));
      await tester.pump();
      await tester.tap(find.byTooltip('Edit description'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '   ');
      await tester.tap(find.text('Save'));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pumpAndSettle();
      expect((await product()).subtitle, isNull);
      expect(find.text('No description yet'), findsOneWidget);
      await disposeScreen(tester);
    });

    testWidgets('Cancel leaves it alone', (tester) async {
      await pump(tester);
      await tester.ensureVisible(find.byTooltip('Edit description'));
      await tester.pump();
      await tester.tap(find.byTooltip('Edit description'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Something else');
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect((await product()).subtitle, startsWith('Lager beer'));
      await disposeScreen(tester);
    });
  });

  group('pop-ups with the keyboard up', () {
    for (final (name, size, insets, keyboard)
        in <(String, Size, FakeViewPadding, double)>[
          ('390x844', const Size(390, 844), _gesture, 300.0),
          ('844x390 sideways', const Size(844, 390), _sideways, 180.0),
        ]) {
      for (final which in const ['Edit description', 'Set sales target']) {
        testWidgets('$which at $name scrolls, no overflow', (tester) async {
          await pump(tester, size: size, insets: insets);
          await tester.ensureVisible(find.byTooltip(which));
          await tester.pump();
          await tester.tap(find.byTooltip(which));
          await tester.pumpAndSettle();
          expect(
            tester.widget<AlertDialog>(find.byType(AlertDialog)).scrollable,
            isTrue,
          );
          tester.view.viewInsets = FakeViewPadding(bottom: keyboard);
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          // The text box and both buttons stay reachable above the keyboard.
          final top = size.height - keyboard;
          expect(tester.getRect(find.byType(TextField)).top, lessThan(top));
          await tester.drag(
            find.byType(SingleChildScrollView).last,
            const Offset(0, -300),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          expect(find.text('Save'), findsOneWidget);
          await disposeScreen(tester);
        });
      }
    }
  });

  group('Archive and Unarchive', () {
    testWidgets('Archive asks first; Cancel changes nothing', (tester) async {
      await pump(tester);
      await showAllCards(tester);
      await tester.tap(find.text('Archive Product'));
      await tester.pumpAndSettle();
      expect(
        find.text(
          'Archive Gulder? It will be hidden from sale. Its sales history is '
          'kept.',
        ),
        findsOneWidget,
      );
      expect(
        tester.widget<AlertDialog>(find.byType(AlertDialog)).scrollable,
        isTrue,
      );
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect((await product()).isAvailable, isTrue);
      expect(find.text('Archived'), findsNothing);
      await disposeScreen(tester);
    });

    testWidgets('confirming archives it, then Unarchive brings it back', (
      tester,
    ) async {
      await pump(tester);
      await showAllCards(tester);
      await tester.tap(find.text('Archive Product'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text('Archive'),
        ),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 150)),
      );
      await tester.pumpAndSettle();
      expect((await product()).isAvailable, isFalse);
      await deliver(tester);
      expect(find.text('Archived'), findsOneWidget);
      expect(find.text('Unarchive Product'), findsOneWidget);
      expect(find.text('Archive Product'), findsNothing);

      // Unarchive needs no confirmation.
      await showAllCards(tester);
      await tester.tap(find.text('Unarchive Product'));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 150)),
      );
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect((await product()).isAvailable, isTrue);
      await deliver(tester);
      expect(find.text('Archived'), findsNothing);
      // Let the toast's timer run out.
      await tester.pump(const Duration(seconds: 5));
      await disposeScreen(tester);
    });

    testWidgets('an archived product opens with the pill and Unarchive', (
      tester,
    ) async {
      detail = await seedDetailSample(env, sample, archived: true);
      await pump(tester, seeded: detail);
      expect(find.text('Archived'), findsOneWidget);
      await showAllCards(tester);
      expect(find.text('Unarchive Product'), findsOneWidget);
      await disposeScreen(tester);
    });

    testWidgets('delete still asks in a scrollable pop-up', (tester) async {
      await pump(tester);
      await showAllCards(tester);
      await tester.tap(find.text('Delete Product'));
      await tester.pumpAndSettle();
      expect(find.text('Delete Product'), findsNWidgets(2));
      expect(
        tester.widget<AlertDialog>(find.byType(AlertDialog)).scrollable,
        isTrue,
      );
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      await disposeScreen(tester);
    });
  });

  group('permissions', () {
    testWidgets('CEO sees every action', (tester) async {
      await pump(tester);
      expect(find.byTooltip('Edit description'), findsOneWidget);
      expect(find.byTooltip('Set sales target'), findsOneWidget);
      expect(find.byTooltip('Change photo'), findsNothing); // a Semantics label
      expect(find.bySemanticsLabel('Change photo'), findsOneWidget);
      await showAllCards(tester);
      expect(find.text('Archive Product'), findsOneWidget);
      expect(find.text('Delete Product'), findsOneWidget);
      await openMenu(tester);
      expect(find.text('Adjust Stock'), findsOneWidget);
      expect(find.text('Edit Product'), findsOneWidget);
      await disposeScreen(tester);
    });

    testWidgets('cashier, view only: nothing to act on', (tester) async {
      await pump(
        tester,
        grants: const {'sales.make', 'stock.view'},
        roleSlug: 'cashier',
        roleRank: GateTier.cashier,
      );
      expect(find.byTooltip('Edit description'), findsNothing);
      expect(find.byTooltip('Set sales target'), findsNothing);
      expect(find.bySemanticsLabel('Change photo'), findsNothing);
      expect(find.byTooltip('More options'), findsNothing);
      expect(find.text('Cost'), findsNothing);
      expect(find.text('Retail profit'), findsNothing);
      await showAllCards(tester);
      expect(find.text('Manage Product'), findsNothing);
      expect(find.text('Archive Product'), findsNothing);
      expect(find.text('Delete Product'), findsNothing);
      // Everything to read is still there.
      expect(find.text('Stock by Store'), findsOneWidget);
      expect(find.text('Sales Target'), findsOneWidget);
      await disposeScreen(tester);
    });

    testWidgets('stock keeper with Adjust Stock only', (tester) async {
      await pump(
        tester,
        grants: const {'stock.view', 'stock.adjust'},
        roleSlug: 'stock_keeper',
        roleRank: GateTier.stockKeeper,
      );
      expect(find.byTooltip('Edit description'), findsNothing);
      await openMenu(tester);
      expect(find.text('Adjust Stock'), findsOneWidget);
      expect(find.text('Edit Product'), findsNothing);
      await tester.tap(find.text('Adjust Stock'));
      await tester.pumpAndSettle();
      // The existing sheet, now titled Adjust Stock.
      expect(find.text('Adjust Stock'), findsOneWidget);
      expect(find.text('Remove stock'), findsOneWidget);
      expect(find.text('Add stock'), findsNothing);
      await disposeScreen(tester);
    });

    testWidgets('manager without delete: Archive yes, Delete no', (
      tester,
    ) async {
      await pump(
        tester,
        grants: {..._ceoKeys}..remove('products.delete'),
        roleSlug: 'manager',
        roleRank: GateTier.manager,
      );
      await showAllCards(tester);
      expect(find.text('Manage Product'), findsOneWidget);
      expect(find.text('Archive Product'), findsOneWidget);
      expect(find.text('Delete Product'), findsNothing);
      await disposeScreen(tester);
    });

    testWidgets('delete only: the card shows just Delete', (tester) async {
      await pump(
        tester,
        grants: const {'stock.view', 'products.delete'},
        roleSlug: 'manager',
        roleRank: GateTier.manager,
      );
      await showAllCards(tester);
      expect(find.text('Manage Product'), findsOneWidget);
      expect(find.text('Archive Product'), findsNothing);
      expect(find.text('Delete Product'), findsOneWidget);
      await disposeScreen(tester);
    });
  });

  group('top bar actions', () {
    testWidgets('Edit Product opens the form in edit mode', (tester) async {
      await pump(tester);
      await openMenu(tester);
      await tester.tap(find.text('Edit Product'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<AddProductScreen>(find.byType(AddProductScreen))
            .editProduct,
        isNotNull,
      );
      await disposeScreen(tester);
    });

    testWidgets('Adjust Stock opens the stock sheet', (tester) async {
      await pump(tester);
      await openMenu(tester);
      await tester.tap(find.text('Adjust Stock'));
      await tester.pumpAndSettle();
      expect(find.text('Add stock'), findsOneWidget);
      expect(find.text('Remove stock'), findsOneWidget);
      await disposeScreen(tester);
    });

    testWidgets('wide: tonal Adjust Stock and primary Edit Product sit in '
        'the bar', (tester) async {
      await pump(
        tester,
        size: const Size(1280, 800),
        insets: const FakeViewPadding(top: 24),
      );
      expect(find.text('Adjust Stock'), findsOneWidget);
      expect(find.text('Edit Product'), findsOneWidget);
      // The menu holds only what is left (the report link needs a factory
      // barcode), so there is no menu at all here.
      expect(find.byTooltip('More options'), findsNothing);
      await tester.tap(find.text('Edit Product'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<AddProductScreen>(find.byType(AddProductScreen))
            .editProduct,
        isNotNull,
      );
      await disposeScreen(tester);
    });

    testWidgets('phone: the actions live in the menu, not the bar', (
      tester,
    ) async {
      await pump(tester);
      expect(find.text('Adjust Stock'), findsNothing);
      expect(find.text('Edit Product'), findsNothing);
      await disposeScreen(tester);
    });

    testWidgets('a factory barcode adds "Report a problem" to the menu', (
      tester,
    ) async {
      detail = await seedDetailSample(env, sample, barcode: '5449000000996');
      await pump(tester, seeded: detail);
      await openMenu(tester);
      expect(
        find.text('Report a problem with the shared details'),
        findsOneWidget,
      );
      await disposeScreen(tester);
    });
  });

  group('layout', () {
    Rect panelOf(WidgetTester tester, String title) => tester.getRect(
      find
          .ancestor(of: find.text(title), matching: find.byType(DetailPanel))
          .first,
    );

    testWidgets('390: one column in the phone order', (tester) async {
      await pump(tester);
      final left = panelOf(tester, 'Description').left;
      for (final t in ['Prices & Profit', 'Stock by Store', 'Sales Target']) {
        expect(panelOf(tester, t).left, closeTo(left, 1), reason: t);
      }
      await showAllCards(tester);
      // Manage Product is the last card, under the two new cards.
      expect(
        panelOf(tester, 'Manage Product').top,
        greaterThan(panelOf(tester, 'Stock History').top),
      );
      await disposeScreen(tester);
    });

    testWidgets('800: two columns', (tester) async {
      await pump(tester, size: const Size(800, 1500));
      final desc = panelOf(tester, 'Description');
      final stock = panelOf(tester, 'Stock by Store');
      // Column 1: Hero, Description, Prices, Manage. Column 2: Stock, Target,
      // then Sales and Stock History.
      expect(panelOf(tester, 'Prices & Profit').left, closeTo(desc.left, 1));
      expect(panelOf(tester, 'Manage Product').left, closeTo(desc.left, 1));
      expect(stock.left, greaterThan(desc.right));
      expect(panelOf(tester, 'Sales Target').left, closeTo(stock.left, 1));
      expect(panelOf(tester, 'Sales').left, closeTo(stock.left, 1));
      await disposeScreen(tester);
    });

    testWidgets('1280: three columns', (tester) async {
      await pump(
        tester,
        size: const Size(1280, 1000),
        insets: const FakeViewPadding(top: 24),
      );
      final desc = panelOf(tester, 'Description');
      final prices = panelOf(tester, 'Prices & Profit');
      final summary = panelOf(tester, 'Sales');
      // Column 1: Hero, Description, Manage. Column 2: Prices, Stock, Target.
      // Column 3: Sales and Stock History.
      expect(panelOf(tester, 'Manage Product').left, closeTo(desc.left, 1));
      expect(prices.left, greaterThan(desc.right));
      expect(panelOf(tester, 'Stock by Store').left, closeTo(prices.left, 1));
      expect(panelOf(tester, 'Sales Target').left, closeTo(prices.left, 1));
      expect(summary.left, greaterThan(prices.right));
      expect(panelOf(tester, 'Stock History').left, closeTo(summary.left, 1));
      await disposeScreen(tester);
    });

    testWidgets('a very wide screen caps the content at 1400', (tester) async {
      await pump(
        tester,
        size: const Size(1900, 1000),
        insets: const FakeViewPadding(top: 24),
      );
      final first = panelOf(tester, 'Description').left;
      final last = panelOf(tester, 'Sales').right;
      expect(last - first, closeTo(1400, 40));
      await disposeScreen(tester);
    });

    for (final (name, size, insets, scale)
        in <(String, Size, FakeViewPadding, double)>[
          ('360x740 @1.3', const Size(360, 740), _gesture, 1.3),
          ('390x844', const Size(390, 844), _gesture, 1.0),
          ('844x390 insets', const Size(844, 390), _sideways, 1.0),
          ('800x1280', const Size(800, 1280), _gesture, 1.0),
          (
            '1280x800',
            const Size(1280, 800),
            const FakeViewPadding(top: 24),
            1.0,
          ),
          (
            '1280x800 @1.3',
            const Size(1280, 800),
            const FakeViewPadding(top: 24),
            1.3,
          ),
        ]) {
      testWidgets('no overflow at $name', (tester) async {
        await pump(
          tester,
          size: size,
          insets: insets,
          textScaler: TextScaler.linear(scale),
        );
        expect(tester.takeException(), isNull);
        // Scroll to the end: every card lays out without an overflow.
        await showAllCards(tester);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.text('Manage Product'), findsOneWidget);
        await disposeScreen(tester);
      });
    }
  });

  group('Sales and Stock History cards (PR 5)', () {
    Future<void> sellToday(int qty, {int cost = 0}) async {
      final productId = sample.productIds['Gulder']!;
      final orderId = UuidV7.generate();
      await env.db
          .into(env.db.orders)
          .insert(
            OrdersCompanion.insert(
              id: Value(orderId),
              businessId: env.businessId,
              orderNumber: 'ORD-$orderId',
              totalAmountKobo: qty * 1500000,
              netAmountKobo: qty * 1500000,
              paymentType: 'cash',
              status: 'pending',
              storeId: Value(env.storeId),
              createdAt: Value(DateTime.now()),
            ),
          );
      await env.db
          .into(env.db.orderItems)
          .insert(
            OrderItemsCompanion.insert(
              id: Value(UuidV7.generate()),
              businessId: env.businessId,
              orderId: orderId,
              productId: Value(productId),
              storeId: env.storeId,
              quantity: qty,
              unitPriceKobo: 1500000,
              totalKobo: qty * 1500000,
              buyingPriceKobo: Value(cost),
            ),
          );
    }

    Future<void> move(
      String type,
      int delta,
      int minutesAgo, {
      String? reason,
    }) async {
      final at = DateTime.now().subtract(Duration(minutes: minutesAgo));
      final String adjId;
      {
        adjId = UuidV7.generate();
        await env.db
            .into(env.db.stockAdjustments)
            .insert(
              StockAdjustmentsCompanion.insert(
                id: Value(adjId),
                businessId: env.businessId,
                productId: sample.productIds['Gulder']!,
                storeId: env.storeId,
                quantityDiff: delta,
                reason: reason ?? 'Sample',
                performedBy: Value(sample.staffId),
                createdAt: Value(at),
                lastUpdatedAt: Value(at),
              ),
            );
      }
      await env.db
          .into(env.db.stockTransactions)
          .insert(
            StockTransactionsCompanion.insert(
              id: Value(UuidV7.generate()),
              businessId: env.businessId,
              productId: sample.productIds['Gulder']!,
              locationId: env.storeId,
              quantityDelta: delta,
              movementType: type,
              adjustmentId: Value(adjId),
              performedBy: Value(sample.staffId),
              createdAt: Value(at),
              lastUpdatedAt: Value(at),
            ),
          );
    }

    /// The ledger is append-only, so the sample's own movement is voided (the
    /// history leaves voided rows out).
    Future<void> clearHistory() => env.db
        .update(env.db.stockTransactions)
        .write(StockTransactionsCompanion(voidedAt: Value(DateTime.now())));

    testWidgets('Week | Month switch changes the period', (tester) async {
      await sellToday(5, cost: 1000000);
      await pump(tester);
      await showAllCards(tester);
      expect(find.text('Last 7 days'), findsOneWidget);
      expect(find.text('5'), findsWidgets);
      expect(find.text('crates sold'), findsOneWidget);
      expect(find.text('Today'), findsOneWidget);
      await tester.drag(
        find.byType(SingleChildScrollView).first,
        const Offset(0, 500),
      );
      await tester.pump();
      await tester.tap(find.text('Month'));
      await tester.pump();
      expect(find.text('This month'), findsOneWidget);
      expect(find.text('Last 7 days'), findsNothing);
      expect(find.text('Today'), findsOneWidget);
      await tester.tap(find.text('Week'));
      await tester.pump();
      expect(find.text('Last 7 days'), findsOneWidget);
      await disposeScreen(tester);
    });

    testWidgets('Revenue and Profit show with the permission', (tester) async {
      await sellToday(2, cost: 1000000);
      await pump(tester);
      expect(find.text('Revenue'), findsOneWidget);
      expect(find.text('Profit'), findsOneWidget);
      expect(find.textContaining('no cost yet'), findsNothing);
      await disposeScreen(tester);
    });

    testWidgets('an uncosted sale adds the small note', (tester) async {
      await sellToday(2, cost: 0);
      await pump(tester);
      expect(find.textContaining('no cost yet'), findsOneWidget);
      await disposeScreen(tester);
    });

    testWidgets('Profit is hidden without editBuyingPrice', (tester) async {
      await sellToday(2, cost: 0);
      await pump(
        tester,
        grants: kInventorySampleGrants,
        roleSlug: 'manager',
        roleRank: GateTier.manager,
      );
      expect(find.text('Revenue'), findsOneWidget);
      expect(find.text('Profit'), findsNothing);
      expect(find.textContaining('no cost yet'), findsNothing);
      await disposeScreen(tester);
    });

    testWidgets('Stock History shows the last 5 movements, typed', (
      tester,
    ) async {
      await clearHistory();
      await move('sale', -2, 10);
      await move('purchase_received', 30, 20);
      await move('adjustment', -1, 30, reason: 'Damaged');
      await move('transfer_out', -10, 40);
      await move('sale', -5, 50);
      await move('sale', -9, 60); // the sixth is not on the card
      await pump(tester);
      await showAllCards(tester);
      expect(find.byType(StockMovementRow), findsNWidgets(5));
      expect(find.text('Sale'), findsNWidgets(2));
      expect(find.text('Stock Received'), findsOneWidget);
      expect(find.text('Adjustment: Damaged'), findsOneWidget);
      expect(find.text('Transfer'), findsOneWidget);
      expect(find.text('-2'), findsOneWidget);
      expect(find.text('+30'), findsOneWidget);
      expect(find.text('-9'), findsNothing);
      expect(find.text('crates'), findsWidgets);
      expect(find.textContaining('Today, '), findsWidgets);
      await disposeScreen(tester);
    });

    testWidgets('View All opens this product\'s whole history', (tester) async {
      await clearHistory();
      for (var i = 0; i < 7; i++) {
        await move('sale', -(i + 1), 10 + i);
      }
      await pump(tester);
      await showAllCards(tester);
      await tester.drag(
        find.byType(SingleChildScrollView).first,
        const Offset(0, 300),
      );
      await tester.pump();
      await tester.tap(find.text('View All'));
      await deliver(tester);
      expect(find.byType(ProductStockHistoryScreen), findsOneWidget);
      expect(find.text('Stock History'), findsOneWidget);
      expect(find.byType(StockMovementRow), findsNWidgets(7));
      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      expect(find.byType(ProductStockHistoryScreen), findsNothing);
      await disposeScreen(tester);
    });

    testWidgets('empty states: no sales and no movements', (tester) async {
      await clearHistory();
      await pump(tester);
      await showAllCards(tester);
      expect(find.text('0'), findsWidgets);
      expect(find.text('crates sold'), findsOneWidget);
      expect(find.text('No stock movements yet'), findsOneWidget);
      await disposeScreen(tester);
    });
  });
}
