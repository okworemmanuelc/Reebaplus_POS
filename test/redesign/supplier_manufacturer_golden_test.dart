// Visual goldens for Supplier Detail, the Manufacturer screen and the crate
// sheets (#392 PR 4).
//
// Main screens at 390x844 (gesture nav, bottom 24), 844x390 (status bar 24,
// 3-button nav on the right 48), 800x1280 and 1280x800; the sheets at 390x844
// and 844x390. Light + dark. Every date is pinned (the ledger opens on a fixed
// March 2025 range), so nothing depends on today. Regenerate with:
//
//     flutter test --update-goldens test/redesign/supplier_manufacturer_golden_test.dart

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/crates/manufacturer_crate_position.dart';
import 'package:reebaplus_pos/core/permissions/gate.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/business_scoped_stream.dart';
import 'package:reebaplus_pos/core/providers/first_run_surface_state.dart';
import 'package:reebaplus_pos/core/services/barcode_catalogue_service.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/features/inventory/screens/manufacturer_screen.dart';
import 'package:reebaplus_pos/features/inventory/screens/supplier_detail_screen.dart';
import 'package:reebaplus_pos/features/inventory/widgets/buy_crates_sheet.dart';
import 'package:reebaplus_pos/features/inventory/widgets/catalogue_report_link.dart';
import 'package:reebaplus_pos/features/inventory/widgets/count_manufacturer_empties_sheet.dart';
import 'package:reebaplus_pos/features/inventory/widgets/crate_value_change_sheet.dart';
import 'package:reebaplus_pos/features/inventory/widgets/manufacturer_settings_tab.dart';
import 'package:reebaplus_pos/features/inventory/widgets/record_damaged_crates_sheet.dart';

