// #395 (PRD #346 Wave 2 A): the restyled Customers list and the Add / Edit
// Customer sheets. Restyle only — these pin that every control, figure,
// permission rule and write still behaves as before, and that nothing
// overflows at the supported sizes (with realistic insets and the keyboard
// up in every form field).

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/core/permissions/gate.dart';
import 'package:reebaplus_pos/core/settings/settings_screen.dart'
    show kSettingsMaxContentWidth;
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/theme/fixed_colors.dart';
import 'package:reebaplus_pos/features/customers/data/models/customer.dart';
import 'package:reebaplus_pos/features/customers/screens/customer_detail_screen.dart';
import 'package:reebaplus_pos/features/customers/screens/customers_screen.dart';
import 'package:reebaplus_pos/features/customers/widgets/add_customer_sheet.dart';
import 'package:reebaplus_pos/features/customers/widgets/customer_parts.dart';
import 'package:reebaplus_pos/features/customers/widgets/edit_customer_sheet.dart';
import 'package:reebaplus_pos/shared/widgets/app_input.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/redesign.dart';

import '../helpers/screen_harness.dart';

const _minTap = kMinInteractiveDimension - 0.01;

const _ceoGrants = {
  'customers.add',
  'customers.update',
  'customers.wallet.update',
  'sales.make',
};

Future<String> _seed(
  ScreenTestEnvironment env, {
  required String name,
  String? phone,
  String? address,
  String priceTier = 'retailer',
  String? storeId,
  int balanceKobo = 0,
  int depositHeldKobo = 0,
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
          phone: Value(phone),
          address: Value(address),
          priceTier: Value(priceTier),
          storeId: Value(storeId ?? env.storeId),
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
  Future<void> txn(int signed, String ref) => db
      .into(db.walletTransactions)
      .insert(
        WalletTransactionsCompanion.insert(
          id: Value(UuidV7.generate()),
          businessId: env.businessId,
          walletId: walletId,
          customerId: id,
          type: signed < 0 ? 'debit' : 'credit',
          amountKobo: signed.abs(),
          signedAmountKobo: signed,
          referenceType: ref,
        ),
      );
  if (balanceKobo != 0) {
    await txn(balanceKobo, balanceKobo < 0 ? 'order_payment' : 'topup_cash');
  }
  if (depositHeldKobo != 0) await txn(depositHeldKobo, 'crate_deposit');
  return id;
}

Future<void> _deliver(WidgetTester tester, [int rounds = 6]) async {
  for (var i = 0; i < rounds; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 250));
  }
}

Future<void> _pumpList(
  WidgetTester tester,
  ScreenTestEnvironment env, {
  Size size = const Size(390, 844),
  EdgeInsets padding = const EdgeInsets.only(top: 24, bottom: 24),
  Set<String> grantedKeys = _ceoGrants,
  TextScaler? textScaler,
  ThemeData? theme,
}) async {
  await pumpScreen(
    tester,
    env: env,
    size: size,
    padding: padding,
    screen: const CustomersScreen(),
    // A drawer destination: no bottom bar under 600dp; the rail at 600dp+.
    bottomNavHeight: size.width >= 600 ? kBottomNavBodyHeight : 0,
    grantedKeys: grantedKeys,
    roleRank: GateTier.ceo,
    textScaler: textScaler,
    theme: theme ?? AppTheme.light(),
    settle: false,
  );
  await _deliver(tester);
}

