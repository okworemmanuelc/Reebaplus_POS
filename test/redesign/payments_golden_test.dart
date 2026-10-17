// Visual goldens for the Supplier Accounts screens and sheets (#411, PRD #346
// Wave 2 B). No mockup: built from the shared parts and the Wave 1 / batch A
// patterns (CEO Settings' top bar and 720dp cap, the Customers sheets).
//
// - `payments_*` / `supplier_transactions_*`: 390x844 (gesture nav), 844x390
//   with a 24dp status bar and 3-button navigation on the right, 800x1280 and
//   1280x800 (the harness leaves the rail's width blank at 600dp+), light +
//   dark. Transaction History opens on "To Date" so the pinned March 2025
//   ledger rows show whenever the suite runs.
// - sheets (`supplier_form_sheet_*`, `record_invoice_sheet_*`,
//   `record_payment_sheet_*`, `record_activity_chooser_*`): 390x844 and
//   844x390 with insets, opened on a tab-like nested navigator.
//
// Sample data only: business "Stallion Global", store "Abuja HQ". Regenerate:
//
//     flutter test --update-goldens test/redesign/payments_golden_test.dart

import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/permissions/gate.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/features/payments/screens/payments_screen.dart';
import 'package:reebaplus_pos/features/payments/screens/supplier_transactions_screen.dart';
import 'package:reebaplus_pos/features/payments/widgets/record_supplier_activity.dart';
import 'package:reebaplus_pos/features/payments/widgets/supplier_form_sheet.dart';
import 'package:reebaplus_pos/shared/widgets/app_dropdown.dart';

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
    for (var i = 0; i < 8; i++) {
      await env.db.notificationsDao.create('info', 'Notification $i');
    }
    // A second supplier with nothing on the books: the list shows "Settled".
    await env.db.catalogDao.insertSupplier(
      SuppliersCompanion.insert(
        businessId: env.businessId,
        name: 'Bola Beverages',
        phone: const Value('0802 555 0188'),
      ),
    );
  });

  tearDown(() => env.dispose());

  setUpAll(() => WidgetsApp.debugAllowBannerOverride = false);
  tearDownAll(() => WidgetsApp.debugAllowBannerOverride = true);

  Future<void> deliver(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 250));
    }
  }

  void setInsets(WidgetTester tester, FakeViewPadding insets) {
    tester.view.padding = insets;
    tester.view.viewPadding = insets;
    addTearDown(tester.view.resetPadding);
    addTearDown(tester.view.resetViewPadding);
  }

  Future<void> pump(
    WidgetTester tester,
    Widget screen,
    Size size,
    FakeViewPadding insets,
    ThemeData theme,
  ) async {
    setInsets(tester, insets);
    await pumpScreen(
      tester,
      env: env,
      size: size,
      screen: screen,
      followView: true,
      bottomNavHeight: size.width >= 600 ? kBottomNavBodyHeight : 0,
      grantedKeys: kSupplierManufacturerGrants,
      roleRank: GateTier.ceo,
      selectableStores: [env.store.copyWith(name: 'Abuja HQ')],
      theme: theme,
      settle: false,
    );
    await deliver(tester);
  }

  for (final brightness in Brightness.values) {
    final themeName = brightness == Brightness.light ? 'light' : 'dark';
    final theme = brightness == Brightness.light
        ? AppTheme.light()
        : AppTheme.dark();

    for (final (sizeName, size, insets) in const [
      ('390x844', Size(390, 844), FakeViewPadding(top: 24, bottom: 24)),
      ('844x390_insets', Size(844, 390), FakeViewPadding(top: 24, right: 48)),
      ('800x1280', Size(800, 1280), FakeViewPadding()),
      ('1280x800', Size(1280, 800), FakeViewPadding()),
    ]) {
      testWidgets('payments list $sizeName $themeName', (tester) async {
        await pump(tester, const PaymentsScreen(), size, insets, theme);
        expect(tester.takeException(), isNull);
        await expectLater(
          find.byType(PaymentsScreen),
          matchesGoldenFile('goldens/payments_${sizeName}_$themeName.png'),
        );
        await disposeScreen(tester);
      });

      testWidgets('supplier transactions $sizeName $themeName', (tester) async {
        await pump(
          tester,
          const SupplierTransactionsScreen(),
          size,
          insets,
          theme,
        );
        // The menu does not fit sideways, so pick the period directly.
        tester
            .widget<AppDropdown<String>>(find.byType(AppDropdown<String>))
            .onChanged('To Date');
        await tester.pumpAndSettle();
        await deliver(tester);
        expect(tester.takeException(), isNull);
        await expectLater(
          find.byType(SupplierTransactionsScreen),
          matchesGoldenFile(
            'goldens/supplier_transactions_${sizeName}_$themeName.png',
          ),
        );
        await disposeScreen(tester);
      });
    }

    for (final (sizeName, size, insets) in const [
      ('390x844', Size(390, 844), FakeViewPadding(top: 24, bottom: 24)),
      ('844x390', Size(844, 390), FakeViewPadding(top: 24, right: 48)),
    ]) {
      final sheets = <(String, void Function(BuildContext))>[
        ('supplier_form_sheet', (c) => SupplierFormSheet.show(c)),
        (
          'record_invoice_sheet',
          (c) => RecordInvoiceSheet.show(
            c,
            supplierId: sample.supplierId,
            supplierName: 'Adamu Distribution Ltd',
            initialDate: DateTime(2026, 3, 14),
          ),
        ),
        (
          'record_payment_sheet',
          (c) => RecordPaymentSheet.show(
            c,
            supplierId: sample.supplierId,
            supplierName: 'Adamu Distribution Ltd',
            initialDate: DateTime(2026, 3, 14),
          ),
        ),
        (
          'record_activity_chooser',
          (c) => showSupplierActivityChooser(
            c,
            supplierId: sample.supplierId,
            supplierName: 'Adamu Distribution Ltd',
          ),
        ),
      ];
      for (final (name, open) in sheets) {
        testWidgets('$name $sizeName $themeName', (tester) async {
          await pump(tester, _Host(open), size, insets, theme);
          await tester.tap(find.text('open'));
          await tester.pumpAndSettle();
          await deliver(tester);
          expect(tester.takeException(), isNull);
          await expectLater(
            find.byType(Navigator).first,
            matchesGoldenFile('goldens/${name}_${sizeName}_$themeName.png'),
          );
          await disposeScreen(tester);
        });
      }
    }
  }
}

/// A tab-like host: Scaffold → nested Navigator → an "open" button.
class _Host extends StatelessWidget {
  const _Host(this.open);

  final void Function(BuildContext context) open;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Navigator(
        onGenerateRoute: (_) => MaterialPageRoute<void>(
          builder: (context) => Scaffold(
            backgroundColor: Colors.transparent,
            body: Center(
              child: TextButton(
                onPressed: () => open(context),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
