// app_notification_test.dart
//
// #384: a toast (`AppNotification`) covered the POS header on a tablet. Cause,
// in the shared notification code: the toast was pinned 12dp under the top
// safe-area edge — exactly where every screen draws its top bar (title, store
// name, bell) — and at tablet widths it became a bar across the whole header.
// It now starts under the tallest top bar the app draws.
//
// Found on the way: the toast's overlay entry was inserted once and reused, so
// after a toast on one tab (each tab has its own Navigator and Overlay), a
// toast raised on another tab painted inside the first, offstage tab and never
// showed. The entry now moves to the caller's Overlay.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/providers/first_run_surface_state.dart';
import 'package:reebaplus_pos/core/providers/first_run_tour_state.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/utils/notifications.dart';
import 'package:reebaplus_pos/features/dashboard/screens/home_screen.dart';
import 'package:reebaplus_pos/features/pos/screens/pos_home_screen.dart';
import 'package:reebaplus_pos/features/pos/widgets/product_grid.dart';
import 'package:reebaplus_pos/shared/services/navigation_service.dart';
import 'package:reebaplus_pos/shared/widgets/main_layout.dart';

import '../helpers/screen_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ScreenTestEnvironment env;

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
      productCount: 4,
      sharedPreferences: const {
        'push_soft_ask_shown_v1': true,
        'hint_pos_gestures': 2,
        'hint_cart_tap_edit': 2,
      },
    );
    AppNotification.hide();
    NavigationService()
      ..resetNavigation()
      ..beginSessionLanding();
  });

  tearDown(() async {
    AppNotification.hide();
    await env.dispose();
    NavigationService().resetNavigation();
  });

  Future<void> pumpFrame(
    WidgetTester tester, {
    required Size size,
    required int tab,
  }) async {
    NavigationService().setIndex(tab);
    await pumpScreen(
      tester,
      env: env,
      size: size,
      padding: const EdgeInsets.only(top: 24),
      screen: const MainLayout(),
      bottomNavHeight: 0,
      grantedKeys: const {'sales.make', 'stock.view'},
      overrides: [
        firstRunTourStopProvider.overrideWithValue(TourStop.none),
        firstRunSurfaceStateProvider.overrideWithValue(
          FirstRunSurfaceState.hasContent,
        ),
      ],
      settle: false,
    );
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 250));
    }
  }

  /// The toast's card: the Material that hosts the message.
  Rect toastRect(WidgetTester tester, String text) => tester.getRect(
    find
        .ancestor(
          of: find.textContaining(text),
          matching: find.byType(Material),
        )
        .first,
  );

  Future<void> drain(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 5));
    await tester.pump(const Duration(seconds: 1));
  }

  const sizes = <String, Size>{
    'tablet 800x1280': Size(800, 1280),
    'wide 1280x800': Size(1280, 800),
    'phone 390x844': Size(390, 844),
  };

  sizes.forEach((name, size) {
    testWidgets('$name: the "added to cart" toast sits under the POS header', (
      tester,
    ) async {
      await pumpFrame(tester, size: size, tab: NavigationService.posTab);
      await tester.tap(find.byKey(posProductTileKey(env.products.first.id)));
      // Past the slide-in, so the toast is where it rests.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));

      final header = tester.getRect(find.byKey(kPosTopBarKey));
      final toast = toastRect(tester, 'added to cart');
      expect(
        toast.top,
        greaterThanOrEqualTo(header.bottom),
        reason: 'the toast must not cover the title, store or bell',
      );
      await drain(tester);
      await disposeScreen(tester);
    });
  });

  testWidgets('a plain screen: the toast sits under a theme-height AppBar', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 1280);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    late BuildContext context;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Builder(
          builder: (c) {
            context = c;
            return Scaffold(
              appBar: AppBar(title: const Text('Title')),
              body: const SizedBox.expand(),
            );
          },
        ),
      ),
    );
    AppNotification.showSuccess(context, 'Saved');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(
      toastRect(tester, 'Saved').top,
      greaterThanOrEqualTo(tester.getRect(find.byType(AppBar)).bottom),
    );
    await drain(tester);
  });

  testWidgets('a toast after one on another tab still shows on this tab', (
    tester,
  ) async {
    await pumpFrame(
      tester,
      size: const Size(390, 844),
      tab: NavigationService.homeTab,
    );
    AppNotification.showInfo(
      tester.element(find.byType(HomeScreen)),
      'From Home',
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('From Home'), findsOneWidget);

    NavigationService().setIndex(NavigationService.posTab);
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 250));
    }
    await tester.tap(find.byKey(posProductTileKey(env.products.first.id)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(
      find.textContaining('added to cart'),
      findsOneWidget,
      reason: 'the toast must paint on the tab the cashier is looking at',
    );
    await drain(tester);
    await disposeScreen(tester);
  });
}