/// A tab-like host: Scaffold → nested Navigator → an "open" button, so the
/// sheet opens on a tab's navigator and the Scaffold's resize owns the
/// keyboard, as in the app.
class _SheetHost extends StatelessWidget {
  const _SheetHost(this.open);

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

Future<void> _openSheet(
  WidgetTester tester,
  ScreenTestEnvironment env,
  void Function(BuildContext context) open, {
  Size size = const Size(390, 844),
  Set<String> grantedKeys = _ceoGrants,
  TextScaler? textScaler,
}) async {
  await pumpScreen(
    tester,
    env: env,
    size: size,
    screen: _SheetHost(open),
    bottomNavHeight: 0,
    followView: true,
    grantedKeys: grantedKeys,
    roleRank: GateTier.ceo,
    textScaler: textScaler,
    theme: AppTheme.light(),
    settle: false,
  );
  await _deliver(tester);
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  await _deliver(tester, 3);
}

Finder _field(String label) => find.descendant(
  of: find.widgetWithText(AppInput, label),
  matching: find.byType(EditableText),
);

void _openEdit(BuildContext context, String id, String storeId) =>
    EditCustomerSheet.show(
      context,
      customerId: id,
      initialName: 'Adaeze Okafor',
      initialPhone: '08031112222',
      initialAddress: '12 Allen Avenue, Ikeja',
      initialLocation: '',
      initialPriceTier: PriceTier.wholesaler,
      initialStoreId: storeId,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ScreenTestEnvironment env;

  setUp(() async {
    env = await setupScreenTestEnvironment(
      productCount: 0,
      businessName: 'Stallion Global',
    );
    await env.db.customStatement(
      "UPDATE stores SET name = 'Abuja HQ' WHERE id = '${env.storeId}'",
    );
  });

  tearDown(() => env.dispose());

  group('Customers list', () {
    testWidgets('top bar, rows, tier tag and Credits Balance', (tester) async {
      final owes = await _seed(
        env,
        name: 'Adaeze Okafor',
        address: '12 Allen Avenue, Ikeja',
        balanceKobo: -1250000,
      );
      final credit = await _seed(
        env,
        name: 'Bola Adewale',
        priceTier: 'wholesaler',
        balanceKobo: 300000,
      );
      await _pumpList(tester, env);

      expect(find.byKey(CustomersKeys.topBar), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(CustomersKeys.topBar),
          matching: find.byType(ScreenHeader),
        ),
        findsOneWidget,
      );
      expect(find.text('Customers'), findsOneWidget);
      expect(find.byKey(CustomersKeys.row(owes)), findsOneWidget);
      expect(find.byKey(CustomersKeys.row(credit)), findsOneWidget);
      expect(find.text('12 Allen Avenue, Ikeja'), findsOneWidget);
      expect(find.text('RETAILER'), findsOneWidget);
      expect(find.text('WHOLESALER'), findsOneWidget);
      expect(find.text('Credits Balance'), findsNWidgets(2));

      final f = AppFixedColors.light;
      final owesText = tester.widget<Text>(find.text('-₦12,500'));
      expect(owesText.style?.color, f.danger);
      final creditText = tester.widget<Text>(find.text('₦3,000'));
      expect(creditText.style?.color, f.green);

      // Each row is one ≥ 48dp tap target.
      expect(
        tester.getSize(find.byKey(CustomersKeys.row(owes))).height,
        greaterThanOrEqualTo(_minTap),
      );
      expect(tester.takeException(), isNull);
      await disposeScreen(tester);
    });

    testWidgets('Credits Balance leaves held crate deposits out', (
      tester,
    ) async {
      await _seed(
        env,
        name: 'Chinedu Eze',
        balanceKobo: 200000,
        depositHeldKobo: 500000,
      );
      await _pumpList(tester, env);
      expect(find.text('₦2,000'), findsOneWidget);
      expect(find.text('₦7,000'), findsNothing);
      await disposeScreen(tester);
    });

    testWidgets('the locked store scopes the list', (tester) async {
      final other = UuidV7.generate();
      await env.db
          .into(env.db.stores)
          .insert(
            StoresCompanion.insert(
              id: Value(other),
              businessId: env.businessId,
              name: 'Lagos Depot',
            ),
          );
      await _seed(env, name: 'Here Customer');
      await _seed(env, name: 'Elsewhere Customer', storeId: other);
      await _pumpList(tester, env);
      expect(find.text('Here Customer'), findsOneWidget);
      expect(find.text('Elsewhere Customer'), findsNothing);
      await disposeScreen(tester);
    });

    testWidgets('the walk-in is never listed', (tester) async {
      await env.db
          .into(env.db.customers)
          .insert(
            CustomersCompanion.insert(
              id: const Value(Customer.walkInId),
              businessId: env.businessId,
              name: 'Walk-in Customer',
              storeId: Value(env.storeId),
            ),
          );
      await _seed(env, name: 'Funmi Lawal');
      await _pumpList(tester, env);
      expect(find.text('Funmi Lawal'), findsOneWidget);
      expect(find.text('Walk-in Customer'), findsNothing);
      await disposeScreen(tester);
    });

    testWidgets('empty list message', (tester) async {
      await _pumpList(tester, env);
      expect(find.byKey(CustomersKeys.empty), findsOneWidget);
      expect(find.text('No customers found.'), findsOneWidget);
      await disposeScreen(tester);
    });

    testWidgets('tapping a row opens Customer Detail', (tester) async {
      final id = await _seed(env, name: 'Adaeze Okafor');
      await _pumpList(tester, env);
      await tester.tap(find.byKey(CustomersKeys.row(id)));
      await tester.pump();
      await _deliver(tester);
      expect(find.byType(CustomerDetailScreen), findsOneWidget);
      expect(find.text('Customer Profile'), findsOneWidget);
      await disposeScreen(tester);
    });

    testWidgets('Add Customer shows with customers.add and opens the sheet', (
      tester,
    ) async {
      await _pumpList(tester, env);
      expect(find.text('Add Customer'), findsOneWidget);
      await tester.tap(find.text('Add Customer'));
      await tester.pumpAndSettle();
      await _deliver(tester, 3);
      expect(find.byKey(CustomersKeys.addSheet), findsOneWidget);
      expect(find.text('Add New Customer'), findsOneWidget);
      await disposeScreen(tester);
    });

    testWidgets('Add Customer is hidden without customers.add', (tester) async {
      await _pumpList(tester, env, grantedKeys: const {'sales.make'});
      expect(find.text('Add Customer'), findsNothing);
      await disposeScreen(tester);
    });

    testWidgets('menu button under 600dp, none beside the rail', (
      tester,
    ) async {
      await _pumpList(tester, env);
      final header = find.byType(ScreenHeader);
      expect(tester.widget<ScreenHeader>(header).leading, isNotNull);
      await disposeScreen(tester);
      await _pumpList(tester, env, size: const Size(800, 1280));
      expect(tester.widget<ScreenHeader>(header).leading, isNull);
      await disposeScreen(tester);
    });

    testWidgets('wide screens cap the list at 720dp, centred', (tester) async {
      final id = await _seed(env, name: 'Adaeze Okafor');
      await _pumpList(tester, env, size: const Size(1280, 800));
      final row = tester.getRect(find.byKey(CustomersKeys.row(id)));
      expect(row.width, closeTo(kSettingsMaxContentWidth, 0.5));
      final list = tester.getRect(find.byKey(CustomersKeys.list));
      expect(row.left - list.left, closeTo(list.right - row.right, 0.5));
      await disposeScreen(tester);
    });

    for (final (name, size, padding, scale) in [
      (
        '360x800 @1.3',
        const Size(360, 800),
        const EdgeInsets.only(top: 24, bottom: 48),
        1.3,
      ),
      (
        '390x844',
        const Size(390, 844),
        const EdgeInsets.only(top: 24, bottom: 24),
        1.0,
      ),
      (
        '844x390 with insets',
        const Size(844, 390),
        const EdgeInsets.only(top: 24, right: 48),
        1.0,
      ),
      ('800x1280', const Size(800, 1280), EdgeInsets.zero, 1.0),
      ('1280x800', const Size(1280, 800), EdgeInsets.zero, 1.0),
    ]) {
      testWidgets('$name: no overflow, a whole row visible', (tester) async {
        final first = await _seed(
          env,
          name: 'Chinedu Eze Okonkwo-Bassey Wholesale Ltd',
          address: '45 Herbert Macaulay Way, Yaba, Lagos State, Nigeria',
          priceTier: 'wholesaler',
          balanceKobo: -123456789,
        );
        for (var i = 0; i < 6; i++) {
          await _seed(env, name: 'Customer $i', balanceKobo: i * 10000);
        }
        await _pumpList(
          tester,
          env,
          size: size,
          padding: padding,
          textScaler: TextScaler.linear(scale),
        );
        expect(tester.takeException(), isNull);
        final row = tester.getRect(find.byKey(CustomersKeys.row(first)));
        expect(row.top, greaterThanOrEqualTo(0));
        expect(row.bottom, lessThanOrEqualTo(size.height));
        await disposeScreen(tester);
      });
    }
  });

