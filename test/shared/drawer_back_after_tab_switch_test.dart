// #764: the phone's back button stopped working everywhere after the side menu
// was used to jump to another tab.
//
// The menu's tab switch closes the drawer and hides its tab in the same moment.
// MainLayout turns tickers off on hidden tabs, so the drawer's close animation
// froze part-way and the drawer stayed mounted. NavigationService counted it as
// open, and `handleBackPress` spent every press trying to close it instead of
// going back.
//
// The harness rebuilds just the parts that matter: two tab Navigators hidden
// the way MainLayout hides them (Offstage + TickerMode), a screen Scaffold with
// a drawer on the first, and the real NavigationService singleton.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/shared/services/navigation_service.dart';
import 'package:reebaplus_pos/shared/widgets/app_drawer.dart';

void main() {
  final nav = NavigationService();
  setUp(nav.resetNavigation);
  tearDown(() => nav.tabNavigatorKeys = []);

  final scaffoldKey = GlobalKey<ScaffoldState>();
  final tabKeys = [GlobalKey<NavigatorState>(), GlobalKey<NavigatorState>()];

  /// One tab, hidden exactly as MainLayout hides an inactive tab.
  Widget tab(int index, Widget root) => ValueListenableBuilder<int>(
    valueListenable: nav.currentIndex,
    builder: (_, current, _) => Offstage(
      offstage: current != index,
      child: TickerMode(
        enabled: current == index,
        child: Navigator(
          key: tabKeys[index],
          onGenerateRoute: (_) => MaterialPageRoute<void>(builder: (_) => root),
        ),
      ),
    ),
  );

  Future<void> pumpTabs(WidgetTester tester) async {
    nav.tabNavigatorKeys = tabKeys;
    await tester.pumpWidget(
      MaterialApp(
        home: Stack(
          children: [
            tab(
              0,
              Scaffold(
                key: scaffoldKey,
                drawer: const Drawer(child: DrawerPresence(child: SizedBox())),
                body: const Text('first tab'),
              ),
            ),
            tab(1, const Scaffold(body: Text('second tab'))),
          ],
        ),
      ),
    );
  }

  /// What the menu's `_navigateTo` does: close the drawer, switch tab.
  Future<void> openMenuThenJumpToSecondTab(WidgetTester tester) async {
    scaffoldKey.currentState!.openDrawer();
    await tester.pumpAndSettle();
    expect(nav.isModalDrawerOpen, isTrue, reason: 'an open drawer counts');

    scaffoldKey.currentState!.closeDrawer();
    nav.setIndex(1);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
  }

  testWidgets(
    'back pops an inner screen after the menu switched tabs (#764)',
    (tester) async {
      await pumpTabs(tester);
      await openMenuThenJumpToSecondTab(tester);

      // The drawer is still there, frozen on the hidden tab — the mechanism.
      expect(find.byType(DrawerPresence, skipOffstage: false), findsOneWidget);
      // …but it no longer counts as open.
      expect(nav.isModalDrawerOpen, isFalse);

      tabKeys[1].currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('inner screen')),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('inner screen'), findsOneWidget);

      nav.handleBackPress(tabKeys[1].currentContext!);
      await tester.pumpAndSettle();

      expect(find.text('inner screen'), findsNothing);
      expect(find.text('second tab'), findsOneWidget);
    },
  );

  testWidgets(
    'the drawer finishes closing when its tab comes back, leaving none open',
    (tester) async {
      await pumpTabs(tester);
      await openMenuThenJumpToSecondTab(tester);

      nav.setIndex(0);
      await tester.pumpAndSettle();

      expect(find.byType(DrawerPresence, skipOffstage: false), findsNothing);
      expect(nav.isModalDrawerOpen, isFalse);
      expect(nav.drawerOpenNotifier.value, isFalse);
    },
  );
}
