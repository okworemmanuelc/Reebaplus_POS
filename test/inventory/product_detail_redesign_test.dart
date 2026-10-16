// #392 PR 3 (Wave 2 A): the restyled Product Detail keeps every value and
// permission rule, holds its content at every redesign viewport, caps at 960
// and pairs its header cards from a measured 900.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/permissions/gate.dart';
import 'package:reebaplus_pos/features/inventory/data/models/inventory_item.dart';
import 'package:reebaplus_pos/features/inventory/screens/product_detail_screen.dart';
import 'package:reebaplus_pos/features/inventory/widgets/inventory_parts.dart';
import 'package:reebaplus_pos/features/inventory/widgets/product_detail_parts.dart';

import '../helpers/inventory_seed.dart';
import '../helpers/screen_harness.dart';

const _all = {
  ...kInventorySampleGrants,
  'products.edit_buying_price',
  'products.delete',
};

const _gesture = FakeViewPadding(top: 24, bottom: 24);
const _sideways = FakeViewPadding(top: 24, right: 48);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ScreenTestEnvironment env;
  late InventorySample sample;

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

  Future<void> pump(
    WidgetTester tester, {
    Size size = const Size(390, 844),
    FakeViewPadding insets = _gesture,
    Set<String> grants = _all,
    TextScaler? textScaler,
  }) async {
    tester.view.padding = insets;
    tester.view.viewPadding = insets;
    addTearDown(tester.view.resetPadding);
    addTearDown(tester.view.resetViewPadding);
    await pumpScreen(
      tester,
      env: env,
      size: size,
      screen: ProductDetailScreen(
        item: InventoryItem(
          id: sample.productIds['Gulder']!,
          productName: 'Gulder',
          subtitle: '60cl',
          icon: Icons.local_drink,
          color: Colors.blue,
          storeStock: {env.storeId: 4},
          lowStockThreshold: 5,
          unit: 'Bottle',
        ),
        onUpdateStock: () {},
        selectedStoreId: env.storeId,
      ),
      followView: true,
      settle: false,
      grantedKeys: grants,
      roleRank: GateTier.ceo,
      textScaler: textScaler,
    );
    // The detail loads its rows from the database on the real clock.
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 250));
    }
  }

  void expectTarget(WidgetTester tester, Finder f) {
    final size = tester.getSize(f);
    expect(size.width, greaterThanOrEqualTo(kMinInteractiveDimension));
    expect(size.height, greaterThanOrEqualTo(kMinInteractiveDimension));
  }

  group('renders its sections', () {
    testWidgets('top bar, hero, status and every section', (tester) async {
      await pump(tester);
      expect(find.byType(InventoryTopBar), findsOneWidget);
      expect(find.text('Product Details'), findsOneWidget);
      expect(find.text('Gulder'), findsWidgets);
      expect(find.text('Low Stock'), findsOneWidget);
      for (final s in const [
        'Pricing',
        'Stock & Info',
        'Sales Summary',
        'Sales Target',
        'Last Delivery',
      ]) {
        expect(find.text(s), findsOneWidget, reason: s);
      }
      expect(find.text('Total Quantity'), findsOneWidget);
      expect(find.text('Total Stock Value'), findsOneWidget);
      expect(find.text('No deliveries recorded yet'), findsOneWidget);
      expect(find.text('VIEW ONLY'), findsOneWidget);
      await disposeScreen(tester);
    });

    testWidgets('back and delete are 48dp targets', (tester) async {
      await pump(tester);
      expectTarget(tester, find.byTooltip('Back'));
      expectTarget(tester, find.byTooltip('Delete product'));
      await disposeScreen(tester);
    });
  });

  group('permission rules', () {
    testWidgets('delete is hidden without products.delete', (tester) async {
      await pump(tester, grants: {..._all}..remove('products.delete'));
      expect(find.byTooltip('Delete product'), findsNothing);
      await disposeScreen(tester);
    });

    testWidgets('Buying Price needs products.edit_buying_price', (
      tester,
    ) async {
      await pump(tester);
      expect(find.text('Buying Price'), findsOneWidget);
      await disposeScreen(tester);
      await pump(
        tester,
        grants: {..._all}..remove('products.edit_buying_price'),
      );
      expect(find.text('Buying Price'), findsNothing);
      await disposeScreen(tester);
    });

    testWidgets('Supplier row needs suppliers.manage', (tester) async {
      await pump(tester);
      expect(find.text('Supplier'), findsOneWidget);
      await disposeScreen(tester);
      await pump(tester, grants: {..._all}..remove('suppliers.manage'));
      expect(find.text('Supplier'), findsNothing);
      await disposeScreen(tester);
    });
  });

  testWidgets('delete opens a scrollable confirmation and Cancel closes it', (
    tester,
  ) async {
    await pump(tester);
    await tester.tap(find.byTooltip('Delete product'));
    await tester.pumpAndSettle();
    expect(find.text('Delete Product'), findsOneWidget);
    expect(
      tester.widget<AlertDialog>(find.byType(AlertDialog)).scrollable,
      isTrue,
    );
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    await disposeScreen(tester);
  });

  group('layout', () {
    for (final (name, size, insets, scale)
        in <(String, Size, FakeViewPadding, double)>[
          ('360x740 @1.3', const Size(360, 740), _gesture, 1.3),
          ('390x844', const Size(390, 844), _gesture, 1.0),
          ('844x390 insets', const Size(844, 390), _sideways, 1.0),
          ('800x1280', const Size(800, 1280), _gesture, 1.0),
          ('1280x800', const Size(1280, 800), FakeViewPadding(top: 24), 1.0),
        ]) {
      testWidgets('no overflow at $name', (tester) async {
        await pump(
          tester,
          size: size,
          insets: insets,
          textScaler: TextScaler.linear(scale),
        );
        expect(tester.takeException(), isNull);
        // Scroll to the end: every section lays out without an overflow.
        await tester.drag(
          find.byType(SingleChildScrollView).first,
          const Offset(0, -4000),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.text('VIEW ONLY'), findsOneWidget);
        await disposeScreen(tester);
      });
    }

    testWidgets('1280x800: capped at 960, centred, cards side by side', (
      tester,
    ) async {
      await pump(
        tester,
        size: const Size(1280, 800),
        insets: const FakeViewPadding(top: 24),
      );
      final stockTitle = tester.getTopLeft(find.text('Stock & Info'));
      final pricingTitle = tester.getTopLeft(find.text('Pricing'));
      // Side by side: same top, Pricing to the right of Stock & Info.
      expect(pricingTitle.dy, closeTo(stockTitle.dy, 1));
      expect(pricingTitle.dx, greaterThan(stockTitle.dx + 300));
      // The two columns together span the 960 cap, centred in the content.
      final left = tester.getTopLeft(find.byType(DetailCard).first).dx;
      final right = tester.getTopRight(find.byType(DetailCard).at(1)).dx;
      expect(right - left, closeTo(kDetailMaxContentWidth, 1));
      await disposeScreen(tester);
    });

    testWidgets('390x844: cards stack in one column', (tester) async {
      await pump(tester);
      final stockCard = tester.getBottomLeft(find.byType(DetailCard).first);
      final pricing = tester.getTopLeft(find.text('Pricing'));
      expect(pricing.dy, greaterThan(stockCard.dy));
      await disposeScreen(tester);
    });
  });
}
