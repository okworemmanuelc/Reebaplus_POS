// receipt_compact_test.dart — the Compact text receipt (#676).

import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/features/pos/services/receipt_builder.dart';
import 'package:reebaplus_pos/features/pos/services/receipt_lines.dart';
import 'package:reebaplus_pos/features/pos/services/receipt_paper_size.dart';

const _cart = <Map<String, dynamic>>[
  {
    'name': 'Coca-Cola 50cl',
    'price': 4800.0,
    'qty': 2.0,
    'unit': 'Bottle',
    'trackEmpties': true,
    'manufacturerId': 'm1',
  },
  {'name': 'Coca-Cola 50cl', 'price': 3000.0, 'qty': 1.0, 'unit': 'PET'},
  {
    'name': 'Eva Table Water Premium Natural Spring 75cl Big Size',
    'price': 1500.0,
    'qty': 3.0,
    'unit': 'Pack',
  },
  {'name': 'Vegetable Oil 1L', 'price': 3500.0, 'qty': 1.0},
];

List<ReceiptLine> _build(
  ReceiptPaperSize size, {
  ReceiptSize receiptSize = ReceiptSize.compact,
  List<Map<String, dynamic>> cart = _cart,
}) => buildReceiptLines(
  paperSize: size,
  orderId: 'ORD-001803',
  cart: cart,
  subtotal: 22600,
  discount: 600,
  crateDeposit: 2000,
  total: 24000,
  paymentMethod: 'Cash',
  customerName: 'Chinedu Okafor',
  cashReceived: 25000,
  tracksCrates: true,
  businessName: 'Freshmart Supermarket',
  storeAddress: 'Plot 14, Market Road, Wuse II, Abuja',
  businessPhone: '0803 123 4567',
  businessEmail: 'hello@freshmart.ng',
  cashierName: 'amina bello',
  saleDate: DateTime(2026, 10, 31, 16, 52),
  manufacturerNames: const {'m1': 'Coca-Cola'},
  cratesReturnedByManufacturer: const {'m1': 1},
  cratesTotalOwedByManufacturer: const {'m1': 6},
  hasLogo: true,
  receiptSize: receiptSize,
);

