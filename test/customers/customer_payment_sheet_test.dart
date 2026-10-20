// #362 PR 3 (PRD #270 "Payment forms"): the shared customer payment sheet,
// opened with no customer from a tiny host screen (Home's Record Payment tile
// lands in #362 PR 4), plus the customer page opening it pre-picked.
//
// The host models the app frame: a Scaffold whose body holds a nested
// Navigator, like a MainLayout tab, so the sheet opens on that navigator and
// the Scaffold's resize owns the keyboard.

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/core/permissions/gate.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/features/customers/data/models/customer.dart';
import 'package:reebaplus_pos/features/customers/screens/customer_detail_screen.dart';
import 'package:reebaplus_pos/features/customers/widgets/customer_payment_sheet.dart';

import '../helpers/screen_harness.dart';
import '../helpers/viewports.dart';

/// 48dp, less floating-point dust from the text-scale arithmetic.
const _minTap = kMinInteractiveDimension - 0.01;

const _grants = {'customers.wallet.update', 'sales.make'};

/// Seeds a customer with a credits balance of [balanceKobo] (negative = owes).
Future<String> seedCustomer(
  ScreenTestEnvironment env, {
  required String name,
  String? phone,
  int balanceKobo = 0,
  bool isDeleted = false,
  String? id,
}) async {
  final db = env.db;
  final cId = id ?? UuidV7.generate();
  await db
      .into(db.customers)
      .insert(
        CustomersCompanion.insert(
          id: Value(cId),
          businessId: env.businessId,
          name: name,
          phone: Value(phone),
          isDeleted: Value(isDeleted),
        ),
      );
  final walletId = UuidV7.generate();
  await db
      .into(db.customerWallets)
      .insert(
        CustomerWalletsCompanion.insert(
          id: Value(walletId),
          businessId: env.businessId,
          customerId: cId,
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
            customerId: cId,
            type: balanceKobo < 0 ? 'debit' : 'credit',
            amountKobo: balanceKobo.abs(),
            signedAmountKobo: balanceKobo,
            referenceType: balanceKobo < 0 ? 'order_payment' : 'topup_cash',
          ),
        );
  }
  return cId;
}

/// A tab-like host: Scaffold → nested Navigator → an "open" button.
class PaymentSheetHost extends StatelessWidget {
  const PaymentSheetHost({super.key, this.customer});

