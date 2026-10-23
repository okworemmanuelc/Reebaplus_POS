// Visual goldens + layout checks for Auth PR 3 (#462): the lock screen, Create
// PIN, Biometric setup, Session expired, PinDialog, the user picker sheet and
// the success overlay.
//
// Goldens: <screen>_<size>_<theme>.png at 390x844, 844x390 (24dp status bar +
// 48dp side inset), 800x1280 and 1280x800, light and dark. Dialog and sheet
// goldens are 390x844 and 844x390 only. Regenerate with:
//
//     flutter test --update-goldens test/redesign/auth_lock_golden_test.dart
//
// Animations are frozen: every pump is a fixed duration and nothing waits for
// a repeating animation (step pulse, loading dots) to settle.

import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/services/supabase_cloud_transport.dart';
import 'package:reebaplus_pos/core/services/supabase_sync_service.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/features/auth/screens/biometric_setup_screen.dart';
import 'package:reebaplus_pos/features/auth/screens/create_pin_screen.dart';
import 'package:reebaplus_pos/features/auth/screens/login_screen.dart';
import 'package:reebaplus_pos/features/auth/widgets/branded_auth_background.dart';
import 'package:reebaplus_pos/features/auth/widgets/pin_keypad.dart';
import 'package:reebaplus_pos/main.dart' show buildSessionExpiredScreenForTest;
import 'package:reebaplus_pos/shared/services/auth_service.dart';
import 'package:reebaplus_pos/shared/services/navigation_service.dart';
import 'package:reebaplus_pos/shared/services/pin_hasher.dart';
import 'package:reebaplus_pos/shared/services/secure_storage_service.dart';
import 'package:reebaplus_pos/shared/widgets/pin_dialog.dart';

import '../helpers/screen_harness.dart';

const _connectivityChannel = MethodChannel(
  'dev.fluttercommunity.plus/connectivity',
);

/// No device user, no plugin-backed storage reads: the lock screen opens on a
/// preset user or on the email box.
class _FakeAuth extends AuthService {
  _FakeAuth(super.db, super.nav, super.secure, super.sync, super.supabase);

  @override
  Future<String?> getDeviceUserId() async => null;

  @override
  Future<String?> getAuthMethod() async => null;
}

