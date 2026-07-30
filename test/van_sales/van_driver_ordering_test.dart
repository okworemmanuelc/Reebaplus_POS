// van_driver_ordering_test.dart
//
// #208 item 2 — `vanDriversProvider` sorts by NAME, and that is a decision.
//
// The house rule is that people lists are tier-ordered (CEO → Manager →
// Cashier → Stock keeper → Driver), never alphabetical. This file exists
// because van code has exactly one place that sorts people by name, and a later
// reader will otherwise "fix" it. The fix would be churn: the list is closed
// under ONE role by construction, so a tier comparator is constant and leaves
// the alphabetical order untouched.
//
// What is pinned here, in the order the argument runs:
//
//   1. The premise — `roles` carries `UNIQUE (business_id, slug)`, so a business
//      can hold at most one `driver` role and `driverRoleIds` is a singleton.
//      This is the load-bearing fact; if it ever stops being true the exception
//      dies with it and this test fails FIRST.
//   2. The degeneracy — a tier-then-name sort over a single-role list returns
//      exactly the name sort. So the "fix" changes nothing but the cost.
//   3. The behaviour — the provider itself really is name-ordered,
//      case-insensitively, and admits only live Driver-role memberships.
//
// Prior art: driver_directory_test.dart (pure) and van_close_test.dart (Drift).

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/shared/utils/role_display.dart';

import '../helpers/dispatch_test_utils.dart';

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

RoleData _role(String id, String slug) => RoleData(
  id: id,
  businessId: 'biz',
  name: slug,
  slug: slug,
  isSystemDefault: true,
  isDeleted: false,
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

/// Reads [vanDriversProvider] with its three composed feeds stubbed. The
/// provider is a plain `Provider` over `.valueOrNull`, so each stubbed stream
/// has to be awaited to its first value before the composition is read.
Future<List<UserData>> readDrivers({
  required List<RoleData> roles,
  required List<UserBusinessData> memberships,
  required Map<String, UserData> usersById,
}) async {
  final container = ProviderContainer(
    overrides: [
      allRolesProvider.overrideWith((ref) => Stream.value(roles)),
      userBusinessesProvider.overrideWith((ref) => Stream.value(memberships)),
      usersByBusinessProvider.overrideWith((ref) => Stream.value(usersById)),
    ],
  );
  addTearDown(container.dispose);
  await container.read(allRolesProvider.future);
  await container.read(userBusinessesProvider.future);
  await container.read(usersByBusinessProvider.future);
  return container.read(vanDriversProvider);
}

void main() {
  group('the premise: one driver role per business', () {
    late AppDatabase db;
    late String businessId;

    setUp(() async {
      final boot = await bootstrapTestDb();
      db = boot.db;
      businessId = boot.businessId;
    });

    tearDown(() => db.close());

    Future<void> insertRole(String bizId, String slug, String name) =>
        db
            .into(db.roles)
            .insert(
              RolesCompanion.insert(
                id: Value(UuidV7.generate()),
                businessId: bizId,
                name: name,
                slug: slug,
              ),
            );

    test(
      'a second `driver` role in the same business is rejected by the schema',
      () async {
        await insertRole(businessId, 'driver', 'Driver');

        // `UNIQUE (business_id, slug)` — a distinct display name does not buy a
        // second driver role.
        await expectLater(
          insertRole(businessId, 'driver', 'Van Driver'),
          throwsA(anything),
          reason:
              'vanDriversProvider\'s name ordering is only harmless because the '
              'list cannot mix roles; that guarantee is this constraint',
        );

        final driverRoles =
            await (db.select(db.roles)
                  ..where((r) => r.slug.equals('driver'))
                  ..where((r) => r.businessId.equals(businessId)))
                .get();
        expect(driverRoles, hasLength(1));
      },
    );

    test('the constraint is per business, not global', () async {
      final otherBiz = UuidV7.generate();
      await db
          .into(db.businesses)
          .insert(
            BusinessesCompanion.insert(id: Value(otherBiz), name: 'Other Biz'),
          );

      await insertRole(businessId, 'driver', 'Driver');
      await expectLater(
        insertRole(otherBiz, 'driver', 'Driver'),
        completes,
        reason: 'each tenant seeds its own Driver role (cloud 0161)',
      );
    });
  });

  group('the degeneracy: tier ordering over one role is the name ordering', () {
    test('roleRank is a constant comparator across a single-role list', () {
      final drivers = [
        _user('c', 'Chidi'),
        _user('a', 'Amaka'),
        _user('b', 'Bola'),
      ];

      final byName = [...drivers]
        ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

      // The "fix" a future reader would reach for: rank first, then name.
      const oneSlug = 'driver';
      final byTierThenName = [...drivers]
        ..sort((a, b) {
          final rank = roleRank(oneSlug).compareTo(roleRank(oneSlug));
          if (rank != 0) return rank;
          return a.name.toLowerCase().compareTo(b.name.toLowerCase());
        });

      expect(
        byTierThenName.map((u) => u.id),
        byName.map((u) => u.id),
        reason:
            'tier ordering is not weakened on this list, it is vacuous on it — '
            'so applying it is churn, not a fix (#208 item 2)',
      );
      expect(byName.map((u) => u.name), ['Amaka', 'Bola', 'Chidi']);
    });
  });

  group('vanDriversProvider', () {
    test('orders drivers by name, case-insensitively', () async {
      final out = await readDrivers(
        roles: [_role(_driverRole, 'driver'), _role(_cashierRole, 'cashier')],
        memberships: [
          _membership('zoe'),
          _membership('amaka'),
          _membership('bola'),
        ],
        usersById: {
          'zoe': _user('zoe', 'zoe'),
          'amaka': _user('amaka', 'Amaka'),
          'bola': _user('bola', 'BOLA'),
        },
      );

      expect(
        out.map((u) => u.id),
        ['amaka', 'bola', 'zoe'],
        reason:
            'the deliberate exception (#208 item 2) — a single-role picker is '
            'scanned by name',
      );
    });

    test('admits only live Driver-role memberships', () async {
      final out = await readDrivers(
        roles: [_role(_driverRole, 'driver'), _role(_cashierRole, 'cashier')],
        memberships: [
          _membership('dan'),
          _membership('cash', roleId: _cashierRole),
          _membership('sus', status: 'suspended'),
        ],
        usersById: {
          'dan': _user('dan', 'Dan'),
          'cash': _user('cash', 'Aaron The Cashier'),
          'sus': _user('sus', 'Abel Suspended'),
        },
      );

      expect(
        out.map((u) => u.id),
        ['dan'],
        reason:
            'a cashier who sorts first alphabetically must not lead the Load '
            'Van picker, and a suspended driver must not be loadable',
      );
    });

    test('an unseeded Driver role yields no drivers at all', () async {
      final out = await readDrivers(
        roles: [_role(_cashierRole, 'cashier')],
        memberships: [_membership('dan')],
        usersById: {'dan': _user('dan', 'Dan')},
      );

      expect(out, isEmpty);
    });
  });
}
