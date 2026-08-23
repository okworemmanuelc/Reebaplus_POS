// role_landing_tab_test.dart
//
// Unit test for the role-based post-login landing tab. Two halves:
//
//  * `NavigationService.landingTabForRole` — the pure role-slug → tab map. CEO,
//    Manager and Stock keeper open on Home; Cashier (and Driver, who normally
//    never reaches MainLayout) open on the till.
//  * `beginSessionLanding` / `applyRoleLanding` — the session protocol.
//    `AuthService.setCurrentUser` opens every session on Home because the role
//    row has not resolved from local SQLite yet, and MainLayout applies the real
//    landing once it has. That application must be a ONE-SHOT: MainLayout
//    re-schedules it on every build, so a second application would yank a user
//    back to their landing tab after they had walked off it.
//
// The back-press fall-home target moves with the landing (Step 3 of
// `handleBackPress`) so a Stock keeper never gets bounced onto the POS tab that
// is hidden from their nav bar.

import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/shared/services/navigation_service.dart';

void main() {
  // NavigationService is a singleton; start every test from a fresh session.
  final nav = NavigationService();
  setUp(nav.resetNavigation);

  group('landingTabForRole', () {
    test('CEO, Manager and Stock keeper land on Home', () {
      expect(NavigationService.landingTabForRole('ceo'),
          NavigationService.homeTab);
      expect(NavigationService.landingTabForRole('manager'),
          NavigationService.homeTab);
      expect(NavigationService.landingTabForRole('stock_keeper'),
          NavigationService.homeTab);
    });

    test('Cashier and Driver land on POS', () {
      expect(NavigationService.landingTabForRole('cashier'),
          NavigationService.posTab);
      expect(NavigationService.landingTabForRole('driver'),
          NavigationService.posTab);
    });

    test('an unresolved / unknown slug lands on Home', () {
      // Home is the only tab never hidden from a nav bar, so it is the one safe
      // answer while the role is still resolving.
      expect(NavigationService.landingTabForRole(null),
          NavigationService.homeTab);
      expect(NavigationService.landingTabForRole('some_future_role'),
          NavigationService.homeTab);
    });
  });

  group('session landing protocol', () {
    test('a session opens on Home before the role resolves', () {
      nav.setIndex(7);
      nav.beginSessionLanding();
      expect(nav.currentIndex.value, NavigationService.homeTab);
      expect(nav.landingIndex, NavigationService.homeTab);
    });

    test('a cashier is moved to POS when the role resolves', () {
      nav.beginSessionLanding();
      nav.applyRoleLanding(NavigationService.landingTabForRole('cashier'));
      expect(nav.currentIndex.value, NavigationService.posTab);
      expect(nav.landingIndex, NavigationService.posTab);
    });

    test('a CEO stays on Home when the role resolves', () {
      nav.beginSessionLanding();
      nav.applyRoleLanding(NavigationService.landingTabForRole('ceo'));
      expect(nav.currentIndex.value, NavigationService.homeTab);
      expect(nav.landingIndex, NavigationService.homeTab);
    });

    test('applying the landing twice does not move the user a second time', () {
      nav.beginSessionLanding();
      nav.applyRoleLanding(NavigationService.posTab);
      // The cashier walks off the till to Stock.
      nav.setIndex(2);
      // MainLayout rebuilds and re-schedules the landing.
      nav.applyRoleLanding(NavigationService.posTab);
      expect(nav.currentIndex.value, 2);
    });

    test('a tab picked inside the resolve window survives the landing', () {
      nav.beginSessionLanding();
      // The user taps Orders before the role row arrives.
      nav.setIndex(3);
      nav.applyRoleLanding(NavigationService.posTab);
      expect(nav.currentIndex.value, 3);
      // The landing target is still recorded — back-press falls home to it.
      expect(nav.landingIndex, NavigationService.posTab);
    });

    test('logout re-arms the landing for the next session', () {
      nav.beginSessionLanding();
      nav.applyRoleLanding(NavigationService.posTab);
      expect(nav.landingIndex, NavigationService.posTab);

      nav.resetNavigation(); // logout / lock
      expect(nav.currentIndex.value, NavigationService.homeTab);
      expect(nav.landingIndex, NavigationService.homeTab);

      // Next session — a stock keeper this time — applies cleanly.
      nav.beginSessionLanding();
      nav.applyRoleLanding(NavigationService.landingTabForRole('stock_keeper'));
      expect(nav.currentIndex.value, NavigationService.homeTab);
      expect(nav.landingIndex, NavigationService.homeTab);
    });

    test('a non-seller landing is Home even if the slug says POS', () {
      // Hard rule #7 folded into the landing by MainLayout: a Cashier stripped
      // of `sales.make` has no POS tab, so it passes homeTab regardless of slug.
      nav.beginSessionLanding();
      nav.applyRoleLanding(NavigationService.homeTab);
      expect(nav.currentIndex.value, NavigationService.homeTab);
      expect(nav.landingIndex, NavigationService.homeTab);
    });
  });
}