const _sizes = <String, (Size, EdgeInsets)>{
  '390x844': (Size(390, 844), EdgeInsets.only(top: 24, bottom: 24)),
  '844x390': (Size(844, 390), EdgeInsets.only(top: 24, right: 48)),
  '800x1280': (Size(800, 1280), EdgeInsets.zero),
  '1280x800': (Size(1280, 800), EdgeInsets.zero),
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // No DEBUG ribbon in the goldens (the dialog and sheet shots take the whole
  // app).
  WidgetsApp.debugAllowBannerOverride = false;

  late ScreenTestEnvironment env;
  late UserData ada;

  setUp(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          _connectivityChannel,
          (call) async => call.method == 'check' ? <String>['wifi'] : null,
        );
    env = await setupScreenTestEnvironment(
      productCount: 0,
      businessName: 'Stallion Global',
    );
    ada = UserData(
      id: 'ada-id',
      businessId: env.businessId,
      name: 'Ada Okafor',
      email: 'ada@example.com',
      pin: '__HASHED__',
      createdAt: DateTime(2026, 1, 1),
      lastUpdatedAt: DateTime(2026, 1, 1),
      avatarColor: '#3B82F6',
      biometricEnabled: false,
    );
  });
  tearDown(() => env.dispose());

  AuthService fakeAuth() {
    final client = Supabase.instance.client;
    return _FakeAuth(
      env.db,
      NavigationService(),
      SecureStorageService(),
      SupabaseSyncService(env.db, SupabaseCloudTransport(client)),
      client,
    );
  }

  void setInsets(WidgetTester tester, EdgeInsets p) {
    tester.view.padding = FakeViewPadding(
      top: p.top,
      right: p.right,
      bottom: p.bottom,
    );
    tester.view.viewPadding = FakeViewPadding(
      top: p.top,
      right: p.right,
      bottom: p.bottom,
    );
    addTearDown(tester.view.resetPadding);
    addTearDown(tester.view.resetViewPadding);
  }

  /// Pumps [screen] with fixed-duration pumps only.
  Future<void> pump(
    WidgetTester tester,
    Widget screen, {
    required Size size,
    required EdgeInsets padding,
    Brightness brightness = Brightness.light,
    TextScaler? textScaler,
    bool followView = false,
    List<Override> overrides = const [],
  }) async {
    setInsets(tester, padding);
    await pumpScreen(
      tester,
      env: env,
      size: size,
      padding: padding,
      bottomNavHeight: 0,
      theme: brightness == Brightness.light
          ? AppTheme.light()
          : AppTheme.dark(),
      screen: screen,
      settle: false,
      textScaler: textScaler,
      followView: followView,
      overrides: [authProvider.overrideWith((ref) => fakeAuth()), ...overrides],
    );
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 600));
  }

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 50));
  }

  final screens = <String, (Widget Function(), Type)>{
    'login': (() => LoginScreen(presetUser: ada), LoginScreen),
    'create_pin': (
      () => const CreatePinScreen(isNewBusinessSetup: true),
      CreatePinScreen,
    ),
    'biometric_setup': (
      () => BiometricSetupScreen(user: ada, isNewBusinessSetup: true),
      BiometricSetupScreen,
    ),
    'session_expired': (() => buildSessionExpiredScreenForTest(ada), Scaffold),
  };

  // ── Screen goldens ─────────────────────────────────────────────────────────
  for (final entry in screens.entries) {
    for (final s in _sizes.entries) {
      for (final b in Brightness.values) {
        final themeKey = b == Brightness.light ? 'light' : 'dark';
        final name = '${entry.key}_${s.key}_$themeKey';
        testWidgets('golden $name', (tester) async {
          final (size, padding) = s.value;
          await pump(
            tester,
            entry.value.$1(),
            size: size,
            padding: padding,
            brightness: b,
          );
          expect(tester.takeException(), isNull);
          await expectLater(
            find.byType(entry.value.$2).first,
            matchesGoldenFile('goldens/$name.png'),
          );
          await unmount(tester);
        });
      }
    }
  }

  // Create PIN, plain reset path (no step indicator, with the user's name).
  testWidgets('create PIN (reset path) renders at every size', (tester) async {
    for (final s in _sizes.values) {
      final (size, padding) = s;
      await pump(
        tester,
        CreatePinScreen(user: ada),
        size: size,
        padding: padding,
      );
      expect(tester.takeException(), isNull);
      expect(find.text('Create a PIN'), findsOneWidget);
      expect(find.byType(PinKeypad), findsOneWidget);
      await unmount(tester);
    }
  });

  // ── No overflow ────────────────────────────────────────────────────────────
  final overflowSizes = <String, (Size, EdgeInsets)>{
    '360x640@1.3': (const Size(360, 640), const EdgeInsets.only(top: 24)),
    ..._sizes,
  };
  for (final entry in screens.entries) {
    for (final s in overflowSizes.entries) {
      testWidgets('no overflow: ${entry.key} at ${s.key}', (tester) async {
        final (size, padding) = s.value;
        await pump(
          tester,
          entry.value.$1(),
          size: size,
          padding: padding,
          textScaler: s.key.contains('@1.3')
              ? const TextScaler.linear(1.3)
              : null,
        );
        expect(tester.takeException(), isNull);
        await unmount(tester);
      });
    }
  }

  testWidgets('lock screen keeps a two-column keypad off the greeting', (
    tester,
  ) async {
    await pump(
      tester,
      LoginScreen(presetUser: ada),
      size: const Size(844, 390),
      padding: const EdgeInsets.only(top: 24, right: 48),
    );
    final greeting = tester.getRect(find.text('Welcome back, Ada'));
    final keypad = tester.getRect(find.byType(PinKeypad));
    expect(greeting.right, lessThan(keypad.left));
    expect(find.text('Forgot PIN?'), findsOneWidget);
    expect(find.text('Not Ada? Switch account'), findsOneWidget);
    // Keys are at least 48dp.
    expect(
      tester.getSize(find.byType(PinKey).first).shortestSide,
      greaterThanOrEqualTo(48),
    );
    await unmount(tester);
  });

  // ── Dialog, sheet and overlay goldens ──────────────────────────────────────
  const popupSizes = <String, (Size, EdgeInsets)>{
    '390x844': (Size(390, 844), EdgeInsets.only(top: 24, bottom: 24)),
    '844x390': (Size(844, 390), EdgeInsets.only(top: 24, right: 48)),
  };

  for (final s in popupSizes.entries) {
    for (final b in Brightness.values) {
      final themeKey = b == Brightness.light ? 'light' : 'dark';
      testWidgets('golden pin_dialog_${s.key}_$themeKey', (tester) async {
        final (size, padding) = s.value;
        await pump(
          tester,
          const _DialogHost(),
          size: size,
          padding: padding,
          brightness: b,
        );
        expect(find.byType(PinDialog), findsOneWidget);
        expect(tester.takeException(), isNull);
        await expectLater(
          find.byType(MaterialApp),
          matchesGoldenFile('goldens/pin_dialog_${s.key}_$themeKey.png'),
        );
        await unmount(tester);
      });

      testWidgets('golden user_picker_sheet_${s.key}_$themeKey', (
        tester,
      ) async {
        final (size, padding) = s.value;
        await _seedSharedPin(env);
        await pump(
          tester,
          const LoginScreen(),
          size: size,
          padding: padding,
          brightness: b,
        );
        await _openPicker(tester);
        expect(find.text('Who is logging in?'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await expectLater(
          find.byType(MaterialApp),
          matchesGoldenFile('goldens/user_picker_sheet_${s.key}_$themeKey.png'),
        );
        await unmount(tester);
      });

      testWidgets('golden success_overlay_${s.key}_$themeKey', (tester) async {
        final (size, padding) = s.value;
        await pump(
          tester,
          Scaffold(
            body: BrandedAuthBackground(
              child: SafeArea(
                child: SuccessOverlay(
                  user: ada,
                  checkScale: const AlwaysStoppedAnimation(1.0),
                  checkFade: const AlwaysStoppedAnimation(1.0),
                ),
              ),
            ),
          ),
          size: size,
          padding: padding,
          brightness: b,
        );
        expect(tester.takeException(), isNull);
        await expectLater(
          find.byType(Scaffold).first,
          matchesGoldenFile('goldens/success_overlay_${s.key}_$themeKey.png'),
        );
        await unmount(tester);
      });
    }
  }

  testWidgets('user picker sheet scrolls and never overflows at 360x640@1.3', (
    tester,
  ) async {
    await _seedSharedPin(env);
    await pump(
      tester,
      const LoginScreen(),
      size: const Size(360, 640),
      padding: const EdgeInsets.only(top: 24, bottom: 24),
      textScaler: const TextScaler.linear(1.3),
    );
    await _openPicker(tester);
    expect(find.text('Who is logging in?'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await unmount(tester);
  });

  // ── Keyboard up ────────────────────────────────────────────────────────────
  const phones = <(String, Size, EdgeInsets, double)>[
    ('360x640', Size(360, 640), EdgeInsets.only(top: 24, bottom: 24), 280),
    ('844x390', Size(844, 390), EdgeInsets.only(top: 24, right: 48), 300),
  ];

  for (final (name, size, padding, keyboard) in phones) {
    testWidgets('lock screen email box fits above the keyboard $name', (
      tester,
    ) async {
      await pump(
        tester,
        const LoginScreen(),
        size: size,
        padding: padding,
        followView: true,
        textScaler: const TextScaler.linear(1.15),
      );
      await tester.tap(find.byType(TextFormField));
      await tester.pump();
      tester.view.viewInsets = FakeViewPadding(bottom: keyboard);
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump(const Duration(milliseconds: 600));
      await tester.enterText(find.byType(TextFormField), 'ada@example.com');
      await tester.pump(const Duration(milliseconds: 600));
      expect(tester.takeException(), isNull);
      final field = tester.getRect(find.byType(TextFormField));
      expect(field.bottom, lessThanOrEqualTo(size.height - keyboard + 1));
      tester.view.resetViewInsets();
      await unmount(tester);
    });

    testWidgets('lock screen (preset user) with the keyboard up $name', (
      tester,
    ) async {
      await pump(
        tester,
        LoginScreen(presetUser: ada),
        size: size,
        padding: padding,
        followView: true,
        textScaler: const TextScaler.linear(1.15),
      );
      tester.view.viewInsets = FakeViewPadding(bottom: keyboard);
      await tester.pump(const Duration(milliseconds: 600));
      expect(tester.takeException(), isNull);
      tester.view.resetViewInsets();
      await unmount(tester);
    });

    testWidgets('PIN pop-up fits above the keyboard $name', (tester) async {
      await pump(
        tester,
        const _DialogHost(),
        size: size,
        padding: padding,
        followView: true,
        textScaler: const TextScaler.linear(1.15),
      );
      tester.view.viewInsets = FakeViewPadding(bottom: keyboard);
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.byType(PinDialog), findsOneWidget);
      expect(tester.takeException(), isNull);
      tester.view.resetViewInsets();
      await unmount(tester);
    });
  }

  testWidgets('PinDialog still cancels with null and the keys type a PIN', (
    tester,
  ) async {
    await pump(
      tester,
      const _DialogHost(),
      size: const Size(390, 844),
      padding: const EdgeInsets.only(top: 24, bottom: 24),
    );
    expect(find.text('Manager Authorisation'), findsOneWidget);
    expect(
      find.text('Enter a 6-digit manager PIN to continue'),
      findsOneWidget,
    );
    await tester.tap(find.text('Cancel'));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 300));
    }
    expect(find.byType(PinDialog), findsNothing);
    await unmount(tester);
  });
}

