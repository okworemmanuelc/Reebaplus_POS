import 'dart:io';

import 'package:esc_pos_utils_plus/esc_pos_utils_plus.dart';
import 'package:image/image.dart' as img;

import 'package:reebaplus_pos/core/utils/number_format.dart'; // assuming fmtNumber is exported here
import 'package:reebaplus_pos/core/utils/product_name.dart';
import 'package:reebaplus_pos/core/utils/stock_calculator.dart';
import 'package:reebaplus_pos/features/pos/services/receipt_paper_size.dart';

class ThermalReceiptService {
  /// Builds a byte array of ESC/POS commands for the given [paperSize].
  /// Defaults to 58mm (32 chars/line) so existing callers are unchanged.
  static Future<List<int>> buildReceipt({
    required String orderId,
    required List<Map<String, dynamic>> cart,
    required double subtotal,
    required double crateDeposit,
    required double total,
    required String paymentMethod,
    String? customerName,
    String? customerAddress,
    String? customerPhone,
    double? cashReceived,
    double? walletBalance,
    bool showWalletInfo = false,
    DateTime? reprintDate,
    DateTime? reshareDate,
    String? riderName,
    String? deliveryRef,
    String? orderStatus,
    double? refundAmount,
    String? storeAddress,
    String? businessName,
    Map<String, String>? manufacturerNames,
    /// Local file path of the cached business logo. When present the image is
    /// converted to a monochrome raster and emitted before the business name.
    /// Falls back to name-only when null or the file is missing.
    String? logoPath,
    /// Physical paper width. Defaults to 58mm so existing callers and the
    /// existing 58mm output are unchanged.
    ReceiptPaperSize paperSize = ReceiptPaperSize.mm58,
  }) async {
    final profile = await CapabilityProfile.load();
    final generator = Generator(paperSize.escPos, profile);
    final int charsPerLine = paperSize.charsPerLine;
    List<int> bytes = [];

    // --- 0. REFUND STAMP ---
    if (orderStatus == 'Refunded') {
      bytes += generator.text(
        'REFUNDED',
        styles: const PosStyles(
          align: PosAlign.center,
          height: PosTextSize.size2,
          width: PosTextSize.size2,
          bold: true,
        ),
      );
      bytes += generator.text(
        'Amount: ${formatCurrency(refundAmount ?? total).replaceAll('₦', 'N')}',
        styles: const PosStyles(align: PosAlign.center, bold: true),
      );
      bytes += generator.hr();
    }

    // --- 1. HEADER ---
    if (reprintDate != null) {
      bytes += generator.text(
        'REPRINTED',
        styles: const PosStyles(
          align: PosAlign.center,
          height: PosTextSize.size2,
          width: PosTextSize.size2,
          bold: true,
        ),
      );
      bytes += generator.hr();
    }
    if (reshareDate != null) {
      bytes += generator.text(
        'RESHARED',
        styles: const PosStyles(
          align: PosAlign.center,
          height: PosTextSize.size2,
          width: PosTextSize.size2,
          bold: true,
        ),
      );
      bytes += generator.hr();
    }
    // --- Logo (before business name) ---
    if (logoPath != null) {
      final logoFile = File(logoPath);
      if (logoFile.existsSync()) {
        final rawBytes = await logoFile.readAsBytes();
        final decoded = img.decodeImage(rawBytes);
        if (decoded != null) {
          // Resize to the paper's print width in dots, convert to mono.
          final resized = img.copyResize(decoded, width: paperSize.logoWidthPx);
          img.grayscale(resized);
          bytes += generator.image(resized, align: PosAlign.center);
        }
      }
    }
    if (businessName != null && businessName.trim().isNotEmpty) {
      bytes += generator.text(
        businessName.trim(),
        styles: const PosStyles(
          align: PosAlign.center,
          height: PosTextSize.size2,
          width: PosTextSize.size2,
          bold: true,
        ),
      );
    }
    if (storeAddress != null && storeAddress.isNotEmpty) {
      bytes += generator.text(
        storeAddress,
        styles: const PosStyles(align: PosAlign.center),
      );
    }
    bytes += generator.text(
      deliveryRef != null ? 'DELIVERY RECEIPT' : 'SALES RECEIPT',
      styles: const PosStyles(align: PosAlign.center, bold: true),
    );
    bytes += generator.hr(); // "--------------------------------"

    // --- 2. CUSTOMER & TRANSACTION DETAILS ---
    if (customerName != null &&
        customerName.isNotEmpty &&
        customerName.toLowerCase() != 'walk-in customer') {
      bytes += generator.text(
        customerName,
        styles: const PosStyles(bold: true),
      );
      if (customerAddress != null &&
          customerAddress.isNotEmpty &&
          customerAddress != 'N/A') {
        bytes += generator.text(customerAddress);
      }
      if (customerPhone != null && customerPhone.isNotEmpty) {
        bytes += generator.text(customerPhone);
      }
      bytes += generator.text('');
    }

    final now = DateTime.now();
    final dateStr =
        '${now.day.toString().padLeft(2, '0')}/${now.month.toString().padLeft(2, '0')}/${now.year} ${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';

    bytes += generator.text('Order #$orderId');
    if (deliveryRef != null) {
      bytes += generator.text(
        'Delivery Ref: $deliveryRef',
        styles: const PosStyles(bold: true),
      );
    }
    bytes += generator.text('Date: $dateStr');
    if (reprintDate != null) {
      final rDateStr =
          '${reprintDate.day.toString().padLeft(2, '0')}/${reprintDate.month.toString().padLeft(2, '0')}/${reprintDate.year} ${reprintDate.hour.toString().padLeft(2, '0')}:${reprintDate.minute.toString().padLeft(2, '0')}';
      bytes += generator.text('Reprinted: $rDateStr');
    }
    bytes += generator.hr();

    // --- 3. ITEMS LIST ---
    // Single line per item: [qty]x [product name]         [price]
    for (var item in cart) {
      final String name = productDisplayName(
        item['name'].toString(),
        item['size'] as String?,
        unit: item['unit'] as String?,
      );
      final double qty = (item['qty'] as num).toDouble();
      final double price = (item['price'] as num).toDouble();
      final double lineTotal = stockValue(price, qty);

      final String qtyStr = '${qty.toStringAsFixed(1)}x ';
      final String priceStr = formatCurrency(lineTotal).replaceAll('₦', 'N');

      bytes += generator.text(
        formatItemLine(
          qtyLabel: qtyStr,
          name: name,
          priceLabel: priceStr,
          charsPerLine: charsPerLine,
        ),
        styles: const PosStyles(bold: false, fontType: PosFontType.fontA),
      );
    }
    bytes += generator.hr();

    // --- 4. EMPTY CRATES SECTION ---
    final Map<String, double> empties = {};
    for (final item in cart) {
      final unit = (item['unit'] as String?)?.toLowerCase();
      final trackEmpties = (item['trackEmpties'] as bool?) ?? false;

      if (unit == 'bottle' && trackEmpties) {
        final mid = item['manufacturerId'];
        if (mid is String) {
          empties[mid] = (empties[mid] ?? 0) + (item['qty'] as num).toDouble();
        }
      }
    }

    if (empties.isNotEmpty) {
      bytes += generator.text('Empty Crates', styles: const PosStyles(bold: true));
      final sortedEntries = empties.entries.toList()
        ..sort((a, b) {
          final nameA = manufacturerNames?[a.key] ?? 'Unknown';
          final nameB = manufacturerNames?[b.key] ?? 'Unknown';
          return nameA.compareTo(nameB);
        });

      for (final e in sortedEntries) {
        final mfrName = manufacturerNames?[e.key] ?? 'Unknown';
        bytes += generator.text('$mfrName (${e.value.toStringAsFixed(0)} crates)');
      }
      bytes += generator.hr();
    }

    // --- 5. TOTALS SECTION ---
    bytes += _buildTwoColumnRow(
      generator,
      'Subtotal',
      formatCurrency(subtotal).replaceAll('₦', 'N'),
      charsPerLine,
    );

    if (crateDeposit > 0) {
      bytes += _buildTwoColumnRow(
        generator,
        'Crate Deposit',
        formatCurrency(crateDeposit).replaceAll('₦', 'N'),
        charsPerLine,
      );
    }
    bytes += generator.hr();

    // BIG TOTAL
    bytes += generator.row([
      PosColumn(
        text: 'TOTAL',
        width: 6,
        styles: const PosStyles(bold: true, align: PosAlign.left),
      ),
      PosColumn(
        text: formatCurrency(total).replaceAll('₦', 'N'),
        width: 6,
        styles: const PosStyles(bold: true, align: PosAlign.right),
      ),
    ]);
    bytes += generator.hr();

    // --- 5. PAYMENT SECTION ---
    bytes += generator.text(
      'Payment Method: ${paymentMethod.toLowerCase() == 'wallet payment' || paymentMethod.toLowerCase() == 'wallet' ? 'Credit Payment' : paymentMethod}',
      styles: const PosStyles(bold: true),
    );

    bytes += _buildTwoColumnRow(
      generator,
      'Amount Paid:',
      formatCurrency(cashReceived ?? total).replaceAll('₦', 'N'),
      charsPerLine,
    );

    // §15.1 — wallet info, only when ticked at checkout. Sign conveys credit
    // vs debt — no "(credit)/(debt)" suffix.
    if (showWalletInfo && walletBalance != null) {
      bytes += _buildTwoColumnRow(
        generator,
        'Credits Balance:',
        formatCurrency(walletBalance).replaceAll('₦', 'N'),
        charsPerLine,
      );
    }

    bytes += generator.text('');

    // --- 6. FOOTER ---
    bytes += generator.text(
      'Rider: ${riderName ?? 'Pick-up'}',
      styles: const PosStyles(align: PosAlign.center, bold: true),
    );
    bytes += generator.text('');
    bytes += generator.text(
      'Goods received in good condition',
      styles: const PosStyles(align: PosAlign.center),
    );
    bytes += generator.text(
      'Powered by Reebaplus+',
      styles: const PosStyles(
        align: PosAlign.center,
        fontType: PosFontType.fontB,
      ),
    );

    // Minimal feed + cut to reduce paper waste
    bytes += generator.feed(2);
    bytes += generator.cut();

    return bytes;
  }

