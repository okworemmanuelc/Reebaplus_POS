// #659 PR 2: the customer buttons lock on the first tap. Two quick taps with no
// frame between them do the job once; the sheet stays open and spinning until
// the save ends; success closes it; failure keeps it open with what was typed;
// a sheet dragged away mid-save never closes the screen underneath.
//
// The save is a slow fake (a Completer) so "during the save" is a state the
// test controls. Record Crate Return writes through DAOs, not the service, so
// it runs on the real database.

import 'dart:async';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/permissions/gate.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/features/customers/data/models/customer.dart';
import 'package:reebaplus_pos/features/customers/data/services/customer_service.dart';
import 'package:reebaplus_pos/features/customers/widgets/add_customer_sheet.dart';
import 'package:reebaplus_pos/features/customers/widgets/customer_parts.dart';
import 'package:reebaplus_pos/features/customers/widgets/customer_payment_sheet.dart';
import 'package:reebaplus_pos/features/customers/widgets/edit_customer_sheet.dart';
import 'package:reebaplus_pos/shared/widgets/app_input.dart';

import '../helpers/customer_detail_fixture.dart';
import '../helpers/screen_harness.dart';

/// A customer service whose saves wait on [gate] and are counted.
class _SlowService extends CustomerService {
  _SlowService(super.db, super.log);

  Completer<void> gate = Completer<void>();
  int adds = 0, updates = 0, topUps = 0, limits = 0, refunds = 0;

  @override
  Future<Customer?> addCustomer(Customer customer, {String? businessId}) async {
    adds++;
    await gate.future;
    return Customer(
      id: 'new-id',
      name: customer.name,
      addressText: '',
      googleMapsLocation: '',
      isWalkIn: false,
      priceTier: customer.priceTier,
    );
  }

  @override
  Future<void> updateCustomer(Customer updatedCustomer) async {
    updates++;
    await gate.future;
  }

  @override
  Future<void> topUpWallet({
    required String customerId,
    required int amountKobo,
    required String method,
    required String staffId,
    String? storeId,
    String? note,
    String? orderId,
  }) async {
    topUps++;
    await gate.future;
  }

  @override
  Future<void> updateWalletLimit(String customerId, double newLimit) async {
    limits++;
    await gate.future;
  }

  @override
  Future<int> refundCashFromWallet({
    required String customerId,
    required int amountKobo,
    required String method,
    required String staffId,
    String? storeId,
    String? note,
  }) async {
    refunds++;
    await gate.future;
    return amountKobo;
  }
}

const _grants = {
  'customers.add',
  'customers.update',
  'customers.wallet.update',
  'customers.set_debt_limit',
  'customers.wallet.withdraw',
  'customers.wallet.totals.view',
  'sales.make',
  'reports.see_sales',
};

