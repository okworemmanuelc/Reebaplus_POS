// cold_start_deletion_gate_test.dart
//
// Test suite for the cold-start / pre-sign-in deletion gate (§10.3):
//   * Returns false when there is no local business or device user.
//   * Returns false and does not wipe when the business is not deleted.
//   * Wipes and full-logouts (reverting the device to a fresh state) and
//     returns true when the business has been confirmed as deleted.

import 'package:drift/drift.dart' hide isNull, isNotNull;
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
  bool stubbedBusinessDeletedResult = false;

  _FakeSyncService(super.db, super.supabase);

  @override
  Future<bool> confirmBusinessDeleted(String businessId) async {
    return stubbedBusinessDeletedResult;
  }
}

class _FakeSecureStorageService extends SecureStorageService {
  String? userId;
  String? email;
  String? authMethod;

  @override
  Future<String?> getDeviceUserId() async => userId;

  @override
  Future<void> saveDeviceUserId(String userId) async {
    this.userId = userId;
  }

  @override
  Future<void> clearDeviceUserId() async {
    userId = null;
  }

  @override
  Future<String?> getLastLoggedInEmail() async => email;

  @override
  Future<void> saveLastLoggedInEmail(String email) async {
    this.email = email;
  }

  @override
  Future<String?> getAuthMethod() async => authMethod;

  @override
  Future<void> saveAuthMethod(String method) async {
    authMethod = method;
  }

  @override
  Future<void> clearAll() async {
    userId = null;
    email = null;
    authMethod = null;
  }
}

void main() {
  late AppDatabase db;
  late _FakeSyncService syncService;
  late _FakeSecureStorageService secureStorage;
  late AuthService auth;
  late NavigationService nav;

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
    nav = NavigationService();
    syncService = _FakeSyncService(db, SupabaseCloudTransport(Supabase.instance.client));
    secureStorage = _FakeSecureStorageService();
    auth = AuthService(
      db,
      nav,
      secureStorage,
      syncService,
      Supabase.instance.client,
    );
  });

  tearDown(() async {
    await db.close();
  });

  test('returns false when no business or device user exists', () async {
    final result = await auth.wipeIfActiveBusinessDeleted();
    expect(result, isFalse);
  });

  test('returns false when business exists but confirmBusinessDeleted is false', () async {
    final businessId = UuidV7.generate();
    await db.into(db.businesses).insert(
          BusinessesCompanion.insert(id: Value(businessId), name: 'Stable Business'),
        );

    final userId = UuidV7.generate();
    await db.into(db.users).insert(
          UsersCompanion.insert(
            id: Value(userId),
            businessId: businessId,
            name: 'Staff Member',
            pin: '__HASHED__',
            pinHash: const Value('pin'),
          ),
        );

    await secureStorage.saveDeviceUserId(userId);
    syncService.stubbedBusinessDeletedResult = false;

    final result = await auth.wipeIfActiveBusinessDeleted();

    expect(result, isFalse);
    // Data remains intact
    final users = await db.select(db.users).get();
    expect(users, isNotEmpty);
  });

  test('wipes and full-logouts, returning true when confirmBusinessDeleted is true', () async {
    final businessId = UuidV7.generate();
    await db.into(db.businesses).insert(
          BusinessesCompanion.insert(id: Value(businessId), name: 'Deleted Business'),
        );

    final userId = UuidV7.generate();
    await db.into(db.users).insert(
          UsersCompanion.insert(
            id: Value(userId),
            businessId: businessId,
            name: 'Staff Member',
            pin: '__HASHED__',
            pinHash: const Value('pin'),
          ),
        );

    await secureStorage.saveDeviceUserId(userId);
    await secureStorage.saveLastLoggedInEmail('staff@example.com');
    await secureStorage.saveAuthMethod('email');

    syncService.stubbedBusinessDeletedResult = true;

    final result = await auth.wipeIfActiveBusinessDeleted();

    expect(result, isTrue);
    expect(auth.businessDeletedRemotely, isTrue);

    // Secure storage is cleared
    expect(await secureStorage.getDeviceUserId(), isNull);
    expect(await secureStorage.getLastLoggedInEmail(), isNull);
    expect(await secureStorage.getAuthMethod(), isNull);

    // Database is cleared
    final users = await db.select(db.users).get();
    expect(users, isEmpty);
    final businesses = await db.select(db.businesses).get();
    expect(businesses, isEmpty);
  });
}
