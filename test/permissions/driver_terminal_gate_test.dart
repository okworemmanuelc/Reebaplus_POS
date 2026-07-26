// driver_terminal_gate_test.dart
//
// #142 (PRD #139 / ADR 0019, van-sales spec §9.2, §9.5 #21) — who gets the
// stripped driver terminal, and what a driver can still not reach from it.
//
// Two claims, and they pull in opposite directions, which is why both are here:
//
//   1. A NON-driver must never be routed into the terminal. `driverTerminalActive`
//      is the router's whole decision (main.dart returns DriverTerminalScreen
//      INSTEAD of MainLayout), so a false positive on a CEO would lock a business
//      owner out of their own app — a worse failure than the one the terminal
//      prevents. The discriminator is `van.sell AND NOT sales.make`: the seeded
//      Driver role holds only the first, a CEO holds both.
//   2. A DRIVER, once in the terminal, still cannot load a van, reconcile, or
//      record a payment. Those all sit behind `Gates.vanManage`, which a driver
//      does not hold — proven at the gate algebra AND at the write boundary,
//      because a hidden control is only a soft guarantee.
//
// The terminal's own screens are gated `Gates.vanSell`, so a live revocation
// empties them rather than leaving a stale sell surface open.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/permissions/gate.dart';
import 'package:reebaplus_pos/core/permissions/gate_registry.dart';
import 'package:reebaplus_pos/core/permissions/guarded.dart';
import 'package:reebaplus_pos/core/providers/business_scoped_stream.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/features/van_sales/screens/driver_run_screen.dart';

GateContext ctx({
  Set<String> keys = const {},
  int? rank,
  bool isReady = true,
}) => GateContext(grantedKeys: keys, roleRank: rank, isReady: isReady);

/// The Driver role exactly as the cloud seeds it (0161): `van.sell`, and no
/// `sales.make`.
GateContext driverCtx() => ctx(keys: {'van.sell'}, rank: GateTier.driver);

GateContext ceoCtx() => ctx(
  keys: {'van.sell', 'van.manage', 'sales.make'},
  rank: GateTier.ceo,
);

GateContext managerCtx() =>
    ctx(keys: {'van.manage', 'sales.make'}, rank: GateTier.manager);

GateContext cashierCtx() => ctx(keys: {'sales.make'}, rank: GateTier.cashier);

bool terminalFor(GateContext gate) {
  final container = ProviderContainer(
    overrides: [gateContextProvider.overrideWithValue(gate)],
  );
  addTearDown(container.dispose);
  return container.read(driverTerminalActiveProvider);
}

void main() {
  group('who lands on the driver terminal', () {
    test('a Driver-role user does', () {
      expect(terminalFor(driverCtx()), isTrue);
    });

    test('a CEO does NOT — they hold van.sell too, and would be locked out of '
        'their own business', () {
      expect(
        terminalFor(ceoCtx()),
        isFalse,
        reason:
            'holding van.sell is not the discriminator; NOT holding sales.make '
            'is. A CEO can sell in the shop, so they are not a driver.',
      );
    });

    test('a manager and a cashier do not', () {
      expect(terminalFor(managerCtx()), isFalse);
      expect(terminalFor(cashierCtx()), isFalse);
    });

    test('a user with neither key does not', () {
      expect(terminalFor(ctx(rank: GateTier.stockKeeper)), isFalse);
    });

    test('it fails CLOSED while permissions are still resolving', () {
      // The safe direction: a momentary ordinary shell is recoverable; a
      // momentary lock-out of an owner is alarming and looks like data loss.
      expect(terminalFor(GateContext.unresolved), isFalse);
      expect(
        terminalFor(ctx(keys: {'van.sell'}, rank: GateTier.driver,
            isReady: false)),
        isFalse,
      );
    });
  });

  group('a driver still cannot load, reconcile, or record a payment', () {
    test('the gate algebra denies vanManage', () {
      expect(Gates.vanSell.rule.evaluate(driverCtx()), isTrue);
      expect(
        Gates.vanManage.rule.evaluate(driverCtx()),
        isFalse,
        reason:
            'Load Van, the reconcile screen and Record Payment are all behind '
            'vanManage (spec §9.5 #21)',
      );
    });

    test('a driver cannot make an ordinary shop sale either', () {
      // Which is what makes routing them past MainLayout correct rather than
      // merely convenient: the shop POS would bounce them anyway.
      expect(Gates.makeSale.rule.evaluate(driverCtx()), isFalse);
    });

    testWidgets('require() throws at the vanManage write boundary',
        (tester) async {
      late WidgetRef ref;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [gateContextProvider.overrideWithValue(driverCtx())],
          child: MaterialApp(
            home: Consumer(
              builder: (_, r, _) {
                ref = r;
                return const SizedBox();
              },
            ),
          ),
        ),
      );

      expect(
        () => Gates.vanManage.require(ref),
        throwsA(
          isA<GateDeniedError>().having(
            (e) => e.gateName,
            'gateName',
            'vanManage',
          ),
        ),
      );
      expect(() => Gates.vanSell.require(ref), returnsNormally);
    });
  });

  group('the run view is read-only and vanSell-gated', () {
    Future<void> pumpRun(WidgetTester tester, GateContext gate) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            gateContextProvider.overrideWithValue(gate),
            // No business bound ⇒ every business-scoped provider emits its
            // `whenAbsent` value without touching a database.
            currentBusinessIdProvider.overrideWithValue(null),
          ],
          child: MaterialApp(
            theme: AppTheme.light(),
            home: const DriverRunScreen(tripId: 'trip-1'),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('a driver sees their run and no write control', (tester) async {
      await pumpRun(tester, driverCtx());

      expect(find.text('Taken on the road'), findsOneWidget);
      expect(find.text('Sales on this run'), findsOneWidget);
      // Nothing on this screen writes. These are the three van write actions;
      // none of them has a control here.
      expect(find.text('Record payment'), findsNothing);
      expect(find.text('Load van'), findsNothing);
      expect(find.text('Reconcile'), findsNothing);
    });

    testWidgets('a revoked driver gets the no-access body', (tester) async {
      await pumpRun(tester, ctx(rank: GateTier.driver));

      expect(find.text('No access'), findsOneWidget);
      expect(find.text('Taken on the road'), findsNothing);
    });
  });
}
