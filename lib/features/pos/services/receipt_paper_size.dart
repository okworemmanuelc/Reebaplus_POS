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

  /// Characters per line on a Compact receipt (#676): 58mm prints in Font B
  /// (42 columns, the owner's sample), 80mm in Font A (48 columns).
  int get compactCharsPerLine => switch (this) {
    ReceiptPaperSize.mm58 => 42,
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

  /// Side in dots of the outlined logo box on a text receipt (the only
  /// picture on it).
  int get logoBoxPx => switch (this) {
    ReceiptPaperSize.mm58 => 120,
    ReceiptPaperSize.mm80 => 144,
  };

  /// Rebuilds a value from the string persisted by `PrinterService`. Any
  /// unknown or absent value falls back to the 58mm default.
  static ReceiptPaperSize fromStorage(String? value) => switch (value) {
    'mm80' => ReceiptPaperSize.mm80,
    _ => ReceiptPaperSize.mm58,
  };
}

/// How a paper receipt is sent to the printer. [text] uses the printer's own
/// font (fast, sharp; only the logo is a picture). [picture] renders the whole
/// receipt as a raster so it matches the design exactly. Remembered per
/// printer next to the paper size; unknown or absent means [text].
enum ReceiptPrintStyle {
  text,
  picture;

  static ReceiptPrintStyle fromStorage(String? value) => switch (value) {
    'picture' => ReceiptPrintStyle.picture,
    _ => ReceiptPrintStyle.text,
  };
}

/// How much a text receipt prints (#676). [full] is the normal receipt;
/// [compact] drops logo, address, email, unit price and item rules to save
/// paper, and always prints as text (58mm in Font B, 42 columns). Remembered
/// per printer; unknown or absent means [full].
enum ReceiptSize {
  full,
  compact;

  static ReceiptSize fromStorage(String? value) => switch (value) {
    'compact' => ReceiptSize.compact,
    _ => ReceiptSize.full,
  };
}
