// daily_reconciliation_detail_screen_test.dart
//
// #192 — the first widget coverage `DailyReconciliationDetailScreen` has ever
// had. Two halves, both of which #192 found broken and neither of which any test
// could see, because every existing day-close test stops at the pure compute.
//
// 1. THE SNAPSHOT TRIGGER. A day close is written once, by the first permitted
//    viewer of a FINISHED day, and it is first-writer-wins — so a write made too
//    early is not a stale figure, it is the permanent record. The four conditions
//    are pinned here: finished day, permission, data ready, one shot. The
//    readiness gate is the #192 fix: it used to name eight streams while the
//    frozen net profit also nets out three CRATE terms, so a Bar could freeze a
//    net profit missing them. The crate half is gated on the business's own
//    opt-in, so this also pins that a NON-crate business is never made to wait on
//    a crate stream it will never read.
//
// 2. WHAT A VIEWER IS TOLD. The banner used to promise "the flagged cards show
//    what moved" whenever ANY frozen figure moved — including figures that live
//    only on CEO cards. A Manager reviewing a day whose supplier payment was
//    backdated (US 35) therefore read that sentence with nothing flagged
//    anywhere. The banner is now worded from what was actually flagged, and the
//    Manager's own money card carries its own Expenses badge.
//
// The money math itself is pinned in `recon_day_close_delta_coverage_test.dart`;
// the snapshots here are hand-built rows, so these tests are about the SCREEN.

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/permissions/gate.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/business_scoped_stream.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/stores/van_store.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/shared/utils/role_display.dart';
import 'package:reebaplus_pos/features/dashboard/reconciliation/recon_data.dart';
import 'package:reebaplus_pos/features/dashboard/screens/daily_reconciliation_detail_screen.dart';

const _biz = 'biz-1';
const _store = 'store-1';
const _day = '2026-07-26';
final _dayStart = DateTime(2026, 7, 26);
final _dayEnd = DateTime(2026, 7, 27);

RoleData _role(String slug) => RoleData(
  id: 'role-$slug',
  businessId: _biz,
  name: slug,
  slug: slug,
  isSystemDefault: true,
  isDeleted: false,
  createdAt: DateTime.utc(2026, 1, 1),
  lastUpdatedAt: DateTime.utc(2026, 1, 1),
);

StoreData _storeRow() => StoreData(
  id: _store,
  businessId: _biz,
  name: 'Main Store',
  location: null,
  kind: kStoreKindStore,
  isDeleted: false,
  createdAt: DateTime.utc(2026, 1, 1),
  lastUpdatedAt: DateTime.utc(2026, 1, 1),
);

BusinessData _business({required bool crates}) => BusinessData(
  id: _biz,
  name: 'Mama Put Bar',
  // A Bar is crate-ELIGIBLE; the opt-in flag is the second half of the gate.
  type: crates ? 'bar' : 'pharmacy',
  timezone: 'Africa/Lagos',
  onboardingComplete: true,
  tracksEmptyCrates: crates,
  subscriptionStatus: 'active',
  createdAt: DateTime.utc(2026, 1, 1),
  lastUpdatedAt: DateTime.utc(2026, 1, 1),
);

/// A frozen day whose figures are all zero except the ones named — so a delta is
/// exactly the figure under test and nothing else can flag a card by accident.
DailyClosingData _snapshot({
  int totalSalesKobo = 0,
  int refundsKobo = 0,
  int expensesKobo = 0,
  int cashOutKobo = 0,
  int netCashMovementKobo = 0,
  String? reviewedBy,
}) {
  final ts = DateTime.utc(2026, 7, 27, 8);
  return DailyClosingData(
    id: 'snap-1',
    businessId: _biz,
    businessDate: _day,
    storeScopeId: null,
    totalSalesKobo: totalSalesKobo,
    refundsKobo: refundsKobo,
    discountsKobo: 0,
    cogsKobo: 0,
    grossProfitKobo: 0,
    netProfitKobo: 0,
    expensesKobo: expensesKobo,
    damagesCostKobo: 0,
    cashSalesKobo: 0,
    cashInKobo: 0,
    cashOutKobo: cashOutKobo,
    netCashMovementKobo: netCashMovementKobo,
    stockCogsKobo: 0,
    stockExpectedClosingKobo: 0,
    itemsSold: 0,
    shortageUnits: 0,
    reviewedBy: reviewedBy,
    reviewedAt: ts,
    createdAt: ts,
    lastUpdatedAt: ts,
  );
}