/// A tab-like host: Scaffold -> nested Navigator -> an "open" button.
class _Host extends StatelessWidget {
  const _Host(this.open);
  final void Function(BuildContext) open;
  @override
  Widget build(BuildContext context) => Scaffold(
    body: Navigator(
      onGenerateRoute: (_) => MaterialPageRoute<void>(
        builder: (context) => Scaffold(
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

/// The detail screen hosted like MainLayout hosts it.
class _ScreenHost extends StatelessWidget {
  const _ScreenHost(this.child);
  final Widget child;
  @override
  Widget build(BuildContext context) => Scaffold(
    body: Navigator(
      onGenerateRoute: (_) => MaterialPageRoute<void>(builder: (_) => child),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ScreenTestEnvironment env;
  late CustomerDetailFixture fx;
  late _SlowService slow;

  setUp(() async {
    env = await setupScreenTestEnvironment(
      productCount: 0,
      manufacturerCount: 1,
      businessName: 'Stallion Global',
    );
    fx = await seedCustomerDetail(env);
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
  });
  tearDown(() => env.dispose());

  Future<void> deliver(WidgetTester tester, [int rounds = 6]) async {
    for (var i = 0; i < rounds; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 250));
    }
  }

  Future<void> pumpHost(WidgetTester tester, Widget screen) async {
    final ctx = await pumpScreen(
      tester,
      env: env,
      size: const Size(412, 915),
      screen: screen,
      followView: true,
      bottomNavHeight: 0,
      grantedKeys: _grants,
      roleRank: GateTier.ceo,
      overrides: [
        ...customerDetailOverrides(),
        customerServiceProvider.overrideWith(
          (ref) => slow = _SlowService(
            ref.read(databaseProvider),
            ref.read(activityLogProvider),
          ),
        ),
      ],
      settle: false,
    );
    ProviderScope.containerOf(
      ctx,
      listen: false,
    ).listen(customerServiceProvider, (_, _) {});
    await deliver(tester);
  }

  Future<void> openFromHost(
    WidgetTester tester,
    void Function(BuildContext) open,
  ) async {
    await pumpHost(tester, _Host(open));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  /// Two taps with no frame between them, then one frame.
  Future<void> doubleTap(WidgetTester tester, Finder f) async {
    await tester.ensureVisible(f);
    await tester.pumpAndSettle();
    await tester.tap(f);
    await tester.tap(f);
    await tester.pump();
  }

  Finder spinnerIn(Finder button) => find.descendant(
    of: button,
    matching: find.byType(CircularProgressIndicator),
  );

  /// Taps outside the sheet (the barrier / top gap) to dismiss it mid-save.
  Future<void> dragAway(WidgetTester tester) async {
    await tester.tapAt(const Offset(200, 8));
    await tester.pumpAndSettle();
  }

  Finder field(String label) => find.descendant(
    of: find.widgetWithText(AppInput, label),
    matching: find.byType(EditableText),
  );

  Customer customer() => fx.model;

  // ── Add Customer ──────────────────────────────────────────────────────────
  group('Save Customer', () {
    Future<Finder> open(WidgetTester tester, {void Function(Customer)? onAdd}) async {
      await openFromHost(
        tester,
        (c) => AddCustomerSheet.show(c, onCustomerAdded: onAdd),
      );
      await tester.enterText(field('Customer Name'), 'Ngozi Ike');
      await tester.tap(find.text('Select store'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(env.store.name).last);
      await tester.pumpAndSettle();
      return find.text('Save Customer');
    }

    testWidgets('double tap saves once; open and spinning; closes on success', (
      tester,
    ) async {
      final added = <Customer>[];
      final save = await open(tester, onAdd: added.add);
      await doubleTap(tester, save);
      expect(slow.adds, 1);
      expect(find.byKey(CustomersKeys.addSheet), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      slow.gate.complete();
      await deliver(tester);
      await tester.pumpAndSettle();
      expect(find.byKey(CustomersKeys.addSheet), findsNothing);
      expect(added, hasLength(1));
      expect(find.text('open'), findsOneWidget);
      await disposeScreen(tester);
    });

    testWidgets('failure keeps the sheet open with the typed values', (
      tester,
    ) async {
      final save = await open(tester);
      await doubleTap(tester, save);
      slow.gate.completeError(StateError('boom'));
      await deliver(tester);
      expect(find.byKey(CustomersKeys.addSheet), findsOneWidget);
      expect(find.text('Ngozi Ike'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.text('Could not save customer. Please try again.'), findsOne);
      await tester.pump(const Duration(seconds: 6));
      await disposeScreen(tester);
    });

    testWidgets('dragged away mid-save: the screen underneath stays', (
      tester,
    ) async {
      final save = await open(tester);
      await doubleTap(tester, save);
      await dragAway(tester);
      expect(find.byKey(CustomersKeys.addSheet), findsNothing);
      slow.gate.complete();
      await deliver(tester);
      await tester.pumpAndSettle();
      expect(find.text('open'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await disposeScreen(tester);
    });
  });

  // ── Edit Customer ─────────────────────────────────────────────────────────
  group('Save Details', () {
    Future<void> open(WidgetTester tester, {void Function(Customer)? onUpd}) =>
        openFromHost(
          tester,
          (c) => EditCustomerSheet.show(
            c,
            customerId: fx.customerId,
            initialName: 'Adaeze Okafor',
            initialPhone: '08031112222',
            initialAddress: '12 Allen Avenue, Ikeja',
            initialLocation: '',
            initialPriceTier: PriceTier.wholesaler,
            initialStoreId: env.storeId,
            onCustomerUpdated: onUpd,
          ),
        );

    testWidgets('double tap saves once; open and spinning; closes on success', (
      tester,
    ) async {
      final updated = <Customer>[];
      await open(tester, onUpd: updated.add);
      await doubleTap(tester, find.text('Save Details'));
      expect(slow.updates, 1);
      expect(find.byKey(CustomersKeys.editSheet), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      slow.gate.complete();
      await deliver(tester);
      await tester.pumpAndSettle();
      expect(find.byKey(CustomersKeys.editSheet), findsNothing);
      expect(updated, hasLength(1));
      await disposeScreen(tester);
    });

    testWidgets('failure keeps the sheet open with the typed values', (
      tester,
    ) async {
      await open(tester);
      await tester.enterText(field('Customer Name'), 'Chidi Eze');
      await doubleTap(tester, find.text('Save Details'));
      slow.gate.completeError(StateError('boom'));
      await deliver(tester);
      expect(find.byKey(CustomersKeys.editSheet), findsOneWidget);
      expect(find.text('Chidi Eze'), findsOneWidget);
      expect(find.text('Could not update customer. Please try again.'), findsOne);
      await tester.pump(const Duration(seconds: 6));
      await disposeScreen(tester);
    });
  });

  // ── Add Credit (payment sheet, pre-picked) ────────────────────────────────
  group('Add Credit', () {
    Future<Finder> open(WidgetTester tester) async {
      await pumpHost(
        tester,
        _Host((c) => CustomerPaymentSheet.show(c, customer: customer())),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.descendant(
          of: find.byKey(CustomerPaymentSheetKeys.amount),
          matching: find.byType(EditableText),
        ),
        '5000',
      );
      await tester.pump();
      return find.byKey(CustomerPaymentSheetKeys.submit);
    }

    testWidgets('double tap adds credit once; open and spinning; closes on '
        'success', (tester) async {
      final submit = await open(tester);
      await doubleTap(tester, submit);
      expect(slow.topUps, 1);
      expect(find.byKey(CustomerPaymentSheetKeys.sheet), findsOneWidget);
      expect(spinnerIn(submit), findsOneWidget);
      slow.gate.complete();
      await deliver(tester);
      await tester.pumpAndSettle();
      expect(find.byKey(CustomerPaymentSheetKeys.sheet), findsNothing);
      expect(find.text('₦5,000 added to credit balance'), findsOneWidget);
      await disposeScreen(tester);
    });

    testWidgets('failure keeps the sheet open with the amount', (tester) async {
      final submit = await open(tester);
      await doubleTap(tester, submit);
      slow.gate.completeError(StateError('boom'));
      await deliver(tester);
      expect(find.byKey(CustomerPaymentSheetKeys.sheet), findsOneWidget);
      expect(find.text('5,000'), findsOneWidget);
      expect(find.text('Could not add credit'), findsOneWidget);
      expect(spinnerIn(submit), findsNothing);
      await disposeScreen(tester);
    });

    testWidgets('dragged away mid-save: the screen underneath stays', (
      tester,
    ) async {
      final submit = await open(tester);
      await doubleTap(tester, submit);
      await dragAway(tester);
      expect(find.byKey(CustomerPaymentSheetKeys.sheet), findsNothing);
      slow.gate.complete();
      await deliver(tester);
      await tester.pumpAndSettle();
      expect(find.text('open'), findsOneWidget);
      expect(find.text('₦5,000 added to credit balance'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await disposeScreen(tester);
    });
  });

  // ── Customer detail sheets ────────────────────────────────────────────────
  group('Customer detail', () {
    Future<void> pumpDetail(WidgetTester tester) =>
        pumpHost(tester, _ScreenHost(fx.screen));

    Future<Finder> openLimit(WidgetTester tester) async {
      await pumpDetail(tester);
      await tester.tap(find.byKey(CustomersKeys.setLimit));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(CustomersKeys.limitField), '75000');
      await tester.pump();
      return find.byKey(CustomersKeys.limitSubmit);
    }

    Future<Finder> openRefund(WidgetTester tester) async {
      await pumpDetail(tester);
      await tester.tap(find.byKey(CustomersKeys.refundCash));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(CustomersKeys.refundAmount), '1000');
      await tester.pump();
      return find.byKey(CustomersKeys.refundSubmit);
    }

    testWidgets('Save Limit: once, spinning, closes on success', (tester) async {
      final submit = await openLimit(tester);
      await doubleTap(tester, submit);
      expect(slow.limits, 1);
      expect(find.text('Set Debt Limit'), findsOneWidget);
      expect(spinnerIn(submit), findsOneWidget);
      slow.gate.complete();
      await deliver(tester);
      await tester.pumpAndSettle();
      expect(find.text('Set Debt Limit'), findsNothing);
      await disposeScreen(tester);
    });

    testWidgets('Save Limit: failure keeps the sheet open with the value', (
      tester,
    ) async {
      final submit = await openLimit(tester);
      await doubleTap(tester, submit);
      slow.gate.completeError(StateError('boom'));
      await deliver(tester);
      expect(find.text('Set Debt Limit'), findsOneWidget);
      expect(find.text('75,000'), findsOneWidget);
      expect(
        find.text('Could not update the debt limit. Please try again.'),
        findsOneWidget,
      );
      await tester.pump(const Duration(seconds: 6));
      await disposeScreen(tester);
    });

    testWidgets('Save Limit: dragged away mid-save keeps the customer screen', (
      tester,
    ) async {
      final submit = await openLimit(tester);
      await doubleTap(tester, submit);
      await dragAway(tester);
      expect(find.text('Set Debt Limit'), findsNothing);
      slow.gate.complete();
      await deliver(tester);
      await tester.pumpAndSettle();
      expect(find.text('Adaeze Okafor'), findsWidgets);
      expect(find.text('Credits Balance'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await disposeScreen(tester);
    });

    testWidgets('Refund Cash: once, spinning, closes on success', (tester) async {
      final submit = await openRefund(tester);
      await doubleTap(tester, submit);
      expect(slow.refunds, 1);
      expect(find.byKey(CustomersKeys.refundAmount), findsOneWidget);
      expect(spinnerIn(submit), findsOneWidget);
      slow.gate.complete();
      await deliver(tester);
      await tester.pumpAndSettle();
      expect(find.byKey(CustomersKeys.refundAmount), findsNothing);
      await disposeScreen(tester);
    });

    testWidgets('Refund Cash: failure keeps the sheet open with the amount', (
      tester,
    ) async {
      final submit = await openRefund(tester);
      await doubleTap(tester, submit);
      slow.gate.completeError(StateError('boom'));
      await deliver(tester);
      expect(find.byKey(CustomersKeys.refundAmount), findsOneWidget);
      expect(find.text('1,000'), findsOneWidget);
      expect(find.text('Could not process refund'), findsOneWidget);
      await tester.pump(const Duration(seconds: 6));
      await disposeScreen(tester);
    });

    testWidgets('Record Return: once, closes when written', (
      tester,
    ) async {
      await pumpDetail(tester);
      await tester.drag(find.byType(NestedScrollView), const Offset(0, -600));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Crates'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(CustomersKeys.recordCrateReturn));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Select a manufacturer'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(env.manufacturers.first.name).last);
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(CustomersKeys.crateQty), '2');
      final submit = find.byKey(CustomersKeys.crateSubmit);
      await doubleTap(tester, submit);
      // The real database settles inside the frame, so only the outcome is
      // pinned here: one return recorded, sheet closed after the writes.
      await deliver(tester);
      await tester.pumpAndSettle();
      expect(find.text('Record Crate Return'), findsNothing);
      final logs = await tester.runAsync(
        () => (env.db.select(
          env.db.activityLogs,
        )..where((t) => t.action.equals('crate_return'))).get(),
      );
      expect(logs, hasLength(1), reason: 'the return was recorded once');
      await disposeScreen(tester);
    });

    testWidgets('Record Return: a failed save adds nothing, so a retry cannot '
        'count the empties twice', (tester) async {
      Future<double> stock() async {
        final rows = await tester.runAsync(
          () => env.db.select(env.db.manufacturers).get(),
        );
        return rows!
            .firstWhere((m) => m.id == env.manufacturers.first.id)
            .emptyCrateStock
            .toDouble();
      }

      await pumpDetail(tester);
      await tester.drag(find.byType(NestedScrollView), const Offset(0, -600));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Crates'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(CustomersKeys.recordCrateReturn));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Select a manufacturer'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(env.manufacturers.first.name).last);
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(CustomersKeys.crateQty), '2');
      final before = await stock();

      // The empties write succeeds, then the customer's return write fails.
      await tester.runAsync(
        () => env.db.customStatement(
          'CREATE TRIGGER fail_return BEFORE INSERT ON crate_ledger '
          'WHEN NEW.customer_id IS NOT NULL '
          "BEGIN SELECT RAISE(ABORT, 'boom'); END",
        ),
      );
      await tester.tap(find.byKey(CustomersKeys.crateSubmit));
      await deliver(tester);
      await tester.pumpAndSettle();
      expect(find.text('Record Crate Return'), findsOneWidget);
      expect(await stock(), before, reason: 'the failed save left nothing');

      await tester.runAsync(
        () => env.db.customStatement('DROP TRIGGER fail_return'),
      );
      await tester.tap(find.byKey(CustomersKeys.crateSubmit));
      await deliver(tester);
      await tester.pumpAndSettle();
      expect(find.text('Record Crate Return'), findsNothing);
      expect(await stock(), before + 2, reason: 'counted once on the retry');
      await tester.pump(const Duration(seconds: 6)); // the error banner ends
      await disposeScreen(tester);
    });
  });
}
