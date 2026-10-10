// Issue #377: a band of plain background sat between the tab content and the
// bottom bar on Stock and POS (Home was clean).
//
// Cause: MainLayout's `_insetContent` (added by 251bc46c for the sideways
// side insets) rebuilt the tabs' MediaQuery from MainLayout's own context,
// ABOVE its Scaffold. The Scaffold had already taken the bottom system inset
// (the bar pads itself by it) and the keyboard (it resizes the body) out of
// its body's MediaQuery; rebuilding from the outer context put both back. Any
// tab body with a bottom `SafeArea` (POS, Stock) then padded the system-nav
// height again above the bar, and nested Scaffolds resized for the keyboard a
// second time.
//
// The rule these tests pin: inside the frame, a tab's MediaQuery carries
// exactly what the frame Scaffold gives its body. Under the bottom bar that is
// no bottom inset and no keyboard inset; with the side rail (600dp+, no bar)
// the screen keeps the bottom inset and owns it.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/providers/first_run_tour_state.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/features/pos/screens/pos_home_screen.dart';
import 'package:reebaplus_pos/shared/services/navigation_service.dart';
import 'package:reebaplus_pos/shared/widgets/main_layout.dart';
import 'package:reebaplus_pos/shared/widgets/spotlight_target.dart';

import '../helpers/screen_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const grants = {
    'sales.make',
    'stock.view',
    'products.add',
    'reports.see_sales',
  };

  const prefs = {
    'push_soft_ask_shown_v1': true,
    'pos_grid_columns': 2,
    'pos_is_list_view': false,
    'hint_pos_gestures': 2,
  };

  const phone = Size(390, 844);
  const barKey = Key('main-bottom-nav');

  // Home starts a connectivity listener; answer "online over wifi".
  setUpAll(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('dev.fluttercommunity.plus/connectivity'),
      (call) async => <String>['wifi'],
    );
    messenger.setMockStreamHandler(
      const EventChannel('dev.fluttercommunity.plus/connectivity_status'),
      MockStreamHandler.inline(
        onListen: (arguments, events) => events.success(<String>['wifi']),
      ),
    );
  });

  late ScreenTestEnvironment env;

  setUp(() async {
    // Enough products that every list scrolls past the bar.
    env = await setupScreenTestEnvironment(
      productCount: 30,
      sharedPreferences: prefs,
    );
    NavigationService()
      ..resetNavigation()
      ..beginSessionLanding();
  });

  tearDown(() async {
    await env.dispose();
    NavigationService().resetNavigation();
  });

  /// Pumps MainLayout on [tab] with [insets] given both to the MediaQuery and
  /// to the raw view (which `deviceBottomPadding` reads).
  Future<BuildContext> pumpFrame(
    WidgetTester tester, {
    required int tab,
    required EdgeInsets insets,
    Size size = phone,
    EdgeInsets keyboard = EdgeInsets.zero,
  }) async {
    final raw = FakeViewPadding(
      left: insets.left,
      top: insets.top,
      right: insets.right,
      bottom: insets.bottom,
    );
    tester.view.padding = raw;
    tester.view.viewPadding = raw;
    tester.view.viewInsets = FakeViewPadding(bottom: keyboard.bottom);
    addTearDown(tester.view.resetPadding);
    addTearDown(tester.view.resetViewPadding);
    addTearDown(tester.view.resetViewInsets);
    NavigationService().setIndex(tab);
    final context = await pumpScreen(
      tester,
      env: env,
      size: size,
      padding: insets,
      viewInsets: keyboard,
      screen: const MainLayout(),
      bottomNavHeight: 0,
      grantedKeys: grants,
      roleSlug: 'manager',
      roleName: 'Manager',
      roleRank: 3,
      overrides: [firstRunTourStopProvider.overrideWithValue(TourStop.none)],
      sharedPreferences: prefs,
      settle: false,
    );
    // Let Drift streams deliver and animations run out (bounded: spinners
    // never settle).
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 250));
    }
    return context;
  }

  /// The lowest bottom edge of any on-screen vertical scrollable: where the
  /// tab's content stops.
  double contentBottom(WidgetTester tester) {
    var bottom = 0.0;
    for (final e in find.byType(Scrollable).hitTestable().evaluate()) {
      final s = e.widget as Scrollable;
      if (axisDirectionToAxis(s.axisDirection) != Axis.vertical) continue;
      final rect = tester.getRect(find.byElementPredicate((x) => x == e));
      if (rect.bottom > bottom) bottom = rect.bottom;
    }
    return bottom;
  }

  const tabs = <String, int>{
    'Home': NavigationService.homeTab,
    'POS': NavigationService.posTab,
    'Stock': 2,
    'Orders': 3,
  };

  const navModes = <String, EdgeInsets>{
    '3-button nav (bottom 48)': EdgeInsets.only(top: 24, bottom: 48),
    'gesture nav (bottom 24)': EdgeInsets.only(top: 24, bottom: 24),
  };

  group('390x844 bottom bar: content reaches the bar, no band', () {
    navModes.forEach((mode, insets) {
      tabs.forEach((name, tab) {
        testWidgets('$name, $mode', (tester) async {
          await pumpFrame(tester, tab: tab, insets: insets);
          final barTop = tester.getTopLeft(find.byKey(barKey)).dy;
          // The bar sits on the screen bottom and pads itself by the inset.
          expect(tester.getBottomLeft(find.byKey(barKey)).dy, phone.height);
          expect(
            contentBottom(tester),
            moreOrLessEquals(barTop, epsilon: 0.5),
            reason:
                '$name: the scrolling content must run down to the bottom '
                'bar; a gap means the system-nav inset was added twice',
          );
          expect(tester.takeException(), isNull);
          await disposeScreen(tester);
        });
      });

      testWidgets('POS scan button and Stock + clear the bar once, $mode', (
        tester,
      ) async {
        for (final (tab, finder) in [
          (NavigationService.posTab, find.byKey(kPosScannerKey)),
          (
            2,
            find.byWidgetPredicate(
              (w) =>
                  w is SpotlightTarget &&
                  w.id == SpotlightTargetId.addProductFab,
            ),
          ),
        ]) {
          await pumpFrame(tester, tab: tab, insets: insets);
          final barTop = tester.getTopLeft(find.byKey(barKey)).dy;
          final fabBottom = tester.getBottomLeft(finder.first).dy;
          expect(fabBottom, lessThan(barTop), reason: 'tab $tab FAB');
          // Material's standard 16dp margin above the bar, not 16dp plus the
          // system-nav height again.
          expect(
            barTop - fabBottom,
            moreOrLessEquals(kFloatingActionButtonMargin, epsilon: 0.5),
            reason: 'tab $tab FAB sits the standard margin above the bar',
          );
          await disposeScreen(tester);
        }
      });
    });
  });

  testWidgets('keyboard up on POS: the body shrinks by the keyboard once', (
    tester,
  ) async {
    const keyboard = EdgeInsets.only(bottom: 300);
    await pumpFrame(
      tester,
      tab: NavigationService.posTab,
      insets: const EdgeInsets.only(top: 24, bottom: 48),
      keyboard: keyboard,
    );
    expect(
      tester.getBottomLeft(find.byKey(kPosScrollSurfaceKey)).dy,
      moreOrLessEquals(phone.height - keyboard.bottom, epsilon: 0.5),
      reason: 'POS content ends at the keyboard top, not a keyboard higher',
    );
    expect(tester.takeException(), isNull);
    await disposeScreen(tester);
  });

  testWidgets('800x1280 side rail (no bar): POS keeps and owns the bottom '
      'inset', (tester) async {
    const size = Size(800, 1280);
    const insets = EdgeInsets.only(top: 24, bottom: 48);
    await pumpFrame(
      tester,
      tab: NavigationService.posTab,
      insets: insets,
      size: size,
    );
    expect(find.byKey(barKey), findsNothing);
    expect(
      tester.getBottomLeft(find.byKey(kPosScrollSurfaceKey)).dy,
      moreOrLessEquals(size.height - insets.bottom, epsilon: 0.5),
    );
    await disposeScreen(tester);
  });

  testWidgets('a sheet opened on a tab root sits on the bar and adds no '
      'second inset', (tester) async {
    const insets = EdgeInsets.only(top: 24, bottom: 48);
    await pumpFrame(tester, tab: 3, insets: insets);
    double? sheetInset;
    showModalBottomSheet<void>(
      context: NavigationService().tabNavigatorKeys[3].currentContext!,
      builder: (context) {
        sheetInset = context.deviceBottomPadding;
        return const SizedBox(key: Key('tab-sheet'), height: 100);
      },
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(
      tester.getBottomLeft(find.byKey(const Key('tab-sheet'))).dy,
      moreOrLessEquals(tester.getTopLeft(find.byKey(barKey)).dy, epsilon: 0.5),
    );
    expect(sheetInset, 0, reason: 'the bar under the sheet clears the inset');
    await disposeScreen(tester);
  });

  testWidgets('a pushed screen and a root-navigator sheet still get the '
      'system-nav inset from deviceBottomPadding', (tester) async {
    const insets = EdgeInsets.only(top: 24, bottom: 48);
    await pumpFrame(tester, tab: 2, insets: insets);

    double? pushedInset;
    NavigationService().tabNavigatorKeys[2].currentState!.push(
      MaterialPageRoute<void>(
        builder: (context) {
          pushedInset = context.deviceBottomPadding;
          return const Scaffold(body: SizedBox.expand());
        },
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(pushedInset, insets.bottom);
    // The bar hides on a pushed screen, so the screen owns the inset.
    expect(find.byKey(barKey), findsNothing);

    double? sheetInset;
    final ctx = NavigationService().tabNavigatorKeys[2].currentContext!;
    showModalBottomSheet<void>(
      context: ctx,
      useRootNavigator: true,
      builder: (context) {
        sheetInset = context.deviceBottomPadding;
        return const SizedBox(height: 100);
      },
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(sheetInset, insets.bottom);
    await disposeScreen(tester);
  });
}
