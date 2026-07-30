// #171 Confirm-safety gates. Two seams:
//   1. Pure Gate algebra — sales.confirm gates Confirm (Cashier-tier and above,
//      expressed by the seeded grant, not a tier atom); the cash-refund branch
//      ADDITIONALLY requires customers.wallet.withdraw.
//   2. The imperative `require()` write-boundary guard — throws GateDeniedError
//      when denied, returns when granted (the shape the Confirm path relies on).
// No DB, no pumped widget for the algebra half; the require half uses the
// module's own gateContextProvider seam, like guarded_test.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/permissions/gate.dart';
import 'package:reebaplus_pos/core/permissions/gate_registry.dart';
import 'package:reebaplus_pos/core/permissions/guarded.dart';

GateContext ctx({Set<String> keys = const {}, int? rank}) =>
    GateContext(grantedKeys: keys, roleRank: rank, isReady: true);

void main() {
  group('Gates.confirmOrder (sales.confirm)', () {
    test('grants a Cashier who holds sales.confirm', () {
      expect(
        Gates.confirmOrder.rule.evaluate(
          ctx(keys: {'sales.confirm'}, rank: GateTier.cashier),
        ),
        isTrue,
      );
    });

    test('denies a Stock keeper who does NOT hold sales.confirm', () {
      expect(
        Gates.confirmOrder.rule.evaluate(
          ctx(keys: {'stock.add', 'stock.view'}, rank: GateTier.stockKeeper),
        ),
        isFalse,
      );
    });

    test('denies anyone missing the key regardless of tier', () {
      expect(
        Gates.confirmOrder.rule.evaluate(ctx(rank: GateTier.manager)),
        isFalse,
      );
    });
  });

  group('Gates.confirmOrderCashRefund (sales.confirm + wallet.withdraw)', () {
    test('grants only when BOTH keys are held', () {
      expect(
        Gates.confirmOrderCashRefund.rule.evaluate(
          ctx(
            keys: {'sales.confirm', 'customers.wallet.withdraw'},
            rank: GateTier.cashier,
          ),
        ),
        isTrue,
      );
    });

    test('a confirmer WITHOUT wallet.withdraw cannot cash-refund', () {
      // Can Confirm (and refund to the credit balance), but not out of the till.
      expect(
        Gates.confirmOrder.rule
            .evaluate(ctx(keys: {'sales.confirm'}, rank: GateTier.cashier)),
        isTrue,
      );
      expect(
        Gates.confirmOrderCashRefund.rule
            .evaluate(ctx(keys: {'sales.confirm'}, rank: GateTier.cashier)),
        isFalse,
      );
    });

    test('wallet.withdraw alone (without sales.confirm) is not enough', () {
      expect(
        Gates.confirmOrderCashRefund.rule.evaluate(
          ctx(keys: {'customers.wallet.withdraw'}, rank: GateTier.manager),
        ),
        isFalse,
      );
    });
  });

  group('require() at the Confirm write boundary', () {
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
      container.read(source.notifier).state = c; // set BEFORE build
      late WidgetRef out;
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: Consumer(
              builder: (_, ref, __) {
                out = ref;
                return const SizedBox();
              },
            ),
          ),
        ),
      );
      return out;
    }

    testWidgets('confirmOrder throws without sales.confirm, returns with it',
        (tester) async {
      final ref = await pumpRef(
        tester,
        ctx(keys: {'stock.add'}, rank: GateTier.stockKeeper),
      );
      expect(
        () => Gates.confirmOrder.require(ref),
        throwsA(isA<GateDeniedError>()
            .having((e) => e.gateName, 'gateName', 'confirmOrder')),
      );

      final ref2 = await pumpRef(
        tester,
        ctx(keys: {'sales.confirm'}, rank: GateTier.cashier),
      );
      expect(() => Gates.confirmOrder.require(ref2), returnsNormally);
    });

    testWidgets('the cash-refund branch require needs wallet.withdraw too',
        (tester) async {
      final ref = await pumpRef(
        tester,
        ctx(keys: {'sales.confirm'}, rank: GateTier.cashier),
      );
      // May Confirm…
      expect(() => Gates.confirmOrder.require(ref), returnsNormally);
      // …but the cash-refund branch is denied.
      expect(
        () => Gates.confirmOrderCashRefund.require(ref),
        throwsA(isA<GateDeniedError>()
            .having((e) => e.gateName, 'gateName', 'confirmOrderCashRefund')),
      );

      final ref2 = await pumpRef(
        tester,
        ctx(
          keys: {'sales.confirm', 'customers.wallet.withdraw'},
          rank: GateTier.cashier,
        ),
      );
      expect(() => Gates.confirmOrderCashRefund.require(ref2), returnsNormally);
    });
  });
}
