// van_sales_trade_neutral_test.dart
//
// Van sales must speak the tenant's trade, not the one the feature was built
// for (ADR 0015 — the Lexicon). Van sales shipped hardcoded to drinks: it asked
// a pharmacy to "Add a drink", captioned its shortage figure "Drinks
// unaccounted for", and put an "Empty crates" field on every load line of every
// business — including trades that deal in no crates at all.
//
// Two distinct rules, because they have two distinct fixes:
//
//   1. The ITEM NOUN is a Lexicon slot. Van sales sells the same catalogue the
//      shop does, so it must caption it with the same word the rest of the app
//      already uses — `Lexicon.item` / `itemPlural`, resolved from
//      `businesses.type`. Pinned twice: a source ban so no new "drink" string
//      creeps back in, and a rendered assertion that the words actually morph.
//
//   2. EMPTY CRATES are not a Lexicon slot and never will be — they are a
//      Bar/Beverage concept with no counterpart in a pharmacy. The fix is the
//      app-wide visibility gate `businessTracksCrates`, the same one the POS,
//      inventory and reconciliation surfaces use. So the crate surfaces must
//      disappear for a non-crate business and must SURVIVE for a crate one:
//      only asserting the first half would be passed by deleting the feature.
//
// The business is overridden and everything else derived, deliberately: the
// lexicon and the crate gate both hang off `currentBusinessProvider`, so
// swapping one row is the same single input a real tenant switch is.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/permissions/gate.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/business_scoped_stream.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/van_sales/van_trip_position.dart';
import 'package:reebaplus_pos/features/van_sales/screens/van_reconcile_screen.dart';

// ── Fixtures ────────────────────────────────────────────────────────────────

BusinessData _business({required String type}) => BusinessData(
  id: 'biz-1',
  name: 'Test Business',
  type: type,
  phone: null,
  email: null,
  logoUrl: null,
  timezone: 'Africa/Lagos',
  onboardingComplete: true,
  createdAt: DateTime.utc(2026, 1, 1),
  lastUpdatedAt: DateTime.utc(2026, 1, 1),
  ownerId: null,
  // Opted in — so for a non-crate TRADE the gate can only be closed by the
  // type, which is exactly the axis under test.
  tracksEmptyCrates: true,
  subscriptionStatus: 'active',
  subscriptionPlan: null,
  trialEndsAt: null,
  currentPeriodEnd: null,
);

GateContext _managerCtx() => const GateContext(
  grantedKeys: {'van.manage', 'van.sell'},
  roleRank: GateTier.manager,
  isReady: true,
);

VanTripData _trip({String status = kVanTripStatusOpen}) => VanTripData(
  id: 'trip-1',
  businessId: 'biz-1',
  vanStoreId: 'van-1',
  driverUserId: 'driver-1',
  sourceStoreId: 'wh-1',
  status: status,
  openedAt: DateTime(2026, 7, 26),
  openedBy: 'mgr',
  closedAt: status == kVanTripStatusOpen ? null : DateTime(2026, 7, 26, 18),
  closedBy: null,
  closedWithBalance: false,
  shellsOut: 20,
  shellsBack: 14,
  restatedAt: null,
  restatedReason: null,
  cogsKobo: 800000,
  recoveredKobo: 1150000,
  unremittedKobo: 0,
  shortageWriteoffKobo: 0,
  damageWriteoffKobo: 0,
  shortageLossKobo: 0,
  damageLossKobo: 0,
  profitKobo: 350000,
  createdAt: DateTime(2026, 7, 26),
  lastUpdatedAt: DateTime(2026, 7, 26),
);

/// A position with something in every bucket the screen captions: a shortage,
/// damage, uncosted units and a shell memo. Written out rather than computed so
/// each caption under test has a non-zero figure beside it.
VanTripPosition _position() => const VanTripPosition(
  loadedUnits: 100,
  soldUnits: 80,
  goodReturnedUnits: 10,
  damagedUnits: 5,
  shortageUnits: 5,
  loadedValueKobo: 11500000,
  soldValueKobo: 9200000,
  rungValueKobo: 9500000,
  goodReturnValueKobo: 1150000,
  damageValueKobo: 575000,
  shortageValueKobo: 575000,
  remittedKobo: 9200000,
  shortageWriteoffKobo: 0,
  damageWriteoffKobo: 0,
  balanceKobo: -1150000,
  outstandingKobo: 1150000,
  unremittedCashKobo: 0,
  shortageOwedKobo: 575000,
  damageOwedKobo: 575000,
  residualCreditKobo: 0,
  loadedCostKobo: 10000000,
  goodReturnCostKobo: 1000000,
  cogsKobo: 8000000,
  shortageLossKobo: 500000,
  damageLossKobo: 500000,
  uncostedUnits: 3,
  recoveredKobo: 11500000,
  profitKobo: 3500000,
  shellsOut: 20,
  shellsBack: 14,
  shortages: [
    VanShortageLine(
      productId: 'prod-1',
      units: 5,
      valueKobo: 575000,
      costKobo: 500000,
      loadPricesKobo: [115000],
    ),
  ],
);

