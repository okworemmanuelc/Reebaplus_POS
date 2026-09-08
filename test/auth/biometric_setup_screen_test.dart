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
import 'package:reebaplus_pos/features/auth/screens/biometric_setup_screen.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:reebaplus_pos/shared/services/auth_service.dart';
import 'package:reebaplus_pos/shared/services/navigation_service.dart';
import 'package:reebaplus_pos/shared/services/secure_storage_service.dart';
import '../helpers/viewports.dart';

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
    try {
      await Supabase.initialize(
        url: 'https://placeholder.supabase.co',
        anonKey: 'placeholder',
      );
    } catch (_) {}
  });

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() => db.close());

  final testUser = UserData(
    id: 'user-1',
    businessId: 'biz-1',
    name: 'Ada Lovelace',
    pin: '123456',
    avatarColor: '#3B82F6',
    biometricEnabled: false,
    createdAt: DateTime(2026, 1, 1),
    lastUpdatedAt: DateTime(2026, 1, 1),
  );

  Widget createWidget({required bool isNewBusinessSetup}) {
    final client = Supabase.instance.client;
    final fake = _FakeAuth(
      db,
      NavigationService(),
      SecureStorageService(),
      SupabaseSyncService(db, SupabaseCloudTransport(client)),
      client,
    );

    return ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(db),
        authProvider.overrideWith((ref) => fake),
      ],
      child: MaterialApp(
        home: BiometricSetupScreen(
          user: testUser,
          isNewBusinessSetup: isNewBusinessSetup,
        ),
      ),
    );
  }

  testWidgets('BiometricSetupScreen renders without overflow at pixel7Landscape', (tester) async {
    await pumpWithViewport(
      tester,
      size: pixel7Landscape,
      child: createWidget(isNewBusinessSetup: true),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);

    // Verify 48dp tap target floor on AppButton
    final buttonFinder = find.widgetWithText(AppButton, 'Enable Biometrics');
    expect(buttonFinder, findsOneWidget);
    final buttonSize = tester.getSize(buttonFinder);
    expect(buttonSize.height, greaterThanOrEqualTo(kMinInteractiveDimension));
  });

  testWidgets('BiometricSetupScreen renders without overflow at androidCompactLandscape', (tester) async {
    await pumpWithViewport(
      tester,
      size: androidCompactLandscape,
      child: createWidget(isNewBusinessSetup: true),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('BiometricSetupScreen renders without overflow at pixel7Portrait', (tester) async {
    await pumpWithViewport(
      tester,
      size: pixel7Portrait,
      child: createWidget(isNewBusinessSetup: true),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
