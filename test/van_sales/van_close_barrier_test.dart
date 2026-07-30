// van_close_barrier_test.dart
//
// #208 item 5 (van-sales spec §7.4) — closing a trip while road sales are still
// stuck in this device's outbox.
//
// v1 warned and let Confirm through. This pins the stricter reading, and pins
// BOTH halves of it, because either alone is the wrong product:
//
//   · the primary "Confirm & close trip" is DISABLED while the outbox is dirty
//     — an un-pushed sale reads as a shortage, so the happy path would settle a
//     driver's liability on goods they sold and were paid for; and
//   · an explicit "Close anyway" override still reaches close. A hard block
//     would be worse than the defect: sync can be down for days (device DNS /
//     VPN, errno 7), and a trip that cannot close strands the van, the driver's
//     balance and the next dispatch.
//
// It also pins the honest limit from #145 — every string says "this device",
// because a device can read only its own `sync_queue`. Claiming the trip is
// complete would be a lie the app is not entitled to tell.
//
// Two levels: the barrier widget's own contract, then the real screen's wiring
// and dialog copy. Prior art: test/permissions/van_payment_gate_test.dart.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/industry/industry.dart';
import 'package:reebaplus_pos/core/industry/lexicon.dart';
import 'package:reebaplus_pos/core/permissions/gate.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/business_scoped_stream.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/van_sales/van_trip_position.dart';
import 'package:reebaplus_pos/features/van_sales/screens/van_reconcile_screen.dart';
import 'package:reebaplus_pos/features/van_sales/widgets/van_close_barrier.dart';

GateContext _ctx({Set<String> keys = const {}, int? rank}) =>
    GateContext(grantedKeys: keys, roleRank: rank, isReady: true);

GateContext _managerCtx() =>
    _ctx(keys: {'van.manage', 'van.sell'}, rank: GateTier.manager);

/// The Driver role as seeded (#140) — holds `van.sell`, never `van.manage`.
GateContext _driverCtx() =>
    _ctx(keys: {'van.sell', 'sales.create'}, rank: GateTier.driver);

VanTripData _trip() => VanTripData(
  id: 'trip-1',
  businessId: 'biz',
  vanStoreId: 'van',
  driverUserId: 'driver',
  sourceStoreId: 'wh',
  status: kVanTripStatusOpen,
  openedAt: DateTime(2026, 7, 30),
  openedBy: 'mgr',
  closedAt: null,
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
  createdAt: DateTime(2026, 7, 30),
  lastUpdatedAt: DateTime(2026, 7, 30),
);

/// A settled position — so nothing on the screen but the outbox can be the
/// reason Confirm is unavailable.
VanTripPosition _settledPosition() => const VanTripPosition(
  loadedUnits: 10,
  soldUnits: 10,
  goodReturnedUnits: 0,
  damagedUnits: 0,
  shortageUnits: 0,
  loadedValueKobo: 1000000,
  soldValueKobo: 1000000,
  rungValueKobo: 1000000,
  goodReturnValueKobo: 0,
  damageValueKobo: 0,
  shortageValueKobo: 0,
  remittedKobo: 1000000,
  shortageWriteoffKobo: 0,
  damageWriteoffKobo: 0,
  balanceKobo: 0,
  outstandingKobo: 0,
  unremittedCashKobo: 0,
  shortageOwedKobo: 0,
  damageOwedKobo: 0,
  residualCreditKobo: 0,
  loadedCostKobo: 800000,
  goodReturnCostKobo: 0,
  cogsKobo: 800000,
  shortageLossKobo: 0,
  damageLossKobo: 0,
  recoveredKobo: 1000000,
  profitKobo: 200000,
  shellsOut: 0,
  shellsBack: 0,
  shortages: [],
);

Finder _primary() => find.widgetWithText(FilledButton, 'Confirm & close trip');

bool _isEnabled(WidgetTester tester, Finder f) =>
    tester.widget<FilledButton>(f).onPressed != null;