  group('Add Customer sheet', () {
    testWidgets('renders its controls and saves a customer', (tester) async {
      await _openSheet(tester, env, (c) => AddCustomerSheet.show(c));
      expect(find.byType(ScreenHeader), findsOneWidget);
      for (final label in [
        'Customer Name',
        'Price Tier',
        'Assign to Store',
        'Address (optional)',
        'Phone Number',
        'Save Customer',
      ]) {
        expect(find.text(label), findsOneWidget, reason: label);
      }

      await tester.enterText(_field('Customer Name'), 'Ngozi Ike');
      await tester.enterText(_field('Phone Number'), '08070001111');
      await tester.tap(find.text('Select store'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Abuja HQ').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save Customer'));
      await tester.pump();
      await _deliver(tester);

      final rows = (await tester.runAsync(
        () => (env.db.select(
          env.db.customers,
        )..where((t) => t.name.equals('Ngozi Ike'))).get(),
      ))!;
      expect(rows, hasLength(1));
      expect(rows.single.phone, '08070001111');
      expect(rows.single.storeId, env.storeId);
      await _deliver(tester, 12);
      await tester.pump(const Duration(seconds: 5));
      await disposeScreen(tester);
    });

    testWidgets('required fields still validate', (tester) async {
      await _openSheet(tester, env, (c) => AddCustomerSheet.show(c));
      await tester.tap(find.text('Save Customer'));
      await tester.pumpAndSettle();
      expect(find.text('This field is required'), findsNWidgets(2));
      expect(find.text('Please select a store'), findsOneWidget);
      await disposeScreen(tester);
    });

    testWidgets('without customers.add, Save writes nothing', (tester) async {
      await _openSheet(
        tester,
        env,
        (c) => AddCustomerSheet.show(c),
        grantedKeys: const {'sales.make'},
      );
      await tester.enterText(_field('Customer Name'), 'Ngozi Ike');
      await tester.tap(find.text('Save Customer'));
      await tester.pump();
      await _deliver(tester);
      final rows = await env.db.select(env.db.customers).get();
      expect(rows, isEmpty);
      expect(find.textContaining('You no longer have access to'), findsOne);
      // Let the denial notification's auto-dismiss timer run out.
      await tester.pump(const Duration(seconds: 6));
      await disposeScreen(tester);
    });
  });

