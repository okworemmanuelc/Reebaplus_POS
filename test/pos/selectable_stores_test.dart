// selectable_stores_test.dart
//
// Unit test for the pure store-confinement filter behind the §28 multi-store
// "pick your store" gate (POS active-store selection). The filter decides which
// stores a user may sell from given their assignment; the rest of the feature
// (defaulting nav.lockedStoreId, the picker gate) is UI glue on top of it.

import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/features/pos/screens/pos_home_screen.dart';

StoreData _store(String id) => StoreData(
      id: id,
      businessId: 'biz',
      name: 'Store $id',
      location: null,
      isDeleted: false,
      createdAt: DateTime.utc(2026, 1, 1),
      lastUpdatedAt: DateTime.utc(2026, 1, 1),
    );

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
}
