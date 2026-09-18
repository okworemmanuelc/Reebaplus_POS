import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/features/auth/screens/create_pin_screen.dart';
import 'package:reebaplus_pos/features/auth/screens/login_screen.dart';
import 'package:reebaplus_pos/features/auth/screens/success_dashboard_entry_screen.dart';
import 'package:reebaplus_pos/shared/services/auth_service.dart';
import 'package:reebaplus_pos/shared/services/navigation_service.dart';
import 'package:reebaplus_pos/shared/services/secure_storage_service.dart';

import '../helpers/screen_harness.dart';
import '../helpers/viewports.dart';

const _kLongFullName = 'Dr. Bartholomew Montgomery-Worthington IV';

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
  late String bizId;
  late UserData longNameUser;

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

    final userId = UuidV7.generate();
    await db.into(db.users).insert(
      UsersCompanion.insert(
        id: Value(userId),
        businessId: bizId,
        name: _kLongFullName,
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

    longNameUser = await (db.select(db.users)..where((u) => u.id.equals(userId))).getSingle();
  });

  tearDown(() async {
    await db.close();
  });

  Widget wrapWithTheme({
    required Widget child,
    required Size size,
    TextScaler textScaler = TextScaler.noScaling,
    ProviderContainer? container,
  }) {
    final mediaQuery = MediaQuery(
      data: MediaQueryData(
        size: size,
        textScaler: textScaler,
      ),
      child: child,
    );

    if (container != null) {
      return UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.amberLight(),
          home: Scaffold(body: mediaQuery),
        ),
      );
    }

    return ProviderScope(
      child: MaterialApp(
        theme: AppTheme.amberLight(),
        home: Scaffold(body: mediaQuery),
      ),
    );
  }

  group('SuccessOverlay viewport tests (Issue #261)', () {
    for (final (label, size) in [
      ('phoneSe1Portrait', phoneSe1Portrait),
      ('pixel7Portrait', pixel7Portrait),
      ('androidCompactLandscape', androidCompactLandscape),
    ]) {
      testWidgets('long name is centred and inset >= 16dp on $label', (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        await tester.pumpWidget(
          wrapWithTheme(
            size: size,
            child: SuccessOverlay(
              user: longNameUser,
              checkScale: const AlwaysStoppedAnimation(1.0),
              checkFade: const AlwaysStoppedAnimation(1.0),
            ),
          ),
        );
        await tester.pump();

        expectNoOverflow(tester);

        final welcomeFinder = find.text('Welcome, $_kLongFullName');
        final openingFinder = find.text('Opening Reebaplus POS...');

        expect(welcomeFinder, findsOneWidget);
        expect(openingFinder, findsOneWidget);

        final welcomeText = tester.widget<Text>(welcomeFinder);
        final openingText = tester.widget<Text>(openingFinder);

        expect(welcomeText.textAlign, TextAlign.center);
        expect(openingText.textAlign, TextAlign.center);

        final welcomeRect = tester.getRect(welcomeFinder);
        final openingRect = tester.getRect(openingFinder);

        // Assert horizontal insets >= 16dp from screen edges
        expect(welcomeRect.left, greaterThanOrEqualTo(16.0));
        expect(welcomeRect.right, lessThanOrEqualTo(size.width - 16.0));
        expect(openingRect.left, greaterThanOrEqualTo(16.0));
        expect(openingRect.right, lessThanOrEqualTo(size.width - 16.0));

        // Assert centred horizontally on screen
        final screenCenterX = size.width / 2;
        expect((welcomeRect.center.dx - screenCenterX).abs(), lessThanOrEqualTo(1.0));
        expect((openingRect.center.dx - screenCenterX).abs(), lessThanOrEqualTo(1.0));

        // Clean unmount to cancel _LoadingDots timers
        await tester.pumpWidget(const SizedBox());
        await tester.pump();
      });
    }

    testWidgets('zero overflow at shortest landscape phone at max text scale (1.3x)', (tester) async {
      const size = androidCompactLandscape;
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        wrapWithTheme(
          size: size,
          textScaler: const TextScaler.linear(1.3),
          child: SuccessOverlay(
            user: longNameUser,
            checkScale: const AlwaysStoppedAnimation(1.0),
            checkFade: const AlwaysStoppedAnimation(1.0),
          ),
        ),
      );
      await tester.pump();

      expectNoOverflow(tester);

      final welcomeFinder = find.text('Welcome, $_kLongFullName');
      final welcomeText = tester.widget<Text>(welcomeFinder);
      expect(welcomeText.textAlign, TextAlign.center);

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });
  });

  group('SuccessDashboardEntryScreen viewport tests (Issue #261)', () {
    for (final (label, size) in [
      ('phoneSe1Portrait', phoneSe1Portrait),
      ('pixel7Portrait', pixel7Portrait),
      ('androidCompactLandscape', androidCompactLandscape),
    ]) {
      testWidgets('headings are centred and inset on $label', (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        await tester.pumpWidget(
          wrapWithTheme(
            size: size,
            child: const SuccessDashboardEntryScreen(),
          ),
        );
        await tester.pump();

        expectNoOverflow(tester);

        final headingFinder = find.text('Your business is ready!');
        final subFinder = find.text('Preparing your dashboard...');

        expect(headingFinder, findsOneWidget);
        expect(subFinder, findsOneWidget);

        final headingText = tester.widget<Text>(headingFinder);
        final subText = tester.widget<Text>(subFinder);

        expect(headingText.textAlign, TextAlign.center);
        expect(subText.textAlign, TextAlign.center);

        final headingRect = tester.getRect(headingFinder);
        final subRect = tester.getRect(subFinder);

        expect(headingRect.left, greaterThanOrEqualTo(16.0));
        expect(headingRect.right, lessThanOrEqualTo(size.width - 16.0));
        expect(subRect.left, greaterThanOrEqualTo(16.0));
        expect(subRect.right, lessThanOrEqualTo(size.width - 16.0));

        final screenCenterX = size.width / 2;
        expect((headingRect.center.dx - screenCenterX).abs(), lessThanOrEqualTo(1.0));
        expect((subRect.center.dx - screenCenterX).abs(), lessThanOrEqualTo(1.0));

        await tester.pumpWidget(const SizedBox());
        await tester.pump();
      });
    }

    testWidgets('zero overflow at shortest landscape phone at 1.3x text scale', (tester) async {
      const size = androidCompactLandscape;
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        wrapWithTheme(
          size: size,
          textScaler: const TextScaler.linear(1.3),
          child: const SuccessDashboardEntryScreen(),
        ),
      );
      await tester.pump();

      expectNoOverflow(tester);

      final headingFinder = find.text('Your business is ready!');
      final headingText = tester.widget<Text>(headingFinder);
      expect(headingText.textAlign, TextAlign.center);

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });
  });

  group('CreatePinScreen viewport tests (Issue #261)', () {
    for (final (label, size) in [
      ('phoneSe1Portrait', phoneSe1Portrait),
      ('pixel7Portrait', pixel7Portrait),
      ('androidCompactLandscape', androidCompactLandscape),
    ]) {
      testWidgets('PIN headings are centred and inset on $label', (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final container = ProviderContainer(
          overrides: [
            databaseProvider.overrideWithValue(db),
          ],
        );
        addTearDown(container.dispose);

        await tester.pumpWidget(
          wrapWithTheme(
            size: size,
            container: container,
            child: CreatePinScreen(user: longNameUser),
          ),
        );
        await tester.pump();

        expectNoOverflow(tester);

        final titleFinder = find.text('Create a PIN');
        expect(titleFinder, findsOneWidget);

        final titleText = tester.widget<Text>(titleFinder);
        expect(titleText.textAlign, TextAlign.center);

        final titleRect = tester.getRect(titleFinder);
        expect(titleRect.left, greaterThanOrEqualTo(16.0));
        expect(titleRect.right, lessThanOrEqualTo(size.width - 16.0));

        final screenCenterX = size.width / 2;
        // In landscape, the title is inside the left column of a 2-column layout; in portrait it spans the full screen.
        if (size == androidCompactLandscape) {
          final instructionFinder = find.text('Choose a 6-digit PIN for quick login');
          expect(instructionFinder, findsOneWidget);
          final instructionText = tester.widget<Text>(instructionFinder);
          expect(instructionText.textAlign, TextAlign.center);
        } else {
          expect((titleRect.center.dx - screenCenterX).abs(), lessThanOrEqualTo(1.0));

          final welcomeFinder = find.text('Welcome, $_kLongFullName!');
          final instructionFinder = find.text('Choose a 6-digit PIN for quick login');

          expect(welcomeFinder, findsOneWidget);
          expect(instructionFinder, findsOneWidget);

          final welcomeText = tester.widget<Text>(welcomeFinder);
          final instructionText = tester.widget<Text>(instructionFinder);

          expect(welcomeText.textAlign, TextAlign.center);
          expect(instructionText.textAlign, TextAlign.center);

          final welcomeRect = tester.getRect(welcomeFinder);
          expect(welcomeRect.left, greaterThanOrEqualTo(16.0));
          expect(welcomeRect.right, lessThanOrEqualTo(size.width - 16.0));
          expect((welcomeRect.center.dx - screenCenterX).abs(), lessThanOrEqualTo(1.0));
        }

        await tester.pumpWidget(const SizedBox());
        await tester.pump();
      });
    }

    testWidgets('zero overflow at compact phone SE1 at 1.3x text scale', (tester) async {
      const size = phoneSe1Portrait;
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
        ],
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(
        wrapWithTheme(
          size: size,
          container: container,
          textScaler: const TextScaler.linear(1.3),
          child: CreatePinScreen(user: longNameUser),
        ),
      );
      await tester.pump();

      expectNoOverflow(tester);

      final welcomeFinder = find.text('Welcome, $_kLongFullName!');
      final welcomeText = tester.widget<Text>(welcomeFinder);
      expect(welcomeText.textAlign, TextAlign.center);

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });
  });

  group('LoginScreen PinPad welcome back test (Issue #261)', () {
    testWidgets('welcome back text has textAlign center', (tester) async {
      const size = pixel7Portrait;
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

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
        wrapWithTheme(
          size: size,
          container: container,
          child: LoginScreen(presetUser: longNameUser),
        ),
      );
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }

      final welcomeFinder = find.text('Welcome back, Dr.');
      expect(welcomeFinder, findsOneWidget);

      final welcomeText = tester.widget<Text>(welcomeFinder);
      expect(welcomeText.textAlign, TextAlign.center);

      expectNoOverflow(tester);

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });
  });
}
