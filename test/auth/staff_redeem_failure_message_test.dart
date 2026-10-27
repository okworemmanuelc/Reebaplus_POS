import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/features/auth/staff_redeem_failure_message.dart';

void main() {
  test('plan_limit_staff from the server becomes the upgrade message', () {
    final msg = staffRedeemPlanLimitMessage(
      Exception('PostgrestException(message: plan_limit_staff, code: P0001)'),
    );
    expect(msg, kStaffPlanLimitMessage);
    expect(msg, contains('upgrade to Premium'));
  });

  test('other failures are not claimed', () {
    expect(staffRedeemPlanLimitMessage(Exception('plan_limit_stores')), isNull);
    expect(staffRedeemPlanLimitMessage(Exception('boom')), isNull);
    expect(staffRedeemPlanLimitMessage(null), isNull);
  });
}
