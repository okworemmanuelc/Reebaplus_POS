// Home screen restyle (#374, PRD #346 Wave 1): cards and order per role,
// trend pills, columns per size, the period pill + Custom, Reports and its
// dot, both Customer Credits forms, Staff Sales, the loading and zero-stores
// states, text scale 1.3, 48dp tap targets and the safe area with realistic
// system insets (sideways: top 24 + right 48; upright: bottom 48).

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/permissions/permissions.dart';
import 'package:reebaplus_pos/core/providers/first_run_surface_state.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/features/dashboard/get_started_checklist.dart';
import 'package:reebaplus_pos/features/dashboard/reports_attention.dart';
import 'package:reebaplus_pos/features/dashboard/screens/home_screen.dart';
import 'package:reebaplus_pos/features/dashboard/widgets/home_parts.dart';
import 'package:reebaplus_pos/shared/widgets/first_run_empty_state.dart';
import 'package:reebaplus_pos/shared/widgets/menu_button.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/redesign.dart';

import '../helpers/screen_harness.dart';

const _sideways = Size(844, 390);
const _upright = Size(390, 844);
const _sidewaysInsets = EdgeInsets.only(top: 24, right: 48);
const _uprightInsets = EdgeInsets.only(bottom: 48);

const _allKeys = {
  'reports.see_sales',
  'reports.see_profit',
  'reports.see_expenses',
  'stock.view',
  'customers.add',
  'sales.make',
};

typedef _Role = ({String slug, String name, int rank, Set<String> keys});

const _ceo = (slug: 'ceo', name: 'CEO', rank: GateTier.ceo, keys: _allKeys);
const _manager = (
  slug: 'manager',
  name: 'Manager',
  rank: GateTier.manager,
  keys: _allKeys,
);
const _cashier = (
  slug: 'cashier',
  name: 'Cashier',
  rank: GateTier.cashier,
  keys: {'reports.see_sales', 'customers.add', 'sales.make'},
);
const _stockKeeper = (
  slug: 'stock_keeper',
  name: 'Stock keeper',
  rank: GateTier.stockKeeper,
  keys: {'stock.view'},
);

