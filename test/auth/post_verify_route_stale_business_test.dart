// post_verify_route_stale_business_test.dart
//
// #285. Deleting a business does NOT delete the Supabase login behind it, so
// one login can be handed to a new business while the phone still holds the
// old one's data. Sign-in then bound the STALE local row, and the minimum pull
// tried to insert the new business's user row carrying an `auth_user_id` the
// stale row already held — UNIQUE (users.auth_user_id) → SqliteException(2067)
// → "Signed in, but we could not load your account" on both entry screens.
//
// The fix clears every OTHER business off the phone once the cloud has
// positively named the one being signed in to. This file pins the decision
// table the owner set on 2026-09-19:
//
//   • tombstoned old business            → cleared, no prompt
//   • old business exists, empty outbox  → cleared, no prompt
//   • old business exists, unsent rows   → one warning; confirm clears, cancel
//                                          abandons the sign-in untouched
//   • cloud positively says "no business"→ everything cleared, no-account screen
//   • cloud unreachable                  → nothing cleared, ever
//   • same business                      → untouched (Switch account, decision 4)
//
// Supersedes post_verify_route_orphan_business_test.dart, whose deleted-tenant
// case is now one branch of the same routine.

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/core/services/supabase_cloud_transport.dart';
import 'package:reebaplus_pos/core/services/supabase_sync_service.dart';
import 'package:reebaplus_pos/features/auth/auth_post_verify_route.dart';
import 'package:reebaplus_pos/shared/services/auth_service.dart';
import 'package:reebaplus_pos/shared/services/navigation_service.dart';
import 'package:reebaplus_pos/shared/services/secure_storage_service.dart';

/// Stubs the `deleted_businesses` tombstone check so the test controls the
/// answer without a network call.
class _FakeSync extends SupabaseSyncService {
  _FakeSync(super.db, super.client);

  final Set<String> tombstoned = {};

  @override
  Future<bool> confirmBusinessDeleted(String businessId) async =>
      tombstoned.contains(businessId);
}

/// Keeps the device-user pointer in memory — `flutter_secure_storage` has no
/// implementation under `flutter test`.
class _FakeSecureStorage extends SecureStorageService {
  String? deviceUserId;

  @override
  Future<String?> getDeviceUserId() async => deviceUserId;

  @override
  Future<void> clearDeviceUserId() async => deviceUserId = null;
}

/// Controls exactly what the cloud says about the signing-in identity, and
/// stubs the network-bound login steps the route calls after a positive match.
class _FakeAuth extends AuthService {
  _FakeAuth(super.db, super.nav, super.secure, super.sync, super.supabase);

  SupabaseAccountLookup lookup = const SupabaseAccountNone();
  int syncOnLoginCalls = 0;
  int abandonCalls = 0;

  @override
  Future<SupabaseAccountLookup> fetchSupabaseAccount() async => lookup;

  @override
  Future<void> syncOnLogin(String businessId) async {
    syncOnLoginCalls++;
  }

  @override
  Future<UserData?> upsertLocalUserFromProfile() async => null;

  @override
  Future<void> abandonSignIn() async {
    abandonCalls++;
  }
}

