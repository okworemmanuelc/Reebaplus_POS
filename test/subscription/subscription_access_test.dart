import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/features/subscription/subscription_access.dart';

void main() {
  final now = DateTime(2026, 6, 6, 12, 0, 0);
  final future = now.add(const Duration(days: 5));
  final past = now.subtract(const Duration(days: 1));

  group('computeSubscriptionAccess', () {
    test('active → active (trial date ignored)', () {
      expect(
        computeSubscriptionAccess('active', null, now),
        SubscriptionAccess.active,
      );
      expect(
        computeSubscriptionAccess('active', past, now),
        SubscriptionAccess.active,
      );
    });

    test('inactive → inactive', () {
      expect(
        computeSubscriptionAccess('inactive', future, now),
        SubscriptionAccess.inactive,
      );
    });

    test('trial before deadline → trialActive', () {
      expect(
        computeSubscriptionAccess('trial', future, now),
        SubscriptionAccess.trialActive,
      );
    });

    test('trial at/after deadline → trialExpired', () {
      expect(
        computeSubscriptionAccess('trial', past, now),
        SubscriptionAccess.trialExpired,
      );
      // Exactly at the deadline is expired (not before).
      expect(
        computeSubscriptionAccess('trial', now, now),
        SubscriptionAccess.trialExpired,
      );
    });

    test('trial with null deadline → grace (never lock without a date)', () {
      expect(
        computeSubscriptionAccess('trial', null, now),
        SubscriptionAccess.grace,
      );
    });

    test('null / unknown status → grace', () {
      expect(
        computeSubscriptionAccess(null, null, now),
        SubscriptionAccess.grace,
      );
      expect(
        computeSubscriptionAccess('something_else', past, now),
        SubscriptionAccess.grace,
      );
    });
  });

  group('isFreeTier', () {
    test('only trialExpired and inactive are on Free', () {
      expect(SubscriptionAccess.trialExpired.isFreeTier, isTrue);
      expect(SubscriptionAccess.inactive.isFreeTier, isTrue);
      expect(SubscriptionAccess.active.isFreeTier, isFalse);
      expect(SubscriptionAccess.trialActive.isFreeTier, isFalse);
      expect(SubscriptionAccess.grace.isFreeTier, isFalse);
    });
  });

  group('badgeLabel', () {
    test('PRO for paid, FREE TRIAL for trial, null otherwise', () {
      expect(SubscriptionAccess.active.badgeLabel, 'PRO');
      expect(SubscriptionAccess.trialActive.badgeLabel, 'FREE TRIAL');
      expect(SubscriptionAccess.trialExpired.badgeLabel, isNull);
      expect(SubscriptionAccess.inactive.badgeLabel, isNull);
      expect(SubscriptionAccess.grace.badgeLabel, isNull);
    });
  });
}
