// cold_start_restore_test.dart
//
// #812 — there is no PIN unlock any more. At cold start a device with a
// signed-in user is bound straight from local data
// (AuthService.restoreSignedInUser), never the network (invariant #11):
//   * no device user pointer → nothing is bound;
//   * a pointer whose local row is missing → nothing is bound;
//   * a pointer with its row → that user is bound (not as a fresh sign-in).

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/core/services/supabase_cloud_transport.dart';
import 'package:reebaplus_pos/core/services/supabase_sync_service.dart';
import 'package:reebaplus_pos/shared/services/auth_service.dart';
import 'package:reebaplus_pos/shared/services/navigation_service.dart';
import 'package:reebaplus_pos/shared/services/secure_storage_service.dart';

class _FakeSyncService extends SupabaseSyncService {
  _FakeSyncService(super.db, super.supabase);

  @override
  Future<bool> confirmBusinessDeleted(String businessId) async => false;
}

class _FakeSecureStorage extends SecureStorageService {
  String? userId;

  @override
  Future<String?> getDeviceUserId() async => userId;
}

/// Records the bind instead of running its sync / session side effects.
class _RecordingAuth extends AuthService {
  _RecordingAuth(super.db, super.nav, super.secure, super.sync, super.supabase);

  final binds = <({String userId, bool freshSignIn})>[];

  @override
  void setCurrentUser(UserData user, {bool freshSignIn = false}) {
    binds.add((userId: user.id, freshSignIn: freshSignIn));
    value = user;
  }
}

void main() {
  late AppDatabase db;
  late _FakeSecureStorage secure;
  late _RecordingAuth auth;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    try {
      await Supabase.initialize(
        url: 'https://placeholder.supabase.co',
        anonKey: 'placeholder',
      );
    } catch (_) {}
  });

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    secure = _FakeSecureStorage();
    auth = _RecordingAuth(
      db,
      NavigationService(),
      secure,
      _FakeSyncService(db, SupabaseCloudTransport(Supabase.instance.client)),
      Supabase.instance.client,
    );
  });

  tearDown(() => db.close());

  Future<String> seedUser() async {
    final businessId = UuidV7.generate();
    await db
        .into(db.businesses)
        .insert(
          BusinessesCompanion.insert(id: Value(businessId), name: 'Shop'),
        );
    final userId = UuidV7.generate();
    await db
        .into(db.users)
        .insert(
          UsersCompanion.insert(
            id: Value(userId),
            businessId: businessId,
            name: 'Ada',
            pin: kSetupRequiredPin,
          ),
        );
    return userId;
  }

  test('no device user → nothing is bound', () async {
    expect(await auth.restoreSignedInUser(), isNull);
    expect(auth.binds, isEmpty);
    expect(auth.currentUser, isNull);
  });

  test('a device user whose row is missing → nothing is bound', () async {
    secure.userId = UuidV7.generate();
    expect(await auth.restoreSignedInUser(), isNull);
    expect(auth.binds, isEmpty);
  });

  test('a device user with its row opens straight in, no PIN', () async {
    final userId = await seedUser();
    secure.userId = userId;

    final restored = await auth.restoreSignedInUser();

    expect(restored?.id, userId);
    expect(auth.currentUser?.id, userId);
    // A cold-start restore is not a fresh sign-in: no new cloud session row.
    expect(auth.binds, [(userId: userId, freshSignIn: false)]);
  });

  test('a second call while already bound does not bind again', () async {
    final userId = await seedUser();
    secure.userId = userId;
    await auth.restoreSignedInUser();
    await auth.restoreSignedInUser();
    expect(auth.binds, hasLength(1));
  });
}