void main() {
  late AppDatabase db;
  late _FakeSync sync;
  late _FakeAuth auth;
  late _FakeSecureStorage secure;
  const email = 'okworchimezie@gmail.com';

  /// Never asked in a test that does not expect the warning.
  Future<bool> refuseToPrompt(StaleBusinessWarning w) async {
    fail('unexpected clear-other-business prompt for ${w.businessName}');
  }

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(
      url: 'https://placeholder.supabase.co',
      anonKey: 'placeholder',
    );
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    db = AppDatabase.forTesting(NativeDatabase.memory());
    final client = Supabase.instance.client;
    sync = _FakeSync(db, SupabaseCloudTransport(client));
    secure = _FakeSecureStorage();
    auth = _FakeAuth(db, NavigationService(), secure, sync, client);
  });

  tearDown(() => db.close());

  Future<String> seedBusiness(
    String name, {
    String? userEmail,
    String? authUserId,
    String pin = '__HASHED__',
  }) async {
    final businessId = UuidV7.generate();
    await db.into(db.businesses).insert(
          BusinessesCompanion.insert(id: Value(businessId), name: name),
        );
    if (userEmail != null) {
      await db.into(db.users).insert(
            UsersCompanion.insert(
              id: Value(UuidV7.generate()),
              businessId: businessId,
              authUserId: Value(authUserId),
              name: 'Owner',
              email: Value(userEmail),
              pin: pin,
              pinHash: const Value('deadbeef'),
              pinSalt: const Value('salt'),
              pinIterations: const Value(120000),
            ),
          );
    }
    return businessId;
  }

  Future<void> seedPendingOutboxRow(String businessId) async {
    await db.into(db.syncQueue).insert(
          SyncQueueCompanion.insert(
            id: Value(UuidV7.generate()),
            businessId: businessId,
            actionType: 'orders:upsert',
            payload: '{"id":"${UuidV7.generate()}","business_id":"$businessId"}',
          ),
        );
  }

  SupabaseAccountLookup found(String businessId, String name) =>
      SupabaseAccountFound(
        SupabaseAccountInfo(businessId: businessId, businessName: name),
      );

  // ── the reported bug ─────────────────────────────────────────────────────

  test(
    'phone holding a DELETED business A signs in to B: A is cleared with no '
    'prompt and the route lands in B',
    () async {
      const login = 'a1b2c3d4-0000-4000-8000-000000000001';
      final bizA = await seedBusiness(
        'Old Biz',
        userEmail: email,
        authUserId: login,
      );
      sync.tombstoned.add(bizA);

      final bizB = await seedBusiness('New Biz');
      auth.lookup = found(bizB, 'New Biz');

      final route = await resolvePostVerifyRoute(
        auth,
        email,
        confirmClearOtherBusiness: refuseToPrompt,
      );

      // No local row for B yet → the existing-account screen, which is what a
      // phone signing in to a business it has no rows for should see.
      expect(route, isA<ExistingAccountRoute>());
      expect((route as ExistingAccountRoute).account.businessId, bizB);

      final businesses = await db.select(db.businesses).get();
      expect(businesses.map((b) => b.id), [bizB]);
      expect(await db.select(db.users).get(), isEmpty);
    },
  );

  test(
    'the stale row is never handed back: getUserByEmail must not resolve a row '
    'from a business other than the one the cloud named',
    () async {
      final bizA = await seedBusiness('Old Biz', userEmail: email);
      final bizB = await seedBusiness('New Biz');

      final resolved = await db.storesDao.getUserByEmail(
        email,
        preferredBusinessId: bizB,
      );
      expect(resolved, isNull, reason: 'bizA\'s row belongs to another tenant');
      expect(bizA, isNotNull);
    },
  );

  // ── the decision table ───────────────────────────────────────────────────

  test('A still exists with no pending rows → cleared with no prompt',
      () async {
    await seedBusiness('Old Biz', userEmail: email);
    final bizB = await seedBusiness('New Biz');
    auth.lookup = found(bizB, 'New Biz');

    final route = await resolvePostVerifyRoute(
      auth,
      email,
      confirmClearOtherBusiness: refuseToPrompt,
    );

    expect(route, isA<ExistingAccountRoute>());
    expect((await db.select(db.businesses).get()).map((b) => b.id), [bizB]);
  });

  test(
    'A still exists with pending rows → the warning names the count and the '
    'business; confirming clears A only and records the loss',
    () async {
      final bizA = await seedBusiness('Mama Ngozi Drinks', userEmail: email);
      await seedPendingOutboxRow(bizA);
      await seedPendingOutboxRow(bizA);
      final bizB = await seedBusiness('New Biz');
      auth.lookup = found(bizB, 'New Biz');

      StaleBusinessWarning? shown;
      final route = await resolvePostVerifyRoute(
        auth,
        email,
        confirmClearOtherBusiness: (w) async {
          shown = w;
          return true;
        },
      );

      expect(shown, isNotNull);
      expect(shown!.businessId, bizA);
      expect(shown!.businessName, 'Mama Ngozi Drinks');
      expect(shown!.unsentCount, 2);

      expect(route, isA<ExistingAccountRoute>());
      expect((await db.select(db.businesses).get()).map((b) => b.id), [bizB]);
      expect(await db.syncDao.countPending(businessId: bizA), 0);

      final prefs = await SharedPreferences.getInstance();
      final breadcrumbs =
          prefs.getStringList('wipe_data_loss_breadcrumbs') ?? const [];
      expect(
        breadcrumbs.where((e) => e.contains(bizA)),
        hasLength(1),
        reason: 'invariant #12: the loss is permitted here but never silent',
      );
      expect(breadcrumbs.single, contains('lost=2'));
    },
  );

  test(
    'cancelling the warning leaves the phone untouched and signs the session '
    'out',
    () async {
      final bizA = await seedBusiness('Old Biz', userEmail: email);
      await seedPendingOutboxRow(bizA);
      final bizB = await seedBusiness('New Biz');
      auth.lookup = found(bizB, 'New Biz');

      final route = await resolvePostVerifyRoute(
        auth,
        email,
        confirmClearOtherBusiness: (_) async => false,
      );

      expect(route, isA<SignInCancelledRoute>());
      expect(auth.abandonCalls, 1);
      expect(
        (await db.select(db.businesses).get()).map((b) => b.id),
        unorderedEquals([bizA, bizB]),
      );
      expect(await db.select(db.users).get(), hasLength(1));
      expect(await db.syncDao.countPending(businessId: bizA), 1);
    },
  );

  test(
    'phone holding A and B with pending B rows → A cleared, B\'s rows and '
    'outbox untouched',
    () async {
      final bizA = await seedBusiness('Old Biz', userEmail: email);
      final bizB = await seedBusiness('New Biz', userEmail: email);
      await seedPendingOutboxRow(bizB);
      auth.lookup = found(bizB, 'New Biz');
      expect(await db.select(db.users).get(), hasLength(2),
          reason: 'seed sanity: one row per business for the same email');

      final route = await resolvePostVerifyRoute(
        auth,
        email,
        confirmClearOtherBusiness: refuseToPrompt,
      );

      expect(route, isA<LoginRoute>());
      expect((route as LoginRoute).user.businessId, bizB);
      expect((await db.select(db.businesses).get()).map((b) => b.id), [bizB]);
      expect(await db.syncDao.countPending(businessId: bizA), 0);
      expect(
        await db.syncDao.countPending(businessId: bizB),
        1,
        reason: 'B\'s unsent work must survive — it is the business being '
            'signed in to',
      );
      expect(
        auth.syncOnLoginCalls,
        1,
        reason: 'an incremental pull, not a full re-download',
      );
    },
  );

  test(
    'cloud positively says no business → every local business cleared, '
    'no-account screen',
    () async {
      await seedBusiness('Old Biz', userEmail: email);
      auth.lookup = const SupabaseAccountNone();

      final route = await resolvePostVerifyRoute(
        auth,
        email,
        confirmClearOtherBusiness: refuseToPrompt,
      );

      expect(route, isA<NoAccountFoundRoute>());
      expect(await db.select(db.businesses).get(), isEmpty);
      expect(await db.select(db.users).get(), isEmpty);
    },
  );

  test(
    'cloud unreachable clears NOTHING and falls back to the local PIN login',
    () async {
      final bizA = await seedBusiness('Old Biz', userEmail: email);
      auth.lookup = const SupabaseAccountUnavailable();

      final route = await resolvePostVerifyRoute(
        auth,
        email,
        confirmClearOtherBusiness: refuseToPrompt,
      );

      expect(route, isA<LoginRoute>());
      expect((route as LoginRoute).user.businessId, bizA);
      expect(await db.select(db.users).get(), hasLength(1));
      expect((await db.select(db.businesses).get()).map((b) => b.id), [bizA]);
    },
  );

  test(
    'cloud unreachable with no local row routes to the network message, not '
    'to sign-up (a second business for this email would break invariant #9)',
    () async {
      auth.lookup = const SupabaseAccountUnavailable();

      final route = await resolvePostVerifyRoute(
        auth,
        email,
        confirmClearOtherBusiness: refuseToPrompt,
      );

      expect(route, isA<AccountLookupUnavailableRoute>());
    },
  );

  test(
    'same business, different person → nothing cleared (decision 4, unchanged)',
    () async {
      final bizA = await seedBusiness('Only Biz', userEmail: email);
      auth.lookup = found(bizA, 'Only Biz');

      final route = await resolvePostVerifyRoute(
        auth,
        email,
        confirmClearOtherBusiness: refuseToPrompt,
      );

      expect(route, isA<LoginRoute>());
      expect((route as LoginRoute).user.businessId, bizA);
      expect(await db.select(db.users).get(), hasLength(1));
    },
  );

  test('a row seeded from the cloud profile still routes into PIN setup',
      () async {
    final bizA = await seedBusiness(
      'Only Biz',
      userEmail: email,
      pin: kSetupRequiredPin,
    );
    auth.lookup = found(bizA, 'Only Biz');

    final route = await resolvePostVerifyRoute(
      auth,
      email,
      confirmClearOtherBusiness: refuseToPrompt,
    );

    expect(route, isA<CreatePinRoute>());
  });
}