List<String> _plain(
  ReceiptPaperSize size, {
  List<Map<String, dynamic>>? cart,
}) => _build(
  size,
  cart: cart ?? _cart,
).where((l) => l.kind == ReceiptLineKind.text).map((l) => l.plain).toList();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('compact print sample (42 columns)', () {
    // ignore: avoid_print
    print(_plain(ReceiptPaperSize.mm58).join('\n'));
  });

  for (final size in ReceiptPaperSize.values) {
    final cols = size.compactCharsPerLine;
    group('compact ${size.name} ($cols columns)', () {
      test('column counts: 58mm = 42 (Font B), 80mm = 48', () {
        expect(cols, size == ReceiptPaperSize.mm58 ? 42 : 48);
      });

      test('every line fits (double-width lines count twice)', () {
        for (final l in _build(
          size,
        ).where((l) => l.kind == ReceiptLineKind.text)) {
          final mult = l.size == ReceiptTextSize.big ? 2 : 1;
          expect(
            l.plain.length * mult,
            lessThanOrEqualTo(cols),
            reason: l.plain,
          );
        }
      });

      test('drops logo, address, email, unit-price column and item rules', () {
        final all = _build(size);
        expect(all.any((l) => l.kind == ReceiptLineKind.logo), isFalse);
        final out = _plain(size).join('\n');
        expect(out, isNot(contains('Plot 14')));
        expect(out, isNot(contains('freshmart.ng')));
        expect(out, isNot(contains('PRICE')));
        expect(out, isNot(contains('N4,800 ')));
        // No dash rule between items: item rows are consecutive.
        final lines = _plain(size);
        final first = lines.indexWhere((l) => l.startsWith('Coca-Cola'));
        expect(lines[first + 1], isNot(matches(RegExp(r'^[- ]{10,}$'))));
        expect(lines[first + 1], contains('Coca-Cola'));
      });

      test('keeps order no, date, cashier, customer and every money line', () {
        final out = _plain(size).join('\n');
        for (final s in [
          'ORD-001803',
          '31/10/2026 4:52 PM',
          'Amina Bello',
          'Chinedu Okafor',
          'Subtotal',
          'Discount',
          'Crate deposit',
          'TOTAL',
          'N24,000',
          'Paid by',
          'Amount paid',
          'Change',
          'N1,000',
        ]) {
          expect(out, contains(s));
        }
      });

      test('item line: name + type tag, qty and total right-aligned', () {
        final lines = _plain(size);
        final btl = lines.firstWhere((l) => l.startsWith('Coca-Cola 50cl Btl'));
        final pet = lines.firstWhere((l) => l.startsWith('Coca-Cola 50cl Pet'));
        expect(btl, endsWith('2     N9,600'));
        expect(btl.length, cols);
        expect(pet, endsWith('1     N3,000'));
      });

      test('long names wrap and stay inside the name column', () {
        final lines = _plain(size);
        final i = lines.indexWhere((l) => l.startsWith('Eva Table Water'));
        expect(lines[i], endsWith('N4,500'));
        expect(lines[i + 1].trim(), isNotEmpty);
        expect(lines[i + 1].trim().length, lessThan(cols - 15));
      });

      test('legend lists only the short words that appear', () {
        final out = _plain(size).join('\n');
        expect(out, contains('Btl=Bottle Pet=PET Pck=Pack'));
        final none = _plain(
          size,
          cart: const [
            {'name': 'Vegetable Oil 1L', 'price': 3500.0, 'qty': 1.0},
          ],
        ).join('\n');
        expect(none, isNot(matches(RegExp(r'[A-Za-z]{3}=[A-Za-z]'))));
      });

      test('crate lines follow #656: Took/Ret/Owed this sale + total owed', () {
        final out = _plain(size).join('\n');
        expect(out, contains('EMPTY CRATES'));
        expect(out, contains('Took 2 Ret 1'));
        expect(out, contains('Owed 1'));
        expect(out, contains('Total Coca-Cola crates you owe: 6'));
      });

      test('crate section uses the same gate as Full', () {
        const noCrates = [
          {'name': 'Vegetable Oil 1L', 'price': 3500.0, 'qty': 1.0},
        ];
        for (final rs in ReceiptSize.values) {
          final out = _build(
            size,
            receiptSize: rs,
            cart: noCrates,
          ).map((l) => l.plain).join('\n');
          expect(out, isNot(contains('EMPTY CRATES')));
        }
        for (final rs in ReceiptSize.values) {
          final out = _build(
            size,
            receiptSize: rs,
          ).map((l) => l.plain).join('\n');
          expect(out, contains('EMPTY CRATES'));
        }
      });

      test('tracksCrates false hides the crate section, like Full', () {
        for (final rs in ReceiptSize.values) {
          final out = buildReceiptLines(
            paperSize: size,
            orderId: 'ORD-1',
            cart: _cart,
            subtotal: 1,
            crateDeposit: 0,
            total: 1,
            paymentMethod: 'Cash',
            tracksCrates: false,
            receiptSize: rs,
          ).map((l) => l.plain).join('\n');
          expect(out, isNot(contains('EMPTY CRATES')));
        }
      });

      test('prints no more lines than Full', () {
        expect(
          _build(size).length,
          lessThan(_build(size, receiptSize: ReceiptSize.full).length),
        );
      });
    });
  }

  group('ESC/POS', () {
    test(
      '58mm compact selects Font B (ESC M 1); full and 80mm do not',
      () async {
        final lines = _build(ReceiptPaperSize.mm58);
        final compact = await ThermalReceiptService.emitTextForTest(
          lines,
          ReceiptPaperSize.mm58,
          compact: true,
        );
        bool hasFontB(List<int> b) {
          for (var i = 0; i + 2 < b.length; i++) {
            if (b[i] == 0x1B && b[i + 1] == 0x4D && b[i + 2] == 0x01) {
              return true;
            }
          }
          return false;
        }

        expect(hasFontB(compact), isTrue);
        final full = await ThermalReceiptService.emitTextForTest(
          _build(ReceiptPaperSize.mm58, receiptSize: ReceiptSize.full),
          ReceiptPaperSize.mm58,
        );
        expect(hasFontB(full), isFalse);
        final wide = await ThermalReceiptService.emitTextForTest(
          _build(ReceiptPaperSize.mm80),
          ReceiptPaperSize.mm80,
          compact: true,
        );
        expect(hasFontB(wide), isFalse);
      },
    );

    test('ReceiptSize storage round-trip, default full', () {
      expect(ReceiptSize.fromStorage(null), ReceiptSize.full);
      expect(ReceiptSize.fromStorage('junk'), ReceiptSize.full);
      expect(ReceiptSize.fromStorage('compact'), ReceiptSize.compact);
    });
  });
}