/// Two staff on one email sharing PIN 123456, so the lock screen asks who.
Future<void> _seedSharedPin(ScreenTestEnvironment env) async {
  final roleId = UuidV7.generate();
  await env.db
      .into(env.db.roles)
      .insert(
        RolesCompanion.insert(
          id: Value(roleId),
          businessId: env.businessId,
          name: 'Cashier',
          slug: 'cashier',
        ),
      );
  // The same email can sit in two businesses (unique per business), and both
  // staff share the PIN.
  final otherBusiness = UuidV7.generate();
  await env.db
      .into(env.db.businesses)
      .insert(
        BusinessesCompanion.insert(
          id: Value(otherBusiness),
          name: 'Abuja Traders',
        ),
      );
  for (final (name, business) in [
    ('Ada Okafor', env.businessId),
    ('Bola Adeyemi', otherBusiness),
  ]) {
    final id = UuidV7.generate();
    final salt = PinHasher.generateSaltBase64();
    await env.db
        .into(env.db.users)
        .insert(
          UsersCompanion.insert(
            id: Value(id),
            businessId: business,
            name: name,
            email: const Value('ada@example.com'),
            pin: '__HASHED__',
            pinHash: Value(PinHasher.hashBase64('123456', salt, 1)),
            pinSalt: Value(salt),
            pinIterations: const Value(1),
          ),
        );
    await env.db
        .into(env.db.userBusinesses)
        .insert(
          UserBusinessesCompanion.insert(
            id: Value(UuidV7.generate()),
            businessId: business,
            userId: id,
            roleId: roleId,
            status: const Value('active'),
          ),
        );
  }
}

/// Types the shared email and PIN on the lock screen and waits for the picker.
Future<void> _openPicker(WidgetTester tester) async {
  await tester.enterText(find.byType(TextFormField), 'ada@example.com');
  await tester.pump();
  for (final d in '123456'.split('')) {
    await tester.tap(find.text(d));
    await tester.pump();
  }
  // Real async DB + hashing work, then the sheet's route animation.
  for (var i = 0; i < 20; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// Opens [PinDialog] over an empty page as soon as it is mounted.
class _DialogHost extends StatefulWidget {
  const _DialogHost();

  @override
  State<_DialogHost> createState() => _DialogHostState();
}

class _DialogHostState extends State<_DialogHost> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) PinDialog.show(context);
    });
  }

  @override
  Widget build(BuildContext context) => const Scaffold(body: SizedBox());
}
