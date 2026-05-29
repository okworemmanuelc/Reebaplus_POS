// staff_detail_screen_test.dart
//
// Widget coverage for StaffDetailScreen's view-only mode (master plan §9.5):
//   * readOnly: true  → no Change role / Suspend actions (your own card);
//   * readOnly: false → both actions render (a manageable card).
//
// The tap that opens this screen (own card → readOnly, manageable card →
// editable) lives in _StaffCard in staff_management_screen.dart; this test
// exercises the detail screen's readOnly gate directly.

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
import 'package:reebaplus_pos/core/services/supabase_sync_service.dart';
import 'package:reebaplus_pos/shared/services/auth_service.dart';
import 'package:reebaplus_pos/shared/services/navigation_service.dart';
import 'package:reebaplus_pos/shared/services/secure_storage_service.dart';
import 'package:reebaplus_pos/features/staff/screens/staff_detail_screen.dart';

/// Real AuthService with the one platform-bound startup call stubbed out.
/// currentUser stays null — the detail screen renders the member from the
/// seeded membership regardless of who's logged in.
class _FakeAuth extends AuthService {
  _FakeAuth(super.db, super.nav, super.secure, super.sync, super.supabase);

  @override
  Future<String?> getDeviceUserId() async => null;
}

void main() {
  late AppDatabase db;
  late String biz;
  late String membershipId;

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

    final ceoRoleId = UuidV7.generate();
    await db.into(db.roles).insert(RolesCompanion.insert(
        id: Value(ceoRoleId), businessId: biz, name: 'CEO', slug: 'ceo'));

    final userId = UuidV7.generate();
    await db.into(db.users).insert(UsersCompanion.insert(
          id: Value(userId),
          businessId: biz,
          name: 'Adaeze',
          pin: '__HASHED__',
        ));

    membershipId = UuidV7.generate();
    await db.into(db.userBusinesses).insert(UserBusinessesCompanion.insert(
          id: Value(membershipId),
          businessId: biz,
          userId: userId,
          roleId: ceoRoleId,
          status: const Value('active'),
        ));
  });

  tearDown(() => db.close());

  Future<void> pumpDetail(WidgetTester tester, {required bool readOnly}) async {
    // Tall, 375-wide viewport (scale factor 1.0) so the whole detail ListView
    // — including the Change role / Suspend buttons at the bottom — lays out
    // and builds. Otherwise the lazy ListView never builds the off-screen
    // buttons, so their absence wouldn't distinguish "hidden" from "scrolled
    // off". reset() restores the default surface after the test.
    tester.view.physicalSize = const Size(375, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final client = Supabase.instance.client;
    final fake = _FakeAuth(
      db,
      NavigationService(),
      SecureStorageService(),
      SupabaseSyncService(db, client),
      client,
    );
    // AuthService's constructor points businessIdResolver at its (null) current
    // user, so scope the session providers to the seeded business AFTER it's
    // built. The detail screen renders the member regardless of who's signed
    // in, so a null current user is fine.
    db.businessIdResolver = () => biz;
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        authProvider.overrideWith((ref) => fake),
      ],
    );
    addTearDown(container.dispose);

    // Pump inside runAsync so the real event loop drains: drift query streams
    // emit, and initState's _loadSales (await .first + a customSelect) runs to
    // completion. Under the fake clock that tester.pump() uses, those never
    // settle, which also stalls db.close() at teardown.
    await tester.runAsync(() async {
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: StaffDetailScreen(
              membershipId: membershipId,
              readOnly: readOnly,
            ),
          ),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 250));
    });
    // Frames to rebuild with the stream data the providers received above.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }

  testWidgets('view-only card hides Change role / Suspend (§9.5)',
      (tester) async {
    await pumpDetail(tester, readOnly: true);

    // The member still renders…
    expect(find.text('Adaeze'), findsOneWidget);
    // …but you can't act on yourself.
    expect(find.text('Change role'), findsNothing);
    expect(find.text('Suspend'), findsNothing);
  });

  testWidgets('manageable card shows Change role / Suspend', (tester) async {
    await pumpDetail(tester, readOnly: false);

    expect(find.text('Adaeze'), findsOneWidget);
    expect(find.text('Change role'), findsOneWidget);
    expect(find.text('Suspend'), findsOneWidget);
  });
}
