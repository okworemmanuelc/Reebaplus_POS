import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/features/subscription/subscription_access.dart';
import 'package:reebaplus_pos/features/subscription/widgets/plan_limit_widgets.dart';

void main() {
  String? t(int staff, int shops, SubscriptionAccess a) => planStatusBannerText(
    pausedStaff: staff,
    readOnlyShops: shops,
    access: a,
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
  test('no banner otherwise', () {
    for (final a in [
      SubscriptionAccess.active,
      SubscriptionAccess.trialActive,
      SubscriptionAccess.grace,
    ]) {
      expect(t(0, 0, a), isNull);
    }
  });
}
