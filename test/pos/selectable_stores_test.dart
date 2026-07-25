// selectable_stores_test.dart
//
// Unit test for the pure store-confinement filter behind the §28 multi-store
// "pick your store" gate (POS active-store selection). The filter decides which
// stores a user may sell from given their assignment; the rest of the feature
// (defaulting nav.lockedStoreId, the picker gate) is UI glue on top of it.
//
// #140 extends it with the van rule: a van is a `stores` row, so without a
// filter here it would land in every picker and confinement default. The last
// group pins that vans are dropped for everyone except the driver assigned to
// them — including the "no assignment → no confinement" fallback, which must
// not silently widen a van-only driver to every warehouse.

import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';

StoreData _store(String id, {String kind = kStoreKindStore}) => StoreData(
      id: id,
      businessId: 'biz',
      name: 'Store $id',
      location: null,
      kind: kind,
      isDeleted: false,
      createdAt: DateTime.utc(2026, 1, 1),
      lastUpdatedAt: DateTime.utc(2026, 1, 1),
    );

StoreData _van(String id) => _store(id, kind: kStoreKindVan);

void main() {
  final all = [_store('a'), _store('b'), _store('c')];

  test('null assignment (CEO / all-stores Manager) → every store', () {
    final result = selectableStoresFor(all, null);
    expect(result.map((s) => s.id), ['a', 'b', 'c']);
  });

  test('confined user → only their assigned stores, order preserved', () {
    final result = selectableStoresFor(all, {'c', 'a'});
    expect(result.map((s) => s.id), ['a', 'c']);
  });

  test('confined user assigned to one store → just that store', () {
    final result = selectableStoresFor(all, {'b'});
    expect(result.map((s) => s.id), ['b']);
  });

  test('confined user with NO assignment → falls back to all (no dead-end)', () {
    final result = selectableStoresFor(all, <String>{});
    expect(result.map((s) => s.id), ['a', 'b', 'c']);
  });

  test('assigned ids not in the active set are ignored', () {
    final result = selectableStoresFor(all, {'a', 'zzz'});
    expect(result.map((s) => s.id), ['a']);
  });

  group('vans (#140)', () {
    final withVan = [_store('a'), _van('v1'), _store('b'), _van('v2')];

    test('an all-stores viewer never sees a van', () {
      final result = selectableStoresFor(withVan, null);
      expect(result.map((s) => s.id), ['a', 'b']);
    });

    test('a confined user assigned to a van still never sees it', () {
      // No `van.sell` — being assigned to a van is not enough.
      final result = selectableStoresFor(withVan, {'a', 'v1'});
      expect(result.map((s) => s.id), ['a']);
    });

    test('a driver sees the van they were assigned to, and no other', () {
      final result =
          selectableStoresFor(withVan, {'v1'}, canSellFromVan: true);
      expect(result.map((s) => s.id), ['v1']);
    });

    test('a driver with a store AND a van gets both, stores first', () {
      final result =
          selectableStoresFor(withVan, {'b', 'v2'}, canSellFromVan: true);
      expect(result.map((s) => s.id), ['b', 'v2']);
    });

    test('a driver is never widened to every warehouse by the empty fallback',
        () {
      // The regression this guards: filtering vans out FIRST would leave a
      // van-only driver with an empty `mine`, and the no-assignment fallback
      // would then hand them every store in the business.
      final result =
          selectableStoresFor(withVan, {'v1'}, canSellFromVan: true);
      expect(result.map((s) => s.id), isNot(contains('a')));
      expect(result.map((s) => s.id), isNot(contains('b')));
    });

    test('a genuinely unassigned user still falls back to the stores only', () {
      final result =
          selectableStoresFor(withVan, <String>{}, canSellFromVan: true);
      expect(result.map((s) => s.id), ['a', 'b']);
    });
  });
}
