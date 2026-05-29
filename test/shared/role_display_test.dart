// role_display_test.dart
//
// Guards roleRank — the staff ordering in Staff Management (§9.2) sorts by it,
// so the hierarchy CEO → Manager → Cashier → Stock keeper (unknown last) must
// stay stable.

import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/shared/utils/role_display.dart';

void main() {
  test('roleRank orders CEO → Manager → Cashier → Stock keeper, unknown last',
      () {
    expect(roleRank('ceo'), lessThan(roleRank('manager')));
    expect(roleRank('manager'), lessThan(roleRank('cashier')));
    expect(roleRank('cashier'), lessThan(roleRank('stock_keeper')));
    expect(roleRank('stock_keeper'), lessThan(roleRank('unknown')));
    expect(roleRank(null), roleRank('anything-unknown'));
  });

  test('sorting a shuffled staff list by roleRank yields the hierarchy', () {
    final slugs = ['stock_keeper', 'ceo', 'cashier', 'manager', null]..sort(
        (a, b) => roleRank(a).compareTo(roleRank(b)));
    expect(slugs, ['ceo', 'manager', 'cashier', 'stock_keeper', null]);
  });
}
