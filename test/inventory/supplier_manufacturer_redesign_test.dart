// #392 PR 4: the restyled Supplier Detail, Manufacturer screen and crate
// sheets keep every control, action and permission rule, hold their content at
// every redesign viewport, cap at a fixed 960, pair their header cards side by
// side at 900+ measured, and every sheet or pop-up with a text box fits above
// the keyboard.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/crates/manufacturer_crate_position.dart';
import 'package:reebaplus_pos/core/permissions/gate.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/first_run_surface_state.dart';
import 'package:reebaplus_pos/features/inventory/screens/manufacturer_screen.dart';
import 'package:reebaplus_pos/features/inventory/screens/supplier_detail_screen.dart';
import 'package:reebaplus_pos/features/inventory/widgets/add_manufacturer_sheet.dart';
import 'package:reebaplus_pos/features/inventory/widgets/buy_crates_sheet.dart';
import 'package:reebaplus_pos/features/inventory/widgets/count_manufacturer_empties_sheet.dart';
import 'package:reebaplus_pos/features/inventory/widgets/crate_money_arrangement_section.dart';
import 'package:reebaplus_pos/features/inventory/widgets/inventory_parts.dart';
import 'package:reebaplus_pos/features/inventory/widgets/manufacturer_settings_tab.dart';
import 'package:reebaplus_pos/features/inventory/widgets/record_damaged_crates_sheet.dart';
import 'package:reebaplus_pos/features/inventory/widgets/supplier_parts.dart';
import 'package:reebaplus_pos/features/inventory/widgets/catalogue_report_link.dart';
import 'package:reebaplus_pos/core/providers/business_scoped_stream.dart';
import 'package:reebaplus_pos/core/services/barcode_catalogue_service.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/redesign.dart';

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

  /// Drift's streams resolve in real async time.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 200));
    }
  }

  /// Unmounts and closes the database inside runAsync (Drift's streams block a
  /// plain tearDown close).
  Future<void> finish(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 5));
    await disposeScreen(tester);
    await tester.runAsync(() => env.dispose());
  }

  Future<void> pump(
    WidgetTester tester, {
    required Widget screen,
    Size size = const Size(390, 844),
    FakeViewPadding insets = const FakeViewPadding(top: 24, bottom: 24),
    Set<String> grants = kSupplierManufacturerGrants,
    int roleRank = GateTier.ceo,
    String roleSlug = 'ceo',
    TextScaler? textScaler,
  }) async {
    tester.view.padding = insets;
    tester.view.viewPadding = insets;
    addTearDown(tester.view.resetPadding);
    addTearDown(tester.view.resetViewPadding);
    addTearDown(tester.view.resetViewInsets);
    await pumpScreen(
      tester,
      env: env,
      size: size,
      screen: screen,
      followView: true,
      bottomNavHeight: 0,
      grantedKeys: grants,
      roleRank: roleRank,
      roleSlug: roleSlug,
      textScaler: textScaler,
      overrides: [
        currentBusinessProvider.overrideWith((ref) => sample.business),
        firstRunSurfaceStateProvider.overrideWithValue(
          FirstRunSurfaceState.hasContent,
        ),
        currentBusinessIdProvider.overrideWithValue(env.businessId),
        barcodeCatalogueServiceProvider.overrideWithValue(
          BarcodeCatalogueService.withFetchers(
            fetchRow: (_) async =>
                (name: 'Gulder Lager 60cl', unit: 'Bottle', photoUrl: null),
            fetchPhoto: (_) async => throw UnimplementedError(),
            sendReport: (_) async {},
            timeout: const Duration(milliseconds: 200),
          ),
        ),
      ],
      settle: false,
    );
    await settle(tester);
  }

  Widget supplierScreen() => SupplierDetailScreen(
    supplierId: sample.supplierId,
    initialTimeFilter: kSampleLedgerPeriod,
  );

  Widget manufacturerScreen() =>
      ManufacturerScreen(manufacturer: sample.guinness);

  Future<void> tapCentred(WidgetTester tester, Finder finder) async {
    // Centre it so the pinned tab bar doesn't cover it.
    await Scrollable.ensureVisible(tester.element(finder), alignment: 0.5);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(finder);
    await settle(tester);
  }

  /// Opens a tab. Sideways the header can fill the screen and the pinned tab
  /// bar is not built until the page scrolls, so drag the header away first.
  Future<void> openTab(WidgetTester tester, String label) async {
    final tab = find.widgetWithText(Tab, label);
    if (tab.evaluate().isEmpty) {
      await tester.drag(find.byType(NestedScrollView), const Offset(0, -600));
      await settle(tester);
    }
    await tapCentred(tester, tab);
  }

  /// A Tab's tap target is the InkWell the TabBar wraps it in (it spans the
  /// bar's full height; the label inside sits above the indicator line).
  Finder tabTarget(String label) => find
      .ancestor(
        of: find.widgetWithText(Tab, label),
        matching: find.byType(InkWell),
      )
      .first;

  void expectTarget(WidgetTester tester, Finder f) {
    final size = tester.getSize(f.first);
    expect(size.width, greaterThanOrEqualTo(kMinInteractiveDimension));
    expect(size.height, greaterThanOrEqualTo(kMinInteractiveDimension));
  }

  const sizes = <(String, Size, FakeViewPadding)>[
    ('360x740', Size(360, 740), FakeViewPadding(top: 24, bottom: 24)),
    ('390x844', Size(390, 844), FakeViewPadding(top: 24, bottom: 24)),
    ('844x390', Size(844, 390), FakeViewPadding(top: 24, right: 48)),
    ('800x1280', Size(800, 1280), FakeViewPadding(top: 24, bottom: 24)),
    ('1280x800', Size(1280, 800), FakeViewPadding(top: 24)),
  ];

  group('Supplier Detail renders its controls', () {
    testWidgets('top bar, tabs, balance, totals, rows and the FAB', (
      tester,
    ) async {
      await pump(tester, screen: supplierScreen());
      expect(find.byType(InventoryTopBar), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(InventoryTopBar),
          matching: find.text('Supplier Details'),
        ),
        findsOneWidget,
      );
      expect(find.byTooltip('Back'), findsOneWidget);
      expect(find.byTooltip('Edit supplier'), findsOneWidget);
      expect(find.byTooltip('Delete supplier'), findsOneWidget);
      expect(find.text('Adamu Distribution Ltd'), findsWidgets);
      expect(find.text('Amount owed to supplier'), findsOneWidget);
      expect(find.text('Total In'), findsOneWidget);
      expect(find.text('Total Out'), findsOneWidget);
      expect(find.widgetWithText(Tab, 'Ledger'), findsOneWidget);
      expect(find.widgetWithText(Tab, 'Empty Crates'), findsOneWidget);
      expect(find.text('Record Activity'), findsOneWidget);
      expect(
        find.byWidgetPredicate(
          (w) =>
              w.key is ValueKey<String> &&
              (w.key! as ValueKey<String>).value.startsWith(
                kSupplierLedgerRowKeyPrefix,
              ),
        ),
        findsWidgets,
      );
      expect(tester.takeException(), isNull);
      await finish(tester);
    });

    testWidgets('top-bar actions and the tab stay 48dp targets', (
      tester,
    ) async {
      await pump(tester, screen: supplierScreen());
      expectTarget(tester, find.byTooltip('Back'));
      expectTarget(tester, find.byTooltip('Edit supplier'));
      expectTarget(tester, find.byTooltip('Delete supplier'));
      expectTarget(tester, tabTarget('Empty Crates'));
      await finish(tester);
    });

    testWidgets('edit and delete are CEO-only (a manager does not see them)', (
      tester,
    ) async {
      await pump(
        tester,
        screen: supplierScreen(),
        roleSlug: 'manager',
        roleRank: GateTier.manager,
      );
      expect(find.text('Adamu Distribution Ltd'), findsWidgets);
      expect(find.byTooltip('Edit supplier'), findsNothing);
      expect(find.byTooltip('Delete supplier'), findsNothing);
      await finish(tester);
    });

    testWidgets('without suppliers.manage the screen says so', (tester) async {
      await pump(
        tester,
        screen: supplierScreen(),
        grants: const {'sales.make'},
        roleSlug: 'cashier',
        roleRank: GateTier.cashier,
      );
      expect(
        find.text('You don’t have access to Supplier Accounts.'),
        findsOneWidget,
      );
      expect(find.text('Record Activity'), findsNothing);
      await finish(tester);
    });

    testWidgets('the Crates tab keeps its actions and sections', (
      tester,
    ) async {
      await pump(tester, screen: supplierScreen());
      await openTab(tester, 'Empty Crates');
      expect(find.text('Record crate activity'), findsOneWidget);
      expect(find.text('Net crate balance'), findsOneWidget);
      expect(find.text('Deposit value (refundable)'), findsOneWidget);
      expect(find.text('Crates received'), findsOneWidget);
      expect(find.text('Crates returned'), findsOneWidget);
      expect(find.text('By manufacturer'), findsOneWidget);
      expect(find.byType(SettingsRow), findsWidgets);
      expect(tester.takeException(), isNull);
      await finish(tester);
    });
  });

  group('Supplier Detail holds at every redesign viewport', () {
    for (final (name, size, insets) in sizes) {
      testWidgets('ledger and crates tab, $name @1.15', (tester) async {
        await pump(
          tester,
          screen: supplierScreen(),
          size: size,
          insets: insets,
          textScaler: const TextScaler.linear(1.15),
        );
        expect(tester.takeException(), isNull);
        await openTab(tester, 'Empty Crates');
        expect(tester.takeException(), isNull);
        await finish(tester);
      });
    }

    testWidgets('360dp wide at text scale 1.3', (tester) async {
      await pump(
        tester,
        screen: supplierScreen(),
        size: const Size(360, 740),
        textScaler: const TextScaler.linear(1.3),
      );
      expect(tester.takeException(), isNull);
      await finish(tester);
    });
  });

  group('detail width rule', () {
    testWidgets('1280: content caps at 960 and the header cards sit side by '
        'side', (tester) async {
      await pump(
        tester,
        screen: supplierScreen(),
        size: const Size(1280, 800),
        insets: const FakeViewPadding(top: 24),
      );
      final column = tester.getRect(find.byType(InventoryDetailHeaderCards));
      // The cards sit in the 960 column: 960 wide, centred in the 1280 view.
      expect(column.width, 960);
      expect(column.center.dx, closeTo(640, 1));
      final cards = find.descendant(
        of: find.byType(InventoryDetailHeaderCards),
        matching: find.byType(Container),
      );
      expect(cards, findsWidgets);
      // Profile name and balance label share a row.
      final name = tester.getTopLeft(find.text('Adamu Distribution Ltd').last);
      final owed = tester.getTopLeft(find.text('Amount owed to supplier'));
      expect((name.dy - owed.dy).abs(), lessThan(80));
      expect(owed.dx, greaterThan(name.dx));
      await finish(tester);
    });

    testWidgets('800: the header cards stack', (tester) async {
      await pump(tester, screen: supplierScreen(), size: const Size(800, 1280));
      final name = tester.getTopLeft(find.text('Adamu Distribution Ltd').last);
      final owed = tester.getTopLeft(find.text('Amount owed to supplier'));
      expect(owed.dy, greaterThan(name.dy + 40));
      await finish(tester);
    });

    testWidgets('Manufacturer 1280: capped at 960, figures side by side', (
      tester,
    ) async {
      await pump(
        tester,
        screen: manufacturerScreen(),
        size: const Size(1280, 800),
        insets: const FakeViewPadding(top: 24),
      );
      expect(
        tester.getRect(find.byType(InventoryDetailHeaderCards)).width,
        960,
      );
      final value = tester.getTopLeft(find.text('Crate value'));
      final total = tester.getTopLeft(find.text('Total crates'));
      expect(total.dy, closeTo(value.dy, 2));
      expect(total.dx, greaterThan(value.dx));
      await finish(tester);
    });

    testWidgets('Manufacturer 390: figures stack', (tester) async {
      await pump(tester, screen: manufacturerScreen());
      final value = tester.getTopLeft(find.textContaining('Crate value'));
      final total = tester.getTopLeft(find.textContaining('Total crates'));
      expect(total.dy, greaterThan(value.dy + 20));
      await finish(tester);
    });
  });

  group('Manufacturer screen renders its controls', () {
    testWidgets('top bar, figures, tabs, buttons and status cards', (
      tester,
    ) async {
      await pump(tester, screen: manufacturerScreen());
      expect(find.byType(InventoryTopBar), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(InventoryTopBar),
          matching: find.text('Guinness Nigeria'),
        ),
        findsOneWidget,
      );
      expect(find.byTooltip('Back'), findsOneWidget);
      for (final tab in ['Crates', 'Products', 'History', 'Settings']) {
        expect(find.widgetWithText(Tab, tab), findsOneWidget);
      }
      expect(find.byKey(const ValueKey(kManufacturerCountButtonKey)), findsOne);
      expect(
        find.byKey(const ValueKey(kManufacturerRecordDamagedButtonKey)),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey(kBuyCratesButtonKey)), findsOneWidget);
      expect(
        find.byKey(
          const ValueKey('${kManufacturerStatusKeyPrefix}in_warehouse'),
        ),
        findsOneWidget,
      );
      // The figures keep their numbers: 37 crates at ₦1,500 = ₦55,500.
      expect(
        find.textContaining('₦55,500 total value', findRichText: true),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await finish(tester);
    });

    testWidgets('Products and History tabs list their rows', (tester) async {
      await pump(tester, screen: manufacturerScreen());
      await openTab(tester, 'Products');
      expect(find.text('Guinness Foreign Extra'), findsOneWidget);
      expect(find.text('Crate: ₦1,500'), findsOneWidget);
      await openTab(tester, 'History');
      expect(find.byType(InventoryDetailRowCard), findsWidgets);
      expect(tester.takeException(), isNull);
      await finish(tester);
    });

    testWidgets('a stock keeper sees neither Buy crates nor Settings', (
      tester,
    ) async {
      await pump(
        tester,
        screen: manufacturerScreen(),
        grants: const {'stock.view', 'stock.add'},
        roleSlug: 'stock_keeper',
        roleRank: GateTier.stockKeeper,
      );
      expect(find.byKey(const ValueKey(kBuyCratesButtonKey)), findsNothing);
      expect(find.widgetWithText(Tab, 'Settings'), findsNothing);
      expect(
        find.byKey(
          const ValueKey('${kManufacturerStatusKeyPrefix}in_warehouse'),
        ),
        findsOneWidget,
      );
      await finish(tester);
    });

    testWidgets('tabs and buttons stay 48dp targets', (tester) async {
      await pump(tester, screen: manufacturerScreen());
      expectTarget(tester, find.byTooltip('Back'));
      expectTarget(tester, tabTarget('Settings'));
      expectTarget(
        tester,
        find.byKey(const ValueKey(kManufacturerCountButtonKey)),
      );
      expectTarget(tester, find.byKey(const ValueKey(kBuyCratesButtonKey)));
      await finish(tester);
    });

    for (final (name, size, insets) in sizes) {
      testWidgets('no overflow at $name @1.15, all four tabs', (tester) async {
        await pump(
          tester,
          screen: manufacturerScreen(),
          size: size,
          insets: insets,
          textScaler: const TextScaler.linear(1.15),
        );
        expect(tester.takeException(), isNull);
        for (final tab in ['Products', 'History', 'Settings', 'Crates']) {
          await openTab(tester, tab);
          expect(tester.takeException(), isNull, reason: '$tab at $name');
        }
        await finish(tester);
      });
    }
  });

  // The keyboard rule (owner phone check on #402): a sheet or pop-up with a
  // text box must fit above the keyboard. Two phones, text scale 1.15.
  group('keyboard up', () {
    const phones = <(String, Size, double)>[
      ('390x844', Size(390, 844), 340),
      ('360x640', Size(360, 640), 280),
    ];

    /// Raises the keyboard the way the engine does: the bottom padding it
    /// covers reads as 0 and [height] shows up as a view inset.
    Future<void> raiseKeyboard(WidgetTester tester, double height) async {
      tester.view.viewInsets = FakeViewPadding(bottom: height);
      tester.view.padding = const FakeViewPadding(top: 24);
      tester.view.viewPadding = const FakeViewPadding(top: 24);
      await settle(tester);
    }

    /// The button can be scrolled above the keyboard: the sheet lifts and
    /// scrolls, so nothing is stuck under it.
    Future<void> expectReachable(
      WidgetTester tester,
      Finder target,
      Size size,
      double keyboard,
    ) async {
      await tester.ensureVisible(target);
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        tester.getRect(target).bottom,
        lessThanOrEqualTo(size.height - keyboard + 0.5),
        reason: 'under the keyboard',
      );
      expect(tester.takeException(), isNull);
    }

    for (final (name, size, keyboard) in phones) {
      testWidgets('Buy crates sheet at $name', (tester) async {
        await pump(
          tester,
          screen: manufacturerScreen(),
          size: size,
          textScaler: const TextScaler.linear(1.15),
        );
        await tapCentred(
          tester,
          find.byKey(const ValueKey(kBuyCratesButtonKey)),
        );
        final field = find.descendant(
          of: find.byKey(const ValueKey(kBuyCratesPriceFieldKey)),
          matching: find.byType(TextField),
        );
        await tester.showKeyboard(field);
        await raiseKeyboard(tester, keyboard);
        expect(tester.takeException(), isNull);
        await expectReachable(
          tester,
          find.byKey(const ValueKey(kBuyCratesSaveButtonKey)),
          size,
          keyboard,
        );
        await finish(tester);
      });

      testWidgets('Record damaged sheet at $name', (tester) async {
        await pump(
          tester,
          screen: manufacturerScreen(),
          size: size,
          textScaler: const TextScaler.linear(1.15),
        );
        await tapCentred(
          tester,
          find.byKey(const ValueKey(kManufacturerRecordDamagedButtonKey)),
        );
        final field = find.descendant(
          of: find.byKey(const ValueKey(kRecordDamagedQuantityFieldKey)),
          matching: find.byType(TextField),
        );
        await tester.showKeyboard(field);
        await raiseKeyboard(tester, keyboard);
        expect(tester.takeException(), isNull);
        await expectReachable(
          tester,
          find.byKey(const ValueKey(kRecordDamagedSaveButtonKey)),
          size,
          keyboard,
        );
        await finish(tester);
      });

      testWidgets('Count empties sheet at $name', (tester) async {
        await pump(
          tester,
          screen: manufacturerScreen(),
          size: size,
          textScaler: const TextScaler.linear(1.15),
        );
        await tapCentred(
          tester,
          find.byKey(const ValueKey(kManufacturerCountButtonKey)),
        );
        final field = find.descendant(
          of: find.byKey(const ValueKey(kCountEmptiesInputFieldKey)),
          matching: find.byType(TextField),
        );
        await tester.showKeyboard(field);
        await raiseKeyboard(tester, keyboard);
        expect(tester.takeException(), isNull);
        await expectReachable(
          tester,
          find.byKey(const ValueKey(kCountEmptiesSaveButtonKey)),
          size,
          keyboard,
        );
        await finish(tester);
      });

      testWidgets('Add Manufacturer sheet at $name', (tester) async {
        await pump(
          tester,
          screen: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () => AddManufacturerSheet.show(
                    context,
                    existingNames: const [],
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
          size: size,
          textScaler: const TextScaler.linear(1.15),
        );
        await tester.tap(find.text('open'));
        await settle(tester);
        await tester.showKeyboard(find.byType(TextField).first);
        await raiseKeyboard(tester, keyboard);
        expect(tester.takeException(), isNull);
        await expectReachable(
          tester,
          find
                  .widgetWithText(ElevatedButton, 'Add Manufacturer')
                  .evaluate()
                  .isEmpty
              ? find.text('Add Manufacturer').last
              : find.widgetWithText(ElevatedButton, 'Add Manufacturer'),
          size,
          keyboard,
        );
        await finish(tester);
      });

      testWidgets('Catalogue report sheet at $name', (tester) async {
        await pump(
          tester,
          screen: const Scaffold(
            body: Center(child: CatalogueReportLink(barcode: '6150001234561')),
          ),
          size: size,
          textScaler: const TextScaler.linear(1.15),
        );
        await tester.tap(find.text(CatalogueReportLink.label));
        await settle(tester);
        await tester.showKeyboard(find.byType(TextField).first);
        await raiseKeyboard(tester, keyboard);
        expect(tester.takeException(), isNull);
        await expectReachable(tester, find.text('Send'), size, keyboard);
        await finish(tester);
      });

      testWidgets('Supplier record-crates sheet at $name', (tester) async {
        await pump(
          tester,
          screen: supplierScreen(),
          size: size,
          textScaler: const TextScaler.linear(1.15),
        );
        await openTab(tester, 'Empty Crates');
        await tapCentred(tester, find.text('Record crate activity'));
        await tester.showKeyboard(find.byType(TextField).first);
        await raiseKeyboard(tester, keyboard);
        expect(tester.takeException(), isNull);
        await expectReachable(
          tester,
          find.text('Record Receipt'),
          size,
          keyboard,
        );
        await finish(tester);
      });

      testWidgets('Manufacturer Settings tab fields at $name', (tester) async {
        await pump(
          tester,
          screen: manufacturerScreen(),
          size: size,
          textScaler: const TextScaler.linear(1.15),
        );
        await openTab(tester, 'Settings');
        final field = find.descendant(
          of: find.byKey(
            const ValueKey(kManufacturerSettingsCrateValueFieldKey),
          ),
          matching: find.byType(TextField),
        );
        await tester.showKeyboard(field);
        await raiseKeyboard(tester, keyboard);
        expect(tester.takeException(), isNull);
        await finish(tester);
      });
    }
  });

  group('pop-ups with or without a text box', () {
    testWidgets('Supplier delete and void dialogs scroll', (tester) async {
      await pump(tester, screen: supplierScreen());
      await tester.tap(find.byTooltip('Delete supplier'));
      await settle(tester);
      final dialog = tester.widget<AlertDialog>(find.byType(AlertDialog));
      expect(dialog.scrollable, isTrue);
      expect(find.text('Delete supplier?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await settle(tester);
      expect(find.byType(AlertDialog), findsNothing);
      await finish(tester);
    });

    testWidgets('Crate money arrangement confirm dialog scrolls', (
      tester,
    ) async {
      await pump(tester, screen: manufacturerScreen());
      await openTab(tester, 'Settings');
      await tapCentred(tester, find.byType(CrateMoneyArrangementSection));
      // Tap an option other than the selected one.
      final other = find.textContaining('Pay on each delivery');
      if (other.evaluate().isNotEmpty) {
        await tapCentred(tester, other.first);
        final dialog = tester.widget<AlertDialog>(find.byType(AlertDialog));
        expect(dialog.scrollable, isTrue);
      }
      expect(tester.takeException(), isNull);
      await finish(tester);
    });
  });
}
