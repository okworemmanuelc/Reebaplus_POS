// lock_screen_test.dart
//
// The "Who's working?" picker is gone: every lock lands on the device user's
// PIN screen. These guard what the picker used to take care of:
//   * lockApp keeps the device pointer, so the PIN screen shows the same user.
//   * A shared-till logout clears the leaving user's PIN, so the device pointer
//     moves to a staff member who still has a PIN on this device.
//   * The PIN screen refuses a suspended member's PIN (the picker used to hide
//     suspended staff).

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/services/supabase_cloud_transport.dart';
import 'package:reebaplus_pos/core/services/supabase_sync_service.dart';
import 'package:reebaplus_pos/features/auth/screens/login_screen.dart';
import 'package:reebaplus_pos/features/auth/widgets/pin_keypad.dart';
import 'package:reebaplus_pos/shared/services/auth_service.dart';
import 'package:reebaplus_pos/shared/services/navigation_service.dart';
import 'package:reebaplus_pos/shared/services/pin_hasher.dart';
import 'package:reebaplus_pos/shared/services/secure_storage_service.dart';

import '../helpers/viewports.dart';

const _connectivityChannel = MethodChannel(
  'dev.fluttercommunity.plus/connectivity',
);

class _FakeSecureStorageService extends SecureStorageService {
  String? userId;

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
  Future<void> saveLastLoggedInEmail(String email) async {}

  @override
  Future<void> clearAll() async {
    userId = null;
  }
}

void main() {
  late AppDatabase db;
  late _FakeSecureStorageService secure;
  late AuthService auth;
  late String biz;
  late String roleId;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          _connectivityChannel,
          (call) async => call.method == 'check' ? <String>['wifi'] : null,
        );
    try {
      await Supabase.initialize(
        url: 'https://placeholder.supabase.co',
        anonKey: 'placeholder',
      );
    } catch (_) {}
  });

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    secure = _FakeSecureStorageService();
    final client = Supabase.instance.client;
    auth = AuthService(
      db,
      NavigationService(),
      secure,
      SupabaseSyncService(db, SupabaseCloudTransport(client)),
      client,
    );

    biz = UuidV7.generate();
    await db
        .into(db.businesses)
        .insert(BusinessesCompanion.insert(id: Value(biz), name: 'Shared Till'));
    roleId = UuidV7.generate();
    await db.into(db.roles).insert(RolesCompanion.insert(
        id: Value(roleId), businessId: biz, name: 'Cashier', slug: 'cashier'));
  });

  tearDown(() => db.close());

  /// Inserts a staff member with a real (cheap, 1-iteration) PIN hash so
  /// [AuthService.getUsersByPin] can match it.
  Future<UserData> addStaff(
    String name, {
    String pin = '123456',
    String status = 'active',
  }) async {
    final id = UuidV7.generate();
    final salt = PinHasher.generateSaltBase64();
    await db.into(db.users).insert(UsersCompanion.insert(
          id: Value(id),
          businessId: biz,
          name: name,
          pin: '__HASHED__',
          pinHash: Value(PinHasher.hashBase64(pin, salt, 1)),
          pinSalt: Value(salt),
          pinIterations: const Value(1),
        ));
    await db.into(db.userBusinesses).insert(UserBusinessesCompanion.insert(
          id: Value(UuidV7.generate()),
          businessId: biz,
          userId: id,
          roleId: roleId,
          status: Value(status),
        ));
    return (db.select(db.users)..where((u) => u.id.equals(id))).getSingle();
  }

  test('lockApp clears the signed-in user but keeps the device pointer',
      () async {
    final alice = await addStaff('Alice');
    await auth.saveDeviceUserId(alice.id);
    auth.value = alice;

    auth.lockApp();

    expect(auth.value, isNull);
    expect(await auth.getDeviceUserId(), alice.id);
    expect(auth.deviceUserIdNotifier.value, alice.id);
  });

  test(
      'shared-till logout moves the device pointer to a staff member who '
      'still has a PIN', () async {
    final alice = await addStaff('Alice');
    final bob = await addStaff('Bob');
    await auth.saveDeviceUserId(bob.id);
    auth.value = bob;

    await auth.logOutCurrentUser();

    expect(auth.value, isNull);
    final bobRow = await (db.select(db.users)
          ..where((u) => u.id.equals(bob.id)))
        .getSingle();
    expect(bobRow.pinHash, isNull, reason: "the leaving user's PIN is cleared");
    expect(await auth.getDeviceUserId(), alice.id);
    expect(auth.deviceUserIdNotifier.value, alice.id);
  });

  testWidgets('the PIN screen refuses a suspended member', (tester) async {
    final carol = await tester.runAsync(
      () => addStaff('Carol', status: 'suspended'),
    );

    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        authProvider.overrideWith((ref) => auth),
      ],
    );
    addTearDown(container.dispose);

    await pumpWithViewport(
      tester,
      size: pixel7Portrait,
      child: UncontrolledProviderScope(
        container: container,
        child: MaterialApp(home: LoginScreen(presetUser: carol)),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));

    for (final digit in '123456'.split('')) {
      await tester.tap(find.widgetWithText(PinKey, digit));
      await tester.pump();
    }
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    expect(
      find.text('Your account is suspended. Ask your manager to reactivate it.'),
      findsOneWidget,
    );
    expect(auth.value, isNull);

    // Let the notification's auto-dismiss timer run out.
    await tester.pump(const Duration(seconds: 5));
  });
}
