import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';

/// Pure permission-resolution layering (§10.2.1): **User > Store > Business**,
/// most-specific wins. This is the heart of the per-store permission scope
/// (Item D) — the runtime provider wires the active store + override streams in,
/// but the layering order itself lives in this pure function so it's testable
/// in isolation.
void main() {
  ({String key, bool granted}) grant(String k) => (key: k, granted: true);
  ({String key, bool granted}) revoke(String k) => (key: k, granted: false);

  test('no overrides → business grants pass through unchanged', () {
    final r = resolveEffectivePermissions(
      isCeo: false,
      roleGrants: const ['sales.make', 'orders.view'],
      storeOverrides: const [],
      userOverrides: const [],
    );
    expect(r, {'sales.make', 'orders.view'});
  });

  test('store override force-revokes a business grant for that store', () {
    final r = resolveEffectivePermissions(
      isCeo: false,
      roleGrants: const ['sales.make', 'cost.view'],
      storeOverrides: [revoke('cost.view')],
      userOverrides: const [],
    );
    expect(r, {'sales.make'});
  });

  test('store override force-grants a permission the business withholds', () {
    final r = resolveEffectivePermissions(
      isCeo: false,
      roleGrants: const ['sales.make'],
      storeOverrides: [grant('expenses.approve')],
      userOverrides: const [],
    );
    expect(r, {'sales.make', 'expenses.approve'});
  });

  test('user override wins over the store layer (most-specific)', () {
    // Business grants cost.view; the store revokes it; but this user is
    // force-granted it → user wins.
    final r = resolveEffectivePermissions(
      isCeo: false,
      roleGrants: const ['cost.view'],
      storeOverrides: [revoke('cost.view')],
      userOverrides: [grant('cost.view')],
    );
    expect(r, contains('cost.view'));
  });

  test('user override can also revoke what the store granted', () {
    final r = resolveEffectivePermissions(
      isCeo: false,
      roleGrants: const <String>[],
      storeOverrides: [grant('sales.discount')],
      userOverrides: [revoke('sales.discount')],
    );
    expect(r, isEmpty);
  });

  test('full order: business → store → user applied in sequence', () {
    final r = resolveEffectivePermissions(
      isCeo: false,
      roleGrants: const ['a', 'b', 'c'],
      storeOverrides: [revoke('b'), grant('d')], // store: -b +d
      userOverrides: [revoke('d'), grant('e')], // user: -d +e
    );
    expect(r, {'a', 'c', 'e'});
  });

  test('CEO is all-on: store + user override layers are skipped entirely', () {
    final r = resolveEffectivePermissions(
      isCeo: true,
      roleGrants: const ['everything'],
      storeOverrides: [revoke('everything')],
      userOverrides: [revoke('everything')],
    );
    expect(r, {'everything'},
        reason: 'CEO is never overridable (§10.2.1) — overrides ignored');
  });
}
