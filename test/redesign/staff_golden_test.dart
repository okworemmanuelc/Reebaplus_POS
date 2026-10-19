// Visual goldens for Staff Management, Staff Detail, Invite Staff and the
// Assigned stores sheet (#440 part 1, PRD #346 Wave 2 batch C). No mockup:
// built from the shared parts and the Wave 1 patterns.
//
// - `staff_management_*`, `staff_detail_*`, `invite_staff_*`: 390x844
//   (gesture nav), 844x390 with a 24dp status bar and a 48dp nav bar on the
//   right, 800x1280 and 1280x800, light + dark.
// - `staff_stores_sheet_*`: 390x844 and 844x390, light + dark.
//
// Sample data only (business "Stallion Global", store "Abuja HQ", made-up
// people); every date is a fixed value. The Invites tab is not drawn: its
// "N days left" line is relative to the clock. Regenerate with:
//
//     flutter test --update-goldens test/redesign/staff_golden_test.dart

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/permissions/gate.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/services/supabase_cloud_transport.dart';
import 'package:reebaplus_pos/core/services/supabase_sync_service.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/features/staff/screens/invite_staff_screen.dart';
import 'package:reebaplus_pos/features/staff/screens/staff_detail_screen.dart';
import 'package:reebaplus_pos/features/staff/screens/staff_management_screen.dart';
import 'package:reebaplus_pos/features/staff/widgets/staff_parts.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../helpers/screen_harness.dart';
import '../helpers/staff_fixture.dart';

class _NoPullSync extends SupabaseSyncService {
  _NoPullSync(super.db, super.transport);

  @override
  Future<void> pullChanges(String businessId) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ScreenTestEnvironment env;
  late StaffFixture fx;

  setUp(() async {
    env = await setupScreenTestEnvironment(
      productCount: 0,
      businessName: 'Stallion Global',
    );
    fx = await seedStaff(env);
  });
  tearDown(() => env.dispose());

  setUpAll(() => WidgetsApp.debugAllowBannerOverride = false);
  tearDownAll(() => WidgetsApp.debugAllowBannerOverride = true);

  Future<void> deliver(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 250));
    }
  }

  Future<void> pump(
    WidgetTester tester,
    Size size,
    FakeViewPadding insets,
    ThemeData theme,
    Widget screen,
  ) async {
    tester.view.padding = insets;
    tester.view.viewPadding = insets;
    addTearDown(tester.view.resetPadding);
    addTearDown(tester.view.resetViewPadding);
    await pumpScreen(
      tester,
      env: env,
      size: size,
      screen: screen,
      bottomNavHeight: 0,
      followView: true,
      grantedKeys: staffGrants,
      roleRank: GateTier.ceo,
      theme: theme,
      overrides: [
        currentBusinessNameProvider.overrideWithValue('Stallion Global'),
        supabaseSyncServiceProvider.overrideWithValue(
          _NoPullSync(env.db, SupabaseCloudTransport(Supabase.instance.client)),
        ),
      ],
      settle: false,
    );
    await deliver(tester);
  }

  for (final brightness in Brightness.values) {
    final themeName = brightness == Brightness.light ? 'light' : 'dark';
    final theme = brightness == Brightness.light
        ? AppTheme.light()
        : AppTheme.dark();

    for (final (sizeName, size, insets) in const [
      ('390x844', Size(390, 844), FakeViewPadding(top: 24, bottom: 24)),
      ('844x390_insets', Size(844, 390), FakeViewPadding(top: 24, right: 48)),
      ('800x1280', Size(800, 1280), FakeViewPadding()),
      ('1280x800', Size(1280, 800), FakeViewPadding()),
    ]) {
      for (final (name, build, type) in <(String, Widget Function(), Type)>[
        (
          'staff_management',
          () => const StaffManagementScreen(),
          StaffManagementScreen,
        ),
        (
          'staff_detail',
          () => StaffDetailScreen(membershipId: fx.membershipIds['Ngozi']!),
          StaffDetailScreen,
        ),
        ('invite_staff', () => const InviteStaffScreen(), InviteStaffScreen),
      ]) {
        testWidgets('$name $sizeName $themeName', (tester) async {
          await pump(tester, size, insets, theme, build());
          expect(tester.takeException(), isNull);
          await expectLater(
            find.byType(type),
            matchesGoldenFile('goldens/${name}_${sizeName}_$themeName.png'),
          );
          await disposeScreen(tester);
        });
      }
    }

    for (final (sizeName, size, insets) in const [
      ('390x844', Size(390, 844), FakeViewPadding(top: 24, bottom: 24)),
      ('844x390', Size(844, 390), FakeViewPadding(top: 24, right: 48)),
    ]) {
      testWidgets('staff stores sheet $sizeName $themeName', (tester) async {
        await pump(
          tester,
          size,
          insets,
          theme,
          StaffDetailScreen(membershipId: fx.membershipIds['Ngozi']!),
        );
        await tester.ensureVisible(find.text('Assigned store'));
        await tester.pump();
        await tester.tap(find.text('Assigned store'));
        await deliver(tester);
        expect(find.byKey(StaffKeys.storesSheet), findsOneWidget);
        expect(tester.takeException(), isNull);
        await expectLater(
          find.byType(MaterialApp),
          matchesGoldenFile(
            'goldens/staff_stores_sheet_${sizeName}_$themeName.png',
          ),
        );
        await disposeScreen(tester);
      });
    }
  }
}
