// Play Billing (#90 slice B): purchase-result handling + the paywall. The IAP
// plugin and the verify Edge Function are faked at their seams.

import 'dart:async';
import 'package:fake_async/fake_async.dart';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/features/subscription/billing/play_billing_constants.dart';
import 'package:reebaplus_pos/features/subscription/billing/play_billing_controller.dart';
import 'package:reebaplus_pos/features/subscription/billing/play_billing_port.dart';
import 'package:reebaplus_pos/features/subscription/billing/play_billing_providers.dart';
import 'package:reebaplus_pos/features/subscription/billing/plans_paywall.dart';

class FakePort implements PlayBillingPort {
  FakePort({this.available = true, this.offers = const []});
  bool available;
  List<StoreOffer> offers;
  final stream = StreamController<PurchaseEvent>.broadcast();
  final completed = <PurchaseEvent>[];
  StoreOffer? bought;
  String? boughtAccount;
  PlanChange? boughtChange;
  int buys = 0;
  int restores = 0;
  OwnedSubscription? owned;

  @override
  Future<bool> isAvailable() async => available;
  @override
  Future<List<StoreOffer>> loadOffers() async => offers;
  @override
  Stream<PurchaseEvent> get events => stream.stream;
  @override
  Future<void> buy(StoreOffer offer, {required String accountId, PlanChange? change}) async {
    buys++;
    bought = offer;
    boughtAccount = accountId;
    boughtChange = change;
  }

  @override
  Future<OwnedSubscription?> queryOwnedSubscription() async => owned;

  @override
  Future<void> restore() async => restores++;
  @override
  Future<void> complete(PurchaseEvent event) async => completed.add(event);
}

const _store = [
  StoreOffer(kProductBasic, kBasePlanMonthly, '₦6,999.00'),
  StoreOffer(kProductPremium, kBasePlanYearly, '₦251,000.00'),
];

PlayBillingController _ctl(FakePort port, PurchaseVerifier v) =>
    PlayBillingController(port: port, verify: v, businessId: 'biz-1');

