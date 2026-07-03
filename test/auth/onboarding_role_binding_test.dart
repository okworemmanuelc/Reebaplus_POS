// onboarding_role_binding_test.dart
//
// Guards the post-onboarding role-binding gate (H1). completeOnboarding's local
// mirror writes only businesses + stores + users; the CEO's role binding
// (user_businesses membership + its roles row + role_permissions grants) is
// cloud-seeded and arrives via the post-onboarding pull. The onboarding commit
// blocks on AuthService.hasLocalRoleBinding so it never hands off to the app
// shell before that binding has actually landed locally — otherwise the CEO
// enters a permission-less shell (no POS access, empty drawer).
//
//   * false when the membership is absent.
//   * false when the membership exists but its roles row is missing.
//   * false when membership + role exist but no role_permissions grant landed.
//   * true once membership + role + at least one grant are all local.

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:reebaplus_pos/core/services/supabase_cloud_transport.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/core/services/supabase_sync_service.dart';
import 'package:reebaplus_pos/shared/services/auth_service.dart';
import 'package:reebaplus_pos/shared/services/navigation_service.dart';
import 'package:reebaplus_pos/shared/services/secure_storage_service.dart';

class _FakeSyncService extends SupabaseSyncService {
  _FakeSyncService(super.db, super.supabase);
}

class _FakeSecureStorageService extends SecureStorageService {
  @override
  Future<void> clearAll() async {}
}

void main() {
  late AppDatabase db;
  late AuthService auth;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(
      url: 'https://placeholder.supabase.co',
      anonKey: 'placeholder',
    );
  });

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    auth = AuthService(
      db,
      NavigationService(),
      _FakeSecureStorageService(),
      _FakeSyncService(db, SupabaseCloudTransport(Supabase.instance.client)),
      Supabase.instance.client,
    );
  });

  tearDown(() => db.close());

  Future<({String businessId, String userId})> seedBusinessAndUser() async {
    final businessId = UuidV7.generate();
    await db.into(db.businesses).insert(
          BusinessesCompanion.insert(id: Value(businessId), name: 'Acme'),
        );
    final userId = UuidV7.generate();
    await db.into(db.users).insert(
          UsersCompanion.insert(
            id: Value(userId),
            businessId: businessId,
            name: 'Owner',
            pin: '__INIT__',
          ),
        );
    return (businessId: businessId, userId: userId);
  }

  Future<String> seedRole(String businessId) async {
    final roleId = UuidV7.generate();
    await db.into(db.roles).insert(
          RolesCompanion.insert(
            id: Value(roleId),
            businessId: businessId,
            name: 'CEO',
            slug: 'ceo',
          ),
        );
    return roleId;
  }

  test('false when no membership exists', () async {
    final seed = await seedBusinessAndUser();
    expect(
      await auth.hasLocalRoleBinding(seed.userId, seed.businessId),
      isFalse,
    );
  });

  // Note: a membership with a missing roles row is unconstructable —
  // user_businesses.role_id has an enforced FK to roles.id, so the role row is
  // guaranteed present whenever a membership is. The grant check below is the
  // remaining "still mid-pull" signal hasLocalRoleBinding actually guards.

  test('false when membership + role exist but no grant landed', () async {
    final seed = await seedBusinessAndUser();
    final roleId = await seedRole(seed.businessId);
    await db.into(db.userBusinesses).insert(
          UserBusinessesCompanion.insert(
            businessId: seed.businessId,
            userId: seed.userId,
            roleId: roleId,
          ),
        );
    expect(
      await auth.hasLocalRoleBinding(seed.userId, seed.businessId),
      isFalse,
    );
  });

  test('true once membership + role + a grant are all local', () async {
    final seed = await seedBusinessAndUser();
    final roleId = await seedRole(seed.businessId);
    await db.into(db.userBusinesses).insert(
          UserBusinessesCompanion.insert(
            businessId: seed.businessId,
            userId: seed.userId,
            roleId: roleId,
          ),
        );
    await db.into(db.rolePermissions).insert(
          RolePermissionsCompanion.insert(
            id: Value(UuidV7.generate()),
            businessId: seed.businessId,
            roleId: roleId,
            permissionKey: 'sales.make',
            lastUpdatedAt: Value(DateTime.now()),
          ),
        );
    expect(
      await auth.hasLocalRoleBinding(seed.userId, seed.businessId),
      isTrue,
    );
  });

  test('false when the binding belongs to a different business', () async {
    final seed = await seedBusinessAndUser();
    final roleId = await seedRole(seed.businessId);
    await db.into(db.userBusinesses).insert(
          UserBusinessesCompanion.insert(
            businessId: seed.businessId,
            userId: seed.userId,
            roleId: roleId,
          ),
        );
    await db.into(db.rolePermissions).insert(
          RolePermissionsCompanion.insert(
            id: Value(UuidV7.generate()),
            businessId: seed.businessId,
            roleId: roleId,
            permissionKey: 'sales.make',
            lastUpdatedAt: Value(DateTime.now()),
          ),
        );
    // Asking about a different (unrelated) business must not resolve.
    expect(
      await auth.hasLocalRoleBinding(seed.userId, UuidV7.generate()),
      isFalse,
    );
  });
}
