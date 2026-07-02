import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:drift/native.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/services/supabase_cloud_transport.dart';
import 'package:reebaplus_pos/core/services/supabase_sync_service.dart';
import 'package:reebaplus_pos/shared/services/auth_service.dart';
import 'package:reebaplus_pos/shared/services/navigation_service.dart';
import 'package:reebaplus_pos/shared/services/secure_storage_service.dart';
import 'package:reebaplus_pos/features/auth/screens/staff_sign_up_screen.dart';
import 'package:reebaplus_pos/features/auth/screens/email_entry_screen.dart';
import 'package:reebaplus_pos/features/auth/screens/welcome_screen.dart';

class _FakeAuth extends AuthService {
  _FakeAuth(super.db, super.nav, super.secure, super.sync, super.supabase);

  @override
  Future<String?> getDeviceUserId() async => null;
}

void main() {
  late AppDatabase db;

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
  });

  tearDown(() => db.close());

  Future<void> pumpWelcome(WidgetTester tester) async {
    final client = Supabase.instance.client;
    final fake = _FakeAuth(
      db,
      NavigationService(),
      SecureStorageService(),
      SupabaseSyncService(db, SupabaseCloudTransport(client)),
      client,
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          authProvider.overrideWith((ref) => fake),
        ],
        child: const MaterialApp(home: WelcomeScreen()),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('renders logo, name, tagline, and the three CTAs', (tester) async {
    await pumpWelcome(tester);

    expect(find.byType(Image), findsOneWidget);
    expect(find.text('Reebaplus'), findsOneWidget);
    expect(
      find.text('Sales, stock, and staff — all in your pocket.'),
      findsOneWidget,
    );
    expect(find.text('Create a new business'), findsOneWidget);
    expect(find.text('Join with invite code'), findsOneWidget);
    expect(find.textContaining('Sign in'), findsOneWidget);
  });

  testWidgets('Create a new business routes to Email Entry Screen with createBusinessIntent', (tester) async {
    await pumpWelcome(tester);

    await tester.runAsync(() async {
      await tester.tap(find.text('Create a new business'));
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }
    });

    expect(find.byType(EmailEntryScreen), findsOneWidget);
    final emailEntryScreen = tester.widget<EmailEntryScreen>(find.byType(EmailEntryScreen));
    expect(emailEntryScreen.createBusinessIntent, isTrue);
  });

  testWidgets('Join with invite code routes to Staff Sign Up', (tester) async {
    await pumpWelcome(tester);

    await tester.tap(find.text('Join with invite code'));
    await tester.pumpAndSettle();

    expect(find.byType(StaffSignUpScreen), findsOneWidget);
    expect(find.text('Enter your invite code'), findsOneWidget);
  });
}
