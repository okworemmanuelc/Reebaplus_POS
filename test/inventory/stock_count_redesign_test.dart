// #392 PR 3 (Wave 2 A): the restyled Stock Count keeps every control and
// permission rule, saves the same count, holds its content at every redesign
// viewport (and with the keyboard up in the count boxes and the Record
// Damages sheet) and caps its content at 720.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/permissions/gate.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/features/inventory/screens/stock_count_screen.dart';
import 'package:reebaplus_pos/features/inventory/widgets/inventory_parts.dart';

import '../helpers/inventory_seed.dart';
import '../helpers/screen_harness.dart';

const _grants = {...kInventorySampleGrants};

const _gesture = FakeViewPadding(top: 24, bottom: 24);
const _sideways = FakeViewPadding(top: 24, right: 48);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ScreenTestEnvironment env;
  late InventorySample sample;

  setUp(() async {
    env = await setupScreenTestEnvironment(
      productCount: 0,
      businessName: 'Stallion Global',
      businessType: 'Beverage distributor',
    );
    sample = await seedInventorySample(env);
  });

  tearDown(() => env.dispose());

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 200));
    }
  }

  Future<void> pump(
    WidgetTester tester, {
    Size size = const Size(390, 844),
    FakeViewPadding insets = _gesture,
    Set<String> grants = _grants,
    String roleSlug = 'ceo',
    int roleRank = GateTier.ceo,
    TextScaler? textScaler,
  }) async {
    tester.view.padding = insets;
    tester.view.viewPadding = insets;
    addTearDown(tester.view.resetPadding);
    addTearDown(tester.view.resetViewPadding);
    addTearDown(tester.view.resetViewInsets);
    await pumpScreen(
      tester,
      env: env,
      size: size,
      screen: StockCountScreen(storeId: env.storeId),
      followView: true,
      settle: false,
      grantedKeys: grants,
      // A pinned business day: the real provider schedules a day-roll timer.
      overrides: [
        todaysBusinessDateProvider.overrideWith((ref) async => '2026-10-01'),
      ],
      roleSlug: roleSlug,
      roleRank: roleRank,
      textScaler: textScaler,
    );
    await settle(tester);
  }

  void expectTarget(WidgetTester tester, Finder f) {
    final size = tester.getSize(f);
    expect(size.width, greaterThanOrEqualTo(kMinInteractiveDimension));
    expect(size.height, greaterThanOrEqualTo(kMinInteractiveDimension));
  }

  group('renders its controls', () {
    testWidgets('top bar, store name, column labels, rows and Save Count', (
      tester,
    ) async {
      await pump(tester);
      expect(find.byType(InventoryTopBar), findsOneWidget);
      expect(find.text('Daily Stock Count'), findsOneWidget);
      expect(find.text('Abuja HQ'), findsOneWidget);
      for (final label in const ['PRODUCT', 'SYSTEM', 'ACTUAL', 'DIFF']) {
        expect(find.text(label), findsOneWidget, reason: label);
      }
      expect(find.text('Star Lager'), findsOneWidget);
      expect(find.text('Save Count'), findsOneWidget);
      expect(
        find.byKey(const Key('stock_count_record_damages_button')),
        findsOneWidget,
      );
      expect(find.byTooltip('View History'), findsOneWidget);
      await disposeScreen(tester);
    });

    testWidgets('back, both actions and the count boxes are 48dp targets', (
      tester,
    ) async {
      await pump(tester);
      expectTarget(tester, find.byTooltip('Back'));
      expectTarget(tester, find.byTooltip('Record Damages'));
      expectTarget(tester, find.byTooltip('View History'));
      expectTarget(tester, find.byType(TextField).first);
      await disposeScreen(tester);
    });
  });

  testWidgets('a cashier is shown the no-access state, not the count', (
    tester,
  ) async {
    await pump(
      tester,
      grants: {..._grants}..remove('stock.adjust'),
      roleSlug: 'cashier',
      roleRank: GateTier.cashier,
    );
    expect(find.text('You don’t have access to stock counts.'), findsOneWidget);
    expect(find.text('Save Count'), findsNothing);
    expect(find.byType(TextField), findsNothing);
    await disposeScreen(tester);
  });

  group('the count', () {
    testWidgets('typing a count shows the difference; Back keeps editing', (
      tester,
    ) async {
      await pump(tester);
      final unchanged = find.text('—').evaluate().length;
      await tester.enterText(find.byType(TextField).first, '999');
      await tester.pump();
      expect(find.text('—').evaluate().length, unchanged - 1);
      await tester.tap(find.text('Save Count'));
      await tester.pumpAndSettle();
      expect(find.text('Review Count'), findsOneWidget);
      expect(find.text('1 adjusted'), findsOneWidget);
      await tester.tap(find.text('Back'));
      await tester.pumpAndSettle();
      expect(find.text('Review Count'), findsNothing);
      expect(find.text('Save Count'), findsOneWidget);
      await disposeScreen(tester);
    });

    testWidgets('Confirm & Save Count adjusts the stock and saves a session', (
      tester,
    ) async {
      // The harness's signed-in user is the one who performs the adjustment.
      await tester.runAsync(
        () => env.db.customStatement(
          "INSERT INTO users (id, business_id, name, pin) VALUES "
          "('test-user-id', '${env.businessId}', 'Test User', '123456')",
        ),
      );
      await pump(tester);
      final first = find.byType(TextField).first;
      final before = tester.widget<TextField>(first).controller!.text;
      final target = (int.parse(before) + 2).toString();
      await tester.enterText(first, target);
      await tester.pump();
      await tester.tap(find.text('Save Count'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Confirm & Save Count'));
      await settle(tester);
      final counts = await tester.runAsync(
        () => env.db.stockCountsDao.watchAllForBusiness().first,
      );
      expect(counts, hasLength(1));
      expect(counts!.single.surplusCount, 1);
      // Let the "Count saved" toast time out.
      await tester.pump(const Duration(seconds: 5));
      await disposeScreen(tester);
    });

    testWidgets('a matched count reads "All products matched"', (tester) async {
      await pump(tester);
      await tester.tap(find.text('Save Count'));
      await tester.pumpAndSettle();
      expect(find.text('All products matched'), findsOneWidget);
      await disposeScreen(tester);
    });
  });

  group('sheets', () {
    testWidgets('Count History lists a saved day and opens it', (tester) async {
      await tester.runAsync(
        () => env.db.stockCountsDao.recordCount(
          storeId: env.storeId,
          businessDate: '2026-10-01',
          productsCounted: 6,
          changedLines: [
            {
              'p': sample.productIds['Gulder'],
              'n': 'Gulder',
              's': 4,
              'a': 3,
              'd': -1,
            },
          ],
          countedBy: sample.staffId,
        ),
      );
      await pump(tester);
      await tester.tap(find.byTooltip('View History'));
      await settle(tester);
      expect(find.text('Count History'), findsOneWidget);
      expect(find.text('Oct 1, 2026'), findsOneWidget);
      expect(find.text('1 count · 1 short'), findsOneWidget);
      await tester.tap(find.text('Oct 1, 2026'));
      await tester.pumpAndSettle();
      expect(find.text('Saved counts'), findsOneWidget);
      expect(find.text('4 → 3'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await disposeScreen(tester);
    });

    testWidgets('Count History with nothing saved says so', (tester) async {
      await pump(tester);
      await tester.tap(find.byTooltip('View History'));
      await settle(tester);
      expect(find.text('No history yet'), findsOneWidget);
      await disposeScreen(tester);
    });
  });

  group('layout', () {
    for (final (name, size, insets, scale)
        in <(String, Size, FakeViewPadding, double)>[
          ('360x740 @1.3', const Size(360, 740), _gesture, 1.3),
          ('390x844', const Size(390, 844), _gesture, 1.0),
          ('844x390 insets', const Size(844, 390), _sideways, 1.0),
          ('800x1280', const Size(800, 1280), _gesture, 1.0),
          ('1280x800', const Size(1280, 800), FakeViewPadding(top: 24), 1.0),
        ]) {
      testWidgets('no overflow at $name, review sheet included', (
        tester,
      ) async {
        await pump(
          tester,
          size: size,
          insets: insets,
          textScaler: TextScaler.linear(scale),
        );
        expect(tester.takeException(), isNull);
        await tester.enterText(find.byType(TextField).first, '99');
        await tester.pump();
        await tester.tap(find.text('Save Count'));
        await tester.pumpAndSettle();
        expect(find.text('Review Count'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await disposeScreen(tester);
      });
    }

    testWidgets('1280x800: rows cap at 720 and sit centred', (tester) async {
      await pump(
        tester,
        size: const Size(1280, 800),
        insets: const FakeViewPadding(top: 24),
      );
      final row = tester.getRect(
        find
            .ancestor(
              of: find.text('Star Lager'),
              matching: find.byType(Container),
            )
            .first,
      );
      expect(row.width, lessThanOrEqualTo(kInventoryMaxContentWidth + 1));
      expect(row.width, greaterThan(kInventoryMaxContentWidth - 40));
      await disposeScreen(tester);
    });
  });

  group('keyboard up', () {
    for (final (name, size, keyboard) in const <(String, Size, double)>[
      ('360x640', Size(360, 640), 280.0),
      ('390x844', Size(390, 844), 340.0),
    ]) {
      testWidgets('a count box fits above the keyboard at $name', (
        tester,
      ) async {
        await pump(
          tester,
          size: size,
          textScaler: const TextScaler.linear(1.15),
        );
        await tester.tap(find.byType(TextField).first);
        tester.view.viewInsets = FakeViewPadding(bottom: keyboard);
        await tester.pump();
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await disposeScreen(tester);
      });

      testWidgets('Record Damages sheet fits above the keyboard at $name', (
        tester,
      ) async {
        await pump(
          tester,
          size: size,
          textScaler: const TextScaler.linear(1.15),
        );
        await tester.tap(find.byTooltip('Record Damages'));
        await tester.pumpAndSettle();
        expect(find.text('Record Damages'), findsOneWidget);
        // The keyboard opens on the whole phone view, so the sheet feels it.
        tester.view.viewInsets = FakeViewPadding(bottom: keyboard);
        await tester.pump();
        await tester.pumpAndSettle();
        expect(find.text('Record Damage'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await disposeScreen(tester);
      });
    }

    testWidgets('Record Damages sheet fits sideways with the keyboard up', (
      tester,
    ) async {
      await pump(tester, size: const Size(844, 390), insets: _sideways);
      await tester.tap(find.byTooltip('Record Damages'));
      await tester.pumpAndSettle();
      tester.view.viewInsets = const FakeViewPadding(bottom: 180);
      await tester.pump();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await disposeScreen(tester);
    });
  });
}