  /// Emits a label/value row padded to [charsPerLine] characters.
  static List<int> _buildTwoColumnRow(
    Generator generator,
    String label,
    String value,
    int charsPerLine,
  ) {
    return generator.text(
      formatTwoColumnLine(
        label: label,
        value: value,
        charsPerLine: charsPerLine,
      ),
    );
  }

  /// Formats one item line — `"[qty]x [name]      [price]"` — to fit exactly
  /// [charsPerLine] characters: the name is truncated when too long, and the
  /// gap between name and price is padded (at least one space). Pure so the
  /// 32-char (58mm) / 48-char (80mm) contract is unit-testable directly.
  static String formatItemLine({
    required String qtyLabel,
    required String name,
    required String priceLabel,
    required int charsPerLine,
  }) {
    // Leave room for the qty label, the price, and at least one space.
    final int maxNameLen = charsPerLine - qtyLabel.length - priceLabel.length - 1;
    String nameStr = name;
    if (maxNameLen <= 0) {
      // Qty + price already consume the whole line; drop the name.
      nameStr = '';
    } else if (nameStr.length > maxNameLen) {
      nameStr = nameStr.substring(0, maxNameLen);
    }

    final String leftPart = '$qtyLabel$nameStr';
    int spaceCount = charsPerLine - leftPart.length - priceLabel.length;
    if (spaceCount < 1) spaceCount = 1;
    return '$leftPart${' ' * spaceCount}$priceLabel';
  }

  /// Formats a `"label        value"` row padded to [charsPerLine] characters
  /// (at least one space between the two). Pure; shared by the totals and
  /// payment rows via [_buildTwoColumnRow].
  static String formatTwoColumnLine({
    required String label,
    required String value,
    required int charsPerLine,
  }) {
    int spaceCount = charsPerLine - label.length - value.length;
    if (spaceCount < 1) spaceCount = 1;
    return '$label${' ' * spaceCount}$value';
  }
}
