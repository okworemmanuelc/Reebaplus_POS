// Visual goldens for the drawer (#368, PRD #346 "Mechanics").
//
// The open drawer at the four reference sizes, light and dark (Blue Classic),
// with the mockup's sample data: Stallion Global, Emmanuel Okwor, PRO + CEO,
// "3 records waiting to sync", store Abuja HQ, Point of Sale selected. Plus
// the sideways phone with a status bar on top and a navigation bar on the
// right (844x390 insets). Compare with docs/redesign/mockups/
// phone-drawer-dark.png (390x844) and wide-drawer-*.png (1280x800).
//
// The drawer is drawn over the plain page background rather than a real
// screen, so these PNGs only change when the drawer does.
//
// The PNGs live in test/redesign/goldens/ — never test/golden/, which CI runs
// on Linux, where pixel goldens made on macOS would fail. Regenerate with:
//
//     flutter test --update-goldens test/redesign/drawer_golden_test.dart

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/shared/services/navigation_service.dart';

import '../helpers/drawer_harness.dart';
import '../helpers/screen_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const sizes = <String, (Size, EdgeInsets)>{
    '390x844': (Size(390, 844), EdgeInsets.only(top: 24, bottom: 24)),
    '844x390': (Size(844, 390), EdgeInsets.zero),
    '844x390_insets': (Size(844, 390), EdgeInsets.only(top: 24, right: 48)),
    '800x1280': (Size(800, 1280), EdgeInsets.only(top: 24)),
    '1280x800': (Size(1280, 800), EdgeInsets.zero),
  };

  late ScreenTestEnvironment env;

  setUp(() async {
    env = await setupScreenTestEnvironment(
      productCount: 2,
      businessName: kDrawerSampleBusiness,
    );
    NavigationService().resetNavigation();
  });

  tearDown(() async {
    await env.dispose();
    NavigationService().resetNavigation();
  });

  for (final entry in sizes.entries) {
    for (final brightness in Brightness.values) {
      final theme = brightness == Brightness.light ? 'light' : 'dark';
      final name = 'drawer_${entry.key}_$theme';
      testWidgets(name, (tester) async {
        final (size, padding) = entry.value;
        final second = await addSecondStore(env);
        await queueSyncRecords(env, 3);
        await pumpOpenDrawer(
          tester,
          env: env,
          size: size,
          padding: padding,
          stores: [env.store, second],
          activeStoreId: second.id,
          theme: brightness == Brightness.light
              ? AppTheme.light()
              : AppTheme.dark(),
        );
        await expectLater(
          find.byType(MaterialApp),
          matchesGoldenFile('goldens/$name.png'),
        );
        await disposeScreen(tester);
      });
    }
  }
}