/// A viewport tall enough to build every card at once.
///
/// The reconcile screen is a `ListView`, so anything below the fold is never
/// built and `find.text` cannot see it — on a default 800px surface the
/// shortage card, the shell memo and the uncosted disclosure all sit off-screen
/// and every assertion about them would pass vacuously.
void _useTallViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(1200, 4000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

Future<void> _pumpReconcile(
  WidgetTester tester, {
  required String businessType,
  String status = kVanTripStatusOpen,
}) async {
  _useTallViewport(tester);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        gateContextProvider.overrideWithValue(_managerCtx()),
        // No business bound ⇒ every OTHER business-scoped provider emits its
        // `whenAbsent` value without reaching for a database.
        currentBusinessIdProvider.overrideWithValue(null),
        // …but the business ROW is what the lexicon and the crate gate read,
        // and it is the single axis this test varies.
        currentBusinessProvider.overrideWith(
          (ref) => _business(type: businessType),
        ),
        vanTripProvider('trip-1').overrideWith(
          (ref) => Stream.value(_trip(status: status)),
        ),
        vanTripPositionProvider('trip-1').overrideWith(
          (ref) => Stream.value(_position()),
        ),
      ],
      child: MaterialApp(
        theme: AppTheme.light(),
        home: const VanReconcileScreen(
          tripId: 'trip-1',
          driverName: 'Driver Dan',
          vanName: 'Van 1',
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  // ── 1. The item noun ──────────────────────────────────────────────────────

  group('the item noun comes from the Lexicon, not the drinks trade', () {
    testWidgets('a pharmacy reads its own word on every captioned figure',
        (tester) async {
      await _pumpReconcile(tester, businessType: 'Pharmacy');

      expect(find.text('Medicines unaccounted for'), findsOneWidget);
      expect(find.text('Damaged medicines'), findsOneWidget);
      expect(find.text('Medicines that never came back'), findsOneWidget);
      expect(
        find.textContaining('Record what those medicines cost you'),
        findsOneWidget,
      );
    });

    testWidgets('a bar reads the same word the rest of its app uses',
        (tester) async {
      await _pumpReconcile(tester, businessType: 'Bar');

      // Beverage/Bar resolve to `item: 'Product'` — the ADR 0015 no-regression
      // rule keeps their product form saying "Product Name", so van sales now
      // agrees with inventory and the POS instead of saying "Drinks" alone.
      expect(find.text('Products unaccounted for'), findsOneWidget);
      expect(find.text('Products that never came back'), findsOneWidget);
    });

    testWidgets('the closed-trip artifact is captioned in trade words too',
        (tester) async {
      await _pumpReconcile(
        tester,
        businessType: 'Pharmacy',
        status: kVanTripStatusClosed,
      );

      expect(find.text('Cost of the medicines gone'), findsOneWidget);
    });

    testWidgets('no screen prints a drinks noun for a non-drinks trade',
        (tester) async {
      await _pumpReconcile(tester, businessType: 'Phone & Gadgets');

      for (final banned in ['Drinks', 'drinks', 'Drink', 'drink']) {
        expect(
          find.textContaining(banned),
          findsNothing,
          reason: 'a phone shop must never be shown "$banned"',
        );
      }
      // …and the trade's real word did render, so the assertion above is not
      // passing merely because the screen is empty.
      expect(find.text('Handsets unaccounted for'), findsOneWidget);
    });
  });

  // ── 2. The crate surfaces ─────────────────────────────────────────────────

  group('empty crates are gated, not translated', () {
    testWidgets('a pharmacy is never asked about crates it does not deal in',
        (tester) async {
      await _pumpReconcile(tester, businessType: 'Pharmacy');

      expect(find.text('Empty crates'), findsNothing);
      expect(find.textContaining('shells'), findsNothing);
      expect(find.textContaining('crate'), findsNothing);
    });

    testWidgets('a bar still gets its shell memo — the gate hides, not deletes',
        (tester) async {
      await _pumpReconcile(tester, businessType: 'Bar');

      expect(find.text('Empty crates'), findsOneWidget);
      expect(
        find.textContaining('Loaded with 20 shells, 14 came back'),
        findsOneWidget,
      );
      expect(
        find.textContaining('6 not returned'),
        findsOneWidget,
        reason: 'the whole point of the memo: 20 out, 14 back, 6 unaccounted',
      );
    });

    testWidgets('a crate-eligible trade that opted OUT sees no crate surface',
        (tester) async {
      // `businessTracksCrates` is BOTH halves — eligible type AND the opt-in.
      _useTallViewport(tester);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            gateContextProvider.overrideWithValue(_managerCtx()),
            currentBusinessIdProvider.overrideWithValue(null),
            currentBusinessProvider.overrideWith(
              (ref) => BusinessData(
                id: 'biz-1',
                name: 'Test Bar',
                type: 'Bar',
                phone: null,
                email: null,
                logoUrl: null,
                timezone: 'Africa/Lagos',
                onboardingComplete: true,
                createdAt: DateTime.utc(2026, 1, 1),
                lastUpdatedAt: DateTime.utc(2026, 1, 1),
                ownerId: null,
                tracksEmptyCrates: false,
                subscriptionStatus: 'active',
                subscriptionPlan: null,
                trialEndsAt: null,
                currentPeriodEnd: null,
              ),
            ),
            vanTripProvider('trip-1').overrideWith(
              (ref) => Stream.value(_trip()),
            ),
            vanTripPositionProvider('trip-1').overrideWith(
              (ref) => Stream.value(_position()),
            ),
          ],
          child: MaterialApp(
            theme: AppTheme.light(),
            home: const VanReconcileScreen(
              tripId: 'trip-1',
              driverName: 'Driver Dan',
              vanName: 'Van 1',
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('Empty crates'), findsNothing);
      // Still a bar, so the item noun is unaffected by the crate opt-out.
      expect(find.text('Products unaccounted for'), findsOneWidget);
    });
  });

  // ── 3. The source ban ─────────────────────────────────────────────────────

  group('no drinks noun is hardcoded into a van sales string', () {
    // Scope: the van sales feature plus the two core files that carry its
    // user-facing text. Comments are exempt — a comment saying "not drinks" is
    // documentation, not copy.
    const roots = [
      'lib/features/van_sales',
      'lib/core/van_sales',
    ];
    const extraFiles = ['lib/core/database/daos_van_sales.dart'];

    // Word-boundary so "drinking" or a product literally named in a fixture is
    // still caught, but `shrink`/`sprinkle` are not.
    final bannedInString = RegExp(r'''(['"])[^'"]*\bdrinks?\b''',
        caseSensitive: false);

    test('every user-visible string is trade-neutral or Lexicon-driven', () {
      final leaks = <String>[];
      final files = [
        for (final root in roots) ..._dartFilesUnder(root),
        for (final path in extraFiles)
          if (File(path).existsSync()) File(path),
      ];

      expect(
        files,
        isNotEmpty,
        reason: 'the ban must actually be scanning something',
      );

      for (final file in files) {
        if (file.path.endsWith('.g.dart')) continue;
        final lines = file.readAsStringSync().split('\n');
        for (var i = 0; i < lines.length; i++) {
          final trimmed = lines[i].trimLeft();
          if (trimmed.startsWith('//') || trimmed.startsWith('*')) continue;
          if (bannedInString.hasMatch(lines[i])) {
            leaks.add('${file.path}:${i + 1}  ${trimmed.trim()}');
          }
        }
      }

      expect(
        leaks,
        isEmpty,
        reason:
            'Van sales sells whatever the tenant sells. Caption the item with '
            '`ref.watch(industryLexiconProvider)` — `lex.item`, `lex.itemLower`, '
            '`lex.itemPlural`, `lex.itemPluralLower` (ADR 0015) — rather than a '
            'drinks noun:\n  ${leaks.join('\n  ')}',
      );
    });
  });
}

List<File> _dartFilesUnder(String dir) {
  final d = Directory(dir);
  if (!d.existsSync()) return const [];
  return d
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart'))
      .toList();
}
