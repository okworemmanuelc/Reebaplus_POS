// driver_directory_test.dart
//
// #146 (PRD #139 as amended by #161 / ADR 0019, van-sales spec §9.5 #19) — who
// belongs on the Drivers list.
//
// The rule under test is a MONEY rule wearing a list's clothes: **offboarding
// must not be able to hide a debt.** A driver who leaves owing stays visible,
// badged, until the balance is settled or written off. Its enforcement half
// lives in `driver_offboarding_test.dart`; this file pins the visibility half.
//
// Pure — no DB, no widgets. Prior art: test/van_sales/van_trip_position_test.dart.

import 'package:drift/drift.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/van_sales/driver_directory.dart';

const _driverRole = 'role-driver';
const _cashierRole = 'role-cashier';

UserData _user(String id, String name) => UserData(
  id: id,
  businessId: 'biz',
  name: name,
  pin: '0000',
  avatarColor: '#3B82F6',
  biometricEnabled: false,
  createdAt: DateTime(2026, 1, 1),
  lastUpdatedAt: DateTime(2026, 1, 1),
);

UserBusinessData _membership(
  String userId, {
  String roleId = _driverRole,
  String status = 'active',
}) => UserBusinessData(
  id: 'm-$userId',
  businessId: 'biz',
  userId: userId,
  roleId: roleId,
  status: status,
  createdAt: DateTime(2026, 1, 1),
  lastUpdatedAt: DateTime(2026, 1, 1),
);

void main() {
  group('buildDriversList', () {
    test('lists every current driver, settled or not', () {
      final out = buildDriversList(
        memberships: [_membership('dan'), _membership('zoe')],
        driverRoleIds: {_driverRole},
        usersById: {'dan': _user('dan', 'Dan'), 'zoe': _user('zoe', 'Zoe')},
        balancesKobo: {'dan': -500000},
      );

      expect(out.map((e) => e.userId), ['dan', 'zoe']);
      expect(out.first.standing, DriverStanding.active);
      expect(out.first.owes, isTrue);
      // Absent from the balance map means zero, not missing.
      expect(out.last.balanceKobo, 0);
      expect(out.last.isSettled, isTrue);
    });

    test('a non-driver is never listed, whatever their balance', () {
      final out = buildDriversList(
        memberships: [_membership('cash', roleId: _cashierRole)],
        driverRoleIds: {_driverRole},
        usersById: {'cash': _user('cash', 'Cashier Cal')},
        balancesKobo: const {},
      );
      expect(out, isEmpty);
    });

    test('a suspended driver is listed and badged suspended', () {
      final out = buildDriversList(
        memberships: [_membership('dan', status: 'suspended')],
        driverRoleIds: {_driverRole},
        usersById: {'dan': _user('dan', 'Dan')},
        balancesKobo: const {},
      );
      expect(out.single.standing, DriverStanding.suspended);
    });

    // ── §9.5 #19 — the invariant ─────────────────────────────────────────────

    test(
      'a REMOVED driver with a non-zero balance is still listed, badged removed',
      () {
        // The membership row is gone — that is exactly what offboarding does
        // (#107 keeps only the `users` attribution stub). The ledger is what
        // keeps them visible.
        final out = buildDriversList(
          memberships: const [],
          driverRoleIds: {_driverRole},
          usersById: {'gone': _user('gone', 'Gone Gary')},
          balancesKobo: {'gone': -1925000},
        );

        expect(out.single.userId, 'gone');
        expect(out.single.standing, DriverStanding.removed);
        expect(out.single.isFormerDriver, isTrue);
        expect(out.single.balanceKobo, -1925000);
      },
    );

    test('a removed driver the business OWES is listed too', () {
      final out = buildDriversList(
        memberships: const [],
        driverRoleIds: {_driverRole},
        usersById: {'gone': _user('gone', 'Gone Gary')},
        balancesKobo: {'gone': 250000},
      );
      expect(out.single.standing, DriverStanding.removed);
      expect(out.single.inCredit, isTrue);
    });

    test('a removed driver at ZERO does not clutter the list', () {
      final out = buildDriversList(
        memberships: const [],
        driverRoleIds: {_driverRole},
        usersById: {'gone': _user('gone', 'Gone Gary')},
        balancesKobo: {'gone': 0},
      );
      expect(out, isEmpty);
    });

    test(
      'a membership row that arrives already marked removed is badged, not '
      'shown as staff',
      () {
        // A pull can carry a `removed` row even though the local scoped read
        // filters it. It must fall through to the ledger rule.
        final out = buildDriversList(
          memberships: [_membership('gone', status: 'removed')],
          driverRoleIds: {_driverRole},
          usersById: {'gone': _user('gone', 'Gone Gary')},
          balancesKobo: {'gone': -100},
        );
        expect(out.single.standing, DriverStanding.removed);
      },
    );

    test(
      'a driver whose role was changed away is still listed while they owe',
      () {
        // Changing the role would drop them from every driver surface just as
        // silently as a removal. The ledger rule catches that too.
        final out = buildDriversList(
          memberships: [_membership('dan', roleId: _cashierRole)],
          driverRoleIds: {_driverRole},
          usersById: {'dan': _user('dan', 'Dan')},
          balancesKobo: {'dan': -700000},
        );
        expect(out.single.standing, DriverStanding.removed);
      },
    );

    test('a balance with no users row at all cannot be rendered, so is not', () {
      final out = buildDriversList(
        memberships: const [],
        driverRoleIds: {_driverRole},
        usersById: const {},
        balancesKobo: {'ghost': -100},
      );
      expect(out, isEmpty);
    });

    // ── Ordering ─────────────────────────────────────────────────────────────

    test('current drivers come first, former drivers last, each by name', () {
      final out = buildDriversList(
        memberships: [
          _membership('zed'),
          _membership('amy'),
          _membership('sue', status: 'suspended'),
        ],
        driverRoleIds: {_driverRole},
        usersById: {
          'zed': _user('zed', 'Zed'),
          'amy': _user('amy', 'Amy'),
          'sue': _user('sue', 'Sue'),
          'bob': _user('bob', 'Bob'),
        },
        balancesKobo: {'bob': -1},
      );

      expect(out.map((e) => e.user.name), ['Amy', 'Zed', 'Sue', 'Bob']);
      expect(out.map((e) => e.standing), [
        DriverStanding.active,
        DriverStanding.active,
        DriverStanding.suspended,
        DriverStanding.removed,
      ]);
    });

    test('no driver role seeded yet means no list', () {
      final out = buildDriversList(
        memberships: [_membership('dan')],
        driverRoleIds: const {},
        usersById: {'dan': _user('dan', 'Dan')},
        balancesKobo: const {},
      );
      expect(out, isEmpty);
    });
  });

  // The Drift import is used by the data-class constructors above; this keeps
  // the analyzer honest about it in a file that otherwise never touches Drift.
  test('fixtures are real Drift data classes', () {
    expect(_user('a', 'A').toCompanion(true), isA<UsersCompanion>());
    expect(const Value(1).present, isTrue);
  });
}
