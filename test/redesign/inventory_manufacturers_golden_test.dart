// Visual goldens for Inventory → Manufacturers (#389): every manufacturer as a
// settings-style row, bottle brands with a blue tile and their crate value,
// the rest neutral with "No returnable bottles".
//
// 390x844 (gesture nav, bottom 24) and 844x390 (status bar 24, 3-button nav
// on the right 48), light + dark. Regenerate with:
//
//     flutter test --update-goldens test/redesign/inventory_manufacturers_golden_test.dart

import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/core/permissions/gate.dart';
import 'package:reebaplus_pos/core/providers/first_run_surface_state.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/features/inventory/screens/inventory_screen.dart';
import 'package:reebaplus_pos/features/inventory/widgets/inventory_manufacturers_tab.dart';

import '../helpers/screen_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ScreenTestEnvironment env;

  Future<void> seed() async {
    for (final (name, unit, kobo) in const [
      ('Guinness Nigeria', 'Bottle', 150000),
      ('Coca-Cola HBC', 'PET', 0),
      ('Nigerian Breweries', 'Bottle', 120000),
      ('Red Bull', 'Can', 0),
    ]) {
      final id = UuidV7.generate();
      await env.db
          .into(env.db.manufacturers)
          .insert(
            ManufacturersCompanion.insert(
              id: Value(id),
              businessId: env.businessId,
              name: name,
              depositAmountKobo: Value(kobo),
            ),
          );
      await env.db
          .into(env.db.products)
          .insert(
            ProductsCompanion.insert(
              id: Value(UuidV7.generate()),
              businessId: env.businessId,
              manufacturerId: Value(id),
              name: '$name $unit',
              unit: Value(unit),
              trackEmpties: const Value(true),
              retailerPriceKobo: const Value(60000),
            ),
          );
    }
  }

  setUp(() async {
    env = await setupScreenTestEnvironment(
      productCount: 0,
      businessName: 'Stallion Global',
      businessType: 'Beverage distributor',
    );
    await seed();
  });

  tearDown(() => env.dispose());

  setUpAll(() => WidgetsApp.debugAllowBannerOverride = false);
  tearDownAll(() => WidgetsApp.debugAllowBannerOverride = true);

  for (final brightness in Brightness.values) {
    final themeName = brightness == Brightness.light ? 'light' : 'dark';
    for (final (size, insets) in const [
      (Size(390, 844), FakeViewPadding(top: 24, bottom: 24)),
      (Size(844, 390), FakeViewPadding(top: 24, right: 48)),
    ]) {
      final sizeName = '${size.width.toInt()}x${size.height.toInt()}';

      testWidgets('inventory manufacturers tab, $sizeName $themeName', (
        tester,
      ) async {
        tester.view.padding = insets;
        tester.view.viewPadding = insets;
        addTearDown(tester.view.resetPadding);
        addTearDown(tester.view.resetViewPadding);
        await pumpScreen(
          tester,
          env: env,
          size: size,
          screen: const InventoryScreen(),
          followView: true,
          grantedKeys: const {
            'sales.make',
            'stock.view',
            'products.add',
            'stock.add',
            'products.edit_price',
          },
          roleRank: GateTier.ceo,
          theme: brightness == Brightness.light
              ? AppTheme.light()
              : AppTheme.dark(),
          overrides: [
            firstRunSurfaceStateProvider.overrideWithValue(
              FirstRunSurfaceState.hasContent,
            ),
          ],
        );
        await tester.tap(find.widgetWithText(Tab, 'Manufacturers'));
        await tester.pumpAndSettle();
        expect(find.byType(InventoryManufacturersTab), findsOneWidget);
        expect(tester.takeException(), isNull);
        await expectLater(
          find.byType(MaterialApp),
          matchesGoldenFile(
            'goldens/inventory_manufacturers_${sizeName}_$themeName.png',
          ),
        );
        await disposeScreen(tester);
      });
    }
  }
}
