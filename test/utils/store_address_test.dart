import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/utils/store_address.dart';

void main() {
  group('receiptStoreAddress — drops the trailing country segment (§15.1)', () {
    test('full "street, city/state, country" → street + city/state', () {
      expect(
        receiptStoreAddress('14 Market Road, Lagos Island, Nigeria'),
        '14 Market Road, Lagos Island',
      );
    });

    test('two parts (street, country) → street only', () {
      expect(receiptStoreAddress('14 Market Road, Nigeria'), '14 Market Road');
    });

    test('single segment is returned unchanged (no country to drop)', () {
      expect(receiptStoreAddress('14 Market Road'), '14 Market Road');
    });

    test('tolerates missing/extra spaces around commas', () {
      expect(
        receiptStoreAddress('14 Market Road ,  Lagos Island ,Nigeria'),
        '14 Market Road, Lagos Island',
      );
    });

    test('null in → null out', () {
      expect(receiptStoreAddress(null), isNull);
    });

    test('empty / comma-only input → null', () {
      expect(receiptStoreAddress(''), isNull);
      expect(receiptStoreAddress('   '), isNull);
      expect(receiptStoreAddress(' , , '), isNull);
    });
  });
}
