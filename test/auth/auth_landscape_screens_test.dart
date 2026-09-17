import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:drift/native.dart';
import 'package:drift/drift.dart' show Value;
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
import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:reebaplus_pos/features/auth/widgets/pin_keypad.dart';

import 'package:reebaplus_pos/features/auth/screens/access_granted_screen.dart';
import 'package:reebaplus_pos/features/auth/screens/ceo_sign_up_screen.dart';
import 'package:reebaplus_pos/features/auth/screens/coming_soon_screen.dart';
import 'package:reebaplus_pos/features/auth/screens/create_pin_screen.dart';
import 'package:reebaplus_pos/features/auth/screens/email_entry_screen.dart';
import 'package:reebaplus_pos/features/auth/screens/existing_account_screen.dart';
import 'package:reebaplus_pos/features/auth/screens/login_screen.dart';
import 'package:reebaplus_pos/features/auth/screens/no_account_found_screen.dart';
import 'package:reebaplus_pos/features/auth/screens/otp_verification_screen.dart';
import 'package:reebaplus_pos/features/auth/screens/staff_sign_up_screen.dart';
import 'package:reebaplus_pos/features/auth/screens/success_dashboard_entry_screen.dart';
import 'package:reebaplus_pos/features/auth/screens/welcome_screen.dart';
import 'package:flutter/services.dart';
import '../helpers/viewports.dart';

const _connectivityChannel = MethodChannel(
  'dev.fluttercommunity.plus/connectivity',
);

class _FakeAuth extends AuthService {
  _FakeAuth(super.db, super.nav, super.secure, super.sync, super.supabase);

  @override
  Future<String?> getDeviceUserId() async => null;
}

