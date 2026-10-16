// Visual goldens for the Customers list and the Add / Edit Customer sheets
// (#395, PRD #346 Wave 2 A). No mockup: built from the shared parts and the
// Wave 1 patterns (CEO Settings' top bar and 720dp cap, the customer payment
// sheet's header).
//
// - `customers_*`: the list at 390x844 (gesture nav), 844x390 with a 24dp
//   status bar and 3-button navigation on the right, 800x1280 and 1280x800
//   (the harness leaves the rail's width blank at 600dp+), light + dark.
// - `add_customer_sheet_*` / `edit_customer_sheet_*`: 390x844 and 844x390
//   with insets, opened on a tab-like nested navigator.
//
// Sample data only: business "Stallion Global", store "Abuja HQ", made-up
// customers. Regenerate with:
//
//     flutter test --update-goldens test/redesign/customers_golden_test.dart

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/core/permissions/gate.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/features/customers/data/models/customer.dart';
import 'package:reebaplus_pos/features/customers/screens/customers_screen.dart';
import 'package:reebaplus_pos/features/customers/widgets/add_customer_sheet.dart';
import 'package:reebaplus_pos/features/customers/widgets/edit_customer_sheet.dart';

import '../helpers/screen_harness.dart';

const _grants = {'customers.add', 'customers.update', 'sales.make'};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ScreenTestEnvironment env;
  late String adaeze;

  Future<String> seed(
    String name, {
    String? address,
    String tier = 'retailer',
    int balanceKobo = 0,
  }) async {
    final db = env.db;
    final id = UuidV7.generate();
    await db
        .into(db.customers)
        .insert(
          CustomersCompanion.insert(
            id: Value(id),
            businessId: env.businessId,
            name: name,
            address: Value(address),
            priceTier: Value(tier),
            storeId: Value(env.storeId),
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
    for (var i = 0; i < 8; i++) {
      await env.db.notificationsDao.create('info', 'Notification $i');
    }
    adaeze = await seed(
      'Adaeze Okafor',
      address: '12 Allen Avenue, Ikeja',
      balanceKobo: -1250000,
    );
    await seed(
      'Bola Adewale',
      address: '3 Wuse Market Road, Abuja',
      tier: 'wholesaler',
      balanceKobo: 300000,
    );
    await seed(
      'Chinedu Eze Okonkwo-Bassey Wholesale Ltd',
      address: '45 Herbert Macaulay Way, Yaba',
      tier: 'wholesaler',
    );
    await seed('Funmi Lawal', balanceKobo: -450000);
    await seed('Musa Ibrahim', address: 'Garki Area 11, Abuja');
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
      testWidgets('customers list $sizeName $themeName', (tester) async {
        setInsets(tester, insets);
        await pumpScreen(
          tester,
          env: env,
          size: size,
          padding: EdgeInsets.fromLTRB(
            insets.left,
            insets.top,
            insets.right,
            insets.bottom,
          ),
          screen: const CustomersScreen(),
          bottomNavHeight: size.width >= 600 ? kBottomNavBodyHeight : 0,
          grantedKeys: _grants,
          roleRank: GateTier.ceo,
          theme: theme,
          overrides: [
            currentBusinessNameProvider.overrideWithValue('Stallion Global'),
          ],
          settle: false,
        );
        await deliver(tester);
        expect(tester.takeException(), isNull);
        await expectLater(
          find.byType(CustomersScreen),
          matchesGoldenFile('goldens/customers_${sizeName}_$themeName.png'),
        );
        await disposeScreen(tester);
      });
    }

    for (final (sizeName, size, insets) in const [
      ('390x844', Size(390, 844), FakeViewPadding(top: 24, bottom: 24)),
      ('844x390', Size(844, 390), FakeViewPadding(top: 24, right: 48)),
    ]) {
      for (final edit in [false, true]) {
        final name = edit ? 'edit_customer_sheet' : 'add_customer_sheet';
        testWidgets('$name $sizeName $themeName', (tester) async {
          setInsets(tester, insets);
          await pumpScreen(
            tester,
            env: env,
            size: size,
            screen: _Host(
              (context) => edit
                  ? EditCustomerSheet.show(
                      context,
                      customerId: adaeze,
                      initialName: 'Adaeze Okafor',
                      initialPhone: '08031112222',
                      initialAddress: '12 Allen Avenue, Ikeja',
                      initialLocation: '',
                      initialPriceTier: PriceTier.retailer,
                      initialStoreId: env.storeId,
                    )
                  : AddCustomerSheet.show(context),
            ),
            bottomNavHeight: 0,
            followView: true,
            grantedKeys: _grants,
            roleRank: GateTier.ceo,
            theme: theme,
            settle: false,
          );
          await deliver(tester);
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