void main() {
  group('VanCloseBarrier — the contract', () {
    late int closes;

    setUp(() => closes = 0);

    Future<void> pumpBarrier(
      WidgetTester tester, {
      required int pending,
      GateContext? gate,
    }) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            gateContextProvider.overrideWithValue(gate ?? _managerCtx()),
          ],
          child: MaterialApp(
            theme: AppTheme.light(),
            home: Scaffold(
              body: VanCloseBarrier(
                pendingSales: pending,
                lex: lexiconFor(Industry.beverage),
                onClose: () => closes++,
              ),
            ),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('a clean outbox leaves the ordinary primary path alone', (
      tester,
    ) async {
      await pumpBarrier(tester, pending: 0);

      expect(_primary(), findsOneWidget);
      expect(_isEnabled(tester, _primary()), isTrue);
      expect(
        find.text('Close anyway'),
        findsNothing,
        reason: 'the override is not offered when there is nothing to override',
      );
      expect(find.textContaining('waiting to sync'), findsNothing);

      await tester.tap(_primary());
      await tester.pump();
      expect(closes, 1);
    });

    testWidgets('a dirty outbox disables the primary and says why', (
      tester,
    ) async {
      await pumpBarrier(tester, pending: 3);

      expect(
        _isEnabled(tester, _primary()),
        isFalse,
        reason:
            'spec §7.4 stricter reading — the happy path must not settle a '
            'driver\'s liability on goods that simply have not synced',
      );

      // #145's honest limit: this device, never a claim about the driver's.
      expect(
        find.textContaining('waiting to sync from this device'),
        findsOneWidget,
      );
      expect(find.textContaining('3 road sales'), findsOneWidget);
    });

    testWidgets('the override still reaches close', (tester) async {
      await pumpBarrier(tester, pending: 3);

      expect(find.text('Close anyway'), findsOneWidget);
      await tester.tap(find.text('Close anyway'));
      await tester.pump();

      expect(
        closes,
        1,
        reason:
            'a hard block would be worse than the defect — sync can be down '
            'for days and a trip must never become un-closable',
      );
    });

    testWidgets('a driver is offered neither control', (tester) async {
      await pumpBarrier(tester, pending: 3, gate: _driverCtx());

      expect(_primary(), findsNothing);
      expect(
        find.text('Close anyway'),
        findsNothing,
        reason:
            'hide, don\'t disable (hard rule #7) — the disabled primary is a '
            'DATA state and must not be mistaken for a permission one',
      );
      // The caveat itself is not a gated action, so it stays readable.
      expect(find.textContaining('waiting to sync from this device'),
          findsOneWidget);
    });
  });

  group('VanReconcileScreen — the wiring and the confirmation', () {
    Future<void> pumpScreen(WidgetTester tester, {required int pending}) async {
      // The screen is a ListView; a default 800×600 surface leaves the close
      // controls unbuilt below the fold. Give it room rather than scrolling.
      tester.view.physicalSize = const Size(1000, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            gateContextProvider.overrideWithValue(_managerCtx()),
            // No business bound ⇒ every business-scoped feed emits its
            // `whenAbsent` value without reaching for a database.
            currentBusinessIdProvider.overrideWithValue(null),
            currentBusinessProvider.overrideWith((ref) => null),
            vanTripProvider('trip-1').overrideWith(
              (ref) => Stream.value(_trip()),
            ),
            vanTripPositionProvider('trip-1').overrideWith(
              (ref) => Stream.value(_settledPosition()),
            ),
            vanTripPendingSalesProvider('trip-1').overrideWith(
              (ref) => Stream.value(pending),
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
      await tester.pumpAndSettle();
    }

    testWidgets('a clean outbox confirms with the ordinary dialog', (
      tester,
    ) async {
      await pumpScreen(tester, pending: 0);

      expect(_isEnabled(tester, _primary()), isTrue);
      await tester.tap(_primary());
      await tester.pumpAndSettle();

      expect(find.text('Close this trip?'), findsOneWidget);
      expect(find.text('Not yet'), findsOneWidget);
      expect(find.text('Close trip'), findsOneWidget);
      expect(find.textContaining('incomplete picture'), findsNothing);
    });

    testWidgets(
      'a dirty outbox routes the override through a risk-naming confirmation',
      (tester) async {
        await pumpScreen(tester, pending: 2);

        expect(_isEnabled(tester, _primary()), isFalse);

        await tester.tap(find.text('Close anyway'));
        await tester.pumpAndSettle();

        expect(find.text('Close on an incomplete picture?'), findsOneWidget);
        expect(
          find.textContaining('2 road sales have not synced from this device'),
          findsOneWidget,
          reason:
              'the risk is named in the manager\'s own words, and scoped to '
              'this device (#145) rather than claiming global knowledge',
        );
        // The affirmative action agrees to the risk; it does not dismiss a
        // notice.
        expect(
          find.widgetWithText(FilledButton, 'Close anyway'),
          findsOneWidget,
        );
        expect(find.text('Wait for sync'), findsOneWidget);
        expect(find.text('Close trip'), findsNothing);
      },
    );

    testWidgets('Wait for sync backs out without closing', (tester) async {
      await pumpScreen(tester, pending: 2);

      await tester.tap(find.text('Close anyway'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Wait for sync'));
      await tester.pumpAndSettle();

      expect(find.text('Close on an incomplete picture?'), findsNothing);
      // Back on the screen, still blocked — backing out changes nothing.
      expect(_isEnabled(tester, _primary()), isFalse);
      expect(find.text('Close anyway'), findsOneWidget);
    });
  });
}
