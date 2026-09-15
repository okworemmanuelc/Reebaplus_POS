// `NavigationService.openDrawer()` has no callers in the app — every open today
// goes through the affordance itself (`Scaffold.of(ctx).openDrawer()`). That is
// exactly why it needs a test: it pointed at `mainScaffoldKey` for a long time,
// whose Scaffold declares no drawer, so the call was a silent no-op and nothing
// in the app was positioned to notice. Its sibling `closeDrawer()` had the same
// bug and *did* have a caller (the store picker), which stayed broken too.
//
// These tests pin the contract: openDrawer() reaches the drawer of the screen
// the user is actually looking at, and no other.
//
// Prior art: the 'drawer presence' group in test/tour/first_run_rail_flow_test.dart.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/shared/services/navigation_service.dart';
import 'package:reebaplus_pos/shared/widgets/app_drawer.dart';

/// A stand-in for a screen that declares its own drawer — the shape every real
/// screen uses (its own Scaffold, never MainLayout's).
Widget _screen(String tag) => Scaffold(
      drawer: Drawer(child: Text('drawer $tag')),
      body: DrawerHost(child: Text('body $tag')),
    );

Widget _tabNavigator(GlobalKey<NavigatorState> key, String tag) => Navigator(
      key: key,
      onGenerateRoute: (_) => MaterialPageRoute(builder: (_) => _screen(tag)),
    );

void main() {
  final nav = NavigationService();

  // The service is a singleton shared across tests in this file.
  tearDown(() {
    nav.tabNavigatorKeys = [];
    nav.currentIndex.value = 0;
  });

  testWidgets('openDrawer opens the drawer of the screen that declares it',
      (tester) async {
    await tester.pumpWidget(MaterialApp(home: _screen('A')));

    expect(find.text('drawer A'), findsNothing);

    nav.openDrawer();
    await tester.pumpAndSettle();

    expect(find.text('drawer A'), findsOneWidget,
        reason: 'this is the regression: routed at mainScaffoldKey, whose '
            'Scaffold has no drawer, this call did nothing at all');
  });

  testWidgets('openDrawer skips a mounted-but-offstage tab and opens the '
      'visible one', (tester) async {
    // MainLayout keeps every visited tab mounted behind Offstage rather than
    // disposing it, so several DrawerHosts are alive at once. Tab B registers
    // last, so a naive "most recently registered wins" picks it — and opens a
    // drawer on a screen the user cannot see.
    final tabA = GlobalKey<NavigatorState>();
    final tabB = GlobalKey<NavigatorState>();
    nav.tabNavigatorKeys = [tabA, tabB];
    nav.currentIndex.value = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Stack(
          children: [
            Offstage(offstage: false, child: _tabNavigator(tabA, 'A')),
            Offstage(offstage: true, child: _tabNavigator(tabB, 'B')),
          ],
        ),
      ),
    );

    nav.openDrawer();
    await tester.pumpAndSettle();

    expect(find.text('drawer A'), findsOneWidget,
        reason: 'tab A is the one on screen');
    expect(find.text('drawer B'), findsNothing,
        reason: 'tab B is mounted but offstage — opening its drawer would be '
            'invisible to the user and leave the app in a state they cannot '
            'back out of');
  });

  testWidgets('openDrawer follows the active tab when it changes',
      (tester) async {
    final tabA = GlobalKey<NavigatorState>();
    final tabB = GlobalKey<NavigatorState>();
    nav.tabNavigatorKeys = [tabA, tabB];
    nav.currentIndex.value = 1;

    await tester.pumpWidget(
      MaterialApp(
        home: Stack(
          children: [
            Offstage(offstage: true, child: _tabNavigator(tabA, 'A')),
            Offstage(offstage: false, child: _tabNavigator(tabB, 'B')),
          ],
        ),
      ),
    );

    nav.openDrawer();
    await tester.pumpAndSettle();

    expect(find.text('drawer B'), findsOneWidget);
    expect(find.text('drawer A'), findsNothing);
  });

  testWidgets('a host that is gone does not answer for its drawer',
      (tester) async {
    await tester.pumpWidget(MaterialApp(home: _screen('A')));
    // Replace the screen — the old DrawerHost must unregister on dispose,
    // leaving nothing behind that still claims it can open a drawer.
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: Text('no drawer here'))),
    );

    nav.openDrawer();
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull,
        reason: 'a stale host would reach for a disposed Scaffold');
    expect(find.text('drawer A'), findsNothing);
  });
}
