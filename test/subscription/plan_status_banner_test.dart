import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/features/subscription/widgets/plan_limit_widgets.dart';

void main() {
  test('plan limits never get a standing banner (shown briefly on refusal)', () {
    expect(planStatusBannerText(), isNull);
    expect(planStatusBannerText(plan: 'free'), isNull);
  });

  group('failed Play renewal (#591)', () {
    String? b(String? issue, {String? plan}) =>
        planStatusBannerText(billingIssue: issue, plan: plan);

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
        b('hold', plan: 'free'),
        'Your shop is on Free until payment is fixed.',
      );
    });
    test('no billing issue: no banner', () {
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