import '../helpers/screen_harness.dart';
import '../helpers/supplier_manufacturer_seed.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ScreenTestEnvironment env;
  late SupplierManufacturerSample sample;

  setUp(() async {
    env = await setupScreenTestEnvironment(
      productCount: 0,
      businessName: 'Stallion Global',
      businessType: 'Beverage distributor',
    );
    sample = await seedSupplierManufacturerSample(env);
  });

  setUpAll(() => WidgetsApp.debugAllowBannerOverride = false);
  tearDownAll(() => WidgetsApp.debugAllowBannerOverride = true);

  const all = <(String, Size, FakeViewPadding)>[
    ('390x844', Size(390, 844), FakeViewPadding(top: 24, bottom: 24)),
    ('844x390', Size(844, 390), FakeViewPadding(top: 24, right: 48)),
    ('800x1280', Size(800, 1280), FakeViewPadding(top: 24, bottom: 24)),
    ('1280x800', Size(1280, 800), FakeViewPadding(top: 24)),
  ];
  final phones = [all[0], all[1]];
  final pair = [all.first, all.last];

  /// Drift's streams resolve in real async time.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 200));
    }
  }

  Future<void> pump(
    WidgetTester tester, {
    required Widget screen,
    required Size size,
    required FakeViewPadding insets,
    required Brightness brightness,
  }) async {
    tester.view.padding = insets;
    tester.view.viewPadding = insets;
    addTearDown(tester.view.resetPadding);
    addTearDown(tester.view.resetViewPadding);
    await pumpScreen(
      tester,
      env: env,
      size: size,
      screen: screen,
      followView: true,
      bottomNavHeight: 0,
      grantedKeys: kSupplierManufacturerGrants,
      roleRank: GateTier.ceo,
      // The harness's store is renamed in the database; the picker list is an
      // override, so rename it there too.
      selectableStores: [env.store.copyWith(name: 'Abuja HQ')],
      theme: brightness == Brightness.light
          ? AppTheme.light()
          : AppTheme.dark(),
      overrides: [
        currentBusinessProvider.overrideWith((ref) => sample.business),
        firstRunSurfaceStateProvider.overrideWithValue(
          FirstRunSurfaceState.hasContent,
        ),
        barcodeCatalogueServiceProvider.overrideWithValue(
          BarcodeCatalogueService.withFetchers(
            fetchRow: (_) async =>
                (name: 'Gulder Lager 60cl', unit: 'Bottle', photoUrl: null),
            fetchPhoto: (_) async => throw UnimplementedError(),
            sendReport: (_) async {},
            timeout: const Duration(milliseconds: 200),
          ),
        ),
        currentBusinessIdProvider.overrideWithValue(env.businessId),
      ],
      settle: false,
    );
    await settle(tester);
  }

  Future<void> snap(WidgetTester tester, String name) async {
    expect(tester.takeException(), isNull);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/$name.png'),
    );
    // Lets a toast's timer run out, then unmounts and closes the database
    // inside runAsync (Drift's streams block a plain tearDown close).
    await tester.pump(const Duration(seconds: 5));
    await disposeScreen(tester);
    await tester.runAsync(() => env.dispose());
  }

  Future<void> tapVisible(WidgetTester tester, Finder finder) async {
    // Centre it so the pinned tab bar doesn't cover it.
    await Scrollable.ensureVisible(tester.element(finder), alignment: 0.5);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(finder);
    await settle(tester);
  }

  for (final brightness in Brightness.values) {
    final theme = brightness == Brightness.light ? 'light' : 'dark';

    for (final (sizeName, size, insets) in all) {
      testWidgets('supplier detail, ledger, $sizeName $theme', (tester) async {
        await pump(
          tester,
          screen: SupplierDetailScreen(
            supplierId: sample.supplierId,
            initialTimeFilter: kSampleLedgerPeriod,
          ),
          size: size,
          insets: insets,
          brightness: brightness,
        );
        await snap(tester, 'supplier_detail_${sizeName}_$theme');
      });

      testWidgets('manufacturer, crates, $sizeName $theme', (tester) async {
        await pump(
          tester,
          screen: ManufacturerScreen(manufacturer: sample.guinness),
          size: size,
          insets: insets,
          brightness: brightness,
        );
        await snap(tester, 'manufacturer_screen_${sizeName}_$theme');
      });
    }

    for (final (sizeName, size, insets) in pair) {
      testWidgets('supplier detail, crates tab, $sizeName $theme', (
        tester,
      ) async {
        await pump(
          tester,
          screen: SupplierDetailScreen(
            supplierId: sample.supplierId,
            initialTimeFilter: kSampleLedgerPeriod,
          ),
          size: size,
          insets: insets,
          brightness: brightness,
        );
        await tapVisible(tester, find.widgetWithText(Tab, 'Empty Crates'));
        await snap(tester, 'supplier_detail_crates_${sizeName}_$theme');
      });

      testWidgets('manufacturer, settings tab, $sizeName $theme', (
        tester,
      ) async {
        await pump(
          tester,
          screen: ManufacturerScreen(manufacturer: sample.guinness),
          size: size,
          insets: insets,
          brightness: brightness,
        );
        await tapVisible(tester, find.widgetWithText(Tab, 'Settings'));
        await snap(tester, 'manufacturer_screen_settings_${sizeName}_$theme');
      });
    }

    for (final (sizeName, size, insets) in phones) {
      testWidgets('buy crates sheet, $sizeName $theme', (tester) async {
        await pump(
          tester,
          screen: ManufacturerScreen(manufacturer: sample.guinness),
          size: size,
          insets: insets,
          brightness: brightness,
        );
        await tapVisible(
          tester,
          find.byKey(const ValueKey(kBuyCratesButtonKey)),
        );
        expect(find.byType(BuyCratesSheet), findsOneWidget);
        await snap(tester, 'buy_crates_sheet_${sizeName}_$theme');
      });

      testWidgets('record damaged crates sheet, $sizeName $theme', (
        tester,
      ) async {
        await pump(
          tester,
          screen: ManufacturerScreen(manufacturer: sample.guinness),
          size: size,
          insets: insets,
          brightness: brightness,
        );
        await tapVisible(
          tester,
          find.byKey(const ValueKey(kManufacturerRecordDamagedButtonKey)),
        );
        expect(find.byType(RecordDamagedCratesSheet), findsOneWidget);
        await tester.enterText(
          find.descendant(
            of: find.byKey(const ValueKey(kRecordDamagedQuantityFieldKey)),
            matching: find.byType(TextField),
          ),
          '2',
        );
        await settle(tester);
        await snap(tester, 'record_damaged_crates_sheet_${sizeName}_$theme');
      });

      testWidgets('count empties sheet, $sizeName $theme', (tester) async {
        await pump(
          tester,
          screen: ManufacturerScreen(manufacturer: sample.guinness),
          size: size,
          insets: insets,
          brightness: brightness,
        );
        await tapVisible(
          tester,
          find.byKey(const ValueKey(kManufacturerCountButtonKey)),
        );
        expect(find.byType(CountManufacturerEmptiesSheet), findsOneWidget);
        await tester.enterText(
          find.descendant(
            of: find.byKey(const ValueKey(kCountEmptiesInputFieldKey)),
            matching: find.byType(TextField),
          ),
          '30',
        );
        await settle(tester);
        await snap(tester, 'count_empties_sheet_${sizeName}_$theme');
      });

      testWidgets('crate value change sheet, $sizeName $theme', (tester) async {
        await pump(
          tester,
          screen: ManufacturerScreen(manufacturer: sample.guinness),
          size: size,
          insets: insets,
          brightness: brightness,
        );
        await tapVisible(tester, find.widgetWithText(Tab, 'Settings'));
        await tester.enterText(
          find.descendant(
            of: find.byKey(
              const ValueKey(kManufacturerSettingsCrateValueFieldKey),
            ),
            matching: find.byType(TextField),
          ),
          '1800',
        );
        FocusManager.instance.primaryFocus?.unfocus();
        await settle(tester);
        await tapVisible(
          tester,
          find.byKey(const ValueKey(kManufacturerSettingsSaveButtonKey)),
        );
        expect(find.byType(CrateValueChangeSheet), findsOneWidget);
        await snap(tester, 'crate_value_change_sheet_${sizeName}_$theme');
      });

      testWidgets('catalogue report sheet, $sizeName $theme', (tester) async {
        await pump(
          tester,
          screen: const Scaffold(
            body: Center(child: CatalogueReportLink(barcode: '6150001234561')),
          ),
          size: size,
          insets: insets,
          brightness: brightness,
        );
        await tapVisible(tester, find.text(CatalogueReportLink.label));
        await settle(tester);
        expect(find.text('Report a problem'), findsOneWidget);
        await snap(tester, 'catalogue_report_sheet_${sizeName}_$theme');
      });

      testWidgets('supplier record crate sheet, $sizeName $theme', (
        tester,
      ) async {
        await pump(
          tester,
          screen: SupplierDetailScreen(
            supplierId: sample.supplierId,
            initialTimeFilter: kSampleLedgerPeriod,
          ),
          size: size,
          insets: insets,
          brightness: brightness,
        );
        await tapVisible(tester, find.widgetWithText(Tab, 'Empty Crates'));
        await tapVisible(tester, find.text('Record crate activity'));
        expect(find.text('Empty Crates'), findsWidgets);
        await snap(tester, 'supplier_record_crate_sheet_${sizeName}_$theme');
      });
    }
  }
}
