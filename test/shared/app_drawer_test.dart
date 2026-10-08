import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/providers/first_run_tour_state.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/theme/fixed_colors.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/features/subscription/subscription_access.dart';
import 'package:reebaplus_pos/shared/services/navigation_service.dart';
import 'package:reebaplus_pos/shared/widgets/app_drawer_parts.dart';
import 'package:reebaplus_pos/shared/widgets/main_layout.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/redesign.dart';

import '../helpers/drawer_harness.dart';
import '../helpers/screen_harness.dart';

/// Issue #368 (PRD #346 Wave 1) — the drawer restyled to the mockups.
///
/// Pinned:
///   * header, scrolling list and pinned footer (Display + Log Out) sit fully
///     inside the safe area on sideways phones with a top status bar and a
///     right-hand navigation bar, and upright with a 48dp bottom inset;
///   * no overflow at text scale 1.3 at 360dp wide (and sideways);
///   * every tap target is at least kMinInteractiveDimension;
///   * the sync banner keeps its signals, gate and wording (pending-only reads
///     the mockup's "N records waiting to sync");
///   * PRO / FREE TRIAL / role tags, store picker, Display and Log Out keep
///     their rules.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ScreenTestEnvironment env;

  // Home starts a connectivity listener; the plugin has no test
  // implementation, so answer "online over wifi" instead of throwing.
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

  /// [finder]'s rect lies inside the screen minus [insets] and inside the
  /// drawer.
  void expectInsideSafeArea(
    WidgetTester tester,
    Finder finder,
    Size size,
    EdgeInsets insets, {
    required String what,
  }) {
    expect(finder, findsOneWidget, reason: '$what is on screen');
    final rect = tester.getRect(finder);
    final drawer = tester.getRect(find.byType(Drawer));
    expect(
      rect.top,
      greaterThanOrEqualTo(insets.top - 0.01),
      reason: '$what clears the status bar',
    );
    expect(
      rect.bottom,
      lessThanOrEqualTo(size.height - insets.bottom + 0.01),
      reason: '$what clears the bottom inset',
    );
    expect(
      rect.left,
      greaterThanOrEqualTo(insets.left - 0.01),
      reason: '$what clears a left cutout',
    );
    expect(
      rect.right,
      lessThanOrEqualTo(drawer.right + 0.01),
      reason: '$what is not clipped by the drawer edge',
    );
    expect(
      rect.right,
      lessThanOrEqualTo(size.width - insets.right + 0.01),
      reason: '$what clears a right navigation bar',
    );
  }

  /// Every live tap target in the drawer is at least 48dp each way.
  void expectTapTargets(WidgetTester tester) {
    final inks = find.descendant(
      of: find.byType(Drawer),
      matching: find.byWidgetPredicate((w) => w is InkWell && w.onTap != null),
    );
    expect(inks, findsWidgets);
    // An IconButton's ink is 40dp; its padded tap area is the button itself
    // (checked below).
    final inIconButton = find
        .descendant(of: find.byType(IconButton), matching: find.byType(InkWell))
        .evaluate()
        .toSet();
    for (final button
        in find
            .descendant(
              of: find.byType(Drawer),
              matching: find.byType(IconButton),
            )
            .evaluate()) {
      final size = (button.renderObject! as RenderBox).size;
      expect(size.height, greaterThanOrEqualTo(kMinInteractiveDimension));
      expect(size.width, greaterThanOrEqualTo(kMinInteractiveDimension));
    }
    for (final element in inks.evaluate()) {
      if (inIconButton.contains(element)) continue;
      final box = element.renderObject! as RenderBox;
      if (!box.hasSize) continue;
      expect(
        box.size.height,
        greaterThanOrEqualTo(kMinInteractiveDimension - 0.01),
        reason: '${element.widget.key ?? element.widget} height',
      );
      expect(
        box.size.width,
        greaterThanOrEqualTo(kMinInteractiveDimension - 0.01),
        reason: '${element.widget.key ?? element.widget} width',
      );
    }
  }

  Future<void> pumpMockupDrawer(
    WidgetTester tester,
    Size size,
    EdgeInsets insets, {
    TextScaler? textScaler,
  }) async {
    final second = await addSecondStore(env);
    await queueSyncRecords(env, 3);
    await pumpOpenDrawer(
      tester,
      env: env,
      size: size,
      padding: insets,
      stores: [env.store, second],
      activeStoreId: second.id,
      textScaler: textScaler,
    );
  }

  group('safe area', () {
    const sideways = EdgeInsets.only(top: 24, right: 48);
    const sizes = <Size>[Size(844, 390), Size(915, 412), Size(800, 360)];

    for (final size in sizes) {
      testWidgets('sideways ${size.width.toInt()}x${size.height.toInt()} '
          '(status bar top, nav bar right): header, list and footer are '
          'inside the safe area', (tester) async {
        await pumpMockupDrawer(tester, size, sideways);

        expectInsideSafeArea(
          tester,
          find.byKey(AppDrawerKeys.header),
          size,
          sideways,
          what: 'header',
        );
        expectInsideSafeArea(
          tester,
          find.byKey(AppDrawerKeys.syncBanner),
          size,
          sideways,
          what: 'sync banner',
        );
        expectInsideSafeArea(
          tester,
          find.byKey(AppDrawerKeys.footer),
          size,
          sideways,
          what: 'footer',
        );
        expectInsideSafeArea(
          tester,
          find.byKey(AppDrawerKeys.display),
          size,
          sideways,
          what: 'Display card',
        );
        expectInsideSafeArea(
          tester,
          find.byKey(AppDrawerKeys.logOut),
          size,
          sideways,
          what: 'Log Out',
        );

        // The list sits between the top and the footer and leaves room to
        // scroll through the items.
        final list = tester.getRect(find.byKey(AppDrawerKeys.list));
        final footer = tester.getRect(find.byKey(AppDrawerKeys.footer));
        expect(list.bottom, lessThanOrEqualTo(footer.top + 0.01));
        expect(
          list.height,
          greaterThanOrEqualTo(kMinInteractiveDimension * 3),
          reason: 'the list keeps room for at least three items',
        );

        // Every item scrolls into view above the pinned footer.
        await tester.scrollUntilVisible(
          find.text('Sync Issues'),
          100,
          scrollable: find.descendant(
            of: find.byKey(AppDrawerKeys.list),
            matching: find.byType(Scrollable),
          ),
        );
        await tester.pump();
        final last = tester.getRect(find.text('Sync Issues'));
        expect(last.bottom, lessThanOrEqualTo(footer.top + 0.01));
        // The footer did not move while the list scrolled.
        expect(
          tester.getRect(find.byKey(AppDrawerKeys.footer)).top,
          closeTo(footer.top, 0.01),
        );

        expectTapTargets(tester);
        expect(tester.takeException(), isNull);
        await disposeScreen(tester);
      });
    }

    testWidgets('sideways with a left cutout: content clears it', (
      tester,
    ) async {
      const cutout = EdgeInsets.only(top: 24, left: 48);
      const size = Size(844, 390);
      await pumpMockupDrawer(tester, size, cutout);
      for (final key in [
        AppDrawerKeys.header,
        AppDrawerKeys.footer,
        AppDrawerKeys.logOut,
      ]) {
        expectInsideSafeArea(
          tester,
          find.byKey(key),
          size,
          cutout,
          what: '$key',
        );
      }
      expect(
        tester.getRect(find.byType(Drawer)).left,
        0,
        reason: 'the drawer Surface runs under the cutout',
      );
      expect(tester.takeException(), isNull);
      await disposeScreen(tester);
    });

    testWidgets('upright 390x844 with a 48dp bottom inset: header pinned, '
        'footer clears the navigation bar', (tester) async {
      const upright = EdgeInsets.only(top: 24, bottom: 48);
      const size = Size(390, 844);
      await pumpMockupDrawer(tester, size, upright);
      for (final key in [
        AppDrawerKeys.header,
        AppDrawerKeys.syncBanner,
        AppDrawerKeys.storePicker,
        AppDrawerKeys.display,
        AppDrawerKeys.logOut,
      ]) {
        expectInsideSafeArea(
          tester,
          find.byKey(key),
          size,
          upright,
          what: '$key',
        );
      }
      // Pinned: the header is outside the scrolling list.
      expect(
        find.descendant(
          of: find.byKey(AppDrawerKeys.list),
          matching: find.byKey(AppDrawerKeys.header),
        ),
        findsNothing,
      );
      expect(
        tester.getRect(find.byKey(AppDrawerKeys.footer)).bottom,
        size.height,
        reason: 'the footer Surface runs under the bottom inset',
      );
      expectTapTargets(tester);
      expect(tester.takeException(), isNull);
      await disposeScreen(tester);
    });
  });

  group('in the real frame', () {
    Future<void> pumpFrame(
      WidgetTester tester,
      Size size,
      EdgeInsets insets,
    ) async {
      tester.view.viewPadding = FakeViewPadding(
        left: insets.left,
        top: insets.top,
        right: insets.right,
        bottom: insets.bottom,
      );
      addTearDown(tester.view.resetViewPadding);
      NavigationService()
        ..beginSessionLanding()
        ..setIndex(NavigationService.homeTab);
      await pumpScreen(
        tester,
        env: env,
        size: size,
        padding: insets,
        screen: const MainLayout(),
        bottomNavHeight: 0,
        grantedKeys: kDrawerCeoGrants,
        overrides: [firstRunTourStopProvider.overrideWithValue(TourStop.none)],
        // The push-notification soft ask would sit over the frame.
        sharedPreferences: const {
          'push_soft_ask_shown_v1': true,
          'hint_pos_gestures': 2,
        },
        settle: false,
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
    }

    testWidgets('sideways 844x390, nav bar right: the rail menu opens the '
        'drawer and its footer is inside the safe area', (tester) async {
      const insets = EdgeInsets.only(top: 24, right: 48);
      const size = Size(844, 390);
      await pumpFrame(tester, size, insets);
      await tester.tap(find.byKey(const Key('frame-rail-menu')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      for (final key in [
        AppDrawerKeys.header,
        AppDrawerKeys.display,
        AppDrawerKeys.logOut,
      ]) {
        expectInsideSafeArea(
          tester,
          find.byKey(key),
          size,
          insets,
          what: '$key',
        );
      }
      expect(find.byKey(const Key('drawer-selected-item')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await disposeScreen(tester);
    });

    testWidgets('upright 390x844, 48dp bottom inset, on a tab root: the drawer '
        'stops at the bottom bar and adds no second inset', (tester) async {
      const insets = EdgeInsets.only(top: 24, bottom: 48);
      const size = Size(390, 844);
      await pumpFrame(tester, size, insets);
      NavigationService().openDrawer();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      final bar = tester.getRect(find.byKey(const Key('main-bottom-nav')));
      final footer = tester.getRect(find.byKey(AppDrawerKeys.footer));
      final logOut = tester.getRect(find.byKey(AppDrawerKeys.logOut));
      expect(footer.bottom, lessThanOrEqualTo(bar.top + 0.01));
      expect(
        footer.bottom - logOut.bottom,
        lessThan(insets.bottom),
        reason: 'the bottom bar already clears the navigation inset',
      );
      expectInsideSafeArea(
        tester,
        find.byKey(AppDrawerKeys.logOut),
        size,
        insets,
        what: 'Log Out',
      );
      expect(tester.takeException(), isNull);
      await disposeScreen(tester);
    });
  });

  group('text scale 1.3', () {
    for (final size in const [Size(360, 740), Size(844, 390)]) {
      testWidgets('${size.width.toInt()}x${size.height.toInt()}: '
          'no overflow, targets still 48dp', (tester) async {
        await pumpMockupDrawer(
          tester,
          size,
          kRealisticPhoneInsets,
          textScaler: const TextScaler.linear(1.3),
        );
        expect(tester.takeException(), isNull);
        expectTapTargets(tester);
        expectInsideSafeArea(
          tester,
          find.byKey(AppDrawerKeys.logOut),
          size,
          kRealisticPhoneInsets,
          what: 'Log Out',
        );
        await disposeScreen(tester);
      });
    }
  });

  group('width', () {
    testWidgets('84% of a narrow phone; the mockup width (328), scaled, on '
        'wider screens', (tester) async {
      await pumpOpenDrawer(tester, env: env, size: const Size(360, 740));
      expect(tester.getSize(find.byType(Drawer)).width, closeTo(302.4, 0.01));
      await disposeScreen(tester);

      final context = await pumpOpenDrawer(
        tester,
        env: env,
        size: const Size(1280, 800),
      );
      final scaled = context.getRSize(kAppDrawerBaseWidth);
      expect(scaled, greaterThan(kAppDrawerBaseWidth));
      expect(tester.getSize(find.byType(Drawer)).width, closeTo(scaled, 0.01));
      await disposeScreen(tester);
    });
  });

  group('header', () {
    testWidgets('business initial tile, name, profile hint, user, tags', (
      tester,
    ) async {
      await pumpOpenDrawer(tester, env: env, size: const Size(390, 844));
      final tile = find.byKey(AppDrawerKeys.profileTile);
      expect(
        find.descendant(of: tile, matching: find.text('S')),
        findsOneWidget,
      );
      expect(find.text(kDrawerSampleBusiness), findsOneWidget);
      expect(find.text('Tap logo to open profile'), findsOneWidget);
      expect(find.text(kDrawerSampleUser), findsOneWidget);
      expect(find.text('Terminal 01'), findsOneWidget);
      final pro = tester.widget<TagPill>(find.widgetWithText(TagPill, 'PRO'));
      expect(pro.tone, TagPillTone.solidInfo);
      final role = tester.widget<TagPill>(find.widgetWithText(TagPill, 'CEO'));
      expect(role.tone, TagPillTone.info);
      expect(find.byKey(AppDrawerKeys.lock), findsOneWidget);
      await disposeScreen(tester);
    });

    testWidgets('FREE TRIAL is amber; no tag when the plan is inactive', (
      tester,
    ) async {
      await pumpOpenDrawer(
        tester,
        env: env,
        size: const Size(390, 844),
        subscription: SubscriptionAccess.trialActive,
      );
      expect(
        tester.widget<TagPill>(find.widgetWithText(TagPill, 'FREE TRIAL')).tone,
        TagPillTone.warning,
      );
      await disposeScreen(tester);

      await pumpOpenDrawer(
        tester,
        env: env,
        size: const Size(390, 844),
        subscription: SubscriptionAccess.inactive,
      );
      expect(find.text('PRO'), findsNothing);
      expect(find.text('FREE TRIAL'), findsNothing);
      expect(find.widgetWithText(TagPill, 'CEO'), findsOneWidget);
      await disposeScreen(tester);
    });

    testWidgets('the ✕ closes the drawer', (tester) async {
      await pumpOpenDrawer(tester, env: env, size: const Size(390, 844));
      expect(find.byType(Drawer), findsOneWidget);
      await tester.tap(find.byKey(AppDrawerKeys.close));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(Drawer), findsNothing);
      await disposeScreen(tester);
    });
  });

  group('sync banner', () {
    Future<String?> bannerText(WidgetTester tester) async {
      final banner = find.byKey(AppDrawerKeys.syncBanner);
      if (banner.evaluate().isEmpty) return null;
      return tester
          .widget<Text>(
            find.descendant(of: banner, matching: find.byType(Text)),
          )
          .data;
    }

    testWidgets('hidden when nothing is waiting', (tester) async {
      await pumpOpenDrawer(tester, env: env, size: const Size(390, 844));
      expect(await bannerText(tester), isNull);
      await disposeScreen(tester);
    });

    testWidgets('pending only: amber "N records waiting to sync"', (
      tester,
    ) async {
      await queueSyncRecords(env, 3);
      await pumpOpenDrawer(tester, env: env, size: const Size(390, 844));
      expect(await bannerText(tester), '3 records waiting to sync');
      final banner = tester.widget<DrawerSyncBanner>(
        find.byType(DrawerSyncBanner),
      );
      expect(banner.tone, DrawerSyncTone.waiting);
      final fixed = Theme.of(
        tester.element(find.byType(DrawerSyncBanner)),
      ).extension<AppFixedColors>()!;
      final material = tester.widget<Material>(
        find.byKey(AppDrawerKeys.syncBanner),
      );
      expect(material.color, fixed.warningTint);
      await disposeScreen(tester);
    });

    testWidgets('one record reads singular', (tester) async {
      await queueSyncRecords(env, 1);
      await pumpOpenDrawer(tester, env: env, size: const Size(390, 844));
      expect(await bannerText(tester), '1 record waiting to sync');
      await disposeScreen(tester);
    });

    testWidgets('failed: today\'s wording, red tone', (tester) async {
      await queueSyncRecords(env, 2, failed: true);
      await pumpOpenDrawer(tester, env: env, size: const Size(390, 844));
      // A failed row is still unsynced, so it also counts as pending.
      expect(await bannerText(tester), 'Syncing 2 · 2 failed');
      expect(
        tester.widget<DrawerSyncBanner>(find.byType(DrawerSyncBanner)).tone,
        DrawerSyncTone.failed,
      );
      await disposeScreen(tester);
    });

    testWidgets('hidden without Sync Issues access', (tester) async {
      await queueSyncRecords(env, 3);
      await pumpOpenDrawer(
        tester,
        env: env,
        size: const Size(390, 844),
        grants: const {'sales.make', 'stock.view'},
        roleSlug: 'cashier',
        roleName: 'Cashier',
        roleRank: 2,
      );
      expect(await bannerText(tester), isNull);
      expect(find.text('Sync Issues'), findsNothing);
      await disposeScreen(tester);
    });
  });

  group('store picker', () {
    testWidgets('shows the active store when there are two to choose from', (
      tester,
    ) async {
      final second = await addSecondStore(env);
      await pumpOpenDrawer(
        tester,
        env: env,
        size: const Size(390, 844),
        stores: [env.store, second],
        activeStoreId: second.id,
      );
      final picker = find.byKey(AppDrawerKeys.storePicker);
      expect(
        find.descendant(of: picker, matching: find.text('Store')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: picker, matching: find.text(kDrawerSampleStore)),
        findsOneWidget,
      );
      await disposeScreen(tester);
    });

    testWidgets('hidden with a single store', (tester) async {
      await pumpOpenDrawer(tester, env: env, size: const Size(390, 844));
      expect(find.byKey(AppDrawerKeys.storePicker), findsNothing);
      await disposeScreen(tester);
    });
  });

  group('items and footer', () {
    testWidgets('CEO: every item in order, selected bar, Display + Log Out', (
      tester,
    ) async {
      await pumpOpenDrawer(tester, env: env, size: const Size(390, 844));
      const order = [
        'Home',
        'Point of Sale',
        'Inventory',
        'Orders',
        'Customers',
        'Staff Management',
        'Supplier Accounts',
        'Expenses',
        'Stores',
        'Activity Logs',
        'CEO Settings',
        'Sync Issues',
      ];
      final tiles = tester
          .widgetList<DrawerNavTile>(
            find.byType(DrawerNavTile, skipOffstage: false),
          )
          .map((t) => t.label)
          .toList();
      expect(tiles, order);
      expect(find.text('Settings'), findsNothing);
      final selected = find.byKey(const Key('drawer-selected-item'));
      expect(selected, findsOneWidget);
      expect(
        find.descendant(of: selected, matching: find.text('Point of Sale')),
        findsOneWidget,
      );
      expect(find.byKey(AppDrawerKeys.display), findsOneWidget);
      expect(find.byKey(AppDrawerKeys.logOut), findsOneWidget);
      await disposeScreen(tester);
    });

    testWidgets('Manager: Settings item, no Display card', (tester) async {
      await pumpOpenDrawer(
        tester,
        env: env,
        size: const Size(390, 844),
        grants: const {'sales.make', 'stock.view', 'customers.add'},
        roleSlug: 'manager',
        roleName: 'Manager',
        roleRank: 3,
      );
      expect(find.text('Settings'), findsOneWidget);
      expect(find.text('CEO Settings'), findsNothing);
      expect(find.byKey(AppDrawerKeys.display), findsNothing);
      expect(find.byKey(AppDrawerKeys.logOut), findsOneWidget);
      await disposeScreen(tester);
    });

    testWidgets('Log Out asks the same erase question; Cancel keeps you in', (
      tester,
    ) async {
      await pumpOpenDrawer(tester, env: env, size: const Size(390, 844));
      await tester.tap(find.byKey(AppDrawerKeys.logOut));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Log out and erase all data?'), findsOneWidget);
      expect(find.text('Log out & Erase'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Log out and erase all data?'), findsNothing);
      expect(find.byType(Drawer), findsOneWidget);
      await disposeScreen(tester);
    });
  });

  testWidgets('light theme renders without errors', (tester) async {
    await pumpOpenDrawer(
      tester,
      env: env,
      size: const Size(390, 844),
      theme: AppTheme.light(),
    );
    expect(tester.takeException(), isNull);
    await disposeScreen(tester);
  });
}
