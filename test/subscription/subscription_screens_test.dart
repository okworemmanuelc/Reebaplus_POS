// Wave 2 B (#414): the restyled Subscription Locked and Thank You screens.
// Renders their controls, runs the actions, and checks there is no overflow at
// the five reference sizes (360 @1.3, 390x844, 844x390 with insets, 800x1280,
// 1280x800).

import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/features/subscription/screens/subscription_locked_screen.dart';
import 'package:reebaplus_pos/features/subscription/screens/thank_you_subscription_screen.dart';
import 'package:reebaplus_pos/features/subscription/subscription_access.dart';
import 'package:reebaplus_pos/features/subscription/subscription_thanks.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/features/subscription/widgets/subscription_parts.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../helpers/screen_harness.dart';
import 'subscription_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ScreenTestEnvironment env;
  late BusinessData business;

  setUp(() async {
    env = await setupScreenTestEnvironment(
      productCount: 0,
      businessName: 'Stallion Global',
    );
    business = await seedSubscriptionBusiness(env);
  });
  tearDown(() => env.dispose());

  const sizes = <String, (Size, EdgeInsets, double)>{
    '360x800 @1.3': (Size(360, 800), EdgeInsets.only(top: 24, bottom: 24), 1.3),
    '390x844': (Size(390, 844), EdgeInsets.only(top: 24, bottom: 48), 1.0),
    '844x390 insets': (
      Size(844, 390),
      EdgeInsets.only(top: 24, right: 48),
      1.0,
    ),
    '800x1280': (Size(800, 1280), EdgeInsets.zero, 1.0),
    '1280x800': (Size(1280, 800), EdgeInsets.zero, 1.0),
  };

  Future<void> pump(
    WidgetTester tester,
    Widget screen, {
    Size size = const Size(390, 844),
    EdgeInsets padding = EdgeInsets.zero,
    double scale = 1.0,
    Brightness brightness = Brightness.light,
  }) async {
    await pumpScreen(
      tester,
      env: env,
      size: size,
      padding: padding,
      textScaler: TextScaler.linear(scale),
      bottomNavHeight: 0,
      theme: brightness == Brightness.light
          ? AppTheme.light()
          : AppTheme.dark(),
      screen: screen,
      settle: false,
    );
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 250));
    }
  }

  group('Subscription Locked', () {
    testWidgets('trial ended: title, body, ended date, both actions', (
      tester,
    ) async {
      await pump(
        tester,
        const SubscriptionLockedScreen(access: SubscriptionAccess.trialExpired),
      );
      expect(find.text('Your free trial has ended'), findsOneWidget);
      expect(find.textContaining('Subscribe to the Reebaplus'), findsOneWidget);
      expect(
        find.text('Your free trial ended on 30 Sep 2026.'),
        findsOneWidget,
      );
      expect(find.text('Subscribe'), findsOneWidget);
      expect(find.text('Sign out'), findsOneWidget);
      await disposeScreen(tester);
    });

    testWidgets('inactive: its own wording, no ended line', (tester) async {
      await pump(
        tester,
        const SubscriptionLockedScreen(access: SubscriptionAccess.inactive),
      );
      expect(find.text('Subscription inactive'), findsOneWidget);
      expect(find.textContaining('currently inactive'), findsOneWidget);
      expect(find.textContaining('free trial ended on'), findsNothing);
      await disposeScreen(tester);
    });

    testWidgets('Subscribe opens the info pop-up and Got it closes it', (
      tester,
    ) async {
      await pump(
        tester,
        const SubscriptionLockedScreen(access: SubscriptionAccess.trialExpired),
      );
      await tester.tap(find.text('Subscribe'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        find.textContaining('In-app payment is coming soon'),
        findsOneWidget,
      );
      await tester.tap(find.text('Got it'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        find.textContaining('In-app payment is coming soon'),
        findsNothing,
      );
      await disposeScreen(tester);
    });

    testWidgets('buttons are at least 48dp tall', (tester) async {
      await pump(
        tester,
        const SubscriptionLockedScreen(access: SubscriptionAccess.trialExpired),
      );
      for (final label in ['Subscribe', 'Sign out']) {
        final h = tester.getSize(find.text(label).first);
        expect(h.height, greaterThan(0));
        final btn = find.ancestor(
          of: find.text(label),
          matching: find.byType(InkWell),
        );
        expect(tester.getSize(btn.first).height, greaterThanOrEqualTo(48));
      }
      await disposeScreen(tester);
    });

    sizes.forEach((name, spec) {
      for (final b in Brightness.values) {
        testWidgets('no overflow at $name ${b.name}', (tester) async {
          final (size, padding, scale) = spec;
          await pump(
            tester,
            const SubscriptionLockedScreen(
              access: SubscriptionAccess.trialExpired,
            ),
            size: size,
            padding: padding,
            scale: scale,
            brightness: b,
          );
          expect(tester.takeException(), isNull);
          expect(find.text('Sign out'), findsOneWidget);
          await disposeScreen(tester);
        });
      }
    });

    testWidgets('content is capped at 720 on a wide screen', (tester) async {
      await pump(
        tester,
        const SubscriptionLockedScreen(access: SubscriptionAccess.trialExpired),
        size: const Size(1280, 800),
      );
      final w = tester.getSize(find.text('Subscribe').first);
      expect(w.width, lessThan(720));
      final btn = find.ancestor(
        of: find.text('Subscribe'),
        matching: find.byType(InkWell),
      );
      expect(tester.getSize(btn.first).width, lessThanOrEqualTo(720));
      expect(find.byType(SubscriptionStateFrame), findsOneWidget);
      await disposeScreen(tester);
    });
  });

  group('Thank You', () {
    testWidgets('shows the thanks, plan card, renewal and Continue', (
      tester,
    ) async {
      await pump(tester, ThankYouSubscriptionScreen(business: business));
      expect(find.text('Thank you for subscribing!'), findsOneWidget);
      expect(
        find.textContaining('Stallion Global is now on the'),
        findsOneWidget,
      );
      expect(find.text('₦6,500 per month'), findsOneWidget);
      expect(find.text('Renews 15 Nov 2026'), findsOneWidget);
      expect(find.text('Continue'), findsOneWidget);
      await disposeScreen(tester);
    });

    testWidgets('premium plan outside Nigeria shows the dollar price', (
      tester,
    ) async {
      final intl = business.copyWith(subscriptionPlan: const Value('premium'));
      await env.db.settingsDao.set('default_currency', 'USD');
      await pump(tester, ThankYouSubscriptionScreen(business: intl));
      expect(find.text('\$20 per month'), findsOneWidget);
      await disposeScreen(tester);
    });

    testWidgets('Continue acknowledges this activation', (tester) async {
      final active = business.copyWith(subscriptionStatus: 'active');
      await pump(tester, ThankYouSubscriptionScreen(business: active));
      final ctx = tester.element(find.byType(ThankYouSubscriptionScreen));
      final svc = ProviderScope.containerOf(
        ctx,
      ).read(subscriptionThanksProvider);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      expect(svc.shouldCelebrate(active), isTrue);
      await tester.tap(find.text('Continue'));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
      expect(svc.shouldCelebrate(active), isFalse);
      await disposeScreen(tester);
    });

    sizes.forEach((name, spec) {
      for (final b in Brightness.values) {
        testWidgets('no overflow at $name ${b.name}', (tester) async {
          final (size, padding, scale) = spec;
          await pump(
            tester,
            ThankYouSubscriptionScreen(business: business),
            size: size,
            padding: padding,
            scale: scale,
            brightness: b,
          );
          expect(tester.takeException(), isNull);
          expect(find.text('Continue'), findsOneWidget);
          await disposeScreen(tester);
        });
      }
    });
  });
}
