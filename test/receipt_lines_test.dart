// receipt_lines_test.dart — the pure text layout of the paper receipt.

import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/features/pos/services/receipt_lines.dart';
import 'package:reebaplus_pos/features/pos/services/receipt_paper_size.dart';

const _cart = <Map<String, dynamic>>[
  {'name': 'Spaghetti 500g', 'price': 1200.0, 'qty': 4.0},
  {'name': 'Vegetable Oil 1L', 'price': 3500.0, 'qty': 1.0},
  {
    'name': 'Lager Beer 60cl',
    'price': 9600.0,
    'qty': 1.0,
    'unit': 'bottle',
    'trackEmpties': true,
    'manufacturerId': 'm1',
  },
];

List<String> _lines(
  ReceiptPaperSize size, {
  List<Map<String, dynamic>> cart = _cart,
  double subtotal = 33000,
  double discount = 1000,
  double deposit = 2000,
  double total = 36400,
  double? paid = 40000,
  String method = 'Cash',
  String? customer = 'Chinedu Okafor',
  int? vatBps,
  double? vat,
  double? full,
  bool hasLogo = false,
  String name = 'Freshmart Supermarket',
  bool wallet = false,
}) => buildReceiptLines(
  paperSize: size,
  orderId: 'ORD-000482-AB12CD',
  cart: cart,
  subtotal: subtotal,
  discount: discount,
  crateDeposit: deposit,
  total: total,
  paymentMethod: method,
  customerName: customer,
  cashReceived: paid,
  tracksCrates: true,
  businessName: name,
  storeAddress: 'Plot 14, Market Road, Wuse II, Abuja',
  businessPhone: '0803 123 4567',
  businessEmail: 'hello@freshmart.ng',
  cashierName: 'amina bello',
  saleDate: DateTime(2026, 10, 31, 16, 52),
  vatRateBps: vatBps,
  vatIncluded: vat,
  crateDepositFull: full,
  manufacturerNames: const {'m1': 'Lager Beer 60cl'},
  hasLogo: hasLogo,
  walletBalance: 500,
  showWalletInfo: wallet,
).where((l) => l.kind == ReceiptLineKind.text).map((l) => l.plain).toList();

