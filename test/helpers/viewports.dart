import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// Named surface sizes and pump helpers for testing responsive layouts across
/// phones, landscape phones, and tablets.
///
/// Reused across all phases of the responsive layout overhaul (see
/// `docs/design/responsive-layout-plan.md`, Section 3). Kept strictly
/// dependency-free: no Riverpod, no Drift database, and no Supabase.

// Phone viewports (portrait)
const Size phoneSe1Portrait = Size(320, 568);
const Size androidCompactPortrait = Size(360, 800);
const Size phoneMiniPortrait = Size(375, 812);
const Size pixel7Portrait = Size(412, 915);
const Size phoneMaxPortrait = Size(430, 932);

// Phone viewports (landscape / short viewports)
const Size pixel7Landscape = Size(915, 412);
const Size androidCompactLandscape = Size(800, 360);

// Tablet viewports
const Size tablet109Portrait = Size(820, 1180);
const Size tablet109Landscape = Size(1180, 820);
const Size tabletMiniPortrait = Size(744, 1133);
const Size tabletMiniLandscape = Size(1133, 744);
const Size tabletProPortrait = Size(1024, 1366);
const Size tabletProLandscape = Size(1366, 1024);

/// Pumps a [child] inside a [MediaQuery] at the specified [size] and returns
/// the inner [BuildContext].
///
/// If [child] is not specified, a [SizedBox.shrink] is used as the child.
/// This allows tests to read `context.getRSize`, `context.getRFontSize`, and
/// responsive getters without pulling in app-level dependencies.
Future<BuildContext> pumpWithViewport(
  WidgetTester tester, {
  required Size size,
  Widget? child,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  late BuildContext capturedContext;
  await tester.pumpWidget(
    MediaQuery(
      data: MediaQueryData(size: size),
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: Builder(
          builder: (context) {
            capturedContext = context;
            return child ?? const SizedBox();
          },
        ),
      ),
    ),
  );
  return capturedContext;
}
