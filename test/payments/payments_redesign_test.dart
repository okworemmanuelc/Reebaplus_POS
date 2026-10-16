// #411 (PRD #346 Wave 2 B): the restyled Supplier Accounts screens and sheets.
// Restyle only: these pin that every control, figure, permission rule and
// write still behaves as before, and that nothing overflows at the supported
// sizes (with realistic insets and the keyboard up in every form field).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/permissions/gate.dart';
import 'package:reebaplus_pos/core/settings/settings_screen.dart'
    show kSettingsMaxContentWidth;
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/features/inventory/screens/supplier_detail_screen.dart';
import 'package:reebaplus_pos/features/payments/screens/payments_screen.dart';
import 'package:reebaplus_pos/features/payments/screens/supplier_transactions_screen.dart';
import 'package:reebaplus_pos/features/payments/widgets/payments_parts.dart';
import 'package:reebaplus_pos/features/payments/widgets/record_supplier_activity.dart';
import 'package:reebaplus_pos/features/payments/widgets/supplier_form_sheet.dart';
import 'package:reebaplus_pos/shared/widgets/app_dropdown.dart';
import 'package:reebaplus_pos/shared/widgets/app_input.dart';

import '../helpers/screen_harness.dart';
import '../helpers/supplier_manufacturer_seed.dart';

const _minTap = kMinInteractiveDimension - 0.01;