  group('Edit Customer sheet', () {
    testWidgets('prefilled; Save Details updates the customer', (tester) async {
      final id = await _seed(env, name: 'Adaeze Okafor');
      await _openSheet(tester, env, (c) => _openEdit(c, id, env.storeId));
      expect(find.byKey(CustomersKeys.editSheet), findsOneWidget);
      expect(find.text('Edit Customer Details'), findsOneWidget);
      expect(find.text('Adaeze Okafor'), findsOneWidget);
      expect(find.text('Abuja HQ'), findsOneWidget);
      expect(
        tester.getSize(find.byKey(CustomersKeys.editBack)).height,
        greaterThanOrEqualTo(_minTap),
      );

      await tester.enterText(_field('Customer Name'), 'Adaeze Okafor-Ibe');
      await tester.tap(find.text('Save Details'));
      await tester.pump();
      await _deliver(tester);
      // The write lands. The harness does not reliably complete the follow-up
      // activity-log write that closes the sheet (the same before #395), so
      // the close is not asserted; the Add test above does the same.
      final row = (await tester.runAsync(
        () => (env.db.select(
          env.db.customers,
        )..where((t) => t.id.equals(id))).getSingle(),
      ))!;
      expect(row.name, 'Adaeze Okafor-Ibe');
      expect(row.priceTier, 'wholesaler');
      await _deliver(tester, 12);
      await tester.pump(const Duration(seconds: 5));
      await disposeScreen(tester);
    });

    testWidgets('back closes it; the barrier does not', (tester) async {
      final id = await _seed(env, name: 'Adaeze Okafor');
      await _openSheet(tester, env, (c) => _openEdit(c, id, env.storeId));
      await tester.tapAt(const Offset(195, 20));
      await tester.pumpAndSettle();
      expect(find.byKey(CustomersKeys.editSheet), findsOneWidget);
      await tester.tap(find.byKey(CustomersKeys.editBack));
      await tester.pumpAndSettle();
      expect(find.byKey(CustomersKeys.editSheet), findsNothing);
      await disposeScreen(tester);
    });

    testWidgets('without customers.update, Save writes nothing', (
      tester,
    ) async {
      final id = await _seed(env, name: 'Adaeze Okafor');
      await _openSheet(
        tester,
        env,
        (c) => _openEdit(c, id, env.storeId),
        grantedKeys: const {'sales.make'},
      );
      await tester.enterText(_field('Customer Name'), 'Changed');
      await tester.tap(find.text('Save Details'));
      await tester.pump();
      await _deliver(tester);
      final row = await (env.db.select(
        env.db.customers,
      )..where((t) => t.id.equals(id))).getSingle();
      expect(row.name, 'Adaeze Okafor');
      await disposeScreen(tester);
    });
  });

