// Staff Management, Staff Detail and Invite Staff after the restyle (#440
// part 1, PRD #346 Wave 2 batch C): every control still renders, every
// permission-hidden control is still hidden, and nothing overflows at the
// batch's viewport set (360@1.3, 390x844, 844x390 with insets, 800x1280,
// 1280x800) or with the keyboard up.

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/core/permissions/gate.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/services/supabase_cloud_transport.dart';
import 'package:reebaplus_pos/core/services/supabase_sync_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/features/staff/screens/invite_staff_screen.dart';
import 'package:reebaplus_pos/features/staff/screens/staff_detail_screen.dart';
import 'package:reebaplus_pos/features/staff/screens/staff_management_screen.dart';
import 'package:reebaplus_pos/features/staff/widgets/staff_parts.dart';

import '../helpers/screen_harness.dart';
import '../helpers/staff_fixture.dart';

/// Staff Management pulls the roster on open; here there is nothing to pull.
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
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 250));
    }
  }

  Future<void> pump(
    WidgetTester tester,
    Widget screen, {
    Size size = const Size(390, 844),
    FakeViewPadding insets = const FakeViewPadding(top: 24, bottom: 24),
    Set<String> grants = staffGrants,
    String roleSlug = 'ceo',
    int roleRank = GateTier.ceo,
    double textScale = 1.0,
    ThemeData? theme,
  }) async {
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
      grantedKeys: grants,
      roleSlug: roleSlug,
      roleRank: roleRank,
      textScaler: TextScaler.linear(textScale),
      theme: theme ?? AppTheme.light(),
      overrides: [
        supabaseSyncServiceProvider.overrideWithValue(
          _NoPullSync(env.db, SupabaseCloudTransport(Supabase.instance.client)),
        ),
      ],
      settle: false,
    );
    await deliver(tester);
  }

  const viewports = <(String, Size, FakeViewPadding, double)>[
    ('360x640@1.3', Size(360, 640), FakeViewPadding(top: 24, bottom: 24), 1.3),
    ('390x844', Size(390, 844), FakeViewPadding(top: 24, bottom: 24), 1.0),
    ('844x390', Size(844, 390), FakeViewPadding(top: 24, right: 48), 1.0),
    ('800x1280', Size(800, 1280), FakeViewPadding(), 1.0),
    ('1280x800', Size(1280, 800), FakeViewPadding(), 1.0),
  ];

  group('Staff Management', () {
    testWidgets('renders people, tabs, search and the Invite FAB', (
      tester,
    ) async {
      await pump(tester, const StaffManagementScreen());
      expect(find.byKey(StaffKeys.topBar), findsOneWidget);
      expect(find.text('Staff Management'), findsOneWidget);
      expect(find.text('Chioma Eze'), findsOneWidget);
      expect(find.text('Tunde Bello'), findsOneWidget);
      expect(find.text('Ngozi Adeyemi'), findsOneWidget);
      expect(find.text('You'), findsOneWidget);
      expect(find.text('Never logged in'), findsOneWidget);
      // Suspended people sit under their own label.
      expect(find.text('SUSPENDED'), findsOneWidget);
      expect(find.text('Emeka Obi'), findsOneWidget);
      expect(find.byKey(StaffKeys.searchStaff), findsOneWidget);
      expect(find.text('Invite new staff'), findsOneWidget);
      expect(find.text('Invites'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await disposeScreen(tester);
    });

    testWidgets('lists roles by tier, CEO first', (tester) async {
      await pump(tester, const StaffManagementScreen());
      double y(String name) => tester.getTopLeft(find.text(name)).dy;
      expect(y('Chioma Eze') < y('Tunde Bello'), isTrue);
      expect(y('Tunde Bello') < y('Ngozi Adeyemi'), isTrue);
      await disposeScreen(tester);
    });

    testWidgets('search filters the list', (tester) async {
      await pump(tester, const StaffManagementScreen());
      await tester.enterText(find.byKey(StaffKeys.searchStaff), 'ngozi');
      await deliver(tester);
      expect(find.text('Ngozi Adeyemi'), findsOneWidget);
      expect(find.text('Tunde Bello'), findsNothing);
      await disposeScreen(tester);
    });

    testWidgets('a manageable row opens Staff Detail', (tester) async {
      await pump(tester, const StaffManagementScreen());
      await tester.tap(find.byKey(StaffKeys.row(fx.membershipIds['Ngozi']!)));
      await deliver(tester);
      expect(find.byType(StaffDetailScreen), findsOneWidget);
      expect(find.text('Account Details'), findsOneWidget);
      await disposeScreen(tester);
    });

    testWidgets('a Manager cannot open another Manager row (still read-only)', (
      tester,
    ) async {
      await pump(
        tester,
        const StaffManagementScreen(),
        roleSlug: 'manager',
        roleRank: GateTier.manager,
      );
      // Tunde is another Manager: faded and not tappable for a Manager.
      await tester.tap(
        find.byKey(StaffKeys.row(fx.membershipIds['Tunde']!)),
        warnIfMissed: false,
      );
      await deliver(tester);
      expect(find.byType(StaffDetailScreen), findsNothing);
      await disposeScreen(tester);
    });

    testWidgets('Invite new staff opens Invite Staff', (tester) async {
      await pump(tester, const StaffManagementScreen());
      await tester.tap(find.text('Invite new staff'));
      await deliver(tester);
      expect(find.byType(InviteStaffScreen), findsOneWidget);
      await disposeScreen(tester);
    });

    testWidgets('Invites tab shows the code and Revoke asks first', (
      tester,
    ) async {
      await pump(tester, const StaffManagementScreen());
      await tester.tap(find.text('Invites'));
      await deliver(tester);
      expect(find.text('K7M2QXP9'), findsOneWidget);
      expect(find.text('bisi@stallion.example'), findsOneWidget);
      await tester.tap(find.byKey(StaffKeys.revoke(fx.inviteId)));
      await deliver(tester);
      expect(find.text('Revoke invite?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await deliver(tester);
      expect(find.text('Revoke invite?'), findsNothing);
      expect(find.text('K7M2QXP9'), findsOneWidget);
      await disposeScreen(tester);
    });

    testWidgets('without staff.invite the screen is still closed', (
      tester,
    ) async {
      await pump(
        tester,
        const StaffManagementScreen(),
        grants: const {'sales.make'},
      );
      expect(
        find.text('You don’t have access to Staff Management.'),
        findsOneWidget,
      );
      expect(find.text('Invite new staff'), findsNothing);
      expect(find.text('Chioma Eze'), findsNothing);
      await disposeScreen(tester);
    });

    for (final (name, size, insets, scale) in viewports) {
      testWidgets('no overflow at $name', (tester) async {
        await pump(
          tester,
          const StaffManagementScreen(),
          size: size,
          insets: insets,
          textScale: scale,
        );
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('Invites'));
        await deliver(tester);
        expect(tester.takeException(), isNull);
        await disposeScreen(tester);
      });
    }
  });

  group('Staff Detail', () {
    Widget detail(String who, {bool readOnly = false}) => StaffDetailScreen(
      membershipId: fx.membershipIds[who]!,
      readOnly: readOnly,
    );

    testWidgets('renders header, figures, details and the three actions', (
      tester,
    ) async {
      await pump(tester, detail('Ngozi'));
      expect(find.byKey(StaffKeys.headerCard), findsOneWidget);
      expect(find.text('Ngozi Adeyemi'), findsOneWidget);
      expect(find.text('Orders'), findsOneWidget);
      expect(find.text('Total sales'), findsOneWidget);
      expect(find.text('Stock Txns'), findsOneWidget);
      expect(find.text('Quick Sales'), findsOneWidget);
      expect(find.text('Expenses'), findsOneWidget);
      expect(find.text('Account Details'), findsOneWidget);
      expect(find.text('Assigned store'), findsOneWidget);
      expect(find.text('Permission access'), findsOneWidget);
      expect(find.text('Never logged in'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('Remove'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('Change role'), findsOneWidget);
      expect(find.text('Suspend'), findsOneWidget);
      expect(find.text('Remove'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await disposeScreen(tester);
    });

    testWidgets('Suspend confirm still asks first', (tester) async {
      await pump(tester, detail('Ngozi'));
      await tester.scrollUntilVisible(
        find.text('Suspend'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('Suspend'));
      await deliver(tester);
      expect(find.text('Suspend staff?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await deliver(tester);
      expect(find.text('Suspend staff?'), findsNothing);
      await disposeScreen(tester);
    });

    testWidgets('a suspended member offers Reactivate', (tester) async {
      await pump(tester, detail('Emeka'));
      await tester.scrollUntilVisible(
        find.text('Reactivate'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('Suspended'), findsWidgets);
      expect(find.text('Reactivate'), findsOneWidget);
      await disposeScreen(tester);
    });

    testWidgets('view-only hides every action and Permission access', (
      tester,
    ) async {
      await pump(tester, detail('Ngozi', readOnly: true));
      expect(find.text('Ngozi Adeyemi'), findsOneWidget);
      expect(find.text('Change role'), findsNothing);
      expect(find.text('Suspend'), findsNothing);
      expect(find.text('Remove'), findsNothing);
      expect(find.text('Permission access'), findsNothing);
      await disposeScreen(tester);
    });

    testWidgets('each action is hidden without its own permission', (
      tester,
    ) async {
      await pump(tester, detail('Ngozi'), grants: const {'staff.suspend'});
      await tester.scrollUntilVisible(
        find.text('Suspend'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('Change role'), findsNothing);
      expect(find.text('Remove'), findsNothing);
      expect(find.text('Suspend'), findsOneWidget);
      await disposeScreen(tester);
    });

    testWidgets('the CEO target has no Permission access link', (tester) async {
      await pump(tester, detail('Chioma'));
      expect(find.text('Full access'), findsOneWidget);
      await disposeScreen(tester);
    });

    for (final (name, size, insets) in const [
      ('390x844', Size(390, 844), FakeViewPadding(top: 24, bottom: 24)),
      ('844x390', Size(844, 390), FakeViewPadding(top: 24, right: 48)),
    ]) {
      testWidgets('Assigned stores sheet opens and fits at $name', (
        tester,
      ) async {
        await pump(tester, detail('Ngozi'), size: size, insets: insets);
        await tester.ensureVisible(find.text('Assigned store'));
        await tester.pump();
        await tester.tap(find.text('Assigned store'));
        await deliver(tester);
        expect(find.byKey(StaffKeys.storesSheet), findsOneWidget);
        expect(find.text('Assigned stores'), findsOneWidget);
        expect(find.text('Abuja HQ'), findsWidgets);
        expect(find.text('Save'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await disposeScreen(tester);
      });
    }

    for (final (name, size, insets, scale) in viewports) {
      testWidgets('no overflow at $name', (tester) async {
        await pump(
          tester,
          detail('Ngozi'),
          size: size,
          insets: insets,
          textScale: scale,
        );
        expect(tester.takeException(), isNull);
        await disposeScreen(tester);
      });
    }

    for (final (name, size, keyboard) in const [
      ('390x844', Size(390, 844), 340.0),
      ('360x640', Size(360, 640), 280.0),
    ]) {
      testWidgets('driver-balance pop-up fits above the keyboard $name', (
        tester,
      ) async {
        // A driver who still owes: removal asks for a typed name.
        await env.db
            .into(env.db.driverLedgerEntries)
            .insert(
              DriverLedgerEntriesCompanion.insert(
                id: Value(UuidV7.generate()),
                businessId: env.businessId,
                driverUserId: fx.userIds['Ngozi']!,
                type: kDriverLedgerTypeLoad,
                amountKobo: 500000,
                signedAmountKobo: -500000,
                referenceType: kDriverLedgerRefLot,
                activityDate: DateTime(2026, 10, 1),
              ),
            );
        await pump(tester, detail('Ngozi'), size: size, textScale: 1.15);
        await tester.scrollUntilVisible(
          find.text('Remove'),
          200,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.tap(find.text('Remove'));
        await deliver(tester);
        expect(find.text('Remove staff?'), findsOneWidget);
        await tester.tap(find.widgetWithText(TextButton, 'Remove'));
        await deliver(tester);
        expect(find.text('Money still on this account'), findsOneWidget);
        tester.view.viewInsets = FakeViewPadding(bottom: keyboard);
        await deliver(tester);
        expect(find.text('Type Ngozi Adeyemi to confirm'), findsOneWidget);
        expect(tester.takeException(), isNull);
        tester.view.resetViewInsets();
        await disposeScreen(tester);
      });
    }
  });

  group('Invite Staff', () {
    testWidgets('renders the form, the role cards and Generate code', (
      tester,
    ) async {
      await pump(tester, const InviteStaffScreen());
      expect(find.text('Invite Staff'), findsOneWidget);
      expect(find.text('Email'), findsWidgets);
      expect(find.text('Select Role & View Capabilities'), findsOneWidget);
      expect(
        find.byKey(StaffKeys.roleCard(fx.roleIds['manager']!)),
        findsOneWidget,
      );
      expect(
        find.byKey(StaffKeys.roleCard(fx.roleIds['cashier']!)),
        findsOneWidget,
      );
      await tester.scrollUntilVisible(
        find.text('Generate code'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('Generate code'), findsOneWidget);
      await disposeScreen(tester);
    });

    testWidgets('tapping a role card selects it', (tester) async {
      await pump(tester, const InviteStaffScreen());
      final card = find.byKey(StaffKeys.roleCard(fx.roleIds['cashier']!));
      await tester.ensureVisible(card);
      await tester.tap(card);
      await deliver(tester);
      expect(tester.takeException(), isNull);
      await disposeScreen(tester);
    });

    for (final (name, size, keyboard) in const [
      ('390x844', Size(390, 844), 340.0),
      ('360x640', Size(360, 640), 280.0),
    ]) {
      testWidgets('form fits with the keyboard up $name', (tester) async {
        await pump(
          tester,
          const InviteStaffScreen(),
          size: size,
          textScale: 1.15,
        );
        await tester.tap(find.byType(TextFormField).first);
        tester.view.viewInsets = FakeViewPadding(bottom: keyboard);
        await deliver(tester);
        await tester.enterText(
          find.byType(TextFormField).first,
          'bisi@stallion.example',
        );
        await deliver(tester);
        expect(tester.takeException(), isNull);
        tester.view.resetViewInsets();
        await disposeScreen(tester);
      });
    }

    for (final (name, size, insets, scale) in viewports) {
      testWidgets('no overflow at $name', (tester) async {
        await pump(
          tester,
          const InviteStaffScreen(),
          size: size,
          insets: insets,
          textScale: scale,
        );
        expect(tester.takeException(), isNull);
        await disposeScreen(tester);
      });
    }
  });
}