void main() {
  for (final size in ReceiptPaperSize.values) {
    final w = size.charsPerLine;

    group('text receipt ${size.name}', () {
      test('every line fits the paper (double-size lines count twice)', () {
        final all = buildReceiptLines(
          paperSize: size,
          orderId: 'ORD-000482-AB12CD',
          cart: _cart,
          subtotal: 33000,
          crateDeposit: 2000,
          total: 36400,
          paymentMethod: 'Cash',
          tracksCrates: true,
          businessName: 'A Very Long Business Name That Must Wrap Not Cut Ltd',
          orderStatus: 'Refunded',
          reprintDate: DateTime(2026, 10, 31),
          manufacturerNames: const {'m1': 'Lager'},
        ).where((l) => l.kind == ReceiptLineKind.text);
        for (final l in all) {
          final mult = l.size == ReceiptTextSize.big ? 2 : 1;
          expect(l.plain.length * mult, lessThanOrEqualTo(w), reason: l.plain);
        }
      });

      test('no naira sign or non-Latin-1 character anywhere', () {
        final out = _lines(
          size,
          name: 'Café “Ñoño” · Ltd ₦ 😀',
          cart: [
            {'name': 'Crème – brûlée ’s', 'price': 100.0, 'qty': 1.0},
          ],
          subtotal: 100,
          discount: 0,
          deposit: 0,
          total: 100,
          paid: 100,
        ).join('\n');
        expect(out.contains('₦'), isFalse);
        expect(out.runes.every((r) => r <= 0xFF), isTrue);
        expect(out, contains('N100'));
      });

      test('details: walk-in hides Customer, named customer shows', () {
        expect(_lines(size, customer: 'Walk-in Customer').join('\n'),
            isNot(contains('Customer')));
        expect(_lines(size).join('\n'), contains('Chinedu Okafor'));
        final date = _lines(size).firstWhere((l) => l.startsWith('Date'));
        expect(date, endsWith('31/10/2026 4:52 PM'));
      });

      test('Change when paid > total, Balance owed when less', () {
        final over = _lines(size).join('\n');
        expect(over, contains('Change'));
        expect(over, contains('N3,600'));
        final under = _lines(size, paid: 30000).join('\n');
        expect(under, contains('Balance owed'));
        expect(under, contains('N6,400'));
        expect(under, isNot(contains('Change')));
        final exact = _lines(size, paid: 36400).join('\n');
        expect(exact, isNot(contains('Change')));
        expect(exact, isNot(contains('Balance owed')));
      });

      test('wallet payment reads Credit; wallet balance only when asked', () {
        expect(_lines(size, method: 'Wallet').join('\n'), contains('Credit'));
        expect(_lines(size).join('\n'), isNot(contains('Credits balance')));
        expect(_lines(size, wallet: true).join('\n'),
            contains('Credits balance'));
      });

      test('VAT line only when given', () {
        expect(_lines(size).join('\n'), isNot(contains('VAT')));
        final v = _lines(size, vatBps: 750, vat: 2400).join('\n');
        expect(v, contains('VAT (7.5%) included'));
        expect(v, contains('N2,400'));
      });

      test('totals order and TOTAL between = rules', () {
        final l = _lines(size);
        int at(String p) => l.indexWhere((x) => x.contains(p));
        expect(at('Subtotal (6 items)'), isNonNegative);
        expect(at('Discount'), greaterThan(at('Subtotal')));
        expect(at('Crate deposit'), greaterThan(at('Discount')));
        final t = at('TOTAL');
        expect(t, greaterThan(at('Crate deposit')));
        expect(l[t - 1], '=' * w);
        expect(l[t + 1], '=' * w);
        expect(l[at('Discount')], contains('-N1,000'));
      });

      test('crate block with full vs part deposit note', () {
        final full = _lines(size).join('\n');
        expect(full, contains('EMPTY CRATES'));
        expect(full, contains('The N2,000 deposit is refunded'));
        final part = _lines(size, full: 3000).join('\n');
        expect(part, contains('Deposit paid N2,000 of N3,000.'));
        final none = _lines(size, deposit: 0).join('\n');
        expect(none, isNot(contains('deposit is refunded')));
        expect(none, isNot(contains('Deposit paid')));
        final plain = _lines(size, cart: [_cart.first]).join('\n');
        expect(plain, isNot(contains('EMPTY CRATES')));
      });

      test('logo line only with a logo', () {
        ReceiptLine? logo(bool has) => buildReceiptLines(
          paperSize: size,
          orderId: 'X',
          cart: const [],
          subtotal: 0,
          crateDeposit: 0,
          total: 0,
          paymentMethod: 'Cash',
          tracksCrates: false,
          hasLogo: has,
        ).where((l) => l.kind == ReceiptLineKind.logo).firstOrNull;
        expect(logo(false), isNull);
        expect(logo(true), isNotNull);
      });
    });
  }

  group('58mm specifics', () {
    final l = _lines(ReceiptPaperSize.mm58);
    test('item = bold name line, then "4 x N1,200 ... N4,800"', () {
      final i = l.indexWhere((x) => x.trim() == 'Spaghetti 500g');
      expect(i, isNonNegative);
      final row = l[i + 1];
      expect(row, startsWith('4 x N1,200'));
      expect(row, endsWith('N4,800'));
      expect(row.length, 32);
      expect(l.any((x) => x == 'ITEM${' ' * 22}AMOUNT'), isTrue);
    });

    test('crate row is one line', () {
      expect(l, contains('Taken: 1   Returned: 0   Owed: 1'));
    });

    test('phone and email on separate lines', () {
      expect(l, contains('Tel: 0803 123 4567'));
      expect(l, contains('hello@freshmart.ng'));
    });

    test('long business name wraps at 32 and is never cut', () {
      const long = 'Ogbonna & Sons Wholesale Distribution Company Limited';
      final out = _lines(ReceiptPaperSize.mm58, name: long);
      final joined = out.take(5).join(' ');
      for (final word in long.toUpperCase().split(' ')) {
        expect(joined, contains(word));
      }
    });
  });

  group('80mm specifics', () {
    final l = _lines(ReceiptPaperSize.mm80);
    test('column header and rows add up to 48', () {
      final h = l.firstWhere((x) => x.startsWith('ITEM'));
      expect(h.length, 48);
      expect(h.substring(0, 22).trim(), 'ITEM');
      expect(h.substring(22, 27).trim(), 'QTY');
      expect(h.substring(27, 37).trim(), 'PRICE');
      expect(h.substring(37).trim(), 'AMOUNT');
      final r = l.firstWhere((x) => x.startsWith('Spaghetti'));
      expect(r.substring(22, 27).trim(), '4');
      expect(r.substring(27, 37).trim(), 'N1,200');
      expect(r.substring(37).trim(), 'N4,800');
    });

    test('long item name wraps inside the ITEM column only', () {
      final out = _lines(
        ReceiptPaperSize.mm80,
        cart: [
          {
            'name': 'Extra Long Premium Basmati Rice Family Pack',
            'price': 9800.0,
            'qty': 1.0,
          },
        ],
      );
      final i = out.indexWhere((x) => x.startsWith('Extra Long'));
      final first = out[i];
      final second = out[i + 1];
      expect(first.substring(0, 22).trim().length, lessThanOrEqualTo(21));
      expect(first.substring(22).trim(), contains('N9,800'));
      expect(second.substring(22).trim(), isEmpty);
      expect(second.trim(), isNotEmpty);
    });

    test('phone and email share one line', () {
      expect(l, contains('Tel: 0803 123 4567 | hello@freshmart.ng'));
    });

    test('payment is a three-column header with values under it', () {
      final i = l.indexWhere((x) => x.startsWith('Paid by'));
      expect(l[i], contains('Amount paid'));
      expect(l[i], endsWith('Change'));
      expect(l[i + 1], startsWith('Cash'));
      expect(l[i + 1], endsWith('N3,600'));
    });

    test('crate table', () {
      final i = l.indexWhere((x) => x.startsWith('Product'));
      expect(l[i], contains('Taken'));
      expect(l[i], contains('Returned'));
      expect(l[i + 1], startsWith('Lager Beer 60cl'));
      expect(l[i + 1].trim(), endsWith('1'));
    });

    test('totals block sits in the right part of the line', () {
      final s = l.firstWhere((x) => x.contains('Subtotal'));
      expect(s.startsWith(' ' * 16), isTrue);
    });
  });
}
