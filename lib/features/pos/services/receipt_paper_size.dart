import 'package:esc_pos_utils_plus/esc_pos_utils_plus.dart';

/// Physical width of the thermal receipt paper, chosen once per device near the
/// printer picker (#116). This is the app's own source of truth — deliberately
/// decoupled from the print library's [PaperSize] enum and from the persisted
/// string so a library change or a stray stored value can't reshape a receipt.
///
/// 58mm is the default and MUST stay byte-identical to the pre-#116 output:
/// 32 chars/line, [PaperSize.mm58], a 200px logo raster.
enum ReceiptPaperSize {
  mm58,
  mm80;

  /// Monospace characters that fit on one Font-A line at this width
  /// (≈203 DPI thermal head): 58mm ≈ 32, 80mm ≈ 48.
  int get charsPerLine => switch (this) {
        ReceiptPaperSize.mm58 => 32,
        ReceiptPaperSize.mm80 => 48,
      };

  /// The print-library paper size this maps to.
  PaperSize get escPos => switch (this) {
        ReceiptPaperSize.mm58 => PaperSize.mm58,
        ReceiptPaperSize.mm80 => PaperSize.mm80,
      };

  /// Logo raster width in printer dots. The 58mm print area is ≈384 dots (keep
  /// the pre-#116 200px); the 80mm area is ≈576 dots, so 384px fills it with a
  /// small margin. A judgment call within the sensible ~380–512 range.
  int get logoWidthPx => switch (this) {
        ReceiptPaperSize.mm58 => 200,
        ReceiptPaperSize.mm80 => 384,
      };

  /// Rebuilds a value from the string persisted by `PrinterService`. Any
  /// unknown or absent value falls back to the 58mm default.
  static ReceiptPaperSize fromStorage(String? value) => switch (value) {
        'mm80' => ReceiptPaperSize.mm80,
        _ => ReceiptPaperSize.mm58,
      };
}
