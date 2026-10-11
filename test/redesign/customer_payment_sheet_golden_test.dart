// Visual goldens for the shared customer payment sheet (#362 PR 3):
//
// - `customer_payment_sheet_picker_*`: opened with no customer (Home's
//   Record Payment, #362 PR 4) — the searchable picker of registered
//   customers (no walk-in).
// - `customer_payment_sheet_picked_owes_*`: a customer who owes, picked in
//   the sheet — "Change", the "Owes ₦X" line, "Pay full ₦X", the empty
//   amount, Cash / Bank Transfer, the note and "Add Credit".
//
// 390x844 (gesture nav, bottom 24) and 844x390 (status bar 24, 3-button nav
// on the right 48), light + dark. The sheet opens on a tab-like nested
// navigator, as in the app. Regenerate with:
//
//     flutter test --update-goldens test/redesign/customer_payment_sheet_golden_test.dart

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/core/permissions/gate.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/features/customers/widgets/customer_payment_sheet.dart';

import '../helpers/screen_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ScreenTestEnvironment env;
  late String owes;

  Future<String> seed(String name, String phone, int balanceKobo) async {
    final db = env.db;
    final id = UuidV7.generate();
    await db
        .into(db.customers)
        .insert(
          CustomersCompanion.insert(
            id: Value(id),
            businessId: env.businessId,
            name: name,
            phone: Value(phone),
          ),
        );
    final walletId = UuidV7.generate();
    await db
        .into(db.customerWallets)
        .insert(
          CustomerWalletsCompanion.insert(
            id: Value(walletId),
            businessId: env.businessId,
            customerId: id,
          ),
        );
    if (balanceKobo != 0) {
      await db
          .into(db.walletTransactions)
          .insert(
            WalletTransactionsCompanion.insert(
              id: Value(UuidV7.generate()),
              businessId: env.businessId,
              walletId: walletId,
              customerId: id,
              type: balanceKobo < 0 ? 'debit' : 'credit',
              amountKobo: balanceKobo.abs(),
              signedAmountKobo: balanceKobo,
              referenceType: balanceKobo < 0 ? 'order_payment' : 'topup_cash',
            ),
          );
    }
    return id;
  }

  setUp(() async {
    env = await setupScreenTestEnvironment(
      productCount: 0,
      businessName: 'Stallion Global',
    );
    await env.db.customStatement(
      "UPDATE stores SET name = 'Abuja HQ' WHERE id = '${env.storeId}'",
    );
    owes = await seed('Adaeze Okafor', '0803 111 2222', -1250000);
    await seed('Bola Adewale', '0805 555 4444', 300000);
    await seed('Chinedu Eze Okonkwo-Bassey Wholesale Ltd', '0701 234 0000', 0);
    await seed('Funmi Lawal', '0809 876 5432', -450000);
  });

  tearDown(() => env.dispose());

  setUpAll(() => WidgetsApp.debugAllowBannerOverride = false);
  tearDownAll(() => WidgetsApp.debugAllowBannerOverride = true);

  Future<void> deliver(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 250));
    }
  }

  for (final brightness in Brightness.values) {
    final themeName = brightness == Brightness.light ? 'light' : 'dark';
    for (final (size, insets) in const [
      (Size(390, 844), FakeViewPadding(top: 24, bottom: 24)),
      (Size(844, 390), FakeViewPadding(top: 24, right: 48)),
    ]) {
      final sizeName = '${size.width.toInt()}x${size.height.toInt()}';

      Future<void> open(WidgetTester tester) async {
        tester.view.padding = insets;
        tester.view.viewPadding = insets;
        addTearDown(tester.view.resetPadding);
        addTearDown(tester.view.resetViewPadding);
        await pumpScreen(
          tester,
          env: env,
          size: size,
          screen: const _Host(),
          bottomNavHeight: 0,
          followView: true,
          grantedKeys: const {'customers.wallet.update'},
          roleRank: GateTier.ceo,
          theme: brightness == Brightness.light
              ? AppTheme.light()
              : AppTheme.dark(),
          settle: false,
        );
        await deliver(tester);
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
        await deliver(tester);
      }

      testWidgets('customer payment sheet, picker, $sizeName $themeName', (
        tester,
      ) async {
        await open(tester);
        expect(tester.takeException(), isNull);
        await expectLater(
          find.byType(Navigator).first,
          matchesGoldenFile(
            'goldens/customer_payment_sheet_picker_${sizeName}_$themeName.png',
          ),
        );
        await disposeScreen(tester);
      });

      testWidgets('customer payment sheet, picked owes, $sizeName $themeName', (
        tester,
      ) async {
        await open(tester);
        await tester.tap(find.byKey(CustomerPaymentSheetKeys.pickerRow(owes)));
        await deliver(tester);
        expect(tester.takeException(), isNull);
        await expectLater(
          find.byType(Navigator).first,
          matchesGoldenFile(
            'goldens/customer_payment_sheet_picked_owes_${sizeName}_$themeName.png',
          ),
        );
        await disposeScreen(tester);
      });
    }
  }
}

/// A tab-like host: Scaffold → nested Navigator → an "open" button.
class _Host extends StatelessWidget {
  const _Host();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Navigator(
        onGenerateRoute: (_) => MaterialPageRoute<void>(
          builder: (context) => Scaffold(
            backgroundColor: Colors.transparent,
            body: Center(
              child: TextButton(
                onPressed: () => CustomerPaymentSheet.show(context),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
