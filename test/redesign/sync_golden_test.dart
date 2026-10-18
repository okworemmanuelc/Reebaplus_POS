// Visual goldens for the Sync + Diagnostics screens (#443, PRD #346 Wave 2
// batch C). No mockup: built from the shared parts and the Wave 1 / batch A / B
// patterns (CEO Settings' top bar and 720dp cap, the Payments cards).
//
// - `sync_issues_*` (top of the list: Health + Catching up + the first
//   Pending rows), `sync_issues_items_*` (scrolled to the Pending and Failed
//   rows), `sync_issues_orphans_*` (the bottom: Orphaned rows and the audit
//   card), `sync_issues_access_*`: 390x844 (gesture nav), 844x390
//   with a 24dp status bar and 3-button navigation on the right, 800x1280 and
//   1280x800 (the harness leaves the rail's width blank at 600dp+), light +
//   dark.
// - `schema_error_*`: the refuse-to-boot screen is dark-only by design (it
//   runs before any theme setting exists), so only `_dark` is drawn.
// - `resolve_unsynced_dialog_*`: 390x844 and 844x390 with insets, light + dark.
//
// Sample data only: business "Stallion Global". The queue rows use fixed dates;
// the one date the screen prints in local time (an orphan's `archived:`) is a
// fixed UTC instant, so regenerate on the owner's machine. Regenerate:
//
//     flutter test --update-goldens test/redesign/sync_golden_test.dart

import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/settings/sync_issues_access_screen.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/features/diagnostics/screens/schema_error_screen.dart';
import 'package:reebaplus_pos/features/sync/screens/sync_issues_screen.dart';
import 'package:reebaplus_pos/features/sync/widgets/resolve_unsynced_data_dialog.dart';
import 'package:reebaplus_pos/features/sync/widgets/sync_parts.dart';