  group('Customer sheets with the keyboard up', () {
    const fields = ['Customer Name', 'Address (optional)', 'Phone Number'];
    for (final (name, size, insets, scale) in [
      (
        '360x800 @1.3',
        const Size(360, 800),
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
        '844x390 with insets',
        const Size(844, 390),
        const FakeViewPadding(top: 24, right: 48),
        1.0,
      ),
    ]) {
      for (final edit in [false, true]) {
        final sheet = edit ? 'Edit' : 'Add';
        testWidgets('$sheet sheet, $name: each field and Save reachable '
            'above the keyboard', (tester) async {
          tester.view.padding = insets;
          tester.view.viewPadding = insets;
          addTearDown(tester.view.resetPadding);
          addTearDown(tester.view.resetViewPadding);
          addTearDown(tester.view.resetViewInsets);
          final id = await _seed(env, name: 'Adaeze Okafor');
          await _openSheet(
            tester,
            env,
            (c) =>
                edit ? _openEdit(c, id, env.storeId) : AddCustomerSheet.show(c),
            size: size,
            textScaler: TextScaler.linear(scale),
          );
          expect(tester.takeException(), isNull, reason: 'sheet overflowed');
          Finder scrollable() => find
              .descendant(
                of: find.byKey(
                  edit ? CustomersKeys.editSheet : CustomersKeys.addSheet,
                ),
                matching: find.byType(Scrollable),
              )
              .first;
          final keyboard = size.height > size.width ? 300.0 : 180.0;
          final keyboardTop = size.height - keyboard;
          for (final label in fields) {
            final field = _field(label);
            await tester.scrollUntilVisible(
              field,
              60,
              scrollable: scrollable(),
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
            final rect = tester.getRect(field);
            expect(
              rect.bottom,
              lessThanOrEqualTo(keyboardTop + 0.5),
              reason: '$label hidden by the keyboard',
            );
            // The whole field (label and box) fits in its scroll view: before
            // #395 the fields' list shrank to ~35dp sideways with the keyboard
            // up, so only a sliver of one field showed at a time.
            final box = tester.getRect(find.widgetWithText(AppInput, label));
            final view = tester.getRect(scrollable());
            expect(
              box.height,
              lessThanOrEqualTo(view.height + 0.5),
              reason: '$label taller than the space left for the fields',
            );
          }
          final save = find.text(edit ? 'Save Details' : 'Save Customer');
          await tester.scrollUntilVisible(save, 60, scrollable: scrollable());
          await tester.ensureVisible(save);
          await tester.pumpAndSettle();
          expect(tester.getRect(save).bottom, lessThanOrEqualTo(keyboardTop));
          expect(tester.takeException(), isNull);
          await disposeScreen(tester);
        });
      }
    }
  });
}
