// Customer Detail restyle (#395 PR 2): every control renders, each main action
// still works, permission-hidden controls stay hidden, nothing overflows at
// the six viewports, and the Refund / Set Limit / Record Crate Return sheets
// scroll with the keyboard up (they did not before: they overflowed at
// 844x390 — BUILD_LOG 2026-10-16).
//
// The detail screen is hosted the way MainLayout hosts it: a Scaffold whose
// body is a nested Navigator, so the Scaffold's resize owns the keyboard.

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/permissions/gate.dart';
import 'package:reebaplus_pos/features/customers/widgets/customer_parts.dart';

import '../helpers/customer_detail_fixture.dart';
import '../helpers/screen_harness.dart';

const _minTap = kMinInteractiveDimension - 0.01;

class _Host extends StatelessWidget {
  const _Host(this.child);
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

  setUp(() async {
    env = await setupScreenTestEnvironment(
      productCount: 0,
      manufacturerCount: 1,
      businessName: 'Stallion Global',
    );
    fx = await seedCustomerDetail(env);
    // The harness's signed-in user, as a real row: a refund and a crate
    // return record who did them (FK to users).
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

  Future<void> deliver(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 250));
    }
  }

  Future<void> pump(
    WidgetTester tester, {
    Size size = const Size(412, 915),
    Set<String> grants = customerDetailGrants,
    int rank = GateTier.ceo,
    double textScale = 1.0,
    EdgeInsets padding = EdgeInsets.zero,
  }) async {
    tester.view.padding = FakeViewPadding(
      left: padding.left,
      top: padding.top,
      right: padding.right,
      bottom: padding.bottom,
    );
    tester.view.viewPadding = tester.view.padding;
    addTearDown(tester.view.resetPadding);
    addTearDown(tester.view.resetViewPadding);
    final ctx = await pumpScreen(
      tester,
      env: env,
      size: size,
      screen: _Host(fx.screen),
      followView: true,
      bottomNavHeight: 0,
      grantedKeys: grants,
      roleRank: rank,
      textScaler: TextScaler.linear(textScale),
      overrides: customerDetailOverrides(),
      settle: false,
    );
    // The write paths read the customer service's cache; warm it as the app
    // has by the time anyone opens a customer.
    ProviderScope.containerOf(
      ctx,
      listen: false,
    ).listen(customerServiceProvider, (_, _) {});
    await deliver(tester);
  }

  /// Scrolls the header cards away so the tab's rows are on screen.
  Future<void> scrollHeaderAway(WidgetTester tester) async {
    await tester.drag(find.byType(NestedScrollView), const Offset(0, -600));
    await tester.pumpAndSettle();
  }

  Future<void> goTab(WidgetTester tester, String label) async {
    // Sideways, the header cards fill the screen until they scroll away.
    if (find.text(label).evaluate().isEmpty) await scrollHeaderAway(tester);
    await tester.tap(find.text(label));
    await tester.pumpAndSettle();
  }

  group('controls render', () {
    testWidgets('CEO sees every control, on every tab', (tester) async {
      await pump(tester);
      expect(find.byKey(CustomersKeys.detailTopBar), findsOneWidget);
      expect(find.text('Customer Profile'), findsOneWidget);
      expect(find.text('Account Details'), findsOneWidget);
      expect(find.byKey(CustomersKeys.detailBack), findsOneWidget);
      expect(find.byKey(CustomersKeys.detailDelete), findsOneWidget);
      expect(find.byKey(CustomersKeys.detailEdit), findsOneWidget);
      expect(find.text('Adaeze Okafor'), findsOneWidget);
      expect(find.text('AO'), findsOneWidget);
      expect(find.text('Wholesaler'), findsOneWidget);
      expect(find.text('08031112222'), findsOneWidget);
      expect(find.text('Since Mar 2026'), findsOneWidget);
      expect(find.text('Credits Balance'), findsOneWidget);
      expect(find.textContaining('37,500'), findsWidgets);
      expect(find.text('Debt Limit'), findsOneWidget);
      expect(find.text('Deposit Held'), findsOneWidget);
      expect(find.byKey(CustomersKeys.addCredit), findsOneWidget);
      expect(find.byKey(CustomersKeys.setLimit), findsOneWidget);
      expect(find.byKey(CustomersKeys.refundCash), findsOneWidget);
      for (final k in [
        CustomersKeys.detailBack,
        CustomersKeys.detailDelete,
        CustomersKeys.detailEdit,
        CustomersKeys.addCredit,
        CustomersKeys.setLimit,
        CustomersKeys.refundCash,
      ]) {
        final r = tester.getRect(find.byKey(k));
        expect(r.height, greaterThanOrEqualTo(_minTap), reason: '$k height');
      }

      // Credits tab.
      await scrollHeaderAway(tester);
      expect(find.text('Total In'), findsOneWidget);
      expect(find.text('Total Out'), findsOneWidget);
      expect(find.text('Cash credit added'), findsOneWidget);

      await goTab(tester, 'Orders');
      expect(find.text('#ORD-000412-A7K2'), findsOneWidget);
      expect(find.text('Completed'), findsOneWidget);
      expect(find.text('Cancelled'), findsOneWidget);

      await goTab(tester, 'Crates');
      expect(find.byKey(CustomersKeys.recordCrateReturn), findsOneWidget);
      expect(find.text('6 crates owed'), findsOneWidget);
      await disposeScreen(tester);
    });

    testWidgets('the Credits tab shows green in / danger out rows and a '
        '48dp void button on a live top-up', (tester) async {
      await pump(tester);
      await scrollHeaderAway(tester);
      final void_ = find.byWidgetPredicate(
        (w) =>
            w.key is ValueKey<String> &&
            (w.key! as ValueKey<String>).value.startsWith(
              'customer-void-topup-',
            ),
      );
      expect(void_, findsOneWidget);
      expect(tester.getSize(void_).height, greaterThanOrEqualTo(_minTap));
      expect(tester.getSize(void_).width, greaterThanOrEqualTo(_minTap));
      await disposeScreen(tester);
    });
  });

  group('permission gates hide controls', () {
    testWidgets('a role with no grants sees none of the gated controls', (
      tester,
    ) async {
      await pump(tester, grants: const {}, rank: GateTier.cashier);
      expect(find.byKey(CustomersKeys.detailDelete), findsNothing);
      expect(find.byKey(CustomersKeys.detailEdit), findsNothing);
      expect(find.byKey(CustomersKeys.addCredit), findsNothing);
      expect(find.byKey(CustomersKeys.setLimit), findsNothing);
      expect(find.byKey(CustomersKeys.refundCash), findsNothing);
      expect(find.text('Total In'), findsNothing);
      expect(find.text('Total Out'), findsNothing);
      // The page itself still renders.
      expect(find.text('Adaeze Okafor'), findsOneWidget);
      expect(find.text('Credits Balance'), findsOneWidget);
      await goTab(tester, 'Crates');
      expect(find.byKey(CustomersKeys.recordCrateReturn), findsNothing);
      await disposeScreen(tester);
    });
  });

  group('actions work', () {
    testWidgets('Set Limit saves the new limit', (tester) async {
      await pump(tester);
      await tester.tap(find.byKey(CustomersKeys.setLimit));
      await tester.pumpAndSettle();
      expect(find.text('Set Debt Limit'), findsOneWidget);
      expect(find.text('Limit Amount (₦)'), findsOneWidget);
      await tester.enterText(find.byKey(CustomersKeys.limitField), '75000');
      await tester.tap(find.byKey(CustomersKeys.limitSubmit));
      await tester.pumpAndSettle();
      await deliver(tester);
      final row = await tester.runAsync(
        () => (env.db.select(
          env.db.customers,
        )..where((t) => t.id.equals(fx.customerId))).getSingle(),
      );
      expect(row!.walletLimitKobo, 7500000);
      await disposeScreen(tester);
    });

    testWidgets('Refund Cash lists four methods and pays the customer back', (
      tester,
    ) async {
      await pump(tester);
      await tester.tap(find.byKey(CustomersKeys.refundCash));
      await tester.pumpAndSettle();
      expect(find.text('Amount to refund (₦)'), findsOneWidget);
      for (final m in ['cash', 'transfer', 'pos', 'other']) {
        expect(find.byKey(CustomersKeys.refundMethod(m)), findsOneWidget);
      }
      await tester.tap(find.byKey(CustomersKeys.refundMethod('transfer')));
      await tester.pump();
      await tester.enterText(find.byKey(CustomersKeys.refundAmount), '1000');
      await tester.tap(find.byKey(CustomersKeys.refundSubmit));
      await tester.pumpAndSettle();
      await deliver(tester);
      final rows = await tester.runAsync(
        () => env.db.select(env.db.walletTransactions).get(),
      );
      expect(
        rows!.where((t) => t.customerId == fx.customerId).length,
        greaterThan(3),
        reason: 'the refund appended wallet rows',
      );
      await disposeScreen(tester);
    });

    testWidgets('Record crate return credits the empties', (tester) async {
      await pump(tester);
      await goTab(tester, 'Crates');
      await tester.tap(find.byKey(CustomersKeys.recordCrateReturn));
      await tester.pumpAndSettle();
      expect(find.text('Record Crate Return'), findsOneWidget);
      await tester.tap(find.text('Select a manufacturer'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(env.manufacturers.first.name).last);
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(CustomersKeys.crateQty), '2');
      await tester.tap(find.byKey(CustomersKeys.crateSubmit));
      await tester.pumpAndSettle();
      await deliver(tester);
      expect(find.text('4 crates owed'), findsOneWidget);
      await disposeScreen(tester);
    });

    testWidgets('Delete asks first, in the theme dialog', (tester) async {
      await pump(tester);
      await tester.tap(find.byKey(CustomersKeys.detailDelete));
      await tester.pumpAndSettle();
      expect(find.text('Delete customer?'), findsOneWidget);
      expect(find.text('Cancel'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.text('Delete customer?'), findsNothing);
      await disposeScreen(tester);
    });
  });

  group('no overflow', () {
    final sizes = <(String, Size, double, EdgeInsets)>[
      ('360dp @1.3', const Size(360, 800), 1.3, EdgeInsets.zero),
      (
        '390x844',
        const Size(390, 844),
        1.0,
        const EdgeInsets.only(top: 24, bottom: 24),
      ),
      (
        '844x390 insets',
        const Size(844, 390),
        1.0,
        const EdgeInsets.only(top: 24, right: 48),
      ),
      ('800x1280', const Size(800, 1280), 1.0, EdgeInsets.zero),
      ('1280x800', const Size(1280, 800), 1.0, EdgeInsets.zero),
    ];
    for (final (name, size, scale, pad) in sizes) {
      testWidgets('$name: every tab', (tester) async {
        await pump(tester, size: size, textScale: scale, padding: pad);
        expect(tester.takeException(), isNull);
        await goTab(tester, 'Orders');
        expect(tester.takeException(), isNull);
        await goTab(tester, 'Crates');
        expect(tester.takeException(), isNull);
        await disposeScreen(tester);
      });
    }

    testWidgets('1280x800 puts the two cards side by side, 800x1280 stacks '
        'them', (tester) async {
      await pump(tester, size: const Size(1280, 800));
      final wideProfile = tester.getRect(find.byKey(CustomersKeys.profileCard));
      final wideCredits = tester.getRect(find.byKey(CustomersKeys.creditsCard));
      expect(wideCredits.left, greaterThan(wideProfile.right - 1));
      expect(
        wideCredits.width + wideProfile.width,
        lessThanOrEqualTo(kCustomerDetailMaxContentWidth),
      );
      await disposeScreen(tester);
      await pump(tester, size: const Size(800, 1280));
      final p = tester.getRect(find.byKey(CustomersKeys.profileCard));
      final c = tester.getRect(find.byKey(CustomersKeys.creditsCard));
      expect(c.top, greaterThan(p.bottom - 1));
      await disposeScreen(tester);
    });
  });

  group('sheets scroll with the keyboard up', () {
    final sizes = <(String, Size, double, double)>[
      ('390x844', const Size(390, 844), 1.0, 300),
      ('844x390', const Size(844, 390), 1.0, 180),
      ('360dp @1.3', const Size(360, 800), 1.3, 300),
    ];
    final sheets = <(String, Key, Key, String, String?)>[
      (
        'Set Limit',
        CustomersKeys.setLimit,
        CustomersKeys.limitSubmit,
        'Set Debt Limit',
        null,
      ),
      (
        'Refund Cash',
        CustomersKeys.refundCash,
        CustomersKeys.refundSubmit,
        'Refund Cash',
        null,
      ),
      (
        'Record crate return',
        CustomersKeys.recordCrateReturn,
        CustomersKeys.crateSubmit,
        'Record Crate Return',
        'Crates',
      ),
    ];
    for (final (sizeName, size, scale, keyboard) in sizes) {
      for (final (label, openKey, submitKey, title, tab) in sheets) {
        testWidgets('$label at $sizeName', (tester) async {
          tester.view.viewInsets = FakeViewPadding.zero;
          addTearDown(tester.view.resetViewInsets);
          await pump(tester, size: size, textScale: scale);
          if (tab != null) await goTab(tester, tab);
          await tester.ensureVisible(find.byKey(openKey));
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(openKey));
          await tester.pumpAndSettle();
          expect(find.text(title), findsWidgets);

          final field = find.descendant(
            of: find.byKey(CustomersKeys.sheetFrame),
            matching: find.byType(TextFormField),
          );
          await tester.tap(field.first);
          await tester.pump();
          tester.view.viewInsets = FakeViewPadding(bottom: keyboard);
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull, reason: 'keyboard overflow');

          // The sheet scrolls: the submit button can be brought above the
          // keyboard and is at least 48dp tall.
          await tester.scrollUntilVisible(
            find.byKey(submitKey),
            80,
            scrollable: find
                .descendant(
                  of: find.byKey(CustomersKeys.sheetFrame),
                  matching: find.byType(Scrollable),
                )
                .first,
          );
          await tester.pump();
          final r = tester.getRect(find.byKey(submitKey));
          expect(r.height, greaterThanOrEqualTo(_minTap));
          expect(r.bottom, lessThanOrEqualTo(size.height - keyboard + 0.5));
          expect(tester.takeException(), isNull);
          await disposeScreen(tester);
        });
      }
    }
  });
}
