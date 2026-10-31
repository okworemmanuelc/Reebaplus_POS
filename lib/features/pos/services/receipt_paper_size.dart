import 'package:esc_pos_utils_plus/esc_pos_utils_plus.dart';

/// Physical width of the thermal receipt paper, remembered per printer (asked
/// once the first time the app prints to it; editable in Settings > Receipt
/// printer). This is the app's own source of truth — deliberately
/// decoupled from the print library's [PaperSize] enum and from the persisted
/// string so a library change or a stray stored value can't reshape a receipt.
///
/// 58mm is the default: maps to [PaperSize.mm58] and a 384-dot picture.
enum ReceiptPaperSize {
  mm58,
  mm80;

  /// Monospace characters that fit on one Font-A line (text-only slips such
  /// as the online-order slip): 58mm ≈ 32, 80mm ≈ 48.
  int get charsPerLine => switch (this) {
        ReceiptPaperSize.mm58 => 32,
        ReceiptPaperSize.mm80 => 48,
      };

  /// The print-library paper size this maps to.
  PaperSize get escPos => switch (this) {
        ReceiptPaperSize.mm58 => PaperSize.mm58,
        ReceiptPaperSize.mm80 => PaperSize.mm80,
      };

  /// Width in dots of the printed picture (≈203 DPI head): 58mm = 384,
  /// 80mm = 576. The paper receipt is laid out at half this in logical pixels
  /// and rendered at pixelRatio 2.
  int get rasterWidthPx => switch (this) {
        ReceiptPaperSize.mm58 => 384,
        ReceiptPaperSize.mm80 => 576,
      };

  /// Rebuilds a value from the string persisted by `PrinterService`. Any
  /// unknown or absent value falls back to the 58mm default.
  static ReceiptPaperSize fromStorage(String? value) => switch (value) {
        'mm80' => ReceiptPaperSize.mm80,
        _ => ReceiptPaperSize.mm58,
      };
}