const _cardKeys = [
  HomeKeys.sales,
  HomeKeys.profit,
  HomeKeys.pending,
  HomeKeys.expenses,
  HomeKeys.stockValue,
  HomeKeys.credits,
  HomeKeys.skus,
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ScreenTestEnvironment env;

  setUp(() async {
    env = await setupScreenTestEnvironment(
      productCount: 3,
      manufacturerCount: 1,
    );
  });

  tearDown(() => env.dispose());

  Future<void> deliver(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 250));
    }
  }

  Future<void> pumpHome(
    WidgetTester tester, {
    _Role role = _ceo,
    Size size = _upright,
    EdgeInsets padding = _uprightInsets,
    TextScaler? textScaler,
    bool dot = false,
    bool zeroStores = false,
    bool doDeliver = true,
    bool getStarted = false,
  }) async {
    tester.view.padding = FakeViewPadding(
      left: padding.left,
      top: padding.top,
      right: padding.right,
      bottom: padding.bottom,
    );
    addTearDown(tester.view.resetPadding);
    await pumpScreen(
      tester,
      env: env,
      size: size,
      padding: padding,
      screen: const HomeScreen(),
      grantedKeys: role.keys,
      roleSlug: role.slug,
      roleName: role.name,
      roleRank: role.rank,
      textScaler: textScaler,
      overrides: [
        reportsAttentionDotProvider.overrideWithValue(dot),
        zeroStoresEmptySurfaceProvider.overrideWithValue(zeroStores),
        // The CEO's Get-started card has its own tests; hidden unless asked
        // for so the cards under it are on screen.
        if (!getStarted)
          getStartedChecklistProvider.overrideWithValue(
            const GetStartedChecklistState(visible: false, steps: []),
          ),
      ],
      settle: false,
    );
    if (doDeliver) await deliver(tester);
  }

  /// One completed sale today (₦2,258 at cost ₦2,187 → ₦71 profit), sold by a
  /// named cashier, plus one pending order.
  Future<void> seedSales({int expenseKobo = 0}) async {
    final db = env.db;
    final b = env.businessId;
    final at = seedAnchorToday();
    final roleId = UuidV7.generate();
    await db
        .into(db.roles)
        .insert(
          RolesCompanion.insert(
            id: Value(roleId),
            businessId: b,
            name: 'Cashier',
            slug: 'cashier',
          ),
        );
    final staffId = UuidV7.generate();
    await db
        .into(db.users)
        .insert(
          UsersCompanion.insert(
            id: Value(staffId),
            businessId: b,
            name: 'Chidi Cashier',
            pin: '123456',
          ),
        );
    await db
        .into(db.userBusinesses)
        .insert(
          UserBusinessesCompanion.insert(
            id: Value(UuidV7.generate()),
            businessId: b,
            userId: staffId,
            roleId: roleId,
            status: const Value('active'),
          ),
        );
    for (final (i, status) in const ['completed', 'pending'].indexed) {
      final orderId = UuidV7.generate();
      await db
          .into(db.orders)
          .insert(
            OrdersCompanion.insert(
              id: Value(orderId),
              businessId: b,
              orderNumber: 'ORD-00000$i-HOME',
              totalAmountKobo: 225800,
              netAmountKobo: 225800,
              amountPaidKobo: const Value(225800),
              paymentType: 'cash',
              status: status,
              staffId: Value(staffId),
              storeId: Value(env.storeId),
              createdAt: Value(at),
            ),
          );
      if (status == 'completed') {
        await db
            .into(db.orderItems)
            .insert(
              OrderItemsCompanion.insert(
                id: Value(UuidV7.generate()),
                businessId: b,
                orderId: orderId,
                storeId: env.storeId,
                productId: Value(env.products.first.id),
                quantity: 1,
                unitPriceKobo: 225800,
                buyingPriceKobo: const Value(218700),
                totalKobo: 225800,
                createdAt: Value(at),
              ),
            );
      }
    }
    if (expenseKobo > 0) {
      await db
          .into(db.expenses)
          .insert(
            ExpensesCompanion.insert(
              id: Value(UuidV7.generate()),
              businessId: b,
              amountKobo: expenseKobo,
              description: 'Fuel',
              storeId: Value(env.storeId),
              expenseDate: Value(at),
              createdAt: Value(at),
            ),
          );
    }
  }

  List<Key> visibleCards() => [
    for (final k in _cardKeys)
      if (find.byKey(k).evaluate().isNotEmpty) k,
  ];

  StatusPill pillOf(Key card) => _widgetOf<StatusPill>(
    find.descendant(of: find.byKey(card), matching: find.byType(StatusPill)),
  );

  group('cards and order per role', () {
    final expected = <String, (_Role, List<Key>, bool staff, bool reports)>{
      'CEO': (
        _ceo,
        [
          HomeKeys.sales,
          HomeKeys.profit,
          HomeKeys.pending,
          HomeKeys.expenses,
          HomeKeys.stockValue,
          HomeKeys.credits,
        ],
        true,
        true,
      ),
      'Manager': (
        _manager,
        [
          HomeKeys.sales,
          HomeKeys.profit,
          HomeKeys.pending,
          HomeKeys.expenses,
          HomeKeys.stockValue,
          HomeKeys.credits,
        ],
        true,
        true,
      ),
      'Cashier': (
        _cashier,
        [HomeKeys.sales, HomeKeys.pending, HomeKeys.credits, HomeKeys.skus],
        false,
        false,
      ),
      'Stock keeper': (
        _stockKeeper,
        [HomeKeys.pending, HomeKeys.skus],
        false,
        false,
      ),
    };
    expected.forEach((name, spec) {
      final (role, cards, staff, reports) = spec;
      testWidgets('$name sees its cards in the mockup order', (tester) async {
        // Wide enough for every card in one view (3 columns).
        await pumpHome(
          tester,
          role: role,
          size: const Size(1280, 800),
          padding: EdgeInsets.zero,
        );
        expect(visibleCards(), cards);
        // Reading order: row by row, left to right.
        final tops = [for (final k in cards) tester.getTopLeft(find.byKey(k))];
        for (var i = 1; i < tops.length; i++) {
          final prev = tops[i - 1];
          final cur = tops[i];
          expect(
            cur.dy > prev.dy + 1 ||
                (cur.dy - prev.dy).abs() < 1 && cur.dx > prev.dx,
            isTrue,
            reason: '${cards[i]} should follow ${cards[i - 1]}',
          );
        }
        expect(
          find.byKey(HomeKeys.staffSales),
          staff ? findsOneWidget : findsNothing,
        );
        expect(
          find.byKey(HomeKeys.reportsPill),
          reports ? findsOneWidget : findsNothing,
        );
        await disposeScreen(tester);
      });
    });
  });

  group('trend pills', () {
    testWidgets('no data: No sales / N/A / Clear / None / Live', (
      tester,
    ) async {
      await pumpHome(
        tester,
        size: const Size(1280, 800),
        padding: EdgeInsets.zero,
      );
      expect(find.text('No sales'), findsOneWidget);
      expect(pillOf(HomeKeys.sales).tone, TagPillTone.neutral);
      // Same flags as before #374: "N/A" was drawn positive (green ↑).
      expect(pillOf(HomeKeys.profit).label, 'N/A');
      expect(pillOf(HomeKeys.profit).tone, TagPillTone.green);
      expect(find.textContaining('Add buying prices'), findsOneWidget);
      expect(pillOf(HomeKeys.pending).label, 'Clear');
      expect(pillOf(HomeKeys.pending).tone, TagPillTone.neutral);
      expect(pillOf(HomeKeys.expenses).label, 'None');
      expect(pillOf(HomeKeys.expenses).tone, TagPillTone.danger);
      expect(pillOf(HomeKeys.stockValue).label, 'Live');
      expect(pillOf(HomeKeys.stockValue).tone, TagPillTone.neutral);
      await disposeScreen(tester);
    });

    testWidgets('sales: Active / Positive / Attention', (tester) async {
      await seedSales();
      await pumpHome(
        tester,
        size: const Size(1280, 800),
        padding: EdgeInsets.zero,
      );
      expect(pillOf(HomeKeys.sales).label, 'Active');
      expect(pillOf(HomeKeys.sales).tone, TagPillTone.neutral);
      expect(pillOf(HomeKeys.profit).label, 'Positive');
      expect(pillOf(HomeKeys.profit).tone, TagPillTone.green);
      expect(pillOf(HomeKeys.pending).label, 'Attention');
      expect(pillOf(HomeKeys.pending).tone, TagPillTone.neutral);
      expect(
        find.text('Revenue minus cost of goods & expenses'),
        findsOneWidget,
      );
      await disposeScreen(tester);
    });

    testWidgets('a loss: Negative + Recorded are red', (tester) async {
      await seedSales(expenseKobo: 500000);
      await pumpHome(
        tester,
        size: const Size(1280, 800),
        padding: EdgeInsets.zero,
      );
      expect(pillOf(HomeKeys.profit).label, 'Negative');
      expect(pillOf(HomeKeys.profit).tone, TagPillTone.danger);
      expect(pillOf(HomeKeys.expenses).label, 'Recorded');
      expect(pillOf(HomeKeys.expenses).tone, TagPillTone.danger);
      await disposeScreen(tester);
    });

    test('homeTrendTone maps the old flags', () {
      expect(homeTrendTone(isNeutral: true), TagPillTone.neutral);
      expect(homeTrendTone(isPositive: true), TagPillTone.green);
      expect(homeTrendTone(isPositive: false), TagPillTone.danger);
    });
  });

  group('columns', () {
    test('homeGridColumns rule', () {
      expect(homeGridColumns(width: 358, landscape: false), 1);
      expect(homeGridColumns(width: 671, landscape: true), 3);
      expect(homeGridColumns(width: 675, landscape: false), 2);
      expect(homeGridColumns(width: 1023, landscape: false), 2);
      expect(homeGridColumns(width: 1024, landscape: false), 3);
      expect(homeGridColumns(width: 1155, landscape: true), 3);
      expect(homeGridColumns(width: 520, landscape: true), 2);
    });

    final cases = <String, (Size, EdgeInsets, int)>{
      '390x844': (_upright, _uprightInsets, 1),
      '844x390': (_sideways, _sidewaysInsets, 3),
      '800x1280': (const Size(800, 1280), _uprightInsets, 2),
      '1280x800': (const Size(1280, 800), EdgeInsets.zero, 3),
    };
    cases.forEach((name, spec) {
      final (size, padding, columns) = spec;
      testWidgets('$name → $columns column(s), rows share a height', (
        tester,
      ) async {
        await pumpHome(tester, size: size, padding: padding);
        final first = tester.getRect(find.byKey(HomeKeys.sales));
        final inRow = [
          for (final k in [HomeKeys.sales, HomeKeys.profit, HomeKeys.pending])
            tester.getRect(find.byKey(k)),
        ].where((r) => (r.top - first.top).abs() < 1).toList();
        expect(inRow.length, columns);
        for (final r in inRow) {
          expect(r.height, moreOrLessEquals(first.height, epsilon: 0.5));
        }
        await disposeScreen(tester);
      });
    });
  });

  group('titles fit (compact density)', () {
    // #374 review: at 844x390 the three-column titles were ellipsized
    // ("Pending Ord…"). Every stat-card title must paint in full, with the
    // widest pills each card can show.
    final sizes = <String, (Size, EdgeInsets)>{
      '844x390': (_sideways, EdgeInsets.zero),
      '844x390 + insets': (_sideways, _sidewaysInsets),
      '915x412 + insets': (const Size(915, 412), _sidewaysInsets),
      '800x1280': (const Size(800, 1280), _uprightInsets),
      '1280x800': (const Size(1280, 800), EdgeInsets.zero),
      '390x844': (_upright, _uprightInsets),
    };
    for (final expense in const [0, 500000]) {
      sizes.forEach((name, spec) {
        final (size, padding) = spec;
        testWidgets('$name, expense $expense: no title is truncated', (
          tester,
        ) async {
          await seedSales(expenseKobo: expense);
          await pumpHome(tester, size: size, padding: padding);
          final titles = {
            HomeKeys.sales: 'Total Sales',
            HomeKeys.profit: 'Net Profit',
            HomeKeys.pending: 'Pending Orders',
            HomeKeys.expenses: 'Total Expenses',
            HomeKeys.stockValue: 'Stock Value',
          };
          // The widest pills: "Attention" (a pending order), "Recorded" or
          // "Negative".
          expect(find.text('Attention'), findsOneWidget);
          titles.forEach((card, title) {
            final f = find.descendant(
              of: find.byKey(card),
              matching: find.text(title),
            );
            expect(f, findsOneWidget, reason: title);
            final p = tester.renderObject<RenderParagraph>(f);
            expect(p.didExceedMaxLines, isFalse, reason: '$title at $name');
          });
          expectNoOverflow(tester);
          await disposeScreen(tester);
        });
      });
    }

    testWidgets('compact only where the cards are narrow', (tester) async {
      StatCardDensity densityAt(WidgetTester t) => _widgetOf<StatCard>(
        find.descendant(
          of: find.byKey(HomeKeys.sales),
          matching: find.byType(StatCard),
          matchRoot: true,
        ),
      ).density;
      await pumpHome(tester);
      expect(densityAt(tester), StatCardDensity.regular);
      await disposeScreen(tester);
      await pumpHome(tester, size: _sideways, padding: _sidewaysInsets);
      expect(densityAt(tester), StatCardDensity.compact);
      await disposeScreen(tester);
      await pumpHome(
        tester,
        size: const Size(1280, 800),
        padding: EdgeInsets.zero,
      );
      expect(densityAt(tester), StatCardDensity.regular);
      await disposeScreen(tester);
    });
  });

  group('period pill and Reports', () {
    testWidgets('upright: period header above the cards with both pills', (
      tester,
    ) async {
      await pumpHome(tester);
      final header = find.byKey(HomeKeys.periodHeader);
      expect(
        find.descendant(of: header, matching: find.byKey(HomeKeys.periodPill)),
        findsOneWidget,
      );
      expect(
        find.descendant(of: header, matching: find.byKey(HomeKeys.reportsPill)),
        findsOneWidget,
      );
      expect(find.text('Performance Overview'), findsOneWidget);
      expect(
        tester.getTopLeft(header).dy,
        lessThan(tester.getTopLeft(find.byKey(HomeKeys.sales)).dy),
      );
      await disposeScreen(tester);
    });

    testWidgets('sideways: the pills move into the top bar before the bell', (
      tester,
    ) async {
      await pumpHome(tester, size: _sideways, padding: _sidewaysInsets);
      final bar = find.byKey(HomeKeys.topBar);
      final pill = find.descendant(
        of: bar,
        matching: find.byKey(HomeKeys.periodPill),
      );
      final reports = find.descendant(
        of: bar,
        matching: find.byKey(HomeKeys.reportsPill),
      );
      expect(pill, findsOneWidget);
      expect(reports, findsOneWidget);
      final bell = find.descendant(of: bar, matching: find.byType(HeaderBell));
      expect(
        tester.getTopLeft(pill).dx,
        lessThan(tester.getTopLeft(reports).dx),
      );
      expect(
        tester.getTopLeft(reports).dx,
        lessThan(tester.getTopLeft(bell).dx),
      );
      // "Performance Overview" + subtitle on one line under the bar.
      expect(
        tester.getTopLeft(find.text('Performance Overview')).dy,
        moreOrLessEquals(
          tester.getTopLeft(find.text('Analytics for the selected period')).dy,
          epsilon: 6,
        ),
      );
      await disposeScreen(tester);
    });

    testWidgets('choosing a period updates the cards', (tester) async {
      await pumpHome(
        tester,
        size: const Size(1280, 800),
        padding: EdgeInsets.zero,
      );
      expect(find.text('Generated from Today transactions'), findsOneWidget);
      await tester.tap(find.byKey(HomeKeys.periodPill));
      await tester.pumpAndSettle();
      for (final p in const [
        'Today',
        'This Week',
        'This Month',
        'This Year',
        'To Date',
        'Custom',
      ]) {
        expect(find.widgetWithText(PopupMenuItem<String>, p), findsOneWidget);
      }
      await tester.tap(find.widgetWithText(PopupMenuItem<String>, 'This Week'));
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byKey(HomeKeys.periodPill),
          matching: find.text('This Week'),
        ),
        findsOneWidget,
      );
      expect(find.textContaining('This Week'), findsWidgets);
      await disposeScreen(tester);
    });

    testWidgets('Custom opens the date range picker; cancel keeps the period', (
      tester,
    ) async {
      await pumpHome(
        tester,
        size: const Size(1280, 800),
        padding: EdgeInsets.zero,
      );
      await tester.tap(find.byKey(HomeKeys.periodPill));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(PopupMenuItem<String>, 'Custom'));
      await tester.pumpAndSettle();
      expect(find.byType(DateRangePickerDialog), findsOneWidget);
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      expect(find.byType(DateRangePickerDialog), findsNothing);
      expect(
        find.descendant(
          of: find.byKey(HomeKeys.periodPill),
          matching: find.text('Today'),
        ),
        findsOneWidget,
      );
      await disposeScreen(tester);
    });

    testWidgets('a cashier gets the short period list', (tester) async {
      await pumpHome(
        tester,
        role: _cashier,
        size: const Size(1280, 800),
        padding: EdgeInsets.zero,
      );
      await tester.tap(find.byKey(HomeKeys.periodPill));
      await tester.pumpAndSettle();
      expect(
        find.widgetWithText(PopupMenuItem<String>, 'This Year'),
        findsNothing,
      );
      expect(
        find.widgetWithText(PopupMenuItem<String>, 'Custom'),
        findsOneWidget,
      );
      await disposeScreen(tester);
    });

    testWidgets('Reports dot follows the attention signal', (tester) async {
      await pumpHome(tester, dot: true);
      expect(find.byKey(HomeKeys.reportsDot), findsOneWidget);
      await disposeScreen(tester);
      await pumpHome(tester);
      expect(find.byKey(HomeKeys.reportsDot), findsNothing);
      await disposeScreen(tester);
    });
  });

  group('Customer Credits', () {
    testWidgets('single column: the full card with Credit and Debt', (
      tester,
    ) async {
      await pumpHome(tester);
      expect(find.byKey(HomeKeys.creditsFull), findsOneWidget);
      expect(find.byKey(HomeKeys.creditsCompact), findsNothing);
      expect(find.text('Credit'), findsOneWidget);
      expect(find.text('Debt'), findsOneWidget);
      await disposeScreen(tester);
    });

    testWidgets('grid cell: compact, and both values stay visible', (
      tester,
    ) async {
      await pumpHome(tester, size: _sideways, padding: _sidewaysInsets);
      expect(find.byKey(HomeKeys.creditsCompact), findsOneWidget);
      expect(find.text('Credit and debt'), findsOneWidget);
      expect(find.text('Credit'), findsOneWidget);
      expect(find.text('Debt'), findsOneWidget);
      await disposeScreen(tester);
    });
  });

  group('Staff Sales', () {
    testWidgets('a row per staff member under the grid', (tester) async {
      await seedSales();
      await pumpHome(
        tester,
        size: const Size(1280, 800),
        padding: EdgeInsets.zero,
      );
      expect(find.text('Staff Sales'), findsOneWidget);
      expect(find.text('Chidi Cashier'), findsOneWidget);
      expect(
        tester.getTopLeft(find.byKey(HomeKeys.staffSales)).dy,
        greaterThan(tester.getBottomLeft(find.byKey(HomeKeys.credits)).dy),
      );
      await disposeScreen(tester);
    });

    testWidgets('empty text when nobody sold', (tester) async {
      await pumpHome(
        tester,
        size: const Size(1280, 800),
        padding: EdgeInsets.zero,
      );
      expect(
        find.text('No staff sales recorded for this period'),
        findsOneWidget,
      );
      await disposeScreen(tester);
    });
  });

  group('Total SKUs', () {
    testWidgets('tap opens the per-manufacturer breakdown', (tester) async {
      await pumpHome(
        tester,
        role: _cashier,
        size: const Size(1280, 800),
        padding: EdgeInsets.zero,
      );
      expect(find.byKey(HomeKeys.skuBreakdown), findsNothing);
      await tester.tap(find.text('Tap to see breakdown by manufacturer'));
      await tester.pump();
      expect(find.byKey(HomeKeys.skuBreakdown), findsOneWidget);
      expect(find.text('Unspecified'), findsOneWidget);
      await disposeScreen(tester);
    });
  });

  group('states', () {
    testWidgets('first load: no cards until the data arrives', (tester) async {
      await pumpHome(tester, doDeliver: false);
      expect(find.byType(StatCard), findsNothing);
      await deliver(tester);
      expect(find.byType(StatCard), findsWidgets);
      await disposeScreen(tester);
    });

    testWidgets('zero stores: the first-run empty state, no cards', (
      tester,
    ) async {
      await pumpHome(tester, zeroStores: true);
      expect(find.byType(FirstRunEmptyState), findsOneWidget);
      expect(find.byKey(HomeKeys.grid), findsNothing);
      await disposeScreen(tester);
    });
  });

  group('fit, tap targets and safe area', () {
    for (final (name, size, padding) in const [
      ('360x740', Size(360, 740), _uprightInsets),
      ('844x390', _sideways, _sidewaysInsets),
    ]) {
      testWidgets('text scale 1.3 at $name: no overflow', (tester) async {
        await seedSales();
        await pumpHome(
          tester,
          size: size,
          padding: padding,
          textScaler: const TextScaler.linear(1.3),
        );
        expectNoOverflow(tester);
        await tester.dragUntilVisible(
          find.byKey(HomeKeys.staffSales),
          find.byType(Scrollable).first,
          const Offset(0, -200),
        );
        await tester.pump();
        expectNoOverflow(tester);
        await disposeScreen(tester);
      });
    }

    for (final (name, size, padding) in const [
      ('390x844', _upright, _uprightInsets),
      ('844x390', _sideways, _sidewaysInsets),
      ('1280x800', Size(1280, 800), EdgeInsets.zero),
    ]) {
      testWidgets('every tap target is at least 48dp at $name', (tester) async {
        // With the CEO's Get-started card showing (its dismiss button too).
        await pumpHome(tester, size: size, padding: padding, getStarted: true);
        expect(find.text('Get started'), findsOneWidget);
        final targets = <Finder>[
          find.byKey(HomeKeys.periodPill),
          find.byKey(HomeKeys.reportsPill),
          find.byType(HeaderBell),
          for (final k in _cardKeys)
            if (find.byKey(k).evaluate().isNotEmpty) find.byKey(k),
        ];
        if (size.width < 600) {
          targets.add(find.byType(MenuButton));
        }
        for (final f in targets) {
          final s = tester.getSize(f);
          expect(
            s.width,
            greaterThanOrEqualTo(kMinInteractiveDimension),
            reason: '$f',
          );
          expect(
            s.height,
            greaterThanOrEqualTo(kMinInteractiveDimension),
            reason: '$f',
          );
        }
        await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
        await disposeScreen(tester);
      });
    }

    for (final (name, size, padding) in const [
      ('844x390', _sideways, _sidewaysInsets),
      ('915x412', Size(915, 412), _sidewaysInsets),
      ('390x844', _upright, _uprightInsets),
    ]) {
      testWidgets('inside the safe area at $name', (tester) async {
        await seedSales();
        await pumpHome(tester, size: size, padding: padding, dot: true);
        final safe = Rect.fromLTRB(
          padding.left,
          padding.top,
          size.width - padding.right,
          size.height - padding.bottom,
        );
        void inside(Finder f) {
          final r = tester.getRect(f);
          expect(
            r.left >= safe.left - 0.5 && r.right <= safe.right + 0.5,
            isTrue,
            reason: '$f at $r is outside $safe',
          );
          expect(r.top >= safe.top - 0.5, isTrue, reason: '$f at $r');
        }

        for (final f in [
          find.byKey(HomeKeys.periodPill),
          find.byKey(HomeKeys.reportsPill),
          find.byType(HeaderBell),
          find.text('Performance Overview'),
          find.byKey(HomeKeys.sales),
        ]) {
          inside(f);
        }
        // Scroll to the end: the last section sits fully on screen.
        await tester.dragUntilVisible(
          find.byKey(HomeKeys.staffSales),
          find.byType(Scrollable).first,
          const Offset(0, -200),
        );
        await tester.fling(
          find.byType(Scrollable).first,
          const Offset(0, -2000),
          3000,
        );
        await tester.pumpAndSettle();
        final staff = tester.getRect(find.byKey(HomeKeys.staffSales));
        inside(find.byKey(HomeKeys.staffSales));
        expect(staff.bottom, lessThanOrEqualTo(safe.bottom + 0.5));
        await disposeScreen(tester);
      });
    }
  });
}

T _widgetOf<T extends Widget>(Finder f) => f.evaluate().single.widget as T;
