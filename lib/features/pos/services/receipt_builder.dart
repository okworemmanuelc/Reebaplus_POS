import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:esc_pos_utils_plus/esc_pos_utils_plus.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:screenshot/screenshot.dart';

import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/features/pos/services/receipt_lines.dart';
import 'package:reebaplus_pos/features/pos/services/receipt_paper_size.dart';
import 'package:reebaplus_pos/features/pos/widgets/paper_receipt.dart';

/// Builds the ESC/POS bytes for a paper receipt (#605).
///
/// [ReceiptPrintStyle.text] (default): the printer's own font via
/// [buildReceiptLines]; only the logo is a small picture. Fast and sharp.
/// [ReceiptPrintStyle.picture]: the receipt is drawn as a [PaperReceipt]
/// widget off-screen, turned into a black-and-white picture and sent as raster
/// bands, so paper matches the mockups exactly.
class ThermalReceiptService {
  /// Tallest raster band sent in one command; cheap printers choke on one
  /// very tall image.
  static const int maxBandRows = 256;

  /// Luminance below this prints black.
  static const int _threshold = 160;

  /// Defaults to 58mm so existing callers are unchanged.
  static Future<List<int>> buildReceipt({
    required String orderId,
    required List<Map<String, dynamic>> cart,
    required double subtotal,
    double discount = 0,
    required double crateDeposit,
    required double total,
    required String paymentMethod,
    String? customerName,
    double? cashReceived,
    double? walletBalance,
    bool showWalletInfo = false,
    DateTime? reprintDate,
    DateTime? reshareDate,
    String? orderStatus,
    double? refundAmount,
    String? storeAddress,
    String? businessName,
    String? businessPhone,
    String? businessEmail,
    String? cashierName,
    DateTime? saleDate,
    int? vatRateBps,
    double? vatIncluded,
    Map<String, double>? cratesOwedByManufacturer,
    double? crateDepositFull,
    Map<String, String>? manufacturerNames,
    String? logoPath,
    ReceiptPaperSize paperSize = ReceiptPaperSize.mm58,
    ReceiptPrintStyle printStyle = ReceiptPrintStyle.text,
    required bool tracksCrates,
  }) async {
    if (printStyle == ReceiptPrintStyle.text) {
      final hasLogo = logoPath != null && File(logoPath).existsSync();
      final lines = buildReceiptLines(
        paperSize: paperSize,
        orderId: orderId,
        cart: cart,
        subtotal: subtotal,
        discount: discount,
        crateDeposit: crateDeposit,
        total: total,
        paymentMethod: paymentMethod,
        customerName: customerName,
        cashReceived: cashReceived,
        walletBalance: walletBalance,
        showWalletInfo: showWalletInfo,
        reprintDate: reprintDate,
        reshareDate: reshareDate,
        orderStatus: orderStatus,
        refundAmount: refundAmount,
        manufacturerNames: manufacturerNames,
        storeAddress: storeAddress,
        businessName: businessName,
        hasLogo: hasLogo,
        businessPhone: businessPhone,
        businessEmail: businessEmail,
        cashierName: cashierName,
        saleDate: saleDate,
        vatRateBps: vatRateBps,
        vatIncluded: vatIncluded,
        cratesOwedByManufacturer: cratesOwedByManufacturer,
        crateDepositFull: crateDepositFull,
        tracksCrates: tracksCrates,
      );
      final logo = hasLogo
          ? await _buildLogo(logoPath, paperSize.logoBoxPx)
          : null;
      return _emitText(lines, paperSize, logo);
    }

    final receipt = PaperReceipt(
      paperSize: paperSize,
      orderId: orderId,
      cart: cart,
      subtotal: subtotal,
      discount: discount,
      crateDeposit: crateDeposit,
      total: total,
      paymentMethod: paymentMethod,
      customerName: customerName,
      cashReceived: cashReceived,
      walletBalance: walletBalance,
      showWalletInfo: showWalletInfo,
      reprintDate: reprintDate,
      reshareDate: reshareDate,
      orderStatus: orderStatus,
      refundAmount: refundAmount,
      manufacturerNames: manufacturerNames,
      storeAddress: storeAddress,
      businessName: businessName,
      logoPath: logoPath,
      businessPhone: businessPhone,
      businessEmail: businessEmail,
      cashierName: cashierName,
      saleDate: saleDate,
      vatRateBps: vatRateBps,
      vatIncluded: vatIncluded,
      cratesOwedByManufacturer: cratesOwedByManufacturer,
      crateDepositFull: crateDepositFull,
      tracksCrates: tracksCrates,
    );

    final png = await ScreenshotController().captureFromWidget(
      MediaQuery(
        data: const MediaQueryData(textScaler: TextScaler.noScaling),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: Theme(
            data: ThemeData(fontFamily: appFontFamily),
            child: Material(
              color: Colors.white,
              child: Align(alignment: Alignment.topCenter, child: receipt),
            ),
          ),
        ),
      ),
      pixelRatio: 2,
      delay: const Duration(milliseconds: 50),
      targetSize: Size(paperSize.rasterWidthPx / 2, 3000),
    );

    final bw = _toBlackAndWhite(png, paperSize.rasterWidthPx);

