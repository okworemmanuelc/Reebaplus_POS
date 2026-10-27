import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/storefront/store_share_link.dart';

void main() {
  test('storeShareLink appends the store id to the storefront base url', () {
    expect(kStorefrontBaseUrl, 'https://reebaplus.com/shop/s/');
    expect(storeShareLink('abc-123'), 'https://reebaplus.com/shop/s/abc-123');
  });
}
