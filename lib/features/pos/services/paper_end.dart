/// How a print job ends on paper (#717).
///
/// Receipt builders emit content only. `PrinterService` appends [paperEnd]
/// with the blank lines chosen for that printer, so every print path ends the
/// same way. `esc_pos_utils_plus`'s `Generator.cut()` is never used: it
/// silently feeds 5 blank lines before cutting, which tear-bar printers (no
/// cutter) turned into wasted paper at the bottom of this receipt and the top
/// of the next.
library;

/// Blank lines fed after a receipt when the printer has no saved choice.
/// Enough for the last line to clear a typical tear bar.
const int kDefaultPaperEndLines = 3;

/// The choices offered on the Receipt printer screen.
const List<int> kPaperEndLineChoices = [0, 1, 2, 3, 4, 5];

/// `ESC d n` (print and feed [lines] lines), then `GS V 65 0` (feed to the
/// cutter's own position and cut). A printer with a cutter moves exactly as
/// far as its blade needs; a tear-bar printer ignores the cut.
List<int> paperEnd(int lines) => [
  0x1B, 0x64, lines.clamp(0, 255), //
  0x1D, 0x56, 0x41, 0x00,
];
