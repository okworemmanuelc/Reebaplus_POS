// Widget-seam tests for the Guarded contract (issue #17, ADR 0002). Exercised
// through the module's public surface: a GateContext goes in (via the module's
// own gateContextProvider seam), a UI consequence comes out — hide-while-loading,
// fallback, live revocation, the fire-time allow block, the screen guard's
// no-flash policy, and require() throwing. No internal widget structure asserted.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/permissions/gate.dart';
import 'package:reebaplus_pos/core/permissions/gate_registry.dart';
import 'package:reebaplus_pos/core/permissions/guarded.dart';
import 'package:reebaplus_pos/core/utils/notifications.dart';

/// Controllable source of the live gate context; the module's
/// [gateContextProvider] is overridden to read it, so a test can flip the
/// permission set mid-frame (live revocation).
final _source = StateProvider<GateContext>((ref) => GateContext.unresolved);

const _granted = GateContext(
  grantedKeys: {'stock.add'},
  roleRank: GateTier.stockKeeper,
  isReady: true,
);
const _deniedReady = GateContext(
  grantedKeys: {'sales.make'},
  roleRank: GateTier.cashier,
  isReady: true,
);

void main() {
  late ProviderContainer container;

  setUp(() {
    container = ProviderContainer(
      overrides: [
        gateContextProvider.overrideWith((ref) => ref.watch(_source)),
      ],
    );
  });

  tearDown(() {
    AppNotification.hide(); // cancel any pending dismiss timer
    container.dispose();
  });

  Widget host(Widget child) => UncontrolledProviderScope(
        container: container,
        child: MaterialApp(home: Scaffold(body: child)),
      );

  void setCtx(GateContext ctx) =>
      container.read(_source.notifier).state = ctx;

  group('Guarded (inline render + allow)', () {
    testWidgets('hides while permissions are still loading', (tester) async {
      setCtx(GateContext.unresolved);
      await tester.pumpWidget(host(
        Guarded(
          gate: Gates.receiveStock,
          builder: (_, __) => const Text('CHILD'),
        ),
      ));
      expect(find.text('CHILD'), findsNothing);
    });

    testWidgets('renders the child when granted', (tester) async {
      setCtx(_granted);
      await tester.pumpWidget(host(
        Guarded(
          gate: Gates.receiveStock,
          builder: (_, __) => const Text('CHILD'),
        ),
      ));
      expect(find.text('CHILD'), findsOneWidget);
    });

    testWidgets('renders the fallback when denied', (tester) async {
      setCtx(_deniedReady);
      await tester.pumpWidget(host(
        Guarded(
          gate: Gates.receiveStock,
          fallback: const Text('FALLBACK'),
          builder: (_, __) => const Text('CHILD'),
        ),
      ));
      expect(find.text('CHILD'), findsNothing);
      expect(find.text('FALLBACK'), findsOneWidget);
    });

    testWidgets('live revocation removes the child', (tester) async {
      setCtx(_granted);
      await tester.pumpWidget(host(
        Guarded(
          gate: Gates.receiveStock,
          builder: (_, __) => const Text('CHILD'),
        ),
      ));
      expect(find.text('CHILD'), findsOneWidget);

      setCtx(_deniedReady); // grant revoked mid-session
      await tester.pump();
      expect(find.text('CHILD'), findsNothing);
    });

    testWidgets('allow blocks a stale action after revocation + shows feedback',
        (tester) async {
      var taps = 0;
      late VoidCallback stale; // the wrapped callback captured while granted

      setCtx(_granted);
      await tester.pumpWidget(host(
        Guarded(
          gate: Gates.receiveStock,
          builder: (context, allow) {
            stale = allow(() => taps++);
            return ElevatedButton(onPressed: stale, child: const Text('GO'));
          },
        ),
      ));
      expect(find.text('GO'), findsOneWidget);

      // Grant revoked; the button rebuilds away, but a tap queued a frame
      // earlier still holds the wrapped callback and fires now.
      setCtx(_deniedReady);
      await tester.pump();
      expect(find.text('GO'), findsNothing, reason: 'render layer hid it');

      stale(); // the stale tap fires against the revoked set
      await tester.pump();
      expect(taps, 0, reason: 'fire-time re-check blocked the revoked action');
      expect(
        find.text('You no longer have access to Receive Stock.'),
        findsOneWidget,
      );

      AppNotification.hide();
      await tester.pump(const Duration(milliseconds: 500));
    });

    testWidgets('allow runs the action when still granted', (tester) async {
      var taps = 0;
      setCtx(_granted);
      await tester.pumpWidget(host(
        Guarded(
          gate: Gates.receiveStock,
          builder: (context, allow) => ElevatedButton(
            onPressed: allow(() => taps++),
            child: const Text('GO'),
          ),
        ),
      ));
      await tester.tap(find.text('GO'));
      await tester.pump();
      expect(taps, 1);
    });
  });

  group('Guarded.screen (body-guard)', () {
    Widget screen() => host(
          Guarded.screen(
            gate: Gates.receiveStock,
            builder: (_) => const Text('BODY'),
          ),
        );

    testWidgets('waits for ready — no denial flash while resolving',
        (tester) async {
      setCtx(GateContext.unresolved); // not ready
      await tester.pumpWidget(screen());
      expect(find.text('BODY'), findsNothing);
      // Crucially, the no-access scaffold does NOT flash before grants land.
      expect(find.textContaining("don't have access"), findsNothing);
    });

    testWidgets('renders the body once ready + granted', (tester) async {
      setCtx(GateContext.unresolved);
      await tester.pumpWidget(screen());
      setCtx(_granted);
      await tester.pump();
      expect(find.text('BODY'), findsOneWidget);
    });

    testWidgets('renders the standard no-access scaffold when denied',
        (tester) async {
      setCtx(_deniedReady);
      await tester.pumpWidget(screen());
      expect(find.text('BODY'), findsNothing);
      // Names the gate's action in the standard scaffold.
      expect(
        find.text("You don't have access to Receive Stock."),
        findsOneWidget,
      );
    });
  });

  group('require() imperative form', () {
    testWidgets('throws GateDeniedError when denied, returns when granted',
        (tester) async {
      late WidgetRef ref;
      setCtx(_deniedReady);
      await tester.pumpWidget(host(
        Consumer(builder: (_, r, __) {
          ref = r;
          return const SizedBox();
        }),
      ));

      expect(
        () => Gates.receiveStock.require(ref),
        throwsA(
          isA<GateDeniedError>()
              .having((e) => e.gateName, 'gateName', 'receiveStock')
              .having((e) => e.action, 'action', 'Receive Stock'),
        ),
      );

      setCtx(_granted);
      await tester.pump();
      expect(() => Gates.receiveStock.require(ref), returnsNormally);
    });
  });
}
