// #656: the one place the receipt's crate maths lives.
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/features/pos/services/receipt_crates.dart';

ReceiptCrateRow _one({
  double taken = 5,
  Map<String, double>? returned,
  Set<String>? settled,
  Map<String, double>? total,
}) => buildReceiptCrateRows(
  taken: {'a': taken},
  returned: returned,
  settledBrands: settled,
  totalOwed: total,
).single;

void main() {
  test('full return -> owed 0', () {
    final r = _one(returned: {'a': 5});
    expect((r.taken, r.returned, r.owed), (5.0, 5.0, 0.0));
  });

  test('part return 3 of 5 -> owed 2', () {
    final r = _one(returned: {'a': 3});
    expect((r.taken, r.returned, r.owed), (5.0, 3.0, 2.0));
  });

  test('nothing returned -> owed = taken (walk-in or none entered)', () {
    expect(_one().owed, 5);
    expect(_one().returned, 0);
  });

  test('over-return never goes negative', () {
    expect(_one(returned: {'a': 6}).owed, 0);
  });

  test('a settled deposit brand owes nothing for this sale', () {
    final r = _one(returned: {'a': 3}, settled: {'a'});
    expect((r.returned, r.owed), (3.0, 0.0));
  });

  test('total line only when it differs from owed', () {
    expect(_one(returned: {'a': 3}, total: {'a': 6}).totalOwed, 6);
    expect(_one(returned: {'a': 3}, total: {'a': 2}).totalOwed, isNull);
    expect(_one(returned: {'a': 3}).totalOwed, isNull);
    expect(_one(returned: {'a': 3}, total: {'b': 6}).totalOwed, isNull);
    expect(_one(returned: {'a': 5}, total: {'a': 4}).totalOwed, 4);
  });

  test('quarter crates add up', () {
    final r = _one(taken: 2.5, returned: {'a': 1.25});
    expect(r.owed, 1.25);
  });

  test('the total line text', () {
    expect(receiptTotalOwedLine('Star', '6'), 'Total Star crates you owe: 6');
  });
}
