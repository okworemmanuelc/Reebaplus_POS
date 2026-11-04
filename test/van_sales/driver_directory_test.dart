// driver_directory_test.dart
//
// #146 / #748 (PRD #139, ADR 0019, van-sales spec §9.5 #19) — who belongs on the
// Drivers list.
//
// The rule under test is a MONEY rule wearing a list's clothes: **removing a
// driver must not be able to hide a debt.** A removed driver who still owes
// stays visible, badged, until the balance is settled or written off. Each
// driver's debt is their own; vans with debt and no driver form "No driver
// assigned" groups.
//
// Pure — no DB, no widgets.

import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/van_sales/driver_directory.dart';

VanDriverData _driver(String id, String name, {bool deleted = false}) =>
    VanDriverData(
      id: id,
      businessId: 'biz',
      name: name,
      phone: null,
      isDeleted: deleted,
      createdAt: DateTime(2026, 1, 1),
      lastUpdatedAt: DateTime(2026, 1, 1),
    );

void main() {
  group('buildDriversList', () {
    test('lists every current driver, settled or not, by name', () {
      final out = buildDriversList(
        drivers: [_driver('b', 'Bayo'), _driver('a', 'Ada')],
        balancesKobo: {'b': -5000},
      );
      expect(out.map((e) => e.driverId), ['a', 'b']);
      expect(out[0].isSettled, isTrue);
      expect(out[1].owes, isTrue);
    });

    test('a removed driver who owes stays, badged', () {
      final out = buildDriversList(
        drivers: [_driver('a', 'Ada', deleted: true)],
        balancesKobo: {'a': -5000},
      );
      expect(out, hasLength(1));
      expect(out.single.isFormerDriver, isTrue);
      expect(out.single.balanceKobo, -5000);
    });

    test('a removed driver at zero is not listed', () {
      final out = buildDriversList(
        drivers: [_driver('a', 'Ada', deleted: true)],
        balancesKobo: const {},
      );
      expect(out, isEmpty);
    });

    test('a removed driver in credit stays (the business owes them)', () {
      final out = buildDriversList(
        drivers: [_driver('a', 'Ada', deleted: true)],
        balancesKobo: {'a': 2000},
      );
      expect(out.single.inCredit, isTrue);
    });

    test('current drivers come before former ones', () {
      final out = buildDriversList(
        drivers: [
          _driver('a', 'Ada', deleted: true),
          _driver('z', 'Zed'),
        ],
        balancesKobo: {'a': -1},
      );
      expect(out.map((e) => e.driverId), ['z', 'a']);
    });
  });

  group('buildNoDriverGroups', () {
    test('lists vans with a non-zero no-driver balance, biggest debt first', () {
      final out = buildNoDriverGroups({'v1': -100, 'v2': 0, 'v3': -900});
      expect(out.map((g) => g.vanStoreId), ['v3', 'v1']);
      expect(out.first.owes, isTrue);
    });
  });
}
