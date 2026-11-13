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
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/features/auth/screens/success_dashboard_entry_screen.dart';

import '../helpers/screen_harness.dart';
import '../helpers/viewports.dart';

const _kLongFullName = 'Dr. Bartholomew Montgomery-Worthington IV';

const _connectivityChannel = MethodChannel(
  'dev.fluttercommunity.plus/connectivity',
);

void main() {
  late AppDatabase db;
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
}
