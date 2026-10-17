// #413 (PRD #346 Wave 2 B, PR 3): the restyled Stock Approvals screen.
// Restyle only: approving / rejecting still goes through the unchanged DAOs;
// these pin the new top bar and cards, the permission rule, the keyboard-up
// pop-ups and that nothing overflows at the supported sizes.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/features/dashboard/screens/stock_approvals_screen.dart';
import 'package:reebaplus_pos/features/dashboard/widgets/report_parts.dart';
import 'package:reebaplus_pos/shared/widgets/app_input.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/redesign.dart';

import '../helpers/screen_harness.dart';
import 'approvals_fixture.dart';

const _manager = {'sales.make', 'reports.view_approvals', 'expenses.approve'};
const _noMoney = {'sales.make', 'reports.view_approvals'};

const _sizes = <(String, Size, EdgeInsets)>[
  ('360x640', Size(360, 640), EdgeInsets.only(top: 24, bottom: 24)),
  ('390x844', Size(390, 844), EdgeInsets.only(top: 24, bottom: 24)),
  ('844x390', Size(844, 390), EdgeInsets.only(top: 24, right: 48)),
  ('800x1280', Size(800, 1280), EdgeInsets.zero),
  ('1280x800', Size(1280, 800), EdgeInsets.zero),
];

void main() {
  late ScreenTestEnvironment env;

  setUp(() async {
    env = await setupScreenTestEnvironment(
      businessType: 'Beverage distributor',
      manufacturerCount: 1,
    );
  });
  tearDown(() => env.dispose());

  Future<void> pump(
    WidgetTester tester, {
    Size size = const Size(390, 844),
    EdgeInsets padding = const EdgeInsets.only(top: 24, bottom: 24),
    Set<String> grants = _manager,
    TextScaler? textScaler,
    bool followView = false,
    bool empty = false,
    bool withRefund = false,
  }) async {
    await pumpScreen(
      tester,
      env: env,
      size: size,
      padding: padding,
      grantedKeys: grants,
      roleRank: 0,
      textScaler: textScaler,
      followView: followView,
      bottomNavHeight: size.width >= 600 ? kBottomNavBodyHeight : 0,
      overrides: [
        viewerScopedPendingStockRequestsProvider.overrideWith(
          (ref) => empty ? [] : [approvalStockReq(env)],
        ),
        viewerScopedPendingQuickSaleRequestsProvider.overrideWith(
          (ref) => empty ? [] : [approvalQuickReq(env)],
        ),
        viewerScopedPendingCrateDepositsProvider.overrideWith(
          (ref) => empty
              ? []
              : [
                  approvalCrateReq(env),
                  if (withRefund)
                    approvalCrateReq(env, id: 'req-crate-2', kind: 'return'),
                ],
        ),
      ],
      screen: const StockApprovalsScreen(),
    );
  }

  for (final (name, size, padding) in _sizes) {
    for (final scale in [1.0, 1.3]) {
      testWidgets('fits at $name @$scale', (tester) async {
        await pump(
          tester,
          size: size,
          padding: padding,
          textScaler: TextScaler.linear(scale),
        );
        expectNoOverflow(tester);
        expect(find.byKey(ReportKeys.topBar), findsOneWidget);
        // Open every card: the expanded details must fit too.
        for (final t in ['Ice Bag', 'Add 5 ${env.products.first.name}']) {
          await tester.scrollUntilVisible(
            find.text(t),
            200,
            scrollable: find.byType(Scrollable).first,
          );
          await tester.tap(find.text(t).first);
          await tester.pumpAndSettle();
        }
        expectNoOverflow(tester);
        await disposeScreen(tester);
      });
    }
  }

  testWidgets('renders the top bar and the three cards', (tester) async {
    await pump(tester);
    expect(find.text('Approvals'), findsOneWidget);
    expect(find.byKey(ReportKeys.back), findsOneWidget);
    expect(find.byType(IconTile), findsNWidgets(3));
    expect(find.byType(TagPill), findsNWidgets(3));
    expect(find.text('PENDING'), findsNWidgets(3));
    expect(find.byType(ExpansionTile), findsNWidgets(3));
    expect(find.text('Ice Bag'), findsOneWidget);
    expect(find.textContaining('10 crates deposit'), findsOneWidget);
    await disposeScreen(tester);
  });

  testWidgets('empty state', (tester) async {
    await pump(tester, empty: true);
    expect(find.byKey(ReportKeys.empty), findsOneWidget);
    expect(find.text('No pending approvals'), findsOneWidget);
    await disposeScreen(tester);
  });

  testWidgets('a role without expenses.approve never sees crate deposits', (
    tester,
  ) async {
    await pump(tester, grants: _noMoney);
    expect(find.byType(ExpansionTile), findsNWidgets(2));
    expect(find.textContaining('10 crates deposit'), findsNothing);
    await disposeScreen(tester);
  });

  testWidgets('back pops the screen', (tester) async {
    await pump(tester);
    expect(find.byKey(ReportKeys.back), findsOneWidget);
    await disposeScreen(tester);
  });

  testWidgets('a refund shows as Crate refund', (tester) async {
    await pump(tester, withRefund: true);
    expect(find.textContaining('Crate refund'), findsOneWidget);
    expect(find.textContaining('Crate deposit'), findsOneWidget);
    await disposeScreen(tester);
  });

  testWidgets('the 720 cap centres the list on a wide screen', (tester) async {
    await pump(tester, size: const Size(1280, 800), padding: EdgeInsets.zero);
    final card = tester.getRect(
      find.byKey(quickSaleApprovalCardKey('req-quick-1')),
    );
    expect(card.width, lessThanOrEqualTo(720));
    expect((card.center.dx - 640).abs(), lessThan(60));
    await disposeScreen(tester);
  });

  // The keyboard opens on the whole view, so the pop-up (which sits above the
  // screen) feels it too: set it on tester.view, not through the harness.
  const phones = <(String, Size, double)>[
    ('390x844', Size(390, 844), 340),
    ('360x640', Size(360, 640), 280),
  ];
  for (final (name, size, keyboard) in phones) {
    testWidgets('reject-reason pop-up fits above the keyboard $name', (
      tester,
    ) async {
      await pump(
        tester,
        size: size,
        followView: true,
        textScaler: const TextScaler.linear(1.15),
      );
      await tester.tap(find.text('Ice Bag').first);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Reject').first);
      await tester.tap(find.text('Reject').first);
      await tester.pumpAndSettle();
      tester.view.viewInsets = FakeViewPadding(bottom: keyboard);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('approval-reject-reason')), findsOneWidget);
      expect(tester.takeException(), isNull);
      tester.view.resetViewInsets();
      await disposeScreen(tester);
    });

    testWidgets('crate deposit amount box fits above the keyboard $name', (
      tester,
    ) async {
      await pump(
        tester,
        size: size,
        followView: true,
        textScaler: const TextScaler.linear(1.15),
      );
      await tester.tap(find.textContaining('10 crates deposit'));
      await tester.pumpAndSettle();
      final box = find.byType(AppInput);
      await tester.ensureVisible(box);
      await tester.tap(box);
      tester.view.viewInsets = FakeViewPadding(bottom: keyboard);
      await tester.pumpAndSettle();
      expect(box, findsOneWidget);
      expect(tester.takeException(), isNull);
      tester.view.resetViewInsets();
      await disposeScreen(tester);
    });
  }
}
