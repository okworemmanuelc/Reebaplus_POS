// who_is_working_screen_test.dart
//
// Widget coverage for the Who Is Working picker (master plan §8):
//   * with N>1 active staff, one tappable card per active member;
//   * suspended staff are hidden (§8.3);
//   * tapping a card with a PIN set routes to the PIN screen (§8.4).

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:drift/drift.dart' hide isNotNull;
import 'package:drift/native.dart';
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
import 'package:reebaplus_pos/features/auth/screens/login_screen.dart';
import 'package:reebaplus_pos/features/auth/screens/who_is_working_screen.dart';

/// Real AuthService with the one platform-bound call the picker makes at
/// startup stubbed out: no device user → the screen falls back to the single
/// local business (which is what the test seeds).
class _FakeAuth extends AuthService {
  _FakeAuth(super.db, super.nav, super.secure, super.sync, super.supabase);

  @override
  Future<String?> getDeviceUserId() async => null;
}

void main() {
  late AppDatabase db;
  late String biz;
  late String ceoRoleId;
  late String cashierRoleId;

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

    biz = UuidV7.generate();
    await db.into(db.businesses).insert(
        BusinessesCompanion.insert(id: Value(biz), name: 'Mama Put Bar'));

    ceoRoleId = UuidV7.generate();
    cashierRoleId = UuidV7.generate();
    await db.into(db.roles).insert(RolesCompanion.insert(
        id: Value(ceoRoleId), businessId: biz, name: 'CEO', slug: 'ceo'));
    await db.into(db.roles).insert(RolesCompanion.insert(
        id: Value(cashierRoleId),
        businessId: biz,
        name: 'Cashier',
        slug: 'cashier'));

    Future<void> addStaff(String name, String roleId, String status) async {
      final userId = UuidV7.generate();
      await db.into(db.users).insert(UsersCompanion.insert(
            id: Value(userId),
            businessId: biz,
            name: name,
            pin: '__HASHED__',
            pinHash: const Value('deadbeef'), // has a PIN → tap goes to PIN
          ));
      await db.into(db.userBusinesses).insert(UserBusinessesCompanion.insert(
            id: Value(UuidV7.generate()),
            businessId: biz,
            userId: userId,
            roleId: roleId,
            status: Value(status),
          ));
    }

    await addStaff('Alice', ceoRoleId, 'active');
    await addStaff('Bob', cashierRoleId, 'active');
    await addStaff('Carol', cashierRoleId, 'active');
    await addStaff('Dan', cashierRoleId, 'suspended');
  });

  tearDown(() => db.close());

  Future<ProviderContainer> pumpPicker(WidgetTester tester) async {
    final client = Supabase.instance.client;
    final fake = _FakeAuth(
      db,
      NavigationService(),
      SecureStorageService(),
      SupabaseSyncService(db, SupabaseCloudTransport(client)),
      client,
    );
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        authProvider.overrideWith((ref) => fake),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: WhoIsWorkingScreen()),
      ),
    );
    // Resolve businessId (async) + first stream emission + entrance fades.
    // Avoid pumpAndSettle: the branded fade / route transitions are timed.
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    return container;
  }

  testWidgets('shows one card per active staff member, suspended hidden',
      (tester) async {
    await pumpPicker(tester);

    expect(find.text("Who's working?"), findsOneWidget);
    expect(find.text('Alice'), findsOneWidget);
    expect(find.text('Bob'), findsOneWidget);
    expect(find.text('Carol'), findsOneWidget);
    // Suspended staff never appear in the picker (§8.3).
    expect(find.text('Dan'), findsNothing);
  });

  testWidgets('tapping a staff card routes to the PIN screen', (tester) async {
    await pumpPicker(tester);

    await tester.tap(find.text('Alice'));
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }

    expect(find.byType(LoginScreen), findsOneWidget);
  });
}