import '../diagnostics/schema_error_sample.dart';
import '../helpers/screen_harness.dart';
import '../sync/sync_issues_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ScreenTestEnvironment env;

  setUp(() async {
    env = await setupScreenTestEnvironment(
      productCount: 0,
      businessName: 'Stallion Global',
    );
    await seedSyncSample(env);
    for (final r in const [
      ('ceo', 'CEO'),
      ('manager', 'Manager'),
      ('cashier', 'Cashier'),
      ('stock_keeper', 'Stock keeper'),
    ]) {
      await env.db
          .into(env.db.roles)
          .insert(
            RolesCompanion.insert(
              id: Value(UuidV7.generate()),
              businessId: env.businessId,
              name: r.$2,
              slug: r.$1,
              isSystemDefault: const Value(true),
            ),
          );
    }
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

  void setInsets(WidgetTester tester, FakeViewPadding insets) {
    tester.view.padding = insets;
    tester.view.viewPadding = insets;
    addTearDown(tester.view.resetPadding);
    addTearDown(tester.view.resetViewPadding);
  }

  Future<void> pump(
    WidgetTester tester,
    Widget screen,
    Size size,
    FakeViewPadding insets,
    ThemeData theme, {
    Set<String> grants = const {'sync.view', 'settings.manage'},
  }) async {
    setInsets(tester, insets);
    await pumpScreen(
      tester,
      env: env,
      size: size,
      screen: screen,
      followView: true,
      bottomNavHeight: size.width >= 600 ? kBottomNavBodyHeight : 0,
      grantedKeys: grants,
      roleRank: 0,
      theme: theme,
      sharedPreferences: deferredTablesPrefs(env),
      settle: false,
    );
    await deliver(tester);
    if (screen is SyncIssuesScreen) {
      // The Health card prints the signed-in business id, which the harness
      // mints at random: pin it so the image is the same on every run. (The
      // queue streams read the database's own resolver, so the rows stay.)
      final container = ProviderScope.containerOf(
        tester.element(find.byType(SyncIssuesScreen)),
      );
      final auth = container.read(authProvider);
      auth.value = auth.currentUser!.copyWith(businessId: kSampleBusinessId);
      await deliver(tester);
    }
  }

  const sizesWithInsets = <(String, Size, FakeViewPadding)>[
    ('390x844', Size(390, 844), FakeViewPadding(top: 24, bottom: 24)),
    ('844x390', Size(844, 390), FakeViewPadding(top: 24, right: 48)),
    ('800x1280', Size(800, 1280), FakeViewPadding()),
    ('1280x800', Size(1280, 800), FakeViewPadding()),
  ];

  for (final brightness in Brightness.values) {
    final themeName = brightness == Brightness.light ? 'light' : 'dark';
    final theme = brightness == Brightness.light
        ? AppTheme.light()
        : AppTheme.dark();

    for (final (sizeName, size, insets) in sizesWithInsets) {
      testWidgets('sync issues $sizeName $themeName', (tester) async {
        await pump(tester, const SyncIssuesScreen(), size, insets, theme);
        expect(tester.takeException(), isNull);
        await expectLater(
          find.byType(SyncIssuesScreen),
          matchesGoldenFile('goldens/sync_issues_${sizeName}_$themeName.png'),
        );
        await disposeScreen(tester);
      });

      testWidgets('sync issues items $sizeName $themeName', (tester) async {
        await pump(tester, const SyncIssuesScreen(), size, insets, theme);
        // Reach the Failed and Orphaned rows, as a thumb would.
        await tester.drag(find.byKey(SyncKeys.list), const Offset(0, -1100));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await expectLater(
          find.byType(SyncIssuesScreen),
          matchesGoldenFile(
            'goldens/sync_issues_items_${sizeName}_$themeName.png',
          ),
        );
        await disposeScreen(tester);
      });

      testWidgets('sync issues orphans $sizeName $themeName', (tester) async {
        await pump(tester, const SyncIssuesScreen(), size, insets, theme);
        // The bottom of the list: the Orphaned rows and the audit card.
        for (var i = 0; i < 6; i++) {
          await tester.drag(find.byKey(SyncKeys.list), const Offset(0, -2000));
          await tester.pumpAndSettle();
        }
        expect(tester.takeException(), isNull);
        await expectLater(
          find.byType(SyncIssuesScreen),
          matchesGoldenFile(
            'goldens/sync_issues_orphans_${sizeName}_$themeName.png',
          ),
        );
        await disposeScreen(tester);
      });

      testWidgets('sync issues access $sizeName $themeName', (tester) async {
        await pump(tester, const SyncIssuesAccessScreen(), size, insets, theme);
        expect(tester.takeException(), isNull);
        await expectLater(
          find.byType(SyncIssuesAccessScreen),
          matchesGoldenFile(
            'goldens/sync_issues_access_${sizeName}_$themeName.png',
          ),
        );
        await disposeScreen(tester);
      });
    }

    for (final (sizeName, size, insets) in const [
      ('390x844', Size(390, 844), FakeViewPadding(top: 24, bottom: 24)),
      ('844x390', Size(844, 390), FakeViewPadding(top: 24, right: 48)),
    ]) {
      testWidgets('resolve unsynced dialog $sizeName $themeName', (
        tester,
      ) async {
        await pump(
          tester,
          Consumer(
            builder: (context, ref, _) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () => showResolveUnsyncedDataDialog(
                    context,
                    ref,
                    pendingCount: 1,
                    orphanCount: 2,
                    photoCount: 3,
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
          size,
          insets,
          theme,
        );
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await expectLater(
          find.byType(Navigator).first,
          matchesGoldenFile(
            'goldens/resolve_unsynced_dialog_${sizeName}_$themeName.png',
          ),
        );
        await disposeScreen(tester);
      });
    }
  }

  // The schema error screen is dark-only and has no providers at all.
  for (final (sizeName, size, insets) in sizesWithInsets) {
    testWidgets('schema error $sizeName dark', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      setInsets(tester, insets);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(SchemaErrorScreen(audit: sampleSchemaAudit()));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await expectLater(
        find.byType(SchemaErrorScreen),
        matchesGoldenFile('goldens/schema_error_${sizeName}_dark.png'),
      );
    });
  }
}
