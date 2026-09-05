import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/shared/widgets/app_dropdown.dart';
import 'package:reebaplus_pos/shared/widgets/app_input.dart';

import '../helpers/viewports.dart';

void main() {
  group('Responsive scale model', () {
    testWidgets('phoneSe1Portrait (320x568): spacing 0.85, font 0.90',
        (tester) async {
      final context = await pumpWithViewport(tester, size: phoneSe1Portrait);

      expect(context.getRSize(100), closeTo(85.0, 0.01));
      expect(context.getRFontSize(100), closeTo(90.0, 0.01));
      expect(rSize(context, 100), closeTo(context.getRSize(100), 0.0001));
      expect(rFontSize(context, 100), closeTo(context.getRFontSize(100), 0.0001));

      // Breakpoint expectations under Section 3
      expect(context.isPhone, isTrue);
      expect(context.isTablet, isFalse);
      expect(context.isDesktop, isFalse);
      expect(context.isShortViewport, isFalse);
    });

    testWidgets('androidCompactPortrait (360x800): spacing 0.96, font 0.96',
        (tester) async {
      final context =
          await pumpWithViewport(tester, size: androidCompactPortrait);

      expect(context.getRSize(100), closeTo(96.0, 0.01));
      expect(context.getRFontSize(100), closeTo(96.0, 0.01));
      expect(rSize(context, 100), closeTo(context.getRSize(100), 0.0001));
      expect(rFontSize(context, 100), closeTo(context.getRFontSize(100), 0.0001));

      // Breakpoint expectations under Section 3
      expect(context.isPhone, isTrue);
      expect(context.isTablet, isFalse);
      expect(context.isDesktop, isFalse);
      expect(context.isShortViewport, isFalse);
    });

    testWidgets('phoneMiniPortrait (375x812): spacing 1.00, font 1.00',
        (tester) async {
      final context = await pumpWithViewport(tester, size: phoneMiniPortrait);

      expect(context.getRSize(100), closeTo(100.0, 0.01));
      expect(context.getRFontSize(100), closeTo(100.0, 0.01));
      expect(rSize(context, 100), closeTo(context.getRSize(100), 0.0001));
      expect(rFontSize(context, 100), closeTo(context.getRFontSize(100), 0.0001));

      // Breakpoint expectations under Section 3
      expect(context.isPhone, isTrue);
      expect(context.isTablet, isFalse);
      expect(context.isDesktop, isFalse);
      expect(context.isShortViewport, isFalse);
    });

    testWidgets('pixel7Portrait (412x915): spacing 1.0987, font 1.0987',
        (tester) async {
      final context = await pumpWithViewport(tester, size: pixel7Portrait);

      expect(context.getRSize(100), closeTo(109.87, 0.01));
      expect(context.getRFontSize(100), closeTo(109.87, 0.01));
      expect(rSize(context, 100), closeTo(context.getRSize(100), 0.0001));
      expect(rFontSize(context, 100), closeTo(context.getRFontSize(100), 0.0001));

      // Breakpoint expectations under Section 3
      expect(context.isPhone, isTrue);
      expect(context.isTablet, isFalse);
      expect(context.isDesktop, isFalse);
      expect(context.isShortViewport, isFalse);
    });

    testWidgets('phoneMaxPortrait (430x932): spacing 1.1467, font 1.1467',
        (tester) async {
      final context = await pumpWithViewport(tester, size: phoneMaxPortrait);

      expect(context.getRSize(100), closeTo(114.67, 0.01));
      expect(context.getRFontSize(100), closeTo(114.67, 0.01));
      expect(rSize(context, 100), closeTo(context.getRSize(100), 0.0001));
      expect(rFontSize(context, 100), closeTo(context.getRFontSize(100), 0.0001));

      // Breakpoint expectations under Section 3
      expect(context.isPhone, isTrue);
      expect(context.isTablet, isFalse);
      expect(context.isDesktop, isFalse);
      expect(context.isShortViewport, isFalse);
    });

    testWidgets('pixel7Landscape (915x412): spacing 0.70, font 0.90',
        (tester) async {
      final context = await pumpWithViewport(tester, size: pixel7Landscape);

      expect(context.getRSize(100), closeTo(70.0, 0.01));
      expect(context.getRFontSize(100), closeTo(90.0, 0.01));
      expect(rSize(context, 100), closeTo(context.getRSize(100), 0.0001));
      expect(rFontSize(context, 100), closeTo(context.getRFontSize(100), 0.0001));

      // Breakpoint expectations under Section 3: a rotated phone is still a phone.
      expect(context.isPhone, isTrue);
      expect(context.isTablet, isFalse);
      expect(context.isDesktop, isFalse);
      expect(context.isShortViewport, isTrue);
    });

    testWidgets(
        'androidCompactLandscape (800x360): spacing 0.70, font 0.90',
        (tester) async {
      final context =
          await pumpWithViewport(tester, size: androidCompactLandscape);

      expect(context.getRSize(100), closeTo(70.0, 0.01));
      expect(context.getRFontSize(100), closeTo(90.0, 0.01));
      expect(rSize(context, 100), closeTo(context.getRSize(100), 0.0001));
      expect(rFontSize(context, 100), closeTo(context.getRFontSize(100), 0.0001));

      // Breakpoint expectations under Section 3: a rotated phone is still a phone.
      expect(context.isPhone, isTrue);
      expect(context.isTablet, isFalse);
      expect(context.isDesktop, isFalse);
      expect(context.isShortViewport, isTrue);
    });

    testWidgets('tablet109Portrait (820x1180): spacing 1.50, font 1.35',
        (tester) async {
      final context = await pumpWithViewport(tester, size: tablet109Portrait);

      expect(context.getRSize(100), closeTo(150.0, 0.01));
      expect(context.getRFontSize(100), closeTo(135.0, 0.01));
      expect(rSize(context, 100), closeTo(context.getRSize(100), 0.0001));
      expect(rFontSize(context, 100), closeTo(context.getRFontSize(100), 0.0001));

      // Breakpoint expectations under Section 3
      expect(context.isPhone, isFalse);
      expect(context.isTablet, isTrue);
      expect(context.isDesktop, isFalse);
      expect(context.isShortViewport, isFalse);
    });

    testWidgets('tablet109Landscape (1180x820): spacing 1.50, font 1.35',
        (tester) async {
      final context = await pumpWithViewport(tester, size: tablet109Landscape);

      expect(context.getRSize(100), closeTo(150.0, 0.01));
      expect(context.getRFontSize(100), closeTo(135.0, 0.01));
      expect(rSize(context, 100), closeTo(context.getRSize(100), 0.0001));
      expect(rFontSize(context, 100), closeTo(context.getRFontSize(100), 0.0001));

      // Breakpoint expectations under Section 3: isDesktop true excludes isTablet.
      expect(context.isPhone, isFalse);
      expect(context.isTablet, isFalse);
      expect(context.isDesktop, isTrue);
      expect(context.isShortViewport, isFalse);
    });

    testWidgets('tabletMiniPortrait (744x1133): spacing 1.50, font 1.35',
        (tester) async {
      final context = await pumpWithViewport(tester, size: tabletMiniPortrait);

      expect(context.getRSize(100), closeTo(150.0, 0.01));
      expect(context.getRFontSize(100), closeTo(135.0, 0.01));
      expect(rSize(context, 100), closeTo(context.getRSize(100), 0.0001));
      expect(rFontSize(context, 100), closeTo(context.getRFontSize(100), 0.0001));

      // Breakpoint expectations under Section 3
      expect(context.isPhone, isFalse);
      expect(context.isTablet, isTrue);
      expect(context.isDesktop, isFalse);
      expect(context.isShortViewport, isFalse);
    });

    testWidgets('tabletMiniLandscape (1133x744): spacing 1.50, font 1.35',
        (tester) async {
      final context = await pumpWithViewport(tester, size: tabletMiniLandscape);

      expect(context.getRSize(100), closeTo(150.0, 0.01));
      expect(context.getRFontSize(100), closeTo(135.0, 0.01));
      expect(rSize(context, 100), closeTo(context.getRSize(100), 0.0001));
      expect(rFontSize(context, 100), closeTo(context.getRFontSize(100), 0.0001));

      // Breakpoint expectations under Section 3: isDesktop true excludes isTablet.
      expect(context.isPhone, isFalse);
      expect(context.isTablet, isFalse);
      expect(context.isDesktop, isTrue);
      expect(context.isShortViewport, isFalse);
    });

    testWidgets('tabletProPortrait (1024x1366): spacing 1.50, font 1.35',
        (tester) async {
      final context = await pumpWithViewport(tester, size: tabletProPortrait);

      expect(context.getRSize(100), closeTo(150.0, 0.01));
      expect(context.getRFontSize(100), closeTo(135.0, 0.01));
      expect(rSize(context, 100), closeTo(context.getRSize(100), 0.0001));
      expect(rFontSize(context, 100), closeTo(context.getRFontSize(100), 0.0001));

      // Breakpoint expectations under Section 3
      expect(context.isPhone, isFalse);
      expect(context.isTablet, isFalse);
      expect(context.isDesktop, isTrue);
      expect(context.isShortViewport, isFalse);
    });

    testWidgets('tabletProLandscape (1366x1024): spacing 1.50, font 1.35',
        (tester) async {
      final context = await pumpWithViewport(tester, size: tabletProLandscape);

      expect(context.getRSize(100), closeTo(150.0, 0.01));
      expect(context.getRFontSize(100), closeTo(135.0, 0.01));
      expect(rSize(context, 100), closeTo(context.getRSize(100), 0.0001));
      expect(rFontSize(context, 100), closeTo(context.getRFontSize(100), 0.0001));

      // Breakpoint expectations under Section 3
      expect(context.isPhone, isFalse);
      expect(context.isTablet, isFalse);
      expect(context.isDesktop, isTrue);
      expect(context.isShortViewport, isFalse);
    });
  });

  group('Responsive breakpoints (Section 3)', () {
    testWidgets('phoneSe1Portrait (320x568): phone only', (tester) async {
      final context = await pumpWithViewport(tester, size: phoneSe1Portrait);
      expect(context.isPhone, isTrue);
      expect(context.isTablet, isFalse);
      expect(context.isDesktop, isFalse);
      expect(context.isShortViewport, isFalse);
    });

    testWidgets('androidCompactPortrait (360x800): phone only', (tester) async {
      final context =
          await pumpWithViewport(tester, size: androidCompactPortrait);
      expect(context.isPhone, isTrue);
      expect(context.isTablet, isFalse);
      expect(context.isDesktop, isFalse);
      expect(context.isShortViewport, isFalse);
    });

    testWidgets('phoneMiniPortrait (375x812): phone only', (tester) async {
      final context = await pumpWithViewport(tester, size: phoneMiniPortrait);
      expect(context.isPhone, isTrue);
      expect(context.isTablet, isFalse);
      expect(context.isDesktop, isFalse);
      expect(context.isShortViewport, isFalse);
    });

    testWidgets('pixel7Portrait (412x915): phone only', (tester) async {
      final context = await pumpWithViewport(tester, size: pixel7Portrait);
      expect(context.isPhone, isTrue);
      expect(context.isTablet, isFalse);
      expect(context.isDesktop, isFalse);
      expect(context.isShortViewport, isFalse);
    });

    testWidgets('phoneMaxPortrait (430x932): phone only', (tester) async {
      final context = await pumpWithViewport(tester, size: phoneMaxPortrait);
      expect(context.isPhone, isTrue);
      expect(context.isTablet, isFalse);
      expect(context.isDesktop, isFalse);
      expect(context.isShortViewport, isFalse);
    });

    testWidgets('pixel7Landscape (915x412): phone only (shortestSide < 600)',
        (tester) async {
      final context = await pumpWithViewport(tester, size: pixel7Landscape);
      expect(context.isPhone, isTrue);
      expect(context.isTablet, isFalse);
      expect(context.isDesktop, isFalse);
      expect(context.isShortViewport, isTrue);
    });

    testWidgets(
        'androidCompactLandscape (800x360): phone only (shortestSide < 600)',
        (tester) async {
      final context =
          await pumpWithViewport(tester, size: androidCompactLandscape);
      expect(context.isPhone, isTrue);
      expect(context.isTablet, isFalse);
      expect(context.isDesktop, isFalse);
      expect(context.isShortViewport, isTrue);
    });

    testWidgets('tablet109Portrait (820x1180): tablet only', (tester) async {
      final context = await pumpWithViewport(tester, size: tablet109Portrait);
      expect(context.isPhone, isFalse);
      expect(context.isTablet, isTrue);
      expect(context.isDesktop, isFalse);
      expect(context.isShortViewport, isFalse);
    });

    testWidgets('tablet109Landscape (1180x820): desktop only (!isTablet)',
        (tester) async {
      final context = await pumpWithViewport(tester, size: tablet109Landscape);
      expect(context.isPhone, isFalse);
      expect(context.isTablet, isFalse);
      expect(context.isDesktop, isTrue);
      expect(context.isShortViewport, isFalse);
    });

    testWidgets('tabletMiniPortrait (744x1133): tablet only', (tester) async {
      final context = await pumpWithViewport(tester, size: tabletMiniPortrait);
      expect(context.isPhone, isFalse);
      expect(context.isTablet, isTrue);
      expect(context.isDesktop, isFalse);
      expect(context.isShortViewport, isFalse);
    });

    testWidgets('tabletMiniLandscape (1133x744): desktop only (!isTablet)',
        (tester) async {
      final context = await pumpWithViewport(tester, size: tabletMiniLandscape);
      expect(context.isPhone, isFalse);
      expect(context.isTablet, isFalse);
      expect(context.isDesktop, isTrue);
      expect(context.isShortViewport, isFalse);
    });

    testWidgets('tabletProPortrait (1024x1366): desktop only', (tester) async {
      final context = await pumpWithViewport(tester, size: tabletProPortrait);
      expect(context.isPhone, isFalse);
      expect(context.isTablet, isFalse);
      expect(context.isDesktop, isTrue);
      expect(context.isShortViewport, isFalse);
    });

    testWidgets('tabletProLandscape (1366x1024): desktop only', (tester) async {
      final context = await pumpWithViewport(tester, size: tabletProLandscape);
      expect(context.isPhone, isFalse);
      expect(context.isTablet, isFalse);
      expect(context.isDesktop, isTrue);
      expect(context.isShortViewport, isFalse);
    });
  });

  group('Field heights under AppTheme.dark() vs bare ThemeData', () {
    testWidgets(
        'AppTheme.dark() renders AppInput and AppDropdown at 40dp +/- 1 in short viewport',
        (tester) async {
      // Portrait: normal unconstrained height under AppTheme.dark()
      await pumpWithViewport(
        tester,
        size: pixel7Portrait,
        child: MaterialApp(
          theme: AppTheme.dark(),
          home: Scaffold(
            body: Column(
              children: [
                const AppInput(hintText: 'Search...'),
                AppDropdown<String>(
                  value: '1',
                  items: const [DropdownMenuItem(value: '1', child: Text('1'))],
                  onChanged: (_) {},
                ),
              ],
            ),
          ),
        ),
      );
      expect(tester.getSize(find.byType(AppInput)).height, closeTo(53.0, 1.0));
      expect(
          tester.getSize(find.byType(AppDropdown<String>)).height,
          closeTo(43.0, 1.0));

      // Landscape: compact height (target 40dp +/- 1) under AppTheme.dark()
      await pumpWithViewport(
        tester,
        size: pixel7Landscape,
        child: MaterialApp(
          theme: AppTheme.dark(),
          home: Scaffold(
            body: Column(
              children: [
                const AppInput(hintText: 'Search...'),
                AppDropdown<String>(
                  value: '1',
                  items: const [DropdownMenuItem(value: '1', child: Text('1'))],
                  onChanged: (_) {},
                ),
              ],
            ),
          ),
        ),
      );
      expect(tester.getSize(find.byType(AppInput)).height, closeTo(40.0, 1.0));
      expect(
          tester.getSize(find.byType(AppDropdown<String>)).height,
          closeTo(40.0, 1.0));
    });

    testWidgets(
        'bare ThemeData disagrees with AppTheme.dark() for field measurements',
        (tester) async {
      // Under bare ThemeData (no AppTheme inputDecorationTheme), AppInput measures 48dp portrait
      await pumpWithViewport(
        tester,
        size: pixel7Portrait,
        child: MaterialApp(
          theme: ThemeData.light(),
          home: const Scaffold(
            body: Column(
              children: [
                AppInput(hintText: 'Search...'),
              ],
            ),
          ),
        ),
      );
      final bareHeight = tester.getSize(find.byType(AppInput)).height;
      expect(bareHeight, equals(48.0));
      expect(bareHeight, isNot(equals(53.0))); // Proves bare ThemeData disagrees with AppTheme.dark()
    });

    testWidgets(
        'AppInput rendered heights across icon configurations at pixel7Landscape',
        (tester) async {
      await pumpWithViewport(
        tester,
        size: pixel7Landscape,
        child: MaterialApp(
          theme: AppTheme.dark(),
          home: Scaffold(
            body: SingleChildScrollView(
              child: Column(
                children: [
                  const AppInput(key: Key('none'), hintText: 'None'),
                  const AppInput(
                    key: Key('prefix'),
                    hintText: 'Prefix',
                    prefixIcon: Icon(Icons.search, size: 16),
                  ),
                  const AppInput(
                    key: Key('suffix'),
                    hintText: 'Suffix',
                    suffixIcon: Icon(Icons.clear, size: 16),
                  ),
                  const AppInput(
                    key: Key('both'),
                    hintText: 'Both',
                    prefixIcon: Icon(Icons.search, size: 16),
                    suffixIcon: Icon(Icons.clear, size: 16),
                  ),
                  AppInput(
                    key: const Key('interactive_suffix'),
                    hintText: 'Interactive Suffix',
                    prefixIcon: const Icon(Icons.search, size: 16),
                    suffixIcon: GestureDetector(
                      onTap: () {},
                      child: const Icon(Icons.clear, size: 16),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );

      final hNone = tester.getSize(find.byKey(const Key('none'))).height;
      final hPrefix = tester.getSize(find.byKey(const Key('prefix'))).height;
      final hSuffix = tester.getSize(find.byKey(const Key('suffix'))).height;
      final hBoth = tester.getSize(find.byKey(const Key('both'))).height;
      final hInteractive =
          tester.getSize(find.byKey(const Key('interactive_suffix'))).height;

      // Purely decorative icons compress to 40x40 constraints in short viewports,
      // achieving the 40.0dp target across all four configurations.
      expect(hNone, equals(40.0));
      expect(hPrefix, equals(40.0));
      expect(hSuffix, equals(40.0));
      expect(hBoth, equals(40.0));

      // When an interactive icon is present (e.g. clear button, tap target),
      // the interactive one wins and the 48dp floor is preserved.
      expect(hInteractive, equals(48.0));
    });

    testWidgets(
        'Field heights at pixel7Landscape with textScaler 1.3 do not overflow',
        (tester) async {
      await pumpWithViewport(
        tester,
        size: pixel7Landscape,
        child: MaterialApp(
          theme: AppTheme.dark(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: const TextScaler.linear(1.3),
            ),
            child: child!,
          ),
          home: Scaffold(
            body: SingleChildScrollView(
              child: Column(
                children: [
                  const AppInput(key: Key('scaled_input'), hintText: 'Search...'),
                  AppDropdown<String>(
                    key: const Key('scaled_dropdown'),
                    value: '1',
                    items: const [
                      DropdownMenuItem(value: '1', child: Text('1')),
                    ],
                    onChanged: (_) {},
                  ),
                ],
              ),
            ),
          ),
        ),
      );

      final hInput = tester.getSize(find.byKey(const Key('scaled_input'))).height;
      final hDropdown = tester.getSize(find.byKey(const Key('scaled_dropdown'))).height;

      // No exception / overflow occurred
      expect(tester.takeException(), isNull);
      // Pinned rendered heights under textScaler 1.3 for drift tracking:
      // AppInput drifts from 40.0dp to 46.0dp (+6.0dp)
      // AppDropdown drifts from 40.0dp to 44.0dp (+4.0dp)
      expect(hInput, equals(46.0));
      expect(hDropdown, equals(44.0));
    });
  });
}
