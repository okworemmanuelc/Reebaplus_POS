// Pure Gate-algebra semantics (issue #17, ADR 0002). The primary seam: a
// permission set + role tier go in, a grant/deny decision comes out — tested as
// a pure function of a GateContext, no widgets pumped. Permission sets are built
// both directly and via the existing `resolveEffectivePermissions` fixture, the
// same layering the rest of the app resolves through.

import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/permissions/gate.dart';
import 'package:reebaplus_pos/core/permissions/gate_registry.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/shared/utils/role_display.dart';

GateContext ctx({
  Set<String> keys = const {},
  int? rank,
  bool ready = true,
}) =>
    GateContext(grantedKeys: keys, roleRank: rank, isReady: ready);

void main() {
  group('atoms', () {
    test('key grants iff the effective set contains the key', () {
      const gate = Gate.key('stock.add');
      expect(gate.evaluate(ctx(keys: {'stock.add'}, rank: GateTier.stockKeeper)),
          isTrue);
      expect(gate.evaluate(ctx(keys: {'sales.make'}, rank: GateTier.cashier)),
          isFalse);
    });

    test('anyKey grants iff the set contains any listed key', () {
      const gate = Gate.anyKey(['stock.add', 'products.add']);
      expect(gate.evaluate(ctx(keys: {'stock.add'}, rank: GateTier.stockKeeper)),
          isTrue);
      expect(gate.evaluate(ctx(keys: {'products.add'}, rank: GateTier.manager)),
          isTrue);
      expect(gate.evaluate(ctx(keys: {'sales.make'}, rank: GateTier.cashier)),
          isFalse);
    });

    test('allKeys grants only when the set contains every listed key', () {
      const gate = Gate.allKeys(['a', 'b']);
      expect(gate.evaluate(ctx(keys: {'a', 'b'}, rank: GateTier.manager)), isTrue);
      expect(gate.evaluate(ctx(keys: {'a'}, rank: GateTier.manager)), isFalse);
    });

    test('tierAtLeast grants for the threshold rank and above (more senior)', () {
      const gate = Gate.tierAtLeast(GateTier.manager);
      expect(gate.evaluate(ctx(rank: GateTier.ceo)), isTrue);
      expect(gate.evaluate(ctx(rank: GateTier.manager)), isTrue);
      expect(gate.evaluate(ctx(rank: GateTier.cashier)), isFalse);
      expect(gate.evaluate(ctx(rank: GateTier.stockKeeper)), isFalse);
    });

    test('ceo grants only for the CEO tier', () {
      const gate = Gate.ceo();
      expect(gate.evaluate(ctx(rank: GateTier.ceo)), isTrue);
      expect(gate.evaluate(ctx(rank: GateTier.manager)), isFalse);
    });
  });

  group('composition', () {
    test('and grants only when both sides grant', () {
      final gate = const Gate.key('a').and(const Gate.key('b'));
      expect(gate.evaluate(ctx(keys: {'a', 'b'}, rank: GateTier.cashier)), isTrue);
      expect(gate.evaluate(ctx(keys: {'a'}, rank: GateTier.cashier)), isFalse);
    });

    test('or grants when either side grants (the Sync-Issues shape)', () {
      // CEO-always OR the sync.view grant — the §21 composite, verbatim.
      final gate = const Gate.ceo().or(const Gate.key('sync.view'));
      expect(gate.evaluate(ctx(rank: GateTier.ceo)), isTrue, reason: 'CEO always');
      expect(gate.evaluate(ctx(keys: {'sync.view'}, rank: GateTier.manager)),
          isTrue);
      expect(gate.evaluate(ctx(rank: GateTier.manager)), isFalse);
    });
  });

  group('fails closed while the role is unresolved', () {
    test('every gate denies against the unresolved context', () {
      const unresolved = GateContext.unresolved;
      expect(Gates.receiveStock.evaluate(unresolved), isFalse);
      expect(Gates.editProductPrice.evaluate(unresolved), isFalse);
      expect(const Gate.tierAtLeast(GateTier.manager).evaluate(unresolved),
          isFalse);
      expect(const Gate.ceo().evaluate(unresolved), isFalse);
    });

    test('a null rank fails tier and ceo atoms even with keys present', () {
      final c = ctx(keys: {'stock.add'}, rank: null);
      // key atoms still read the set…
      expect(Gates.receiveStock.evaluate(c), isTrue);
      // …but tier/ceo fail closed until the role resolves.
      expect(const Gate.tierAtLeast(GateTier.manager).evaluate(c), isFalse);
      expect(const Gate.ceo().evaluate(c), isFalse);
    });
  });

  group('CEO is all-on (seeded grants)', () {
    test('CEO passes key gates because the effective set carries every grant',
        () {
      // resolveEffectivePermissions returns the CEO role grants unchanged
      // (isCeo skips override layers). Seed the CEO with the receive keys.
      final ceoKeys = resolveEffectivePermissions(
        isCeo: true,
        roleGrants: const ['stock.add', 'products.add', 'products.edit_price'],
        storeOverrides: const [],
        userOverrides: const [],
      );
      final c = ctx(keys: ceoKeys, rank: GateTier.ceo);
      expect(Gates.receiveStock.evaluate(c), isTrue);
      expect(Gates.addProduct.evaluate(c), isTrue);
      expect(Gates.editProductPrice.evaluate(c), isTrue);
    });
  });

  group('effective-permission fixture feeds the gate', () {
    test('a store override that grants a key flips the gate to allow', () {
      // Cashier with no receive grant, but the active store force-grants
      // stock.add → the receive gate now allows (User > Store > Business).
      final keys = resolveEffectivePermissions(
        isCeo: false,
        roleGrants: const ['sales.make'],
        storeOverrides: const [(key: 'stock.add', granted: true)],
        userOverrides: const [],
      );
      expect(Gates.receiveStock.evaluate(ctx(keys: keys, rank: GateTier.cashier)),
          isTrue);
    });
  });

  group('registry gates match their intended keys', () {
    test('receiveStock is the any-of stock.add / products.add gate', () {
      expect(
          Gates.receiveStock.evaluate(ctx(keys: {'stock.add'}, rank: 3)), isTrue);
      expect(Gates.receiveStock.evaluate(ctx(keys: {'products.add'}, rank: 1)),
          isTrue);
      expect(Gates.receiveStock.evaluate(ctx(keys: {'sales.make'}, rank: 2)),
          isFalse);
    });
  });

  test('GateTier ranks stay in lockstep with roleRank() slugs', () {
    // The tier atoms are only meaningful if the algebra's ranks match the app's
    // role ranks; the glue maps slug → GateTier via roleRank.
    expect(GateTier.ceo, roleRank('ceo'));
    expect(GateTier.manager, roleRank('manager'));
    expect(GateTier.cashier, roleRank('cashier'));
    expect(GateTier.stockKeeper, roleRank('stock_keeper'));
  });

  group('GateDeniedError telemetry payload carries the gate name', () {
    test('errorType + message (what CrashReporter records) name the gate', () {
      const err = GateDeniedError(gateName: 'receiveStock', action: 'Receive Stock');
      // CrashReporter.record writes error.runtimeType.toString() → errorType
      // and error.toString() → message into error_logs.
      expect(err.runtimeType.toString(), 'GateDeniedError');
      expect(err.toString(), contains('receiveStock'));
      expect(err.toString(), contains('Receive Stock'));
    });
  });
}
