// Regression guard for the "used after being disposed" crash on
// "Login with a different account" from the PIN screen.
//
// `deviceUserIdProvider` and `activeCustomerProvider` EXPOSE a ValueNotifier
// that is OWNED by another long-lived object (AuthService / CartService). They
// must therefore be plain `Provider`s: a `ChangeNotifierProvider` disposes the
// notifier it exposes on every recompute (Riverpod's
// `ChangeNotifierProviderElement.runOnDispose` runs on recompute, not only on
// teardown), and these providers recompute whenever the object they watch
// notifies. As a `ChangeNotifierProvider`, `deviceUserIdProvider` recomputed on
// every `AuthService.value` change (login / lock / logout) and disposed the
// shared `deviceUserIdNotifier` out from under `clearDeviceUserId()` /
// `fullLogout()`, which then threw:
//
//     A ValueNotifier<String?> was used after being disposed.
//
// These tests recreate the ownership + recompute conditions and assert the
// borrowed notifier survives — they fail (throw on the post-recompute
// `.value =`) if either provider is reverted to a ChangeNotifierProvider.

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/services/supabase_cloud_transport.dart';
import 'package:reebaplus_pos/core/services/supabase_sync_service.dart';
import 'package:reebaplus_pos/shared/services/auth_service.dart';
import 'package:reebaplus_pos/shared/services/navigation_service.dart';
import 'package:reebaplus_pos/shared/services/secure_storage_service.dart';

/// Secure storage that keeps the device-user pointer in memory so
/// `saveDeviceUserId` / `clearDeviceUserId` exercise the real notifier writes
/// without touching the platform keystore.
class _InMemorySecure extends SecureStorageService {
  String? _userId;
  @override
  Future<String?> getDeviceUserId() async => _userId;
  @override
  Future<void> saveDeviceUserId(String userId) async => _userId = userId;
  @override
  Future<void> clearDeviceUserId() async => _userId = null;
  @override
  Future<void> clearAll() async => _userId = null;
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

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    final client = Supabase.instance.client;
    auth = AuthService(
      db,
      NavigationService(),
      _InMemorySecure(),
      SupabaseSyncService(db, SupabaseCloudTransport(client)),
      client,
    );
  });

  tearDown(() async => db.close());

  ProviderContainer makeContainer() {
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        authProvider.overrideWith((ref) => auth),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  /// Seeds a business + user and returns the persisted [UserData], so a test can
  /// drive a genuine `AuthService.value` change (the real recompute trigger).
  Future<UserData> seedUser() async {
    final businessId = UuidV7.generate();
    await db
        .into(db.businesses)
        .insert(BusinessesCompanion.insert(id: Value(businessId), name: 'Biz'));
    return db.into(db.users).insertReturning(
          UsersCompanion.insert(
            id: Value(UuidV7.generate()),
            businessId: businessId,
            name: 'Owner',
            pin: '__HASHED__',
            pinHash: const Value('pin'),
          ),
        );
  }

  group('deviceUserIdProvider', () {
    test('exposes the AuthService-owned notifier, not a copy', () {
      final container = makeContainer();
      expect(
        identical(
          container.read(deviceUserIdProvider),
          auth.deviceUserIdNotifier,
        ),
        isTrue,
        reason: 'the provider must borrow the shared notifier',
      );
    });

    test(
      'shared notifier survives a recompute (login → logout no longer crashes)',
      () async {
        final container = makeContainer();
        // Instantiate + subscribe the provider (as the inventory screen does).
        container.read(deviceUserIdProvider);

        // A real login flips AuthService.value, which notifies authProvider and
        // recomputes every provider that watches it — including this one. The
        // read flushes that recompute synchronously.
        auth.value = await seedUser();
        container.read(deviceUserIdProvider);

        // The old ChangeNotifierProvider disposed the notifier during that
        // recompute; the subsequent logout write then threw. It must not.
        expect(
          () => auth.deviceUserIdNotifier.value = 'someone',
          returnsNormally,
        );
        await auth.clearDeviceUserId();
        expect(auth.deviceUserIdNotifier.value, isNull);
      },
    );

    test('force-refresh does not dispose the borrowed notifier', () {
      final container = makeContainer();
      container.read(deviceUserIdProvider);
      // refresh forcibly disposes + recreates the provider state — the exact
      // runOnDispose path that killed the shared notifier under the bug.
      container.refresh(deviceUserIdProvider);
      expect(
        () => auth.deviceUserIdNotifier.value = 'still-alive',
        returnsNormally,
      );
    });
  });

  group('activeCustomerProvider', () {
    test('shared notifier survives a recompute', () {
      final container = makeContainer();
      final cart = container.read(cartProvider);
      container.read(activeCustomerProvider);
      container.refresh(activeCustomerProvider);
      expect(() => cart.activeCustomer.value = null, returnsNormally);
    });
  });
}
