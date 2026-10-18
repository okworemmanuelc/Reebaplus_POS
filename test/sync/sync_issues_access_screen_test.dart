// Sync Issues access restyle (#443). The per-role sync.view toggle keeps its
// calls: grant / revoke through the role permissions DAO, the activity-log
// line, and the CEO row locked on. A viewer without settings.manage sees no
// toggles.

import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/core/settings/sync_issues_access_screen.dart';
import 'package:reebaplus_pos/features/sync/widgets/sync_parts.dart';

import '../helpers/screen_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ScreenTestEnvironment env;
  late String cashierId;

  setUp(() async {
    env = await setupScreenTestEnvironment(
      productCount: 0,
      businessName: 'Stallion Global',
    );
    for (final r in const [
      ('ceo', 'CEO'),
      ('manager', 'Manager'),
      ('cashier', 'Cashier'),
      ('stock_keeper', 'Stock keeper'),
    ]) {
      final id = UuidV7.generate();
      if (r.$1 == 'cashier') cashierId = id;
      await env.db
          .into(env.db.roles)
          .insert(
            RolesCompanion.insert(
              id: Value(id),
              businessId: env.businessId,
              name: r.$2,
              slug: r.$1,
              isSystemDefault: const Value(true),
            ),
          );
    }
  });
  tearDown(() => env.dispose());

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 250));
    }
  }

  Future<void> pumpAccess(
    WidgetTester tester, {
    Size size = const Size(390, 844),
    EdgeInsets? padding,
    TextScaler? textScaler,
    Set<String> grants = const {'settings.manage'},
  }) async {
    await pumpScreen(
      tester,
      env: env,
      size: size,
      padding: padding,
      textScaler: textScaler,
      screen: const SyncIssuesAccessScreen(),
      grantedKeys: grants,
      bottomNavHeight: size.width >= 600 ? kBottomNavBodyHeight : 0,
      settle: false,
    );
    await settle(tester);
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 5));
    await disposeScreen(tester);
  }

  testWidgets('renders the top bar, the intro and one row per role', (
    tester,
  ) async {
    await pumpAccess(tester);
    expect(find.byKey(SyncKeys.topBar), findsOneWidget);
    expect(find.text('Sync Issues access'), findsOneWidget);
    expect(find.byKey(SyncKeys.back), findsOneWidget);
    expect(
      find.textContaining('Choose which roles can open Sync Issues'),
      findsOneWidget,
    );
    for (final role in const ['CEO', 'Manager', 'Cashier', 'Stock keeper']) {
      expect(find.text(role), findsOneWidget, reason: role);
    }
    expect(find.text('Always on'), findsOneWidget);
    expect(find.text('Can open Sync Issues'), findsNWidgets(3));
    expect(tester.takeException(), isNull);
    await close(tester);
  });

  testWidgets('the CEO row is locked on', (tester) async {
    await pumpAccess(tester);
    final ceo = tester.widget<Switch>(find.byKey(SyncKeys.roleSwitch('ceo')));
    expect(ceo.value, isTrue);
    expect(ceo.onChanged, isNull);
    final cashier = tester.widget<Switch>(
      find.byKey(SyncKeys.roleSwitch('cashier')),
    );
    expect(cashier.value, isFalse);
    expect(cashier.onChanged, isNotNull);
    await close(tester);
  });

  testWidgets('switching a role on grants sync.view, off revokes it', (
    tester,
  ) async {
    await pumpAccess(tester);
    Future<List<RolePermissionData>> grants() async => (await tester.runAsync(
      () => (env.db.select(
        env.db.rolePermissions,
      )..where((t) => t.roleId.equals(cashierId))).get(),
    ))!;

    await tester.tap(find.byKey(SyncKeys.roleSwitch('cashier')));
    await settle(tester);
    expect((await grants()).map((g) => g.permissionKey), ['sync.view']);
    expect(
      tester.widget<Switch>(find.byKey(SyncKeys.roleSwitch('cashier'))).value,
      isTrue,
    );

    await tester.tap(find.byKey(SyncKeys.roleSwitch('cashier')));
    await settle(tester);
    expect(await grants(), isEmpty);
    await close(tester);
  });

  testWidgets('a viewer without settings.manage sees no toggles', (
    tester,
  ) async {
    await pumpAccess(tester, grants: const {});
    expect(find.byKey(SyncKeys.noAccess), findsOneWidget);
    expect(find.text('You don\'t have access to settings.'), findsOneWidget);
    expect(find.byType(Switch), findsNothing);
    expect(find.byKey(SyncKeys.accessList), findsNothing);
    expect(find.byKey(SyncKeys.back), findsOneWidget);
    await close(tester);
  });

  testWidgets('every role row is at least 48dp tall', (tester) async {
    await pumpAccess(tester);
    final size = tester.getSize(find.byKey(SyncKeys.roleRow('manager')));
    expect(size.height, greaterThanOrEqualTo(kMinInteractiveDimension));
    await close(tester);
  });

  testWidgets('the list caps at 720dp on a wide screen', (tester) async {
    await pumpAccess(tester, size: const Size(1280, 800));
    final width = tester.getSize(find.byKey(SyncKeys.roleRow('ceo'))).width;
    expect(width, lessThanOrEqualTo(720));
    expect(width, greaterThan(600));
    await close(tester);
  });

  final sizes = <(String, Size, EdgeInsets, double)>[
    (
      '360@1.3',
      const Size(360, 640),
      const EdgeInsets.only(top: 24, bottom: 48),
      1.3,
    ),
    (
      '390x844',
      const Size(390, 844),
      const EdgeInsets.only(top: 24, bottom: 24),
      1.0,
    ),
    (
      '844x390',
      const Size(844, 390),
      const EdgeInsets.only(top: 24, right: 48),
      1.0,
    ),
    ('800x1280', const Size(800, 1280), EdgeInsets.zero, 1.0),
    ('1280x800', const Size(1280, 800), EdgeInsets.zero, 1.0),
  ];
  for (final (name, size, pad, scale) in sizes) {
    testWidgets('Sync Issues access has no overflow at $name', (tester) async {
      await pumpAccess(
        tester,
        size: size,
        padding: pad,
        textScaler: TextScaler.linear(scale),
      );
      expectNoOverflow(tester, reason: 'overflowed at $name');
      await close(tester);
    });
  }
}
