// #380: the list a Request Stock screen builds before sending.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/features/stores/state/stock_request_list.dart';

ProductData _product(String id) => ProductData.fromJson({
  'id': id,
  'businessId': 'b',
  'name': 'Product $id',
  'retailerPriceKobo': 0,
  'wholesalerPriceKobo': 0,
  'buyingPriceKobo': 0,
  'isAvailable': true,
  'showOnline': true,
  'isDeleted': false,
  'lowStockThreshold': 5,
  'avgDailySales': 0.0,
  'leadTimeDays': 0,
  'safetyStockQty': 0,
  'monthlyTargetUnits': 0,
  'emptyCrateValueKobo': 0,
  'trackEmpties': false,
  'allowFractionalSales': false,
  'version': 1,
  'createdAt': DateTime(2026).millisecondsSinceEpoch,
  'lastUpdatedAt': DateTime(2026).millisecondsSinceEpoch,
});
void main() {
  late ProviderContainer container;
  late StockRequestListNotifier list;
  List<StockRequestItem> items() => container.read(stockRequestListProvider);
  Map<String, int> quantities() => {
    for (final i in items()) i.product.id: i.quantity,
  };

  setUp(() {
    container = ProviderContainer();
    // Keep the auto-dispose list alive for the test, as the open screen does.
    container.listen(stockRequestListProvider, (_, __) {});
    list = container.read(stockRequestListProvider.notifier);
  });
  tearDown(() => container.dispose());

  test('a tap adds one; another tap adds one more; order is kept', () {
    list.add(_product('a'));
    list.add(_product('b'));
    list.add(_product('a'));
    expect(quantities(), {'a': 2, 'b': 1});
    expect(items().map((i) => i.product.id), ['a', 'b']);
    expect(totalRequestedUnits(items()), 3);
    expect(quantityOnRequest(items(), 'a'), 2);
    expect(quantityOnRequest(items(), 'zzz'), 0);
  });

  test('hold sets a quantity, adding the product if needed', () {
    list.setQuantity(_product('a'), 7);
    expect(quantities(), {'a': 7});
    list.setQuantity(_product('a'), 3);
    expect(quantities(), {'a': 3});
    list.setQuantity(_product('a'), 0);
    expect(items(), isEmpty);
  });

  test('the stepper never goes below 1: at 1 the minus removes', () {
    list.setQuantity(_product('a'), 2);
    list.add(_product('b'));
    list.decrement('a');
    expect(quantities(), {'a': 1, 'b': 1});
    list.decrement('a');
    expect(quantities(), {'b': 1});
    list.increment('b');
    expect(quantities(), {'b': 2});
  });

  test('remove and clear', () {
    list.add(_product('a'));
    list.add(_product('b'));
    list.remove('a');
    expect(quantities(), {'b': 1});
    list.clear();
    expect(items(), isEmpty);
  });
}
