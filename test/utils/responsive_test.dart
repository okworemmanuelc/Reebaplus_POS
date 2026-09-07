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
        'AppTheme.dark() compacts AppInput to 40dp in a short viewport; AppDropdown holds its 48dp tap-target floor',
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
      // AppDropdown's whole surface is the tap target, so it holds 48dp even in
      // portrait. Its padding alone measured 43dp here until 2026-09-07 — a
      // PRE-EXISTING breach of the 48dp floor that predates Phase 0; Phase 0
      // only made it worse (43 -> 40) in landscape. See the plan Section 10 gap 3.
      expect(
          tester.getSize(find.byType(AppDropdown<String>)).height,
          equals(kMinInteractiveDimension));

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
      // The compact 12.5 vertical padding still applies — it just cannot take
      // the control under the tap-target floor. A display field compacts; a
      // control does not.
      expect(
          tester.getSize(find.byType(AppDropdown<String>)).height,
          equals(kMinInteractiveDimension));
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
                    key: const Key('interactive_bare'),
                    hintText: 'Bare Interactive',
                    prefixIcon: const Icon(Icons.search, size: 16),
                    suffixIcon: GestureDetector(
                      onTap: () {},
                      child: const Icon(Icons.clear, size: 16),
                    ),
                  ),
                  AppInput(
                    key: const Key('interactive_wrapped_1'),
                    hintText: 'Wrapped in Padding',
                    prefixIcon: const Icon(Icons.search, size: 16),
                    suffixIcon: Padding(
                      padding: const EdgeInsets.all(4),
                      child: GestureDetector(
                        onTap: () {},
                        child: const Icon(Icons.clear, size: 16),
                      ),
                    ),
                  ),
                  AppInput(
                    key: const Key('interactive_wrapped_2'),
                    hintText: 'Wrapped Two Deep',
                    prefixIcon: const Icon(Icons.search, size: 16),
                    suffixIcon: Padding(
                      padding: const EdgeInsets.all(2),
                      child: SizedBox(
                        child: GestureDetector(
                          onTap: () {},
                          child: const Icon(Icons.clear, size: 16),
                        ),
                      ),
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
      final hBare =
          tester.getSize(find.byKey(const Key('interactive_bare'))).height;
      final hWrapped1 =
          tester.getSize(find.byKey(const Key('interactive_wrapped_1'))).height;
      final hWrapped2 =
          tester.getSize(find.byKey(const Key('interactive_wrapped_2'))).height;

      // Purely decorative icons compress to 40x40 constraints in short viewports,
      // achieving the 40.0dp target across all four configurations.
      expect(hNone, equals(40.0));
      expect(hPrefix, equals(40.0));
      expect(hSuffix, equals(40.0));
      expect(hBoth, equals(40.0));

      // Interactive icons preserve the 48dp floor whether bare, wrapped in
      // Padding, or wrapped two deep (Padding -> SizedBox -> GestureDetector).
      expect(hBare, equals(48.0));
      expect(hWrapped1, equals(48.0));
      expect(hWrapped2, equals(48.0));
    });

    testWidgets(
        'readOnly + onTap fields keep the 48dp tap target at pixel7Landscape',
        (tester) async {
      // A readOnly field with an onTap is tapped anywhere on its surface, so
      // the icon inspection in _isInteractive cannot see that the field itself
      // is a control. 40dp would put its only tap target under the 48dp
      // Material / WCAG 2.5.5 floor. See responsive-layout-plan.md Section 10,
      // gap 3.
      await pumpWithViewport(
        tester,
        size: pixel7Landscape,
        child: MaterialApp(
          theme: AppTheme.dark(),
          home: Scaffold(
            body: SingleChildScrollView(
              child: Column(
                children: [
                  // The shape of the three real call sites: two date pickers in
                  // payments/widgets/record_supplier_activity.dart and one in
                  // expenses/screens/add_expense_screen.dart. The calendar glyph
                  // is decorative; the whole field is the tap target.
                  AppInput(
                    key: const Key('tap_with_decorative_icon'),
                    hintText: 'Date',
                    readOnly: true,
                    onTap: () {},
                    suffixIcon: const Icon(Icons.calendar_today, size: 16),
                  ),
                  // The case no icon inspection could ever reach.
                  AppInput(
                    key: const Key('tap_no_icon'),
                    hintText: 'Date',
                    readOnly: true,
                    onTap: () {},
                  ),
                  // readOnly WITHOUT onTap is a display field, not a control —
                  // it must still compact. Guards the ~8 display-only readOnly
                  // fields in inventory_screen / product_detail_screen.
                  const AppInput(
                    key: Key('readonly_display_only'),
                    hintText: 'Display',
                    readOnly: true,
                  ),
                  const AppInput(
                    key: Key('readonly_display_with_icon'),
                    hintText: 'Display',
                    readOnly: true,
                    suffixIcon: Icon(Icons.calendar_today, size: 16),
                  ),
                ],
              ),
            ),
          ),
        ),
      );

      final hTapIcon =
          tester.getSize(find.byKey(const Key('tap_with_decorative_icon')))
              .height;
      final hTapBare =
          tester.getSize(find.byKey(const Key('tap_no_icon'))).height;
      final hDisplay =
          tester.getSize(find.byKey(const Key('readonly_display_only'))).height;
      final hDisplayIcon =
          tester.getSize(find.byKey(const Key('readonly_display_with_icon')))
              .height;

      // A whole-surface tap target holds 48dp with or without an icon.
      expect(hTapIcon, equals(48.0));
      expect(hTapBare, equals(48.0));

      // A readOnly display field is not a control and still compacts to 40dp,
      // so the fix does not leak vertical chrome back onto every readOnly field.
      expect(hDisplay, equals(40.0));
      expect(hDisplayIcon, equals(40.0));
    });

    testWidgets(
        'AppDropdown holds the 48dp tap-target floor at every viewport, even against a caller padding override',
        (tester) async {
      // AppDropdown's entire surface is a GestureDetector (app_dropdown.dart:232)
      // and `onChanged` is required and non-nullable, so there is no disabled
      // state and no configuration in which 40dp would be acceptable. The floor
      // is therefore unconditional, unlike AppInput's — which distinguishes a
      // display field from a control.
      Widget harness(Key key, {EdgeInsetsGeometry? contentPadding}) =>
          MaterialApp(
            theme: AppTheme.dark(),
            home: Scaffold(
              body: SingleChildScrollView(
                child: Column(
                  children: [
                    AppDropdown<String>(
                      key: key,
                      value: '1',
                      contentPadding: contentPadding,
                      items: const [
                        DropdownMenuItem(value: '1', child: Text('1')),
                      ],
                      onChanged: (_) {},
                    ),
                  ],
                ),
              ),
            ),
          );

      for (final size in [pixel7Landscape, pixel7Portrait, androidCompactLandscape]) {
        await pumpWithViewport(
          tester,
          size: size,
          child: harness(const Key('dd')),
        );
        expect(
          tester.getSize(find.byKey(const Key('dd'))).height,
          equals(kMinInteractiveDimension),
          reason: 'AppDropdown fell below the tap-target floor at $size',
        );
      }

      // A caller-supplied contentPadding replaces the vertical padding but must
      // not be able to breach the floor — the constraint sits OUTSIDE the padded
      // Container on purpose. Measured without the floor, this case renders a
      // 15.0dp control (probe, 2026-09-07).
      await pumpWithViewport(
        tester,
        size: pixel7Landscape,
        child: harness(
          const Key('dd'),
          contentPadding: EdgeInsets.zero,
        ),
      );
      expect(
        tester.getSize(find.byKey(const Key('dd'))).height,
        equals(kMinInteractiveDimension),
      );
    });

    testWidgets(
        'readOnly + onTap fields are unchanged in a comfortable viewport',
        (tester) async {
      await pumpWithViewport(
        tester,
        size: pixel7Portrait,
        child: MaterialApp(
          theme: AppTheme.dark(),
          home: Scaffold(
            body: SingleChildScrollView(
              child: Column(
                children: [
                  AppInput(
                    key: const Key('portrait_tap'),
                    hintText: 'Date',
                    readOnly: true,
                    onTap: () {},
                    suffixIcon: const Icon(Icons.calendar_today, size: 16),
                  ),
                ],
              ),
            ),
          ),
        ),
      );

      // Portrait already clears the floor at 53dp; the tap-target rule adds
      // nothing there and must not shrink the field to 48dp either.
      expect(
        tester.getSize(find.byKey(const Key('portrait_tap'))).height,
        closeTo(53.0, 1.0),
      );
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
      // AppInput drifts from 40.0dp to 46.0dp (+6.0dp).
      // AppDropdown does NOT drift — its 48dp tap-target floor (2026-09-07)
      // already exceeds the 44.0dp its padding + scaled text would produce, so
      // the floor absorbs the drift entirely. It is the one field whose height
      // is now stable across text scaling.
      expect(hInput, equals(46.0));
      expect(hDropdown, equals(48.0));
    });
  });
}