void main() {
  group('purchase result handling', () {
    test('purchased -> verified -> completed -> success', () async {
      final port = FakePort();
      String? gotToken;
      final c = _ctl(port, ({required businessId, required purchaseToken, required productId}) async {
        gotToken = purchaseToken;
        expect(businessId, 'biz-1');
        return const VerifyOutcome(true);
      });
      const e = PurchaseEvent(PurchaseEventStatus.purchased,
          productId: kProductBasic, purchaseToken: 'tok');
      await c.handleEvent(e);
      expect(gotToken, 'tok');
      expect(port.completed, [e]);
      expect(c.state.phase, BillingPhase.success);
    });

    test('verification failure does NOT complete the purchase', () async {
      final port = FakePort();
      final c = _ctl(port, ({required businessId, required purchaseToken, required productId}) async =>
          const VerifyOutcome(false, 'internal'));
      await c.handleEvent(const PurchaseEvent(PurchaseEventStatus.restored,
          productId: kProductPremium, purchaseToken: 'tok'));
      expect(port.completed, isEmpty);
      expect(c.state.phase, BillingPhase.error);
    });

    test('canceled returns to ready; error surfaces message; pending waits', () async {
      final c = _ctl(FakePort(), ({required businessId, required purchaseToken, required productId}) async =>
          const VerifyOutcome(true));
      await c.handleEvent(const PurchaseEvent(PurchaseEventStatus.canceled));
      expect(c.state.phase, BillingPhase.ready);
      await c.handleEvent(const PurchaseEvent(PurchaseEventStatus.error, message: 'boom'));
      expect(c.state.phase, BillingPhase.error);
      expect(c.state.message, 'boom');
      await c.handleEvent(const PurchaseEvent(PurchaseEventStatus.pending));
      expect(c.state.phase, BillingPhase.purchasing);
    });

    test('purchase without a token is an error and never verified', () async {
      var called = false;
      final c = _ctl(FakePort(), ({required businessId, required purchaseToken, required productId}) async {
        called = true;
        return const VerifyOutcome(true);
      });
      await c.handleEvent(const PurchaseEvent(PurchaseEventStatus.purchased, productId: kProductBasic));
      expect(called, isFalse);
      expect(c.state.phase, BillingPhase.error);
    });

    test('prices: store wins, fallback otherwise', () async {
      final c = _ctl(FakePort(offers: _store), ({required businessId, required purchaseToken, required productId}) async =>
          const VerifyOutcome(true));
      await c.init();
      expect(c.priceFor(PlanTier.basic, BillingCycle.monthly, naira: true), '₦6,999.00');
      expect(c.priceFor(PlanTier.basic, BillingCycle.yearly, naira: true), '₦65,000');
      expect(c.priceFor(PlanTier.premium, BillingCycle.monthly, naira: false), '\$20');
      expect(c.priceFor(PlanTier.basic, BillingCycle.yearly, naira: false), '\$50');
      c.dispose();
    });
  });

  group('plan switching (#589)', () {
    const all = [
      StoreOffer(kProductBasic, kBasePlanMonthly, 'b-m'),
      StoreOffer(kProductBasic, kBasePlanYearly, 'b-y'),
      StoreOffer(kProductPremium, kBasePlanMonthly, 'p-m'),
      StoreOffer(kProductPremium, kBasePlanYearly, 'p-y'),
    ];
    Future<VerifyOutcome> ok({required businessId, required purchaseToken, required productId}) async =>
        const VerifyOutcome(true);

    Future<PlayBillingController> ctl(FakePort port, CurrentPlan? cur,
        {PlaySubscriptionLookup? lookup}) async {
      final c = PlayBillingController(
        port: port,
        verify: ok,
        businessId: 'biz-1',
        currentPlan: () => cur,
        hasPlaySubscription: lookup,
      );
      await c.init();
      return c;
    }

    test('planMove: tier first, then cycle', () {
      expect(planMove(PlanTier.basic, BillingCycle.monthly, PlanTier.premium, BillingCycle.monthly), PlanMove.upgrade);
      expect(planMove(PlanTier.basic, BillingCycle.monthly, PlanTier.basic, BillingCycle.yearly), PlanMove.upgrade);
      expect(planMove(PlanTier.basic, BillingCycle.yearly, PlanTier.premium, BillingCycle.monthly), PlanMove.upgrade);
      expect(planMove(PlanTier.premium, BillingCycle.monthly, PlanTier.basic, BillingCycle.yearly), PlanMove.downgrade);
      expect(planMove(PlanTier.premium, BillingCycle.yearly, PlanTier.premium, BillingCycle.monthly), PlanMove.downgrade);
      expect(planMove(PlanTier.basic, BillingCycle.yearly, PlanTier.basic, BillingCycle.yearly), PlanMove.same);
    });

    test('upgrade replaces the owned subscription, prorated and now', () async {
      final port = FakePort(offers: all)
        ..owned = const OwnedSubscription(kProductBasic, 'old-tok', accountId: 'biz-1');
      final c = await ctl(port, const CurrentPlan(PlanTier.basic, BillingCycle.monthly));
      await c.subscribe(PlanTier.premium, BillingCycle.monthly);
      expect(port.bought?.productId, kProductPremium);
      expect(port.boughtChange?.old.purchaseToken, 'old-tok');
      expect(port.boughtChange?.kind, ReplacementKind.upgradeNow);
      await c.handleEvent(const PurchaseEvent(PurchaseEventStatus.purchased,
          productId: kProductPremium, purchaseToken: 'new-tok'));
      expect(c.state.message, 'Your plan is active.');
    });

    test('monthly -> yearly on the same tier is an upgrade', () async {
      final port = FakePort(offers: all)
        ..owned = const OwnedSubscription(kProductPremium, 'old-tok');
      final c = await ctl(port, const CurrentPlan(PlanTier.premium, BillingCycle.monthly));
      await c.subscribe(PlanTier.premium, BillingCycle.yearly);
      expect(port.boughtChange?.kind, ReplacementKind.upgradeNow);
    });

    test('downgrade is deferred to renewal and says when', () async {
      final port = FakePort(offers: all)
        ..owned = const OwnedSubscription(kProductPremium, 'old-tok', accountId: 'biz-1');
      final c = await ctl(port, CurrentPlan(PlanTier.premium, BillingCycle.monthly,
          periodEnd: DateTime(2026, 11, 12, 12)));
      await c.subscribe(PlanTier.basic, BillingCycle.yearly); // mixed: lower tier wins
      expect(port.boughtChange?.kind, ReplacementKind.downgradeAtRenewal);
      await c.handleEvent(const PurchaseEvent(PurchaseEventStatus.purchased,
          productId: kProductPremium, purchaseToken: 'new-tok'));
      expect(c.state.phase, BillingPhase.success);
      expect(c.state.message, 'Your plan changes to Basic on 12 Nov 2026.');
    });

    test('deferred downgrade with no purchase event settles after 60s', () {
      fakeAsync((async) {
        final port = FakePort(offers: all)
          ..owned = const OwnedSubscription(kProductPremium, 'old-tok', accountId: 'biz-1');
        late PlayBillingController c;
        ctl(port, CurrentPlan(PlanTier.premium, BillingCycle.monthly,
                periodEnd: DateTime(2026, 11, 12, 12)))
            .then((v) => c = v);
        async.flushMicrotasks();
        c.subscribe(PlanTier.basic, BillingCycle.monthly);
        async.flushMicrotasks();
        expect(c.state.phase, BillingPhase.purchasing);
        async.elapse(const Duration(seconds: 61));
        expect(c.state.phase, BillingPhase.ready);
        expect(c.state.message,
            'If you confirmed the change: Your plan changes to Basic on 12 Nov 2026.');
      });
    });

    test('same plan never starts a purchase', () async {
      final port = FakePort(offers: all)
        ..owned = const OwnedSubscription(kProductBasic, 'old-tok');
      final c = await ctl(port, const CurrentPlan(PlanTier.basic, BillingCycle.yearly));
      expect(c.isCurrentPlan(PlanTier.basic, BillingCycle.yearly), isTrue);
      expect(c.isCurrentPlan(PlanTier.basic, BillingCycle.monthly), isFalse);
      await c.subscribe(PlanTier.basic, BillingCycle.yearly);
      expect(port.buys, 0);
    });

    test('paid on Play but not on this device: manage in Play, no purchase', () async {
      final port = FakePort(offers: all);
      final c = await ctl(port, const CurrentPlan(PlanTier.basic, BillingCycle.monthly),
          lookup: (_) async => true);
      await c.subscribe(PlanTier.premium, BillingCycle.monthly);
      expect(port.buys, 0);
      expect(c.state.message, kManageInPlayMessage);
    });

    test('a subscription tagged for another business is not replaced', () async {
      final port = FakePort(offers: all)
        ..owned = const OwnedSubscription(kProductBasic, 'x', accountId: 'biz-2');
      final c = await ctl(port, const CurrentPlan(PlanTier.basic, BillingCycle.monthly),
          lookup: (_) async => true);
      await c.subscribe(PlanTier.premium, BillingCycle.monthly);
      expect(port.buys, 0);
      expect(c.state.message, kManageInPlayMessage);
    });

    test('hand-given plan (not on Play) can be bought over with a new purchase', () async {
      final port = FakePort(offers: all);
      final c = await ctl(port, const CurrentPlan(PlanTier.basic, BillingCycle.monthly),
          lookup: (_) async => false);
      await c.subscribe(PlanTier.premium, BillingCycle.monthly);
      expect(port.buys, 1);
      expect(port.boughtChange, isNull);
    });

    test('lookup failure blocks the purchase with a retry message', () async {
      final port = FakePort(offers: all);
      final c = await ctl(port, const CurrentPlan(PlanTier.basic, BillingCycle.monthly),
          lookup: (_) async => throw Exception('offline'));
      await c.subscribe(PlanTier.premium, BillingCycle.monthly);
      expect(port.buys, 0);
      expect(c.state.phase, BillingPhase.error);
    });

    test('no plan yet: a plain first purchase', () async {
      final port = FakePort(offers: all);
      final c = await ctl(port, null, lookup: (_) async => true);
      await c.subscribe(PlanTier.basic, BillingCycle.monthly);
      expect(port.buys, 1);
      expect(port.boughtChange, isNull);
    });
  });

  group('PlansPaywall', () {
    Future<FakePort> pump(WidgetTester tester,
        {bool android = true, FakePort? port, List<StoreOffer>? offers, CurrentPlan? current}) async {
      final p = port ?? FakePort(offers: offers ?? _store);
      await tester.pumpWidget(ProviderScope(
        overrides: [
          billingSupportedProvider.overrideWithValue(android),
          billingBusinessIdProvider.overrideWithValue('biz-1'),
          billingUsesNairaProvider.overrideWithValue(true),
          billingCurrentPlanProvider.overrideWithValue(current),
          playSubscriptionLookupProvider.overrideWithValue((_) async => false),
          playBillingPortProvider.overrideWithValue(p),
          purchaseVerifierProvider.overrideWithValue(
            ({required businessId, required purchaseToken, required productId}) async =>
                const VerifyOutcome(true),
          ),
        ],
        child: const MaterialApp(home: Scaffold(body: SingleChildScrollView(child: PlansPaywall()))),
      ));
      await tester.pumpAndSettle();
      return p;
    }

    testWidgets('non-Android shows the interim message and no plans', (tester) async {
      await pump(tester, android: false);
      expect(find.byKey(const Key('paywall-non-android')), findsOneWidget);
      expect(find.byKey(const Key('paywall')), findsNothing);
    });

    testWidgets('Android shows store price, fallback, and toggles yearly', (tester) async {
      await pump(tester);
      expect(find.text('₦6,999.00 per month'), findsOneWidget); // store
      expect(find.text('₦25,000 per month'), findsOneWidget); // fallback
      await tester.tap(find.text('Yearly (2 months free)'));
      await tester.pumpAndSettle();
      expect(find.text('₦65,000 per year'), findsOneWidget); // fallback
      expect(find.text('₦251,000.00 per year'), findsOneWidget); // store
    });

    testWidgets('choosing a plan starts the purchase tagged with the business', (tester) async {
      final port = await pump(tester);
      await tester.tap(find.text('Choose Basic'));
      await tester.pump();
      expect(port.bought?.productId, kProductBasic);
      expect(port.bought?.basePlanId, kBasePlanMonthly);
      expect(port.boughtAccount, 'biz-1');
    });

    testWidgets('a plan the store does not offer shows a message, no purchase', (tester) async {
      final port = await pump(tester, offers: const []);
      await tester.tap(find.text('Choose Premium'));
      await tester.pumpAndSettle();
      expect(port.bought, isNull);
      expect(find.byKey(const Key('paywall-message')), findsOneWidget);
    });

    testWidgets('restore calls the store; success event shows active', (tester) async {
      final port = await pump(tester);
      await tester.tap(find.byKey(const Key('paywall-restore')));
      await tester.pump();
      expect(port.restores, 1);
      port.stream.add(const PurchaseEvent(PurchaseEventStatus.restored,
          productId: kProductPremium, purchaseToken: 'tok'));
      await tester.pump();
      await tester.pump();
      expect(find.text('Your plan is active.'), findsOneWidget);
      expect(port.completed, hasLength(1));
    });

    testWidgets('the plan you are on shows a disabled Current plan button', (tester) async {
      final port = await pump(tester,
          current: const CurrentPlan(PlanTier.basic, BillingCycle.monthly));
      expect(find.byKey(const Key('current-basic')), findsOneWidget);
      expect(find.text('Choose Basic'), findsNothing);
      await tester.tap(find.byKey(const Key('current-basic')));
      await tester.pump();
      expect(port.buys, 0);
      // Yearly Basic is a different plan: choosable again.
      await tester.tap(find.text('Yearly (2 months free)'));
      await tester.pumpAndSettle();
      expect(find.text('Choose Basic'), findsOneWidget);
    });

    testWidgets('unavailable store shows the unavailable note', (tester) async {
      await pump(tester, port: FakePort(available: false));
      expect(find.byKey(const Key('paywall-unavailable')), findsOneWidget);
    });
  });
}