  final Customer? customer;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Navigator(
        onGenerateRoute: (_) => MaterialPageRoute<void>(
          builder: (context) => Scaffold(
            backgroundColor: Colors.transparent,
            body: Center(
              child: TextButton(
                onPressed: () =>
                    CustomerPaymentSheet.show(context, customer: customer),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

Future<void> deliver(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 250));
  }
}

Future<void> openHost(
  WidgetTester tester,
  ScreenTestEnvironment env, {
  Size size = const Size(390, 844),
  Set<String> grantedKeys = _grants,
  Customer? customer,
  TextScaler? textScaler,
  ThemeData? theme,
}) async {
  await pumpScreen(
    tester,
    env: env,
    size: size,
    screen: PaymentSheetHost(customer: customer),
    bottomNavHeight: 0,
    followView: true,
    grantedKeys: grantedKeys,
    roleRank: GateTier.ceo,
    textScaler: textScaler,
    theme: theme,
    settle: false,
  );
  await deliver(tester);
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  await deliver(tester);
}

Future<void> pickCustomer(WidgetTester tester, String id) async {
  final row = find.byKey(CustomerPaymentSheetKeys.pickerRow(id));
  await tester.ensureVisible(row);
  await tester.pumpAndSettle();
  await tester.tap(row);
  await deliver(tester);
}

String balanceText(WidgetTester tester) =>
    tester.widget<Text>(find.byKey(CustomerPaymentSheetKeys.balance)).data!;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ScreenTestEnvironment env;
  late String owes; // Adaeze Okafor, owes ₦12,500
  late String credit; // Bola Adewale, holds ₦3,000
  late String even; // Chinedu Eze, nothing owed
  late String deleted;

  setUp(() async {
    env = await setupScreenTestEnvironment(
      productCount: 0,
      businessName: 'Stallion Global',
    );
    owes = await seedCustomer(
      env,
      name: 'Adaeze Okafor',
      phone: '0803 111 2222',
      balanceKobo: -1250000,
    );
    credit = await seedCustomer(
      env,
      name: 'Bola Adewale',
      phone: '08055554444',
      balanceKobo: 300000,
    );
    even = await seedCustomer(env, name: 'Chinedu Eze', phone: '07012340000');
    deleted = await seedCustomer(
      env,
      name: 'Dele Removed',
      phone: '08099990000',
      isDeleted: true,
    );
    // The harness's signed-in user, as a real row: a payment records who
    // took it (FK to users).
    await env.db
        .into(env.db.users)
        .insert(
          UsersCompanion.insert(
            id: const Value('test-user-id'),
            businessId: env.businessId,
            name: 'Test Admin',
            pin: '1234',
          ),
        );
    // A persisted walk-in row must never be offered.
    await seedCustomer(env, name: 'Walk-in Customer', id: Customer.walkInId);
  });

  tearDown(() => env.dispose());

  group('picker (opened with no customer)', () {
    testWidgets('lists registered customers only, no walk-in, no deleted', (
      tester,
    ) async {
      await openHost(tester, env);
      expect(find.byKey(CustomerPaymentSheetKeys.search), findsOneWidget);
      for (final id in [owes, credit, even]) {
        expect(
          find.byKey(CustomerPaymentSheetKeys.pickerRow(id)),
          findsOneWidget,
        );
      }
      expect(
        find.byKey(CustomerPaymentSheetKeys.pickerRow(deleted)),
        findsNothing,
      );
      expect(
        find.byKey(CustomerPaymentSheetKeys.pickerRow(Customer.walkInId)),
        findsNothing,
      );
      expect(find.text('Walk-in Customer'), findsNothing);
      // No form until a customer is chosen.
      expect(find.byKey(CustomerPaymentSheetKeys.amount), findsNothing);
      await disposeScreen(tester);
    });

    testWidgets('searches by name and by phone', (tester) async {
      await openHost(tester, env);
      final search = find.descendant(
        of: find.byKey(CustomerPaymentSheetKeys.search),
        matching: find.byType(EditableText),
      );

      await tester.enterText(search, 'bola');
      await tester.pump();
      expect(
        find.byKey(CustomerPaymentSheetKeys.pickerRow(credit)),
        findsOneWidget,
      );
      expect(
        find.byKey(CustomerPaymentSheetKeys.pickerRow(owes)),
        findsNothing,
      );

      // Phone, typed without the spaces the record has.
      await tester.enterText(search, '0803111');
      await tester.pump();
      expect(
        find.byKey(CustomerPaymentSheetKeys.pickerRow(owes)),
        findsOneWidget,
      );
      expect(
        find.byKey(CustomerPaymentSheetKeys.pickerRow(credit)),
        findsNothing,
      );

      await tester.enterText(search, '0999');
      await tester.pump();
      expect(find.text('No customers match'), findsOneWidget);
      // The deleted customer's phone never matches.
      expect(
        find.byKey(CustomerPaymentSheetKeys.pickerRow(deleted)),
        findsNothing,
      );
      await disposeScreen(tester);
    });

    testWidgets('"No customers yet" when the business has none', (
      tester,
    ) async {
      await env.db.customStatement(
        "UPDATE customers SET is_deleted = 1 WHERE id <> '${Customer.walkInId}'",
      );
      await openHost(tester, env);
      expect(find.text('No customers yet'), findsOneWidget);
      expect(find.byKey(CustomerPaymentSheetKeys.search), findsNothing);
      await disposeScreen(tester);
    });

    testWidgets('Change goes back to the picker', (tester) async {
      await openHost(tester, env);
      await pickCustomer(tester, even);
      expect(find.byKey(CustomerPaymentSheetKeys.pickedCustomer), findsOne);
      await tester.tap(find.byKey(CustomerPaymentSheetKeys.change));
      await deliver(tester);
      expect(find.byKey(CustomerPaymentSheetKeys.search), findsOneWidget);
      await disposeScreen(tester);
    });
  });

  group('balance line and "Pay full"', () {
    testWidgets('owes: "Owes ₦12,500" and Pay full fills the exact amount', (
      tester,
    ) async {
      await openHost(tester, env);
      await pickCustomer(tester, owes);
      expect(balanceText(tester), 'Owes ₦12,500');
      final amountField = find.descendant(
        of: find.byKey(CustomerPaymentSheetKeys.amount),
        matching: find.byType(EditableText),
      );
      // The amount starts empty: a part payment is the usual case.
      expect(tester.widget<EditableText>(amountField).controller.text, '');
      expect(find.text('Pay full ₦12,500'), findsOneWidget);
      await tester.tap(find.byKey(CustomerPaymentSheetKeys.payFull));
      await tester.pump();
      expect(
        tester.widget<EditableText>(amountField).controller.text,
        '12,500',
      );
      await disposeScreen(tester);
    });

    testWidgets('holds credit: "Has ₦3,000 credit", no Pay full', (
      tester,
    ) async {
      await openHost(tester, env);
      await pickCustomer(tester, credit);
      expect(balanceText(tester), 'Has ₦3,000 credit');
      expect(find.byKey(CustomerPaymentSheetKeys.payFull), findsNothing);
      await disposeScreen(tester);
    });

    testWidgets('nothing owed: "Nothing owed", no Pay full', (tester) async {
      await openHost(tester, env);
      await pickCustomer(tester, even);
      expect(balanceText(tester), 'Nothing owed');
      expect(find.byKey(CustomerPaymentSheetKeys.payFull), findsNothing);
      await disposeScreen(tester);
    });

    testWidgets('held crate deposits are not part of the figure', (
      tester,
    ) async {
      final wallet = await env.db.customerWalletsDao.getByCustomerId(even);
      await env.db
          .into(env.db.walletTransactions)
          .insert(
            WalletTransactionsCompanion.insert(
              id: Value(UuidV7.generate()),
              businessId: env.businessId,
              walletId: wallet!.id,
              customerId: even,
              type: 'credit',
              amountKobo: 500000,
              signedAmountKobo: 500000,
              referenceType: 'crate_deposit',
            ),
          );
      await openHost(tester, env);
      await pickCustomer(tester, even);
      expect(balanceText(tester), 'Nothing owed');
      await disposeScreen(tester);
    });
  });

  group('submit', () {
    Future<void> pay(
      WidgetTester tester, {
      required String customerId,
      required String amount,
      String method = 'cash',
      Set<String> grantedKeys = _grants,
    }) async {
      await openHost(tester, env, grantedKeys: grantedKeys);
      await pickCustomer(tester, customerId);
      await tester.enterText(
        find.descendant(
          of: find.byKey(CustomerPaymentSheetKeys.amount),
          matching: find.byType(EditableText),
        ),
        amount,
      );
      await tester.tap(find.byKey(CustomerPaymentSheetKeys.method(method)));
      await tester.pump();
      final submit = find.byKey(CustomerPaymentSheetKeys.submit);
      await tester.ensureVisible(submit);
      await tester.pumpAndSettle();
      await tester.tap(submit);
      await deliver(tester);
      await tester.pumpAndSettle();
    }

    testWidgets('writes the payment row with the active write store and the '
        'balance drops', (tester) async {
      await pay(tester, customerId: owes, amount: '5000', method: 'transfer');

      final rows = await tester.runAsync(
        () => env.db.select(env.db.paymentTransactions).get(),
      );
      expect(rows, hasLength(1));
      final row = rows!.single;
      expect(row.amountKobo, 500000);
      expect(row.type, 'wallet_topup');
      expect(row.method, 'transfer');
      expect(row.storeId, env.storeId);
      expect(row.performedBy, 'test-user-id');
      final balance = await tester.runAsync(
        () => env.db.walletTransactionsDao.getBalanceKobo(owes),
      );
      expect(balance, -750000);
      expect(find.byKey(CustomerPaymentSheetKeys.sheet), findsNothing);
      expect(find.text('₦5,000 added to credit balance'), findsOneWidget);
      await disposeScreen(tester);
    });

    testWidgets('paying more than the debt becomes credit', (tester) async {
      await pay(tester, customerId: owes, amount: '20000');
      final balance = await tester.runAsync(
        () => env.db.walletTransactionsDao.getBalanceKobo(owes),
      );
      expect(balance, 750000);
      await disposeScreen(tester);
    });

    testWidgets('without customers.wallet.update nothing is written', (
      tester,
    ) async {
      await pay(
        tester,
        customerId: owes,
        amount: '5000',
        grantedKeys: const {'sales.make'},
      );
      final rows = await tester.runAsync(
        () => env.db.select(env.db.paymentTransactions).get(),
      );
      expect(rows, isEmpty);
      final balance = await tester.runAsync(
        () => env.db.walletTransactionsDao.getBalanceKobo(owes),
      );
      expect(balance, -1250000);
      expect(find.text('You no longer have access to Add Credit.'), findsOne);
      // Let the denial notification's auto-dismiss timer run out.
      await tester.pump(const Duration(seconds: 6));
      await disposeScreen(tester);
    });

    testWidgets('an empty amount is refused', (tester) async {
      await openHost(tester, env);
      await pickCustomer(tester, owes);
      final submit = find.byKey(CustomerPaymentSheetKeys.submit);
      await tester.ensureVisible(submit);
      await tester.pumpAndSettle();
      await tester.tap(submit);
      await tester.pump();
      expect(find.text('Enter a valid amount'), findsOneWidget);
      final rows = await tester.runAsync(
        () => env.db.select(env.db.paymentTransactions).get(),
      );
      expect(rows, isEmpty);
      await disposeScreen(tester);
    });
  });

  group('layout', () {
    for (final (name, size, insets, scale) in [
      (
        '360x800 @1.3',
        androidCompactPortrait,
        const FakeViewPadding(top: 24, bottom: 48),
        1.3,
      ),
      (
        '390x844',
        const Size(390, 844),
        const FakeViewPadding(top: 24, bottom: 24),
        1.0,
      ),
      (
        '844x390 sideways',
        const Size(844, 390),
        const FakeViewPadding(top: 24, right: 48),
        1.0,
      ),
    ]) {
      testWidgets('$name: picker and form fit, keyboard up the form scrolls '
          'to the submit button', (tester) async {
        tester.view.padding = insets;
        tester.view.viewPadding = insets;
        addTearDown(tester.view.resetPadding);
        addTearDown(tester.view.resetViewPadding);
        addTearDown(tester.view.resetViewInsets);
        await openHost(
          tester,
          env,
          size: size,
          textScaler: TextScaler.linear(scale),
          theme: AppTheme.light(),
        );
        expect(tester.takeException(), isNull, reason: 'picker overflowed');
        await pickCustomer(tester, owes);
        expect(tester.takeException(), isNull, reason: 'form overflowed');

        // Focus the amount, then the keyboard comes up.
        final amount = find.descendant(
          of: find.byKey(CustomerPaymentSheetKeys.amount),
          matching: find.byType(EditableText),
        );
        await tester.ensureVisible(amount);
        await tester.pumpAndSettle();
        await tester.tap(amount);
        await tester.pump();
        final keyboard = size.height > size.width ? 300.0 : 180.0;
        tester.view.viewInsets = FakeViewPadding(bottom: keyboard);
        tester.view.padding = FakeViewPadding(
          top: insets.top,
          right: insets.right,
        );
        await tester.pump();
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: 'keyboard overflowed');

        final keyboardTop = size.height - keyboard;
        final field = tester.getRect(amount);
        expect(field.bottom, lessThanOrEqualTo(keyboardTop + 0.5));

        // Every control is reachable above the keyboard and ≥ 48dp.
        final submit = find.byKey(CustomerPaymentSheetKeys.submit);
        await tester.ensureVisible(submit);
        await tester.pumpAndSettle();
        final submitRect = tester.getRect(submit);
        expect(submitRect.bottom, lessThanOrEqualTo(keyboardTop + 0.5));
        expect(submitRect.height, greaterThanOrEqualTo(_minTap));
        final payFull = find.byKey(CustomerPaymentSheetKeys.payFull);
        await tester.ensureVisible(payFull);
        await tester.pumpAndSettle();
        expect(tester.getRect(payFull).height, greaterThanOrEqualTo(_minTap));
        for (final m in ['cash', 'transfer']) {
          expect(
            tester
                .getRect(find.byKey(CustomerPaymentSheetKeys.method(m)))
                .height,
            greaterThanOrEqualTo(_minTap),
          );
        }
        expect(tester.takeException(), isNull);
        await disposeScreen(tester);
      });
    }
  });

  group('Customer Detail opens the sheet pre-picked', () {
    testWidgets('Add Credit: no picker, balance line and Pay full', (
      tester,
    ) async {
      final data = await (env.db.select(
        env.db.customers,
      )..where((t) => t.id.equals(owes))).getSingle();
      await pumpScreen(
        tester,
        env: env,
        size: pixel7Portrait,
        screen: CustomerDetailScreen(customer: Customer.fromDb(data)),
        grantedKeys: const {
          'customers.wallet.update',
          'customers.wallet.totals.view',
          'sales.make',
        },
        roleRank: GateTier.ceo,
        settle: false,
      );
      await deliver(tester);
      final addCredit = find.text('Add Credit');
      expect(addCredit, findsOneWidget);
      await tester.tap(addCredit);
      await tester.pumpAndSettle();
      await deliver(tester);

      expect(find.byKey(CustomerPaymentSheetKeys.sheet), findsOneWidget);
      expect(find.byKey(CustomerPaymentSheetKeys.search), findsNothing);
      expect(find.byKey(CustomerPaymentSheetKeys.change), findsNothing);
      expect(
        find.descendant(
          of: find.byKey(CustomerPaymentSheetKeys.pickedCustomer),
          matching: find.text('Adaeze Okafor'),
        ),
        findsOneWidget,
      );
      expect(balanceText(tester), 'Owes ₦12,500');
      expect(find.text('Pay full ₦12,500'), findsOneWidget);
      // The page keeps its "Add Credit" wording on the sheet's button.
      expect(
        find.descendant(
          of: find.byKey(CustomerPaymentSheetKeys.submit),
          matching: find.text('Add Credit'),
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await disposeScreen(tester);
    });
  });
}
