// van_payment_gate_test.dart
//
// #144 (PRD #139 / ADR 0019, van-sales spec §9.5 edge case 21) — "a driver
// records their own payment" must be impossible, not merely inconvenient.
//
// The spec's wording is deliberate: *no surface, and the gate rejects it*. Both
// halves are tested here, because either alone is a soft guarantee — a hidden
// button is still reachable from a stale frame, and a gate nobody renders
// behind is a rule nobody obeys.
//
//   1. Gate algebra — `van.manage` grants, `van.sell` (the Driver role's only
//      van key) does not. A driver's tier sits BELOW stock keeper, so no
//      `tierAtLeast` fallback can let them in either.
//   2. `require()` at the write boundary — throws GateDeniedError for a driver.
//   3. The surface — DriverPaymentsScreen shows a driver the no-access body and
//      renders no Record-payment control.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/permissions/gate.dart';
import 'package:reebaplus_pos/core/permissions/gate_registry.dart';
import 'package:reebaplus_pos/core/permissions/guarded.dart';
import 'package:reebaplus_pos/core/providers/business_scoped_stream.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/features/van_sales/screens/driver_payments_screen.dart';

GateContext ctx({Set<String> keys = const {}, int? rank}) =>
    GateContext(grantedKeys: keys, roleRank: rank, isReady: true);

/// The Driver role as seeded (#140): `van.sell` and nothing else van-side.
GateContext driverCtx() =>
    ctx(keys: {'van.sell', 'sales.create'}, rank: GateTier.driver);

GateContext managerCtx() =>
    ctx(keys: {'van.manage', 'van.sell'}, rank: GateTier.manager);

VanTripData trip({String status = kVanTripStatusOpen}) => VanTripData(
  id: 'trip-1',
  businessId: 'biz',
  vanStoreId: 'van',
  driverUserId: 'driver',
  sourceStoreId: 'wh',
  status: status,
  openedAt: DateTime(2026, 7, 26),
  openedBy: 'mgr',
  closedAt: status == kVanTripStatusOpen ? null : DateTime(2026, 7, 26, 18),
  closedBy: null,
  closedWithBalance: false,
  shellsOut: 0,
  shellsBack: 0,
  restatedAt: null,
  restatedReason: null,
  cogsKobo: 0,
  recoveredKobo: 0,
  unremittedKobo: 0,
  shortageWriteoffKobo: 0,
  damageWriteoffKobo: 0,
  shortageLossKobo: 0,
  damageLossKobo: 0,
  profitKobo: 0,
  createdAt: DateTime(2026, 7, 26),
  lastUpdatedAt: DateTime(2026, 7, 26),
);

void main() {
  group('Gates.vanManage — the algebra', () {
    test('a manager holding van.manage is granted', () {
      expect(Gates.vanManage.rule.evaluate(managerCtx()), isTrue);
    });

    test('a Driver-role user is denied — van.sell is not van.manage', () {
      expect(
        Gates.vanManage.rule.evaluate(driverCtx()),
        isFalse,
        reason:
            'the whole point of two keys: a driver may sell from the van and '
            'may never touch the money side of it',
      );
      // …and they genuinely hold the selling key, so this is a real
      // discrimination between the two, not an empty permission set.
      expect(Gates.vanSell.rule.evaluate(driverCtx()), isTrue);
    });

    test('no tier fallback lets a driver in', () {
      // A driver ranks BELOW stock keeper, so even a hypothetical tier rule
      // would exclude them; and vanManage is key-based anyway.
      expect(GateTier.driver, greaterThan(GateTier.stockKeeper));
      expect(
        Gates.vanManage.rule.evaluate(ctx(rank: GateTier.ceo)),
        isFalse,
        reason: 'seniority alone does not grant van.manage — the key does',
      );
    });
  });

  group('require() at the remittance write boundary', () {
    late ProviderContainer container;
    final source = StateProvider<GateContext>((ref) => GateContext.unresolved);

    setUp(() {
      container = ProviderContainer(
        overrides: [
          gateContextProvider.overrideWith((ref) => ref.watch(source)),
        ],
      );
    });
    tearDown(() => container.dispose());

    Future<WidgetRef> pumpRef(WidgetTester tester, GateContext c) async {
      container.read(source.notifier).state = c;
      late WidgetRef out;
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: Consumer(
              builder: (_, ref, _) {
                out = ref;
                return const SizedBox();
              },
            ),
          ),
        ),
      );
      return out;
    }

    testWidgets('a driver is rejected, a manager is not', (tester) async {
      final driverRef = await pumpRef(tester, driverCtx());
      expect(
        () => Gates.vanManage.require(driverRef),
        throwsA(
          isA<GateDeniedError>().having(
            (e) => e.gateName,
            'gateName',
            'vanManage',
          ),
        ),
      );

      final managerRef = await pumpRef(tester, managerCtx());
      expect(() => Gates.vanManage.require(managerRef), returnsNormally);
    });
  });

  group('the surface — DriverPaymentsScreen', () {
    Future<void> pumpScreen(
      WidgetTester tester, {
      required GateContext gate,
      VanTripData? tripRow,
    }) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            gateContextProvider.overrideWithValue(gate),
            // No business bound ⇒ every business-scoped provider emits its
            // `whenAbsent` value without reaching for a database.
            currentBusinessIdProvider.overrideWithValue(null),
            if (tripRow != null)
              vanTripProvider('trip-1').overrideWith(
                (ref) => Stream.value(tripRow),
              ),
          ],
          // The real app theme: the screen reads the AppSemanticColors
          // extension, which only exists on it.
          child: MaterialApp(
            theme: AppTheme.light(),
            home: const DriverPaymentsScreen(
              tripId: 'trip-1',
              driverName: 'Driver Dan',
              vanName: 'Van 1',
            ),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('a driver sees the no-access body and no Record payment',
        (tester) async {
      await pumpScreen(tester, gate: driverCtx(), tripRow: trip());

      expect(find.text('No access'), findsOneWidget);
      expect(
        find.text('Record payment'),
        findsNothing,
        reason: 'hide-don\'t-block: a driver is never offered the control',
      );
      expect(find.text('Trip activity'), findsNothing);
    });

    testWidgets('a manager on an OPEN trip gets the Record payment control',
        (tester) async {
      await pumpScreen(tester, gate: managerCtx(), tripRow: trip());

      expect(find.text('No access'), findsNothing);
      expect(find.text('Record payment'), findsOneWidget);
      expect(find.text('Trip activity'), findsOneWidget);
    });

    testWidgets('a manager on a CLOSED trip is told why, not offered the form',
        (tester) async {
      await pumpScreen(
        tester,
        gate: managerCtx(),
        tripRow: trip(status: kVanTripStatusClosed),
      );

      expect(
        find.text('Record payment'),
        findsNothing,
        reason: 'a closed trip is never edited in place (spec §9.4 #16)',
      );
      expect(find.textContaining('This trip is closed'), findsOneWidget);
    });
  });
}