void main() {
  late AppDatabase db;

  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
  });

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    db.businessIdResolver = () => _biz;
    await db.customSelect('SELECT 1').get(); // force onCreate
    // `daily_closings` carries FKs to the business and the reviewer, so both
    // rows have to exist for the snapshot write to land at all.
    await db.into(db.businesses).insert(
          BusinessesCompanion.insert(
            id: const Value(_biz),
            name: 'Mama Put Bar',
            type: const Value('bar'),
          ),
        );
    await db.into(db.users).insert(
          UsersCompanion.insert(
            id: const Value('user-1'),
            businessId: _biz,
            name: 'Adaeze',
            pin: '__HASHED__',
          ),
        );
  });

  tearDown(() => db.close());

  /// Pumps the detail screen for [start]..[endExclusive].
  ///
  /// Every business-scoped feed is left on its `whenAbsent` value (no business
  /// bound) unless [overrides] replaces it, so a test names ONLY the streams it
  /// cares about — and a stream it wants to hold un-emitted it hands a
  /// never-completing one.
  Future<void> pumpDetail(
    WidgetTester tester, {
    required DateTime start,
    required DateTime endExclusive,
    String roleSlug = 'ceo',
    BusinessData? business,
    DailyClosingData? snapshot,
    List<Override> overrides = const [],
  }) async {
    // 375 logical px wide keeps `responsive.dart`'s `_scaleFactor` at 1.0 (it
    // keys off WIDTH only and pegs at its 1.5x cap on the 800px default
    // surface), and 2400 tall lets the whole card ListView lay out — a card
    // below the fold is still BUILT but offstage, and `find.text` skips offstage
    // by default, so its absence would be indistinguishable from a card that was
    // never rendered. See the 2026-07-27 BUILD_LOG entry.
    tester.view.physicalSize = const Size(375, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.runAsync(() async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            databaseProvider.overrideWithValue(db),
            // No business bound ⇒ every business-scoped feed emits its
            // `whenAbsent` value without reaching for the database.
            currentBusinessIdProvider.overrideWithValue(null),
            currentBusinessProvider
                .overrideWith((ref) => business ?? _business(crates: false)),
            currentUserRoleProvider.overrideWithValue(_role(roleSlug)),
            currentUserIdProvider.overrideWithValue('user-1'),
            // The gate seam, resolved from the SAME slug the screen reads its
            // role from — `Gates.dailyReconciliation` is Manager-up, so the rank
            // must track the slug or a test could pass for the wrong reason.
            gateContextProvider.overrideWithValue(
              GateContext(
                grantedKeys: const {},
                roleRank: roleRank(roleSlug),
                isReady: true,
              ),
            ),
            currencySymbolProvider.overrideWithValue('₦'),
            activeStoreLabelProvider.overrideWithValue('All Stores'),
            canViewAllStoresProvider.overrideWithValue(true),
            selectableStoresProvider.overrideWithValue([_storeRow()]),
            vanStoresProvider.overrideWithValue(VanStores.of([_storeRow()])),
            lockedStoreProvider.overrideWith(
              (ref) => ValueNotifier<String?>(null),
            ),
            dailyClosingForDayProvider.overrideWith(
              (ref, date) => Stream.value(snapshot),
            ),
            ...overrides,
          ],
          child: MaterialApp(
            theme: AppTheme.light(),
            home: DailyReconciliationDetailScreen(
              start: start,
              endExclusive: endExclusive,
              grouping: ReconGrouping.day,
              title: 'Sun, 26 Jul 2026',
            ),
          ),
        ),
      );
      // Let the stream feeds deliver and the deferred snapshot microtask (a real
      // database write) run to completion.
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 20));
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    await tester.pump();
  }

  /// A stream that never emits — the shape a not-yet-warm Drift query has.
  Stream<T> never<T>() => const Stream.empty().asBroadcastStream().cast<T>();

  group('the day-close snapshot trigger (#174, hardened by #192)', () {
    testWidgets('a finished day, opened by a Manager, freezes once',
        (tester) async {
      await pumpDetail(
        tester,
        start: _dayStart,
        endExclusive: _dayEnd,
        roleSlug: 'manager',
      );

      final row = await db.dailyClosingsDao.getForDay(_day);
      expect(row, isNotNull, reason: 'the first permitted open freezes the day');
      expect(row!.reviewedBy, 'user-1');
      expect(row.storeScopeId, isNull, reason: '#191 — business-wide by build');
    });

    testWidgets('an UNFINISHED day is never frozen', (tester) async {
      final tomorrow = DateTime.now().add(const Duration(days: 1));
      final dayStart = DateTime(tomorrow.year, tomorrow.month, tomorrow.day);

      await pumpDetail(
        tester,
        start: dayStart,
        endExclusive: dayStart.add(const Duration(days: 1)),
      );

      expect(
        await db.dailyClosingsDao.getForDay(
          '${dayStart.year.toString().padLeft(4, '0')}-'
          '${dayStart.month.toString().padLeft(2, '0')}-'
          '${dayStart.day.toString().padLeft(2, '0')}',
        ),
        isNull,
        reason: 'a day still running has no figures worth banking against',
      );
    });

    testWidgets('a viewer below Manager freezes nothing', (tester) async {
      await pumpDetail(
        tester,
        start: _dayStart,
        endExclusive: _dayEnd,
        roleSlug: 'cashier',
      );

      expect(
        await db.dailyClosingsDao.getForDay(_day),
        isNull,
        reason: 'the baseline is first-writer-wins, so it must never be set by '
            'someone the report is not even for',
      );
    });

    testWidgets('a still-loading source defers the write', (tester) async {
      await pumpDetail(
        tester,
        start: _dayStart,
        endExclusive: _dayEnd,
        overrides: [
          allOrdersProvider.overrideWith((ref) => never<List<OrderWithItems>>()),
        ],
      );

      expect(
        await db.dailyClosingsDao.getForDay(_day),
        isNull,
        reason: 'a mid-load compute reads a still-loading stream as EMPTY, and '
            'first-writer-wins would make those zeros the permanent record',
      );
    });

    testWidgets('re-opening a frozen day does not rewrite it', (tester) async {
      await pumpDetail(tester, start: _dayStart, endExclusive: _dayEnd);
      final first = await db.dailyClosingsDao.getForDay(_day);
      expect(first, isNotNull);

      await pumpDetail(tester, start: _dayStart, endExclusive: _dayEnd);
      final second = await db.dailyClosingsDao.getForDay(_day);

      expect(second!.reviewedAt, first!.reviewedAt);
      expect(
        await (db.select(db.dailyClosings)).get(),
        hasLength(1),
        reason: 'one durable record per business day (#191)',
      );
    });
  });

  group('the readiness gate covers the crate terms (#192 gap 5)', () {
    testWidgets('a crate business waits for the forfeit-income stream',
        (tester) async {
      await pumpDetail(
        tester,
        start: _dayStart,
        endExclusive: _dayEnd,
        business: _business(crates: true),
        overrides: [
          crateForfeitRowsProvider
              .overrideWith((ref) => never<List<WalletTransactionData>>()),
        ],
      );

      expect(
        await db.dailyClosingsDao.getForDay(_day),
        isNull,
        reason: 'kept crate deposits are ADDED to the frozen net profit — '
            'freezing before they load banks a profit that is short by them, '
            'permanently',
      );
    });

    testWidgets('a crate business waits for the damaged-empties ledger',
        (tester) async {
      await pumpDetail(
        tester,
        start: _dayStart,
        endExclusive: _dayEnd,
        business: _business(crates: true),
        overrides: [
          allCrateDamagesProvider
              .overrideWith((ref) => never<List<CrateLedgerData>>()),
        ],
      );

      expect(await db.dailyClosingsDao.getForDay(_day), isNull);
    });

    testWidgets('a crate business waits for the per-manufacturer deposit rates',
        (tester) async {
      await pumpDetail(
        tester,
        start: _dayStart,
        endExclusive: _dayEnd,
        business: _business(crates: true),
        overrides: [
          allManufacturersProvider
              .overrideWith((ref) => never<List<ManufacturerData>>()),
        ],
      );

      expect(await db.dailyClosingsDao.getForDay(_day), isNull);
    });

    testWidgets('a crate business with every source warm freezes normally',
        (tester) async {
      await pumpDetail(
        tester,
        start: _dayStart,
        endExclusive: _dayEnd,
        business: _business(crates: true),
      );

      expect(
        await db.dailyClosingsDao.getForDay(_day),
        isNotNull,
        reason: 'the gate must defer a mid-load write, not block the feature',
      );
    });

    testWidgets('a NON-crate business is not made to wait on a crate stream',
        (tester) async {
      await pumpDetail(
        tester,
        start: _dayStart,
        endExclusive: _dayEnd,
        business: _business(crates: false),
        overrides: [
          crateForfeitRowsProvider
              .overrideWith((ref) => never<List<WalletTransactionData>>()),
        ],
      );

      expect(
        await db.dailyClosingsDao.getForDay(_day),
        isNotNull,
        reason: 'the forfeit feed is read only behind the crate opt-in, so a '
            'pharmacy must neither open it nor be held up by it',
      );
    });
  });

  group('what the reviewed banner is allowed to promise (#192 gaps 1, 2, 4)',
      () {
    // US 35's shape, reduced to what the SCREEN has to do with it: the day was
    // frozen with ₦20,000 of cash going out, and the live day has none — so the
    // cash figures moved and nothing else did.
    DailyClosingData cashOnlyMove() => _snapshot(
      cashOutKobo: 2000000,
      netCashMovementKobo: -2000000,
    );

    testWidgets('a CEO gets the cash-flow card flagged', (tester) async {
      await pumpDetail(
        tester,
        start: _dayStart,
        endExclusive: _dayEnd,
        snapshot: cashOnlyMove(),
      );

      expect(find.textContaining('Net cash movement +'), findsOneWidget);
      expect(find.textContaining('Cash out −'), findsOneWidget);
      expect(
        find.textContaining('the flagged cards show what moved'),
        findsOneWidget,
      );
    });

    testWidgets('a Manager is told plainly that it is not on their cards',
        (tester) async {
      await pumpDetail(
        tester,
        start: _dayStart,
        endExclusive: _dayEnd,
        roleSlug: 'manager',
        snapshot: cashOnlyMove(),
      );

      expect(
        find.textContaining('Cash flow'),
        findsNothing,
        reason: 'the cash card is CEO-only (§25.3) — this is the premise',
      );
      expect(
        find.textContaining('the flagged cards show what moved'),
        findsNothing,
        reason: 'the banner pointed at flagged cards that were not on screen — '
            'the exact sentence #192 filed',
      );
      expect(
        find.textContaining('not on any card you can see here'),
        findsOneWidget,
      );
    });

    testWidgets("a Manager's own Expenses figure now carries its delta",
        (tester) async {
      await pumpDetail(
        tester,
        start: _dayStart,
        endExclusive: _dayEnd,
        roleSlug: 'manager',
        snapshot: _snapshot(expensesKobo: 750000),
      );

      expect(find.textContaining('Debts & expenses'), findsOneWidget);
      expect(
        find.textContaining('Expenses −'),
        findsOneWidget,
        reason: 'the card renders the frozen expensesKobo and rendered it with '
            'no delta at all before #192',
      );
      expect(
        find.textContaining('the flagged cards show what moved'),
        findsOneWidget,
        reason: 'now that a card IS flagged, the banner may point at it',
      );
    });

    testWidgets('a refund VOIDED after the review keeps its line on the card',
        (tester) async {
      // The reviewed day carried a ₦10,000 refund; the refund has since been
      // voided, so the live figure is 0 and the Sales card's Refunds line — which
      // renders only when the figure is non-zero — would have disappeared, taking
      // the explanation for its own badge with it.
      await pumpDetail(
        tester,
        start: _dayStart,
        endExclusive: _dayEnd,
        roleSlug: 'manager',
        snapshot: _snapshot(refundsKobo: 1000000),
      );

      expect(find.textContaining('Refunds −'), findsOneWidget,
          reason: 'the badge names the figure that moved');
      expect(
        find.text('Refunds'),
        findsOneWidget,
        reason: 'a badge must never point at a line the card stopped rendering',
      );
    });

    testWidgets('an unchanged reviewed day flags nothing and says so',
        (tester) async {
      await pumpDetail(
        tester,
        start: _dayStart,
        endExclusive: _dayEnd,
        roleSlug: 'manager',
        snapshot: _snapshot(),
      );

      expect(
        find.textContaining('The figures still match what was reviewed'),
        findsOneWidget,
      );
      expect(find.textContaining('since review'), findsNothing);
      expect(find.textContaining('changed'), findsNothing);
    });

    testWidgets('an unreviewed day renders no banner at all', (tester) async {
      await pumpDetail(
        tester,
        start: _dayStart,
        endExclusive: _dayEnd,
        roleSlug: 'cashier',
      );

      expect(find.textContaining('Reviewed'), findsNothing);
      expect(find.textContaining('still match what was reviewed'), findsNothing);
    });
  });
}
