// receipt_builder_test.dart
//
// Covers #116 — manual 58/80mm receipt paper size. buildReceipt emits raw
// ESC/POS bytes, so the width contract is exercised through the two pure line
// formatters it delegates to (formatItemLine / formatTwoColumnLine) plus the
// ReceiptPaperSize enum that is their single source of truth.

import 'dart:io';

import 'package:esc_pos_utils_plus/esc_pos_utils_plus.dart';
import 'package:image/image.dart' as img;
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/features/pos/services/receipt_builder.dart';
import 'package:reebaplus_pos/features/pos/services/receipt_paper_size.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const mm58 = ReceiptPaperSize.mm58;
  const mm80 = ReceiptPaperSize.mm80;

  group('ReceiptPaperSize', () {
    test('58mm keeps the pre-#116 defaults (unchanged output)', () {
      expect(mm58.charsPerLine, 32);
      expect(mm58.escPos, PaperSize.mm58);
      expect(mm58.rasterWidthPx, 384);
    });

    test('80mm widens chars, paper size and logo', () {
      expect(mm80.charsPerLine, 48);
      expect(mm80.escPos, PaperSize.mm80);
      expect(mm80.rasterWidthPx, 576);
    });

    test('fromStorage defaults unknown/absent values to 58mm', () {
      expect(ReceiptPaperSize.fromStorage(null), mm58);
      expect(ReceiptPaperSize.fromStorage(''), mm58);
      expect(ReceiptPaperSize.fromStorage('garbage'), mm58);
      expect(ReceiptPaperSize.fromStorage('mm58'), mm58);
      expect(ReceiptPaperSize.fromStorage('mm80'), mm80);
    });

    test('round-trips through the persisted string (enum name)', () {
      expect(ReceiptPaperSize.fromStorage(mm58.name), mm58);
      expect(ReceiptPaperSize.fromStorage(mm80.name), mm80);
    });
  });

  group('formatItemLine — AC #4: exactly N chars from the same input', () {
    String itemLine(ReceiptPaperSize size) => ThermalReceiptService.formatItemLine(
          qtyLabel: '2.0x ',
          name: 'Star Lager',
          priceLabel: 'N2,000',
          charsPerLine: size.charsPerLine,
        );

    test('58mm renders a 32-char line', () {
      final line = itemLine(mm58);
      expect(line.length, 32);
      expect(line.startsWith('2.0x Star Lager'), isTrue);
      expect(line.endsWith('N2,000'), isTrue);
    });

    test('80mm renders a 48-char line from the identical input', () {
      final line = itemLine(mm80);
      expect(line.length, 48);
      expect(line.startsWith('2.0x Star Lager'), isTrue);
      expect(line.endsWith('N2,000'), isTrue);
    });
  });

  group('formatItemLine — truncation & padding edges', () {
    test('over-long name is truncated so the line still fits the width', () {
      const longName =
          'A Very Long Product Name That Overflows Any Receipt Line';
      for (final size in [mm58, mm80]) {
        final line = ThermalReceiptService.formatItemLine(
          qtyLabel: '1.0x ',
          name: longName,
          priceLabel: 'N10,000',
          charsPerLine: size.charsPerLine,
        );
        expect(line.length, size.charsPerLine,
            reason: 'truncated line must be exactly ${size.charsPerLine}');
        expect(line.startsWith('1.0x '), isTrue);
        expect(line.endsWith('N10,000'), isTrue);
        // A single space between the (truncated) name and the price.
        expect(line.contains('  '), isFalse);
      }
    });

    test('short name is padded out to the full width', () {
      for (final size in [mm58, mm80]) {
        final line = ThermalReceiptService.formatItemLine(
          qtyLabel: '2.0x ',
          name: 'Coke',
          priceLabel: 'N500',
          charsPerLine: size.charsPerLine,
        );
        expect(line.length, size.charsPerLine);
        expect(line.startsWith('2.0x Coke'), isTrue);
        expect(line.endsWith('N500'), isTrue);
      }
    });
  });

  group('formatTwoColumnLine — AC #4 for totals/payment rows', () {
    test('pads a label/value row to exactly the width', () {
      expect(
        ThermalReceiptService.formatTwoColumnLine(
          label: 'Subtotal',
          value: 'N2,000',
          charsPerLine: mm58.charsPerLine,
        ).length,
        32,
      );
      expect(
        ThermalReceiptService.formatTwoColumnLine(
          label: 'Subtotal',
          value: 'N2,000',
          charsPerLine: mm80.charsPerLine,
        ).length,
        48,
      );
    });

    test('keeps at least one space when label + value fill the line', () {
      final line = ThermalReceiptService.formatTwoColumnLine(
        label: 'A' * 20,
        value: 'B' * 20,
        charsPerLine: mm58.charsPerLine,
      );
      // Overflow can't be padded down; a single separating space is kept.
      expect(line, '${'A' * 20} ${'B' * 20}');
    });
  });

  group('buildReceipt bytes', () {
    Future<List<int>> build(
      ReceiptPaperSize size,
      WidgetTester tester, {
      ReceiptPrintStyle style = ReceiptPrintStyle.picture,
      String? logoPath,
    }) async {
      late List<int> bytes;
      await tester.runAsync(() async {
        bytes = await ThermalReceiptService.buildReceipt(
          orderId: 'ORD-000101-AAAAAA',
          cart: const [
            {'name': 'Spaghetti 500g', 'price': 1200.0, 'qty': 4.0},
          ],
          subtotal: 4800,
          crateDeposit: 0,
          total: 4800,
          paymentMethod: 'Cash',
          businessName: 'Test Shop',
          paperSize: size,
          printStyle: style,
          logoPath: logoPath,
          tracksCrates: false,
        );
      });
      return bytes;
    }

    bool hasSeq(List<int> b, List<int> seq) {
      for (var i = 0; i <= b.length - seq.length; i++) {
        var ok = true;
        for (var j = 0; j < seq.length; j++) {
          if (b[i + j] != seq[j]) {
            ok = false;
            break;
          }
        }
        if (ok) return true;
      }
      return false;
    }

    for (final size in [mm58, mm80]) {
      testWidgets('${size.name}: text style has no raster without a logo',
          (tester) async {
        final bytes = await build(size, tester, style: ReceiptPrintStyle.text);
        expect(bytes.sublist(0, 2), [0x1B, 0x40]);
        expect(hasSeq(bytes, [0x1D, 0x76, 0x30]), isFalse);
        expect(hasSeq(bytes, 'Spaghetti 500g'.codeUnits), isTrue);
        expect(hasSeq(bytes.sublist(bytes.length - 4), [0x1D, 0x56]), isTrue);
      });

      testWidgets('${size.name}: text style rasters only the logo',
          (tester) async {
        final dir = Directory.systemTemp.createTempSync('logo');
        addTearDown(() => dir.deleteSync(recursive: true));
        final png = img.Image(width: 20, height: 10);
        img.fill(png, color: img.ColorRgb8(0, 0, 0));
        final f = File('${dir.path}/logo.png')
          ..writeAsBytesSync(img.encodePng(png));
        final bytes = await build(size, tester,
            style: ReceiptPrintStyle.text, logoPath: f.path);
        expect(hasSeq(bytes, [0x1D, 0x76, 0x30]), isTrue);
        expect(hasSeq(bytes.sublist(bytes.length - 4), [0x1D, 0x56]), isTrue);
      });

      testWidgets('${size.name}: picture style: ESC @ first, GS v 0 raster, cut last',
          (tester) async {
        final bytes = await build(size, tester);
        expect(bytes.sublist(0, 2), [0x1B, 0x40]);
        // GS v 0 = raster bit image command.
        expect(hasSeq(bytes, [0x1D, 0x76, 0x30]), isTrue);
        // Cut = GS V ...
        expect(hasSeq(bytes.sublist(bytes.length - 4), [0x1D, 0x56]), isTrue);
      });
    }
  });
}