    final profile = await CapabilityProfile.load();
    final generator = Generator(paperSize.escPos, profile);
    final bytes = <int>[...generator.reset()];
    for (var y = 0; y < bw.height; y += maxBandRows) {
      final h = (y + maxBandRows > bw.height) ? bw.height - y : maxBandRows;
      final band = img.copyCrop(bw, x: 0, y: y, width: bw.width, height: h);
      bytes.addAll(generator.imageRaster(band, align: PosAlign.center));
    }
    bytes.addAll(generator.feed(2));
    bytes.addAll(generator.cut());
    return bytes;
  }

  /// Maps [lines] to ESC/POS. Single-style lines go through `generator.text`;
  /// mixed bold lines set the style per segment and write the bytes raw.
  static Future<List<int>> _emitText(
    List<ReceiptLine> lines,
    ReceiptPaperSize paperSize,
    img.Image? logo,
  ) async {
    final profile = await CapabilityProfile.load();
    final generator = Generator(paperSize.escPos, profile);
    final bytes = <int>[...generator.reset()];
    for (final line in lines) {
      switch (line.kind) {
        case ReceiptLineKind.logo:
          if (logo != null) {
            bytes.addAll(generator.imageRaster(logo, align: PosAlign.center));
          }
        case ReceiptLineKind.feed:
          bytes.addAll(generator.feed(line.feedLines));
        case ReceiptLineKind.text:
          final size = switch (line.size) {
            ReceiptTextSize.normal => PosTextSize.size1,
            ReceiptTextSize.tall => PosTextSize.size1,
            ReceiptTextSize.big => PosTextSize.size2,
          };
          final height = line.size == ReceiptTextSize.normal
              ? PosTextSize.size1
              : PosTextSize.size2;
          final align = switch (line.align) {
            ReceiptAlign.left => PosAlign.left,
            ReceiptAlign.center => PosAlign.center,
            ReceiptAlign.right => PosAlign.right,
          };
          PosStyles style(bool bold) => PosStyles(
                bold: bold,
                align: align,
                width: size,
                height: height,
              );
          if (line.segments.length == 1) {
            final s = line.segments.first;
            bytes.addAll(generator.text(s.text, styles: style(s.bold)));
          } else {
            for (final s in line.segments) {
              bytes.addAll(generator.setStyles(style(s.bold)));
              bytes.addAll(generator.rawBytes(latin1.encode(s.text)));
            }
            bytes.addAll(generator.rawBytes([0x0A]));
          }
      }
    }
    bytes.addAll(generator.cut());
    return bytes;
  }

  /// A white square of [box] dots with a rounded black outline and the logo
  /// fitted inside (aspect kept), thresholded to pure black and white.
  /// Null when the file cannot be read as an image.
  static Future<img.Image?> _buildLogo(String path, int box) async {
    try {
      final src = img.decodeImage(await File(path).readAsBytes());
      if (src == null) return null;
      final out = img.Image(width: box, height: box);
      img.fill(out, color: img.ColorRgb8(255, 255, 255));
      img.drawRect(
        out,
        x1: 1,
        y1: 1,
        x2: box - 2,
        y2: box - 2,
        color: img.ColorRgb8(0, 0, 0),
        thickness: 3,
        radius: box * 0.12,
      );
      final inner = box - 2 * (box * 0.15).round();
      final fitted = src.width >= src.height
          ? img.copyResize(src, width: inner)
          : img.copyResize(src, height: inner);
      img.compositeImage(
        out,
        fitted,
        dstX: (box - fitted.width) ~/ 2,
        dstY: (box - fitted.height) ~/ 2,
      );
      for (var y = 0; y < box; y++) {
        for (var x = 0; x < box; x++) {
          final v = img.getLuminance(out.getPixel(x, y)) < _threshold ? 0 : 255;
          out.setPixelRgb(x, y, v, v, v);
        }
      }
      return out;
    } catch (_) {
      return null;
    }
  }

  /// Decodes [png], trims the empty white tail, forces [width] and applies a
  /// hard black/white threshold (printers dither badly on greys).
  static img.Image _toBlackAndWhite(Uint8List png, int width) {
    var src = img.decodeImage(png)!;
    if (src.width != width) src = img.copyResize(src, width: width);
    // Trim trailing blank rows (the capture is taller than the content).
    var last = src.height - 1;
    bool rowBlank(int y) {
      for (var x = 0; x < src.width; x++) {
        final p = src.getPixel(x, y);
        if (p.a > 0 && img.getLuminance(p) < 250) return false;
      }
      return true;
    }

    while (last > 0 && rowBlank(last)) {
      last--;
    }
    final h = (last + 1 + 8).clamp(1, src.height);
    final out = img.Image(width: width, height: h);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < width; x++) {
        final p = src.getPixel(x, y);
        final lum = p.a == 0 ? 255 : img.getLuminance(p);
        final v = lum < _threshold ? 0 : 255;
        out.setPixelRgb(x, y, v, v, v);
      }
    }
    return out;
  }

  /// Formats one item line — `"[qty]x [name]      [price]"` — to fit exactly
  /// [charsPerLine] characters. Still used by the text-only online-order slip.
  static String formatItemLine({
    required String qtyLabel,
    required String name,
    required String priceLabel,
    required int charsPerLine,
  }) {
    final int maxNameLen = charsPerLine - qtyLabel.length - priceLabel.length - 1;
    String nameStr = name;
    if (maxNameLen <= 0) {
      nameStr = '';
    } else if (nameStr.length > maxNameLen) {
      nameStr = nameStr.substring(0, maxNameLen);
    }
    final String leftPart = '$qtyLabel$nameStr';
    int spaceCount = charsPerLine - leftPart.length - priceLabel.length;
    if (spaceCount < 1) spaceCount = 1;
    return '$leftPart${' ' * spaceCount}$priceLabel';
  }

  /// A `"label        value"` row padded to [charsPerLine] characters.
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
