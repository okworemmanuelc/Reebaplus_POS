// #812 S5: browser copy wiped after 30 days unused. Pure decision + the
// cold-start hook (AuthService.wipeStaleBrowserCopy).

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/core/services/browser_last_used_service.dart';
import 'package:reebaplus_pos/core/services/supabase_cloud_transport.dart';
import 'package:reebaplus_pos/core/services/supabase_sync_service.dart';
import 'package:reebaplus_pos/shared/services/auth_service.dart';
import 'package:reebaplus_pos/shared/services/navigation_service.dart';
import 'package:reebaplus_pos/shared/services/secure_storage_service.dart';

class _FakeSecure extends SecureStorageService {
  String? userId;
  @override
  Future<String?> getDeviceUserId() async => userId;
  @override
  Future<void> saveDeviceUserId(String id) async => userId = id;
  @override
  Future<void> clearDeviceUserId() async => userId = null;
  @override
  Future<String?> getLastLoggedInEmail() async => null;
  @override
  Future<String?> getAuthMethod() async => null;
  @override
  Future<void> clearAll() async => userId = null;
}

void main() {
  final now = DateTime(2026, 11, 13);

  group('shouldWipe (pure)', () {
    test('no date keeps', () {
      expect(
        BrowserLastUsedService.shouldWipe(now: now, lastUsed: null),
        isFalse,
      );
    });
    test('29 days keeps, exactly 30 keeps, 31 wipes', () {
      bool at(int d) => BrowserLastUsedService.shouldWipe(
        now: now,
        lastUsed: now.subtract(Duration(days: d)),
      );
      expect(at(29), isFalse);
      expect(at(30), isFalse);
      expect(at(31), isTrue);
    });
    test('constant is 30 days', () {
      expect(kBrowserUnusedWipeAfter, const Duration(days: 30));
    });
  });

  group('wipeStaleBrowserCopy (cold-start hook)', () {
    late AppDatabase db;
    late _FakeSecure secure;
    late AuthService auth;
    late String businessId;
    late String userId;

    setUpAll(() async {
      TestWidgetsFlutterBinding.ensureInitialized();
      SharedPreferences.setMockInitialValues({});
      await Supabase.initialize(
        url: 'https://placeholder.supabase.co',
        anonKey: 'placeholder',
      );
    });

    void stampDaysAgo(int d) {
      SharedPreferences.setMockInitialValues({
        BrowserLastUsedService.prefsKey: now
            .subtract(Duration(days: d))
            .millisecondsSinceEpoch,
      });
    }

    setUp(() async {
      db = AppDatabase.forTesting(NativeDatabase.memory());
      secure = _FakeSecure();
      auth = AuthService(
        db,
        NavigationService(),
        secure,
        SupabaseSyncService(
          db,
          SupabaseCloudTransport(Supabase.instance.client),
        ),
        Supabase.instance.client,
      );
      businessId = UuidV7.generate();
      userId = UuidV7.generate();
      await db
          .into(db.businesses)
          .insert(
            BusinessesCompanion.insert(id: Value(businessId), name: 'Shop'),
          );
      await db
          .into(db.users)
          .insert(
            UsersCompanion.insert(
              id: Value(userId),
              businessId: businessId,
              name: 'Staff',
              pin: '__HASHED__',
              pinHash: const Value('pin'),
            ),
          );
      await secure.saveDeviceUserId(userId);
    });

    tearDown(() => db.close());

    test('not web: never wipes, even when very old', () async {
      stampDaysAgo(90);
      expect(await auth.wipeStaleBrowserCopy(now: now, isWeb: false), isFalse);
      expect(await db.select(db.users).get(), isNotEmpty);
    });

    test('web, used 5 days ago: keeps', () async {
      stampDaysAgo(5);
      expect(await auth.wipeStaleBrowserCopy(now: now, isWeb: true), isFalse);
      expect(await db.select(db.users).get(), isNotEmpty);
    });

    test('web, 40 days, clean outbox: wipes and signs out', () async {
      stampDaysAgo(40);
      expect(await auth.wipeStaleBrowserCopy(now: now, isWeb: true), isTrue);
      expect(await db.select(db.users).get(), isEmpty);
      expect(await secure.getDeviceUserId(), isNull);
    });

    test('web, 40 days, unsent rows: keeps the data', () async {
      stampDaysAgo(40);
      await db.customStatement(
        "INSERT INTO sync_queue (id, business_id, action_type, payload, status, attempts, created_at, is_synced) "
        "VALUES ('q1', ?, 'x', '{}', 'pending', 0, 1, 0)",
        [businessId],
      );
      expect(await auth.wipeStaleBrowserCopy(now: now, isWeb: true), isFalse);
      expect(await db.select(db.users).get(), isNotEmpty);
      expect(await secure.getDeviceUserId(), userId);
    });
  });
}