const _sizes = <(String, Size, FakeViewPadding, double)>[
  ('360x800 @1.3', Size(360, 800), FakeViewPadding(top: 24, bottom: 48), 1.3),
  ('390x844', Size(390, 844), FakeViewPadding(top: 24, bottom: 24), 1.0),
  ('844x390 insets', Size(844, 390), FakeViewPadding(top: 24, right: 48), 1.0),
  ('800x1280', Size(800, 1280), FakeViewPadding(), 1.0),
  ('1280x800', Size(1280, 800), FakeViewPadding(), 1.0),
];

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

  tearDown(() => env.dispose());

  Future<void> deliver(WidgetTester tester, [int rounds = 8]) async {
    for (var i = 0; i < rounds; i++) {
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
    addTearDown(tester.view.resetViewInsets);
  }

  Future<void> pumpScreenAt(
    WidgetTester tester,
    Widget screen, {
    Size size = const Size(390, 844),
    FakeViewPadding insets = const FakeViewPadding(top: 24, bottom: 24),
    double scale = 1.0,
    Set<String> grants = kSupplierManufacturerGrants,
  }) async {
    setInsets(tester, insets);
    await pumpScreen(
      tester,
      env: env,
      size: size,
      screen: screen,
      followView: true,
      bottomNavHeight: size.width >= 600 ? kBottomNavBodyHeight : 0,
      grantedKeys: grants,
      roleRank: GateTier.ceo,
      textScaler: TextScaler.linear(scale),
      theme: AppTheme.light(),
      settle: false,
    );
    await deliver(tester);
  }

  group('Supplier Accounts list', () {
    testWidgets('renders its controls, the supplier balance and the FAB', (
      tester,
    ) async {
      await pumpScreenAt(tester, const PaymentsScreen());
      expect(find.byKey(PaymentsKeys.topBar), findsOneWidget);
      expect(find.text('Supplier Accounts'), findsOneWidget);
      expect(find.text('Transaction history'), findsOneWidget);
      expect(find.textContaining('Balances for:'), findsOneWidget);
      expect(find.text('Adamu Distribution Ltd'), findsOneWidget);
      // Wallet sign mapping, unchanged: 25m+18m+9m invoiced, 10m+15m paid.
      expect(find.textContaining('Owed '), findsOneWidget);
      expect(find.text('Add Supplier'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await disposeScreen(tester);
    });

    testWidgets('the history link, a supplier row and the FAB still open '
        'their destinations', (tester) async {
      await pumpScreenAt(tester, const PaymentsScreen());
      await tester.tap(find.byKey(PaymentsKeys.historyLink));
      await tester.pumpAndSettle();
      expect(find.byType(SupplierTransactionsScreen), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(PaymentsKeys.supplierRow(sample.supplierId)));
      await tester.pumpAndSettle();
      expect(find.byType(SupplierDetailScreen), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();

      await tester.tap(find.text('Add Supplier'));
      await tester.pumpAndSettle();
      expect(find.byType(SupplierFormSheet), findsOneWidget);
      expect(tester.takeException(), isNull);
      await disposeScreen(tester);
    });

    testWidgets('without suppliers.manage the list and the FAB stay hidden', (
      tester,
    ) async {
      await pumpScreenAt(
        tester,
        const PaymentsScreen(),
        grants: const {'sales.make'},
      );
      expect(
        find.text('You don’t have access to Supplier Accounts.'),
        findsOneWidget,
      );
      expect(find.text('Add Supplier'), findsNothing);
      expect(find.text('Adamu Distribution Ltd'), findsNothing);
      await disposeScreen(tester);
    });

    testWidgets('no suppliers: the empty message', (tester) async {
      await env.db.customStatement('UPDATE suppliers SET is_deleted = 1');
      await pumpScreenAt(tester, const PaymentsScreen());
      expect(find.text('No suppliers added yet'), findsOneWidget);
      await disposeScreen(tester);
    });

    for (final (name, size, insets, scale) in _sizes) {
      testWidgets('fits at $name and caps at 720', (tester) async {
        await pumpScreenAt(
          tester,
          const PaymentsScreen(),
          size: size,
          insets: insets,
          scale: scale,
        );
        expect(tester.takeException(), isNull);
        final link = tester.getRect(find.byKey(PaymentsKeys.historyLink));
        expect(link.width, lessThanOrEqualTo(kSettingsMaxContentWidth + 0.5));
        expect(link.height, greaterThanOrEqualTo(_minTap));
        final row = tester.getRect(
          find.byKey(PaymentsKeys.supplierRow(sample.supplierId)),
        );
        expect(row.width, lessThanOrEqualTo(kSettingsMaxContentWidth + 0.5));
        expect(row.height, greaterThanOrEqualTo(_minTap));
        await disposeScreen(tester);
      });
    }
  });

  group('Transaction History', () {
    Future<void> chooseToDate(WidgetTester tester) async {
      await tester.tap(find.byType(AppDropdown<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('To Date').last);
      await tester.pumpAndSettle();
      await deliver(tester);
    }

    testWidgets('renders the totals, the dropdown and the ledger rows', (
      tester,
    ) async {
      await pumpScreenAt(tester, const SupplierTransactionsScreen());
      expect(find.byKey(PaymentsKeys.transactionsTopBar), findsOneWidget);
      expect(find.text('Transaction History'), findsOneWidget);
      expect(find.text('Total In'), findsOneWidget);
      expect(find.text('Total Out'), findsOneWidget);
      // This Month holds none of the pinned March 2025 rows.
      expect(find.text('No transactions in this period'), findsOneWidget);
      await chooseToDate(tester);
      expect(find.textContaining('5 transactions'), findsOneWidget);
      expect(find.text('Adamu Distribution Ltd'), findsNWidgets(5));
      expect(find.textContaining('+'), findsWidgets);
      expect(find.textContaining('100,000'), findsWidgets);
      expect(find.textContaining('-'), findsWidgets);
      expect(find.textContaining('250,000'), findsWidgets);
      expect(tester.takeException(), isNull);
      await disposeScreen(tester);
    });

    testWidgets('the back arrow pops', (tester) async {
      await pumpScreenAt(tester, const PaymentsScreen());
      await tester.tap(find.byKey(PaymentsKeys.historyLink));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(PaymentsKeys.transactionsBack));
      await tester.pumpAndSettle();
      expect(find.byType(SupplierTransactionsScreen), findsNothing);
      await disposeScreen(tester);
    });

    testWidgets('without suppliers.manage it shows the no-access body', (
      tester,
    ) async {
      await pumpScreenAt(
        tester,
        const SupplierTransactionsScreen(),
        grants: const {'sales.make'},
      );
      expect(
        find.text('You don’t have access to Supplier Accounts.'),
        findsOneWidget,
      );
      expect(find.byKey(PaymentsKeys.totalIn), findsNothing);
      await disposeScreen(tester);
    });

    for (final (name, size, insets, scale) in _sizes) {
      testWidgets('fits at $name', (tester) async {
        await pumpScreenAt(
          tester,
          const SupplierTransactionsScreen(),
          size: size,
          insets: insets,
          scale: scale,
        );
        await chooseToDate(tester);
        expect(tester.takeException(), isNull);
        final card = tester.getRect(find.byKey(PaymentsKeys.totalIn));
        expect(card.height, greaterThanOrEqualTo(_minTap));
        final row = tester.getRect(find.byType(Material).last);
        expect(row.width, lessThanOrEqualTo(size.width + 0.5));
        await disposeScreen(tester);
      });
    }
  });

  group('Sheets', () {
    Future<void> openSheet(
      WidgetTester tester,
      void Function(BuildContext context) open, {
      Size size = const Size(390, 844),
      FakeViewPadding insets = const FakeViewPadding(top: 24, bottom: 24),
      double scale = 1.0,
    }) async {
      await pumpScreenAt(
        tester,
        _Host(open),
        size: size,
        insets: insets,
        scale: scale,
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await deliver(tester, 3);
    }

    final sheets =
        <
          (String, Key, void Function(BuildContext c, String id), List<String>)
        >[
          (
            'supplier form',
            PaymentsKeys.formSheet,
            (c, id) => SupplierFormSheet.show(c),
            ['Supplier Name', 'Notes (optional)'],
          ),
          (
            'record invoice',
            PaymentsKeys.invoiceSheet,
            (c, id) => RecordInvoiceSheet.show(
              c,
              supplierId: id,
              supplierName: 'Adamu Distribution Ltd',
            ),
            ['Invoice Amount', 'Note (Optional)'],
          ),
          (
            'record payment',
            PaymentsKeys.paymentSheet,
            (c, id) => RecordPaymentSheet.show(
              c,
              supplierId: id,
              supplierName: 'Adamu Distribution Ltd',
            ),
            ['Amount', 'Reference / Note'],
          ),
        ];

    testWidgets('the Record Activity chooser opens both sheets', (
      tester,
    ) async {
      await openSheet(
        tester,
        (c) => showSupplierActivityChooser(
          c,
          supplierId: sample.supplierId,
          supplierName: 'Adamu Distribution Ltd',
        ),
      );
      expect(find.byKey(PaymentsKeys.chooserSheet), findsOneWidget);
      expect(find.text('Record Activity'), findsOneWidget);
      expect(find.text('Invoice Total'), findsOneWidget);
      expect(find.text('Record Payment'), findsOneWidget);
      final tile = tester.getRect(find.byKey(PaymentsKeys.chooserInvoice));
      expect(tile.height, greaterThanOrEqualTo(_minTap));
      await tester.tap(find.byKey(PaymentsKeys.chooserInvoice));
      await tester.pumpAndSettle();
      expect(find.byKey(PaymentsKeys.invoiceSheet), findsOneWidget);
      expect(tester.takeException(), isNull);
      await disposeScreen(tester);
    });

    testWidgets('Record Invoice still asks for confirmation before writing', (
      tester,
    ) async {
      await openSheet(
        tester,
        (c) => RecordInvoiceSheet.show(
          c,
          supplierId: sample.supplierId,
          supplierName: 'Adamu Distribution Ltd',
        ),
      );
      await tester.enterText(
        find.descendant(
          of: find.widgetWithText(AppInput, 'Invoice Amount'),
          matching: find.byType(EditableText),
        ),
        '5000',
      );
      await tester.tap(find.text('Record Invoice'));
      await tester.pumpAndSettle();
      expect(find.text('Confirm Invoice Total'), findsOneWidget);
      expect(
        find.text('This entry is permanent. It can only be reversed by a CEO void.'),
        findsOneWidget,
      );
      await disposeScreen(tester);
    });

    testWidgets('Record Payment without proof is refused', (tester) async {
      await openSheet(
        tester,
        (c) => RecordPaymentSheet.show(
          c,
          supplierId: sample.supplierId,
          supplierName: 'Adamu Distribution Ltd',
        ),
      );
      expect(find.text('Attach receipt (photo or file)'), findsOneWidget);
      expect(find.text('Payment Method'), findsOneWidget);
      await tester.enterText(
        find.descendant(
          of: find.widgetWithText(AppInput, 'Amount'),
          matching: find.byType(EditableText),
        ),
        '5000',
      );
      await tester.tap(find.text('Record Payment').last);
      await tester.pumpAndSettle();
      expect(
        find.text('Attach a receipt or enter a reference / explanation'),
        findsOneWidget,
      );
      await disposeScreen(tester);
    });

    for (final (sheetName, key, open, fields) in sheets) {
      for (final (name, size, insets, scale) in [
        ..._sizes.sublist(0, 3),
        (
          '360x640 @1.15',
          const Size(360, 640),
          const FakeViewPadding(top: 24, bottom: 24),
          1.15,
        ),
      ]) {
        testWidgets('$sheetName sheet, $name: no overflow, each field '
            'reachable above the keyboard', (tester) async {
          await openSheet(
            tester,
            (c) => open(c, sample.supplierId),
            size: size,
            insets: insets,
            scale: scale,
          );
          expect(find.byKey(key), findsOneWidget);
          expect(tester.takeException(), isNull, reason: 'sheet overflowed');
          final keyboard = size.height > size.width ? 300.0 : 150.0;
          final keyboardTop = size.height - keyboard;
          for (final label in fields) {
            final field = find.descendant(
              of: find.widgetWithText(AppInput, label),
              matching: find.byType(EditableText),
            );
            await tester.scrollUntilVisible(
              field,
              60,
              scrollable: find
                  .descendant(
                    of: find.byKey(key),
                    matching: find.byType(Scrollable),
                  )
                  .first,
            );
            await tester.pumpAndSettle();
            await tester.tap(field);
            await tester.pump();
            tester.view.viewInsets = FakeViewPadding(bottom: keyboard);
            tester.view.padding = FakeViewPadding(
              top: insets.top,
              right: insets.right,
            );
            await tester.pumpAndSettle();
            expect(
              tester.takeException(),
              isNull,
              reason: '$label: keyboard overflowed',
            );
            await tester.ensureVisible(field);
            await tester.pumpAndSettle();
            expect(
              tester.getRect(field).bottom,
              lessThanOrEqualTo(keyboardTop + 0.5),
              reason: '$label hidden by the keyboard',
            );
            tester.view.resetViewInsets();
            setInsets(tester, insets);
            await tester.pumpAndSettle();
          }
          await disposeScreen(tester);
        });
      }
    }
  });
}

/// A tab-like host: Scaffold → nested Navigator → an "open" button, so a sheet
/// opens as in the app.
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
