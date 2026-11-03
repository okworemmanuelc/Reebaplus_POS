// receipt_full_identity_test.dart — the Full receipt must stay byte-identical
// (#676). The fixture was generated from the layout before Compact existed;
// regenerate only on purpose with UPDATE_RECEIPT_SNAPSHOT=1.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/features/pos/services/receipt_lines.dart';
import 'package:reebaplus_pos/features/pos/services/receipt_paper_size.dart';

const _cart = <Map<String, dynamic>>[
  {'name': 'Spaghetti 500g', 'price': 1200.0, 'qty': 4.0, 'unit': 'Pack'},
  {'name': 'Vegetable Oil 1L', 'price': 3500.0, 'qty': 1.0},
  {
    'name': 'Lager Beer 60cl Extra Long Name For Wrapping',
    'price': 9600.0,
    'qty': 2.0,
    'unit': 'Bottle',
    'trackEmpties': true,
    'manufacturerId': 'm1',
  },
];

String _render(ReceiptPaperSize size, {bool refunded = false}) {
  final lines = buildReceiptLines(
    paperSize: size,
    orderId: 'ORD-000482-AB12CD',
    cart: _cart,
    subtotal: 33000,
    discount: 1000,
    crateDeposit: 2000,
    total: 36400,
    paymentMethod: 'Cash',
    customerName: 'Chinedu Okafor',
    cashReceived: 40000,
    tracksCrates: true,
    businessName: 'Freshmart Supermarket',
    storeAddress: 'Plot 14, Market Road, Wuse II, Abuja',
    businessPhone: '0803 123 4567',
    businessEmail: 'hello@freshmart.ng',
    cashierName: 'amina bello',
    saleDate: DateTime(2026, 10, 31, 16, 52),
    vatRateBps: 750,
    vatIncluded: 2000,
    manufacturerNames: const {'m1': 'Lager'},
    cratesReturnedByManufacturer: const {'m1': 1},
    cratesTotalOwedByManufacturer: const {'m1': 6},
    orderStatus: refunded ? 'Refunded' : null,
    hasLogo: true,
  );
  return lines
      .map((l) {
        final tag = switch (l.kind) {
          ReceiptLineKind.logo => 'LOGO',
          ReceiptLineKind.feed => 'FEED${l.feedLines}',
          ReceiptLineKind.text =>
            '${l.size.name}/${l.align.name}/${l.segments.map((s) => s.bold ? 'B' : '-').join()}',
        };
        return '$tag|${l.plain}|';
      })
      .join('\n');
}

void main() {
  final file = File('test/fixtures/receipt_full_snapshot.txt');
  final actual = [
    for (final s in ReceiptPaperSize.values) ...[
      '== ${s.name}',
      _render(s),
      '== ${s.name} refunded',
      _render(s, refunded: true),
    ],
  ].join('\n');

  test('Full receipt layout is byte-identical to the pre-Compact snapshot', () {
    if (Platform.environment['UPDATE_RECEIPT_SNAPSHOT'] == '1') {
      file.writeAsStringSync(actual);
    }
    expect(actual, file.readAsStringSync());
  });
}
