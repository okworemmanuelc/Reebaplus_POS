import 'dart:io';

import 'package:esc_pos_utils_plus/esc_pos_utils_plus.dart';
import 'package:image/image.dart' as img;

import 'package:reebaplus_pos/core/utils/number_format.dart'; // assuming fmtNumber is exported here
import 'package:reebaplus_pos/core/utils/product_name.dart';
import 'package:reebaplus_pos/core/utils/stock_calculator.dart';

class ThermalReceiptService {
  /// Builds a byte array of ESC/POS commands formatted for 58mm (32 chars/line)
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
  }) async {
    // Generate profile for 58mm printer
    final profile = await CapabilityProfile.load();
    final generator = Generator(PaperSize.mm58, profile);
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
          // Resize to 58mm print width (≈200px at 203 DPI), convert to mono.
          final resized = img.copyResize(decoded, width: 200);
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

      // Calculate max length for product name to fit in 32 characters
      int maxNameLen =
          32 - qtyStr.length - priceStr.length - 1; // 1 space minimum
      String nameStr = name;
      if (nameStr.length > maxNameLen) {
        nameStr = nameStr.substring(0, maxNameLen);
      }

      final String leftPart = '$qtyStr$nameStr';
      int spaceCount = 32 - leftPart.length - priceStr.length;
      if (spaceCount < 1) spaceCount = 1;

      final String spacing = ' ' * spaceCount;
      bytes += generator.text(
        '$leftPart$spacing$priceStr',
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
    );

    if (crateDeposit > 0) {
      bytes += _buildTwoColumnRow(
        generator,
        'Crate Deposit',
        formatCurrency(crateDeposit).replaceAll('₦', 'N'),
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
      'Payment Method: $paymentMethod',
      styles: const PosStyles(bold: true),
    );

    bytes += _buildTwoColumnRow(
      generator,
      'Amount Paid:',
      formatCurrency(cashReceived ?? total).replaceAll('₦', 'N'),
    );

    // §15.1 — wallet info, only when ticked at checkout.
    if (showWalletInfo && walletBalance != null) {
      final tag = walletBalance < 0 ? '(debt)' : '(credit)';
      bytes += _buildTwoColumnRow(
        generator,
        'Wallet Balance:',
        '${formatCurrency(walletBalance).replaceAll('₦', 'N')} $tag',
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

  /// Helper to create exactly 32-character lines for 58mm
  static List<int> _buildTwoColumnRow(
    Generator generator,
    String label,
    String value,
  ) {
    int spaceCount = 32 - label.length - value.length;
    if (spaceCount < 1) spaceCount = 1;
    final spacing = ' ' * spaceCount;
    return generator.text('$label$spacing$value');
  }
}
