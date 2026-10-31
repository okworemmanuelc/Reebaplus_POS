import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/features/subscription/subscription_access.dart';
import 'package:reebaplus_pos/features/subscription/widgets/plan_limit_widgets.dart';

void main() {
  String? t(int staff, int shops, SubscriptionAccess a, {bool hadPlan = true}) =>
      planStatusBannerText(
        pausedStaff: staff,
        readOnlyShops: shops,
        access: a,
        hadPlan: hadPlan,
      );

  test('over-limit beats plan-ended', () {
    expect(
      t(3, 1, SubscriptionAccess.inactive),
      '3 staff paused · 1 shop read-only on your plan — Upgrade',
    );
  });
  test('zero part omitted, plural shops', () {
    expect(
      t(0, 2, SubscriptionAccess.active),
      '2 shops read-only on your plan — Upgrade',
    );
    expect(
      t(1, 0, SubscriptionAccess.trialActive),
      '1 staff paused on your plan — Upgrade',
    );
  });
  test('plan ended shows Free message', () {
    for (final a in [SubscriptionAccess.inactive, SubscriptionAccess.trialExpired]) {
      expect(t(0, 0, a), contains("you're on Free"));
    }
  });
  test('started on Free (never had a plan): no plan-ended banner', () {
    expect(t(0, 0, SubscriptionAccess.inactive, hadPlan: false), isNull);
    expect(
      t(2, 0, SubscriptionAccess.inactive, hadPlan: false),
      '2 staff paused on your plan — Upgrade',
    );
  });
  test('no banner otherwise', () {
    for (final a in [
      SubscriptionAccess.active,
      SubscriptionAccess.trialActive,
      SubscriptionAccess.grace,
    ]) {
      expect(t(0, 0, a), isNull);
    }
  });

  group('failed Play renewal (#591)', () {
    String? b(String? issue, {String? plan, int staff = 0, int shops = 0,
            SubscriptionAccess a = SubscriptionAccess.active}) =>
        planStatusBannerText(
          pausedStaff: staff,
          readOnlyShops: shops,
          access: a,
          hadPlan: true,
          billingIssue: issue,
          plan: plan,
        );

    test('grace names the plan the payment keeps', () {
      expect(
        b('grace', plan: 'premium'),
        "Your payment didn't go through — update it in Google Play to keep "
        'Premium.',
      );
      expect(b('grace', plan: 'basic'), endsWith('keep Basic.'));
      expect(b('grace', plan: 'free'), endsWith('keep your plan.'));
    });
    test('hold says the shop is on Free', () {
      expect(
        b('hold', plan: 'free', a: SubscriptionAccess.inactive),
        'Your shop is on Free until payment is fixed.',
      );
    });
    test('grace / hold beat over-limit and plan-ended', () {
      expect(b('grace', plan: 'basic', staff: 3, shops: 1), contains('Google Play'));
      expect(
        b('hold', staff: 2, a: SubscriptionAccess.inactive),
        'Your shop is on Free until payment is fixed.',
      );
    });
    test('no billing issue falls through to the plan banners', () {
      expect(b(null, staff: 1), '1 staff paused on your plan — Upgrade');
      expect(b(null), isNull);
      expect(b('unknown'), isNull);
    });
    test('only grace / hold offer Fix payment', () {
      expect(planStatusBannerFixesPayment('grace'), isTrue);
      expect(planStatusBannerFixesPayment('hold'), isTrue);
      expect(planStatusBannerFixesPayment(null), isFalse);
      expect(planStatusBannerFixesPayment('other'), isFalse);
    });
    test('Fix payment opens the Play subscription page', () {
      expect(
        fixPaymentUrl(plan: 'premium', packageName: 'com.reebaplus.pos'),
        'https://play.google.com/store/account/subscriptions'
        '?sku=reebaplus_premium&package=com.reebaplus.pos',
      );
      expect(
        fixPaymentUrl(plan: 'basic', packageName: 'p'),
        contains('sku=reebaplus_basic'),
      );
      // On hold the plan is Free: the subscriptions list, no sku.
      expect(
        fixPaymentUrl(plan: 'free', packageName: 'com.reebaplus.pos'),
        'https://play.google.com/store/account/subscriptions'
        '?package=com.reebaplus.pos',
      );
      expect(
        fixPaymentUrl(plan: null, packageName: ''),
        'https://play.google.com/store/account/subscriptions',
      );
    });
  });
}
