// Visual goldens for Customer Detail and its three sheets (#395 PR 2, PRD #346
// Wave 2 A). No mockup: built from the shared parts and the Wave 1 patterns.
//
// - `customer_detail_*`: 390x844 (gesture nav), 844x390 with a 24dp status
//   bar and a 48dp nav bar on the right, 800x1280 and 1280x800, light + dark.
// - `customer_refund_cash_sheet_*`, `customer_set_debt_limit_sheet_*`,
//   `customer_crate_return_sheet_*`: 390x844 and 844x390, light + dark.
//
// Sample data only (business "Stallion Global", store "Abuja HQ", made-up
// customers); every date is a fixed value. Regenerate with:
//
//     flutter test --update-goldens test/redesign/customer_detail_golden_test.dart

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/permissions/gate.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/features/customers/screens/customer_detail_screen.dart';
import 'package:reebaplus_pos/features/customers/widgets/customer_parts.dart';

import '../helpers/customer_detail_fixture.dart';
import '../helpers/screen_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ScreenTestEnvironment env;
  late CustomerDetailFixture fx;

  setUp(() async {
    env = await setupScreenTestEnvironment(
      productCount: 0,
      manufacturerCount: 1,
      businessName: 'Stallion Global',
    );
    await env.db.customStatement(
      "UPDATE stores SET name = 'Abuja HQ' WHERE id = '${env.storeId}'",
    );
    await env.db.customStatement(
      "UPDATE manufacturers SET name = 'Nigerian Breweries'",
    );
    for (var i = 0; i < 8; i++) {
      await env.db.notificationsDao.create('info', 'Notification $i');
    }
    await env.db
        .into(env.db.users)
        .insert(
          UsersCompanion.insert(
            id: const Value('test-user-id'),
            businessId: env.businessId,
            name: 'Test Admin',
            pin: '1234',
          ),
        );
    fx = await seedCustomerDetail(env);
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
    Size size,
    FakeViewPadding insets,
    ThemeData theme, {
    required Widget screen,
  }) async {
    setInsets(tester, insets);
    await pumpScreen(
      tester,
      env: env,
      size: size,
      screen: screen,
      bottomNavHeight: 0,
      followView: true,
      grantedKeys: customerDetailGrants,
      roleRank: GateTier.ceo,
      theme: theme,
      overrides: [
        ...customerDetailOverrides(),
        currentBusinessNameProvider.overrideWithValue('Stallion Global'),
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
      testWidgets('customer detail $sizeName $themeName', (tester) async {
        await pump(tester, size, insets, theme, screen: fx.screen);
        expect(tester.takeException(), isNull);
        await expectLater(
          find.byType(CustomerDetailScreen),
          matchesGoldenFile(
            'goldens/customer_detail_${sizeName}_$themeName.png',
          ),
        );
        await disposeScreen(tester);
      });
    }

    for (final (sizeName, size, insets) in const [
      ('390x844', Size(390, 844), FakeViewPadding(top: 24, bottom: 24)),
      ('844x390', Size(844, 390), FakeViewPadding(top: 24, right: 48)),
    ]) {
      for (final (name, openKey, tab) in [
        ('customer_refund_cash_sheet', CustomersKeys.refundCash, null),
        ('customer_set_debt_limit_sheet', CustomersKeys.setLimit, null),
        (
          'customer_crate_return_sheet',
          CustomersKeys.recordCrateReturn,
          'Crates',
        ),
      ]) {
        testWidgets('$name $sizeName $themeName', (tester) async {
          await pump(tester, size, insets, theme, screen: _Host(fx.screen));
          if (tab != null) {
            if (find.text(tab).evaluate().isEmpty) {
              await tester.drag(
                find.byType(NestedScrollView),
                const Offset(0, -600),
              );
              await tester.pumpAndSettle();
            }
            await tester.tap(find.text(tab));
            await tester.pumpAndSettle();
          }
          await tester.ensureVisible(find.byKey(openKey));
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(openKey));
          await tester.pumpAndSettle();
          await deliver(tester);
          expect(tester.takeException(), isNull);
          await expectLater(
            find.byType(Navigator).first,
            matchesGoldenFile('goldens/${name}_${sizeName}_$themeName.png'),
          );
          await disposeScreen(tester);
        });
      }
    }
  }
}

/// A tab-like host: Scaffold -> nested Navigator -> the screen, so the
/// Scaffold's resize owns the keyboard and sheets open on that navigator.
class _Host extends StatelessWidget {
  const _Host(this.child);

  final Widget child;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Navigator(
      onGenerateRoute: (_) => MaterialPageRoute<void>(builder: (_) => child),
    ),
  );
}