void main() {
  late AppDatabase db;
  late UserData testUser;
  late String bizId;

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
    bizId = UuidV7.generate();
    await db.into(db.businesses).insert(
      BusinessesCompanion.insert(id: Value(bizId), name: 'Test Business'),
    );

    final ceoRoleId = UuidV7.generate();
    await db.into(db.roles).insert(
      RolesCompanion.insert(
        id: Value(ceoRoleId),
        businessId: bizId,
        name: 'CEO',
        slug: 'ceo',
      ),
    );

    final cashierRoleId = UuidV7.generate();
    await db.into(db.roles).insert(
      RolesCompanion.insert(
        id: Value(cashierRoleId),
        businessId: bizId,
        name: 'Cashier',
        slug: 'cashier',
      ),
    );

    final userId = UuidV7.generate();
    await db.into(db.users).insert(
      UsersCompanion.insert(
        id: Value(userId),
        businessId: bizId,
        name: 'Alice',
        pin: '123456',
        pinHash: const Value('deadbeef'),
      ),
    );
    await db.into(db.userBusinesses).insert(
      UserBusinessesCompanion.insert(
        id: Value(UuidV7.generate()),
        businessId: bizId,
        userId: userId,
        roleId: ceoRoleId,
        status: const Value('active'),
      ),
    );

    final staff2Id = UuidV7.generate();
    await db.into(db.users).insert(
      UsersCompanion.insert(
        id: Value(staff2Id),
        businessId: bizId,
        name: 'Bob',
        pin: '654321',
        pinHash: const Value('beefdead'),
      ),
    );
    await db.into(db.userBusinesses).insert(
      UserBusinessesCompanion.insert(
        id: Value(UuidV7.generate()),
        businessId: bizId,
        userId: staff2Id,
        roleId: cashierRoleId,
        status: const Value('active'),
      ),
    );

    testUser = await (db.select(db.users)..where((u) => u.id.equals(userId))).getSingle();
  });

  tearDown(() => db.close());

  ProviderContainer createContainer() {
    final client = Supabase.instance.client;
    final fake = _FakeAuth(
      db,
      NavigationService(),
      SecureStorageService(),
      SupabaseSyncService(db, SupabaseCloudTransport(client)),
      client,
    );

    return ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        authProvider.overrideWith((ref) => fake),
      ],
    );
  }

  Widget wrap(Widget screen, ProviderContainer container) {
    return UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: ThemeData.dark(),
        home: screen,
      ),
    );
  }

  Future<void> pumpScreen(WidgetTester tester, Widget screen, Size size) async {
    final container = createContainer();
    addTearDown(container.dispose);
    await pumpWithViewport(
      tester,
      size: size,
      child: wrap(screen, container),
    );
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  group('Phase 1 - LoginScreen responsive layout', () {
    for (final (name, size) in [
      ('pixel7Landscape', pixel7Landscape),
      ('androidCompactLandscape', androidCompactLandscape),
      ('pixel7Portrait', pixel7Portrait),
    ]) {
      testWidgets('renders cleanly without overflow at $name', (tester) async {
        await pumpScreen(tester, LoginScreen(presetUser: testUser), size);
        expect(tester.takeException(), isNull);

        // Verify key elements render
        expect(find.text('Welcome back, Alice'), findsOneWidget);
        expect(find.byType(PinKeypad), findsOneWidget);
      });
    }
  });

  group('Phase 1 - CreatePinScreen responsive layout', () {
    for (final (name, size) in [
      ('pixel7Landscape', pixel7Landscape),
      ('androidCompactLandscape', androidCompactLandscape),
      ('pixel7Portrait', pixel7Portrait),
    ]) {
      testWidgets('renders cleanly without overflow at $name', (tester) async {
        await pumpScreen(tester, CreatePinScreen(user: testUser, isNewBusinessSetup: false), size);
        expect(tester.takeException(), isNull);
        expect(find.text('Create a PIN'), findsOneWidget);
      });
    }
  });

  group('Phase 1 - CeoSignUpScreen responsive layout', () {
    for (final (name, size) in [
      ('pixel7Landscape', pixel7Landscape),
      ('androidCompactLandscape', androidCompactLandscape),
      ('pixel7Portrait', pixel7Portrait),
    ]) {
      testWidgets('renders cleanly without overflow at $name', (tester) async {
        await pumpScreen(tester, const CeoSignUpScreen(verifiedEmail: 'ceo@test.com'), size);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);

        if (size == pixel7Landscape || size == androidCompactLandscape) {
          // Verify compact step text appears in short viewports
          expect(find.textContaining('Step 1 of'), findsOneWidget);
        }
      });
    }
  });

  group('Phase 1 - SuccessDashboardEntryScreen responsive layout', () {
    for (final (name, size) in [
      ('pixel7Landscape', pixel7Landscape),
      ('androidCompactLandscape', androidCompactLandscape),
      ('pixel7Portrait', pixel7Portrait),
    ]) {
      testWidgets('renders cleanly without overflow at $name', (tester) async {
        await pumpScreen(tester, const SuccessDashboardEntryScreen(), size);
        expect(tester.takeException(), isNull);
        // Clear pending auto-forward timer by unmounting before disposal
        await tester.pumpWidget(const SizedBox());
      });
    }
  });

  group('Phase 1 - ComingSoonScreen responsive layout', () {
    for (final (name, size) in [
      ('pixel7Landscape', pixel7Landscape),
      ('androidCompactLandscape', androidCompactLandscape),
      ('pixel7Portrait', pixel7Portrait),
    ]) {
      testWidgets('renders cleanly without overflow at $name', (tester) async {
        await pumpScreen(tester, const ComingSoonScreen(
          title: 'Terms of Service',
          message: 'Terms of service will be available soon.',
        ), size);
        expect(tester.takeException(), isNull);
      });
    }
  });

  group('Phase 1 - Verify-only screens responsive layout', () {
    for (final (name, size) in [
      ('pixel7Landscape', pixel7Landscape),
      ('androidCompactLandscape', androidCompactLandscape),
      ('pixel7Portrait', pixel7Portrait),
    ]) {
      testWidgets('EmailEntryScreen renders cleanly at $name', (tester) async {
        await pumpScreen(tester, const EmailEntryScreen(), size);
        expect(tester.takeException(), isNull);
      });

      testWidgets('OtpVerificationScreen renders cleanly at $name', (tester) async {
        await pumpScreen(tester, const OtpVerificationScreen(
          user: null,
          email: 'test@example.com',
        ), size);
        expect(tester.takeException(), isNull);
        // Let OtpBoxRow's 350ms keyboard request timer fire
        await tester.pump(const Duration(milliseconds: 400));
        // Cancel resend countdown timer by unmounting
        await tester.pumpWidget(const SizedBox());
        await tester.pump();
      });

      testWidgets('ExistingAccountScreen renders cleanly at $name', (tester) async {
        await pumpScreen(tester, const ExistingAccountScreen(
          email: 'test@example.com',
          account: SupabaseAccountInfo(
            businessId: 'biz-1',
            businessName: 'Existing Biz',
            roleName: 'Cashier',
            roleSlug: 'cashier',
          ),
        ), size);
        expect(tester.takeException(), isNull);
      });

      testWidgets('NoAccountFoundScreen renders cleanly at $name', (tester) async {
        await pumpScreen(tester, const NoAccountFoundScreen(email: 'test@example.com'), size);
        expect(tester.takeException(), isNull);
      });

      testWidgets('StaffSignUpScreen renders cleanly at $name', (tester) async {
        await pumpScreen(tester, const StaffSignUpScreen(), size);
        expect(tester.takeException(), isNull);
      });

      testWidgets('WelcomeScreen renders cleanly at $name', (tester) async {
        await pumpScreen(tester, const WelcomeScreen(), size);
        expect(tester.takeException(), isNull);
      });

      testWidgets('AccessGrantedScreen renders cleanly at $name', (tester) async {
        await pumpScreen(tester, AccessGrantedScreen(user: testUser), size);
        expect(tester.takeException(), isNull);
        // Clear repeating pulse animation and delayed controller by unmounting
        await tester.pumpWidget(const SizedBox());
      });
    }
  });

  group('Interactive control tap target floors (48dp)', () {
    testWidgets('AppButton normal & large maintain >= 48dp height in short viewports', (tester) async {
      await pumpScreen(
        tester,
        Column(
          children: [
            AppButton(text: 'Normal Button', onPressed: () {}),
            AppButton(text: 'Large Button', size: AppButtonSize.large, onPressed: () {}),
            AppButton(text: 'Small Button', size: AppButtonSize.small, onPressed: () {}),
            AppButton(text: 'XSmall Button', size: AppButtonSize.xsmall, onPressed: () {}),
          ],
        ),
        pixel7Landscape,
      );

      final normalFinder = find.widgetWithText(AppButton, 'Normal Button');
      final largeFinder = find.widgetWithText(AppButton, 'Large Button');
      final smallFinder = find.widgetWithText(AppButton, 'Small Button');
      final xsmallFinder = find.widgetWithText(AppButton, 'XSmall Button');

      expect(tester.getSize(normalFinder).height, greaterThanOrEqualTo(kMinInteractiveDimension));
      expect(tester.getSize(largeFinder).height, greaterThanOrEqualTo(kMinInteractiveDimension));
      expect(tester.getSize(smallFinder).height, equals(40.0));
      expect(tester.getSize(xsmallFinder).height, equals(32.0));
    });
  });
}
