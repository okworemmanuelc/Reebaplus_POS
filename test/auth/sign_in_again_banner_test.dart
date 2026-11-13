// #798: a dead cloud login never blocks the shop. The banner says sales are
// not backing up and offers "Sign in again"; the verify page has "Not now".

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/services/supabase_cloud_transport.dart';
import 'package:reebaplus_pos/core/services/supabase_sync_service.dart';
import 'package:reebaplus_pos/features/auth/screens/session_expired_screen.dart';
import 'package:reebaplus_pos/features/auth/widgets/sign_in_again_banner.dart';
import 'package:reebaplus_pos/shared/services/auth_service.dart';
import 'package:reebaplus_pos/shared/services/navigation_service.dart';
import 'package:reebaplus_pos/shared/services/secure_storage_service.dart';

class _FakeAuth extends AuthService {
  _FakeAuth(super.db, super.nav, super.secure, super.sync, super.supabase);

  @override
  Future<String?> getAuthMethod() async => 'email';
}

void main() {
  late AppDatabase db;
  late _FakeAuth auth;
  late ValueNotifier<bool> lost;

  final ada = UserData(
    id: 'ada-id',
    businessId: 'biz-1',
    name: 'Ada Okafor',
    email: 'ada@example.com',
    pin: '__HASHED__',
    createdAt: DateTime(2026, 1, 1),
    lastUpdatedAt: DateTime(2026, 1, 1),
    avatarColor: '#3B82F6',
    biometricEnabled: false,
  );

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
    auth = _FakeAuth(
      db,
      NavigationService(),
      SecureStorageService(),
      SupabaseSyncService(db, SupabaseCloudTransport(client)),
      client,
    );
    lost = ValueNotifier<bool>(false);
  });

  tearDown(() => db.close());

  Future<void> pumpBanner(WidgetTester tester) => tester.pumpWidget(
    ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(db),
        authProvider.overrideWith((ref) => auth),
      ],
      child: MaterialApp(
        home: Scaffold(body: SignInAgainBanner(lost: lost)),
      ),
    ),
  );

  testWidgets('hidden while the cloud login is fine', (tester) async {
    auth.value = ada;
    await pumpBanner(tester);
    expect(find.text(kSignInAgainBannerText), findsNothing);
  });

  testWidgets('hidden when nobody is signed in on the device', (tester) async {
    lost.value = true;
    await pumpBanner(tester);
    expect(find.text(kSignInAgainBannerText), findsNothing);
  });

  testWidgets('shows when the login is lost and goes when it returns', (
    tester,
  ) async {
    auth.value = ada;
    await pumpBanner(tester);

    lost.value = true;
    await tester.pump();
    expect(find.text(kSignInAgainBannerText), findsOneWidget);
    expect(find.text('Sign in again'), findsOneWidget);

    lost.value = false;
    await tester.pump();
    expect(find.text(kSignInAgainBannerText), findsNothing);
  });

  testWidgets('"Sign in again" opens the verify page; "Not now" returns', (
    tester,
  ) async {
    auth.value = ada;
    lost.value = true;
    await pumpBanner(tester);

    await tester.tap(find.byKey(const Key('sign-in-again')));
    await tester.pumpAndSettle();
    expect(find.byType(SessionExpiredScreen), findsOneWidget);
    expect(find.text('Not now'), findsOneWidget);

    await tester.tap(find.byKey(const Key('session-expired-not-now')));
    await tester.pumpAndSettle();
    expect(find.byType(SessionExpiredScreen), findsNothing);
    expect(find.text(kSignInAgainBannerText), findsOneWidget);
  });
}
