// post_verify_route_orphan_business_test.dart
//
// Guards the fix for re-registering with the same email after
// "Delete Business & Account" (§10.3) left a stale local `users` row behind
// on this device. Without the fix, resolvePostVerifyRoute logs the
// re-registered email into the dead tenant's businessId — causing
// tenant_mismatch on pull (server checks the new profile's business_id) and
// row-level-security violations on push (stale sync_queue rows stamped with
// the old business_id).
//
// Fix: when the cloud confirms no business for this auth identity
// (fetchSupabaseAccount returns null) AND the `deleted_businesses` tombstone
// confirms the stale row's businessId was deleted, the device is wiped and
// the email is routed as brand-new (NoAccountFoundRoute). Any ambiguity (no
// tombstone / offline) must preserve the existing offline PIN-login path
// (LoginRoute) — never a false-positive wipe.

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/core/services/supabase_sync_service.dart';
import 'package:reebaplus_pos/features/auth/auth_post_verify_route.dart';
import 'package:reebaplus_pos/shared/services/auth_service.dart';
import 'package:reebaplus_pos/shared/services/navigation_service.dart';
import 'package:reebaplus_pos/shared/services/secure_storage_service.dart';

/// Stubs the `deleted_businesses` tombstone check so the test controls the
/// outcome without a real network call.
class _FakeSync extends SupabaseSyncService {
  _FakeSync(super.db, super.client);

  bool tombstoneConfirmed = false;

  @override
  Future<bool> confirmBusinessDeleted(String businessId) async =>
      tombstoneConfirmed;
}

/// Simulates the re-registration scenario: the auth identity that just
/// verified OTP has no cloud business/profile yet.
class _FakeAuth extends AuthService {
  _FakeAuth(super.db, super.nav, super.secure, super.sync, super.supabase);

  @override
  Future<SupabaseAccountInfo?> fetchSupabaseAccount() async => null;
}

void main() {
  late AppDatabase db;
  late _FakeSync sync;
  late _FakeAuth auth;
  const email = 'okworchimezie@gmail.com';

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
    final client = Supabase.instance.client;
    sync = _FakeSync(db, client);
    auth = _FakeAuth(
      db,
      NavigationService(),
      SecureStorageService(),
      sync,
      client,
    );
  });

  tearDown(() => db.close());

  Future<String> seedStaleUser() async {
    final oldBusinessId = UuidV7.generate();
    await db.into(db.businesses).insert(BusinessesCompanion.insert(
          id: Value(oldBusinessId),
          name: 'Old Biz',
        ));
    final userId = UuidV7.generate();
    await db.into(db.users).insert(UsersCompanion.insert(
          id: Value(userId),
          businessId: oldBusinessId,
          name: 'Owner',
          email: const Value(email),
          pin: '__HASHED__',
          pinHash: const Value('deadbeef'),
          pinSalt: const Value('salt'),
          pinIterations: const Value(120000),
        ));
    return oldBusinessId;
  }

  test(
      'confirmed deleted_businesses tombstone wipes the device and routes '
      'the re-registered email as brand-new, not into the dead tenant',
      () async {
    await seedStaleUser();
    sync.tombstoneConfirmed = true;

    final route = await resolvePostVerifyRoute(auth, email);

    expect(route, isA<NoAccountFoundRoute>());
    expect(await db.select(db.users).get(), isEmpty,
        reason: 'stale local data for the deleted business must be wiped');
  });

  test(
      'no tombstone match preserves offline PIN login for the stale local '
      'row (never a false-positive wipe)', () async {
    final oldBusinessId = await seedStaleUser();
    sync.tombstoneConfirmed = false;

    final route = await resolvePostVerifyRoute(auth, email);

    expect(route, isA<LoginRoute>());
    expect((route as LoginRoute).user.businessId, oldBusinessId);
    expect(await db.select(db.users).get(), isNotEmpty,
        reason: 'ambiguous result must never wipe local data');
  });
}
