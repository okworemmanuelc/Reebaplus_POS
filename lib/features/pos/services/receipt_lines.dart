import 'package:reebaplus_pos/core/settings/vat_settings.dart';
import 'package:reebaplus_pos/core/utils/name_case.dart';
import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/core/utils/product_name.dart';
import 'package:reebaplus_pos/features/pos/services/receipt_crates.dart';
import 'package:reebaplus_pos/features/pos/services/receipt_paper_size.dart';
import 'package:reebaplus_pos/shared/widgets/receipt_format.dart';

/// Pure layout of the text paper receipt (#605 follow-up). No printer, no I/O:
/// [buildReceiptLines] turns a sale into [ReceiptLine]s that are plain strings
/// plus style, so the layout is unit-testable. `ThermalReceiptService` maps
/// the lines to ESC/POS calls.

enum ReceiptTextSize { normal, tall, big }

enum ReceiptAlign { left, center, right }

enum ReceiptLineKind { text, logo, feed }

/// A run of text inside a line, with its own weight.
class ReceiptSegment {
  final String text;
  final bool bold;
  const ReceiptSegment(this.text, {this.bold = false});
}

class ReceiptLine {
  final ReceiptLineKind kind;
  final List<ReceiptSegment> segments;
  final ReceiptTextSize size;
  final ReceiptAlign align;

  /// Blank lines to feed (kind == feed).
  final int feedLines;

  const ReceiptLine._(
    this.kind,
    this.segments,
    this.size,
    this.align,
    this.feedLines,
  );

  const ReceiptLine.text(
    List<ReceiptSegment> segments, {
    ReceiptTextSize size = ReceiptTextSize.normal,
    ReceiptAlign align = ReceiptAlign.left,
  }) : this._(ReceiptLineKind.text, segments, size, align, 0);

  const ReceiptLine.logo()
      : this._(
          ReceiptLineKind.logo,
          const [],
          ReceiptTextSize.normal,
          ReceiptAlign.center,
          0,
        );

  const ReceiptLine.feed(int n)
      : this._(
          ReceiptLineKind.feed,
          const [],
          ReceiptTextSize.normal,
          ReceiptAlign.left,
          n,
        );

  /// The line as printed, without styling.
  String get plain => segments.map((s) => s.text).join();
}

/// Maps text to something every thermal printer can encode (Latin-1): the
/// currency sign becomes `N`, typographic marks become ASCII, anything else
/// outside Latin-1 becomes `?`, line breaks become spaces.
String receiptSafe(String s) {
  final b = StringBuffer();
  for (final r in s.runes) {
    switch (r) {
      case 0x20A6: // ₦
        b.write('N');
      case 0xB7: // ·
      case 0x2022: // •
        b.write('-');
      case 0x2018:
      case 0x2019:
        b.write("'");
      case 0x201C:
      case 0x201D:
        b.write('"');
      case 0x2013:
      case 0x2014:
        b.write('-');
      case 0x2026:
        b.write('...');
      case 0x0A:
      case 0x0D:
      case 0x09:
        b.write(' ');
      default:
        b.writeCharCode(r <= 0xFF && r >= 0x20 ? r : 0x3F);
    }
  }
  return b.toString();
}

/// `formatCurrency` with the printable currency sign: `N4,800`.
String receiptMoney(num n) => receiptSafe(formatCurrency(n));

/// Word-wraps [text] to [width]; a word longer than [width] is split, never
/// cut off.
List<String> wrapReceiptText(String text, int width) {
  final out = <String>[];
  var line = '';
  for (var word in text.trim().split(RegExp(r'\s+'))) {
    if (word.isEmpty) continue;
    while (word.length > width) {
      if (line.isNotEmpty) {
        out.add(line);
        line = '';
      }
      out.add(word.substring(0, width));
      word = word.substring(width);
    }
    if (line.isEmpty) {
      line = word;
    } else if (line.length + 1 + word.length <= width) {
      line = '$line $word';
    } else {
      out.add(line);
      line = word;
    }
  }
  if (line.isNotEmpty) out.add(line);
  return out;
}

class _Col {
  final String text;
  final int width;
  final bool right;
  final bool bold;

  /// Wrap width; defaults to [width]. Lets a column keep a one-char gap.
  final int? wrapAt;
  const _Col(
    this.text,
    this.width, {
    this.right = false,
    this.bold = false,
    this.wrapAt,
  });
}

/// The short type tag printed after an item name on a Compact receipt (#676),
/// so same-name products of different units never look alike. Null for units
/// without a tag.
String? receiptUnitTag(Object? unit) => switch (unit
    ?.toString()
    .trim()
    .toLowerCase()) {
  'bottle' => 'Btl',
  'pet' => 'Pet',
  'can' => 'Can',
  'carton' => 'Ctn',
  'pack' => 'Pck',
  _ => null,
};

const _unitTagLegend = {
  'Btl': 'Bottle',
  'Pet': 'PET',
  'Ctn': 'Carton',
  'Pck': 'Pack',
};

/// Everything a text receipt needs; mirrors `ThermalReceiptService.buildReceipt`
/// (the logo is reduced to [hasLogo]).
List<ReceiptLine> buildReceiptLines({
  required ReceiptPaperSize paperSize,
  required String orderId,
  required List<Map<String, dynamic>> cart,
  required double subtotal,
  double discount = 0,
  required double crateDeposit,
  required double total,
  required String paymentMethod,
  required bool tracksCrates,
  String? customerName,
  double? cashReceived,
  double? walletBalance,
  bool showWalletInfo = false,
  DateTime? reprintDate,
  DateTime? reshareDate,
  String? slipTitle,
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
  Map<String, double>? cratesReturnedByManufacturer,
  Set<String>? cratesSettledBrands,
  Map<String, double>? cratesTotalOwedByManufacturer,
  double? crateDepositFull,
  Map<String, String>? manufacturerNames,
  bool hasLogo = false,
  ReceiptSize receiptSize = ReceiptSize.full,
}) {
  final compact = receiptSize == ReceiptSize.compact;
  // Compact (#676) always uses the narrow single-column layout, at the
  // Font-B / Font-A column count.
  final wide = paperSize == ReceiptPaperSize.mm80 && !compact;
  final w = compact ? paperSize.compactCharsPerLine : paperSize.charsPerLine;
  final lines = <ReceiptLine>[];

  ReceiptSegment seg(String t, {bool bold = false}) =>
      ReceiptSegment(t, bold: bold);

  void centered(
    String text, {
    bool bold = false,
    ReceiptTextSize size = ReceiptTextSize.normal,
  }) {
    final cap = size == ReceiptTextSize.big ? w ~/ 2 : w;
    for (final l in wrapReceiptText(receiptSafe(text), cap)) {
      lines.add(ReceiptLine.text(
        [seg(l, bold: bold)],
        size: size,
        align: ReceiptAlign.center,
      ));
    }
  }

  void rule(String ch) =>
      lines.add(ReceiptLine.text([seg(List.filled(w, ch).join())]));
  void section() => rule('-');
  void total_() => rule('=');
  void dashed() => lines.add(ReceiptLine.text([
        seg(List.generate(w, (i) => i.isEven ? '-' : ' ').join()),
      ]));

  /// Fixed-width columns; text that is too long wraps inside its column.
  void columns(
    List<_Col> cols, {
    int indent = 0,
    ReceiptTextSize size = ReceiptTextSize.normal,
  }) {
    final wrapped = [
      for (final c in cols) wrapReceiptText(receiptSafe(c.text), c.wrapAt ?? c.width),
    ];
    final rows = wrapped.fold<int>(1, (a, l) => l.length > a ? l.length : a);
    for (var r = 0; r < rows; r++) {
      final segs = <ReceiptSegment>[if (indent > 0) seg(' ' * indent)];
      for (var i = 0; i < cols.length; i++) {
        final t = r < wrapped[i].length ? wrapped[i][r] : '';
        final c = cols[i];
        final padded =
            c.right ? t.padLeft(c.width) : t.padRight(c.width);
        segs.add(seg(padded, bold: c.bold && t.isNotEmpty));
      }
      lines.add(ReceiptLine.text(segs, size: size));
    }
  }

  /// Label left, value right, within [width] (default the paper width).
  void lr(
    String l,
    String r, {
    bool boldL = false,
    bool boldR = false,
    int indent = 0,
    ReceiptTextSize size = ReceiptTextSize.normal,
  }) {
    final width = w - indent;
    final ls = receiptSafe(l);
    final rs = receiptSafe(r);
    if (ls.length + 1 + rs.length <= width) {
      columns([
        _Col(ls, width - rs.length, bold: boldL),
        _Col(rs, rs.length, right: true, bold: boldR),
      ], indent: indent, size: size);
    } else {
      // Too long for one line: label on its own, value right-aligned below.
      columns([_Col(ls, width, bold: boldL)], indent: indent, size: size);
      columns([_Col(rs, width, right: true, bold: boldR)],
          indent: indent, size: size);
    }
  }

  // Stamps.
  void stamp(String s) =>
      centered(s, bold: true, size: ReceiptTextSize.big);
  // #713 — an Edit slip names itself and is never a reprint.
  if (slipTitle != null) stamp(receiptSafe(slipTitle.toUpperCase()));
  if (reprintDate != null && slipTitle == null) stamp('REPRINTED');
  if (reshareDate != null) stamp('RESHARED');
  if (orderStatus == 'Refunded') {
    stamp('REFUNDED ${receiptMoney(refundAmount ?? total)}');
  }

  if (hasLogo && !compact) lines.add(const ReceiptLine.logo());

  // Header.
  final name = (businessName ?? '').trim();
  if (name.isNotEmpty) {
    final upper = receiptSafe(name.toUpperCase());
    final big = wide && upper.length <= w ~/ 2;
    centered(
      upper,
      bold: true,
      size: big ? ReceiptTextSize.big : ReceiptTextSize.tall,
    );
  }
  final addr = (storeAddress ?? '').trim();
  if (addr.isNotEmpty && !compact) centered(addr);
  final phone = (businessPhone ?? '').trim();
  final email = compact ? '' : (businessEmail ?? '').trim();
  final phoneLine = phone.isEmpty ? '' : 'Tel: $phone';
  if (wide && phoneLine.isNotEmpty && email.isNotEmpty) {
    final one = receiptSafe('$phoneLine | $email');
    if (one.length <= w) {
      centered(one);
    } else {
      centered(phoneLine);
      centered(email);
    }
  } else {
    if (phoneLine.isNotEmpty) centered(phoneLine);
    if (email.isNotEmpty) centered(email);
  }
  section();

  // Details.
  final cashier = (cashierName ?? '').trim();
  lr('Receipt No.', orderId, boldR: true);
  lr('Date', ReceiptFormat.paperDate(saleDate ?? DateTime.now()));
  if (cashier.isNotEmpty) lr('Cashier', toNameCase(cashier));
  if (!ReceiptFormat.isWalkIn(customerName)) {
    lr('Customer', toNameCase(customerName!.trim()));
  }
  section();

  // Items.
  const itemW = 22;
  const qtyW = 5;
  const priceW = 10;
  const amtW = 11;
  const cQtyW = 5;
  const cAmtW = 11;
  if (wide) {
    columns([
      const _Col('ITEM', 22, bold: true),
      const _Col('QTY', 5, right: true, bold: true),
      const _Col('PRICE', 10, right: true, bold: true),
      const _Col('AMOUNT', 11, right: true, bold: true),
    ]);
  } else if (compact) {
    columns([
      _Col('ITEM', w - cQtyW - cAmtW, bold: true),
      const _Col('QTY', cQtyW, right: true, bold: true),
      const _Col('AMOUNT', cAmtW, right: true, bold: true),
    ]);
  } else {
    lr('ITEM', 'AMOUNT', boldL: true, boldR: true);
  }
  final usedTags = <String>{};
  for (final item in cart) {
    final qty = ReceiptFormat.num(item['qty']);
    final price = ReceiptFormat.num(item['price']);
    final amount = ReceiptFormat.lineAmount(price, qty);
    final label = productDisplayName(item['name'].toString());
    final q = ReceiptFormat.qty(qty);
    if (compact) {
      final tag = receiptUnitTag(item['unit']);
      if (tag != null && _unitTagLegend.containsKey(tag)) usedTags.add(tag);
      final nameW = w - cQtyW - cAmtW;
      // Wrap the name, then keep the type tag on the last name line.
      final nameLines = wrapReceiptText(receiptSafe(label), nameW - 1);
      if (nameLines.isEmpty) nameLines.add('');
      if (tag != null) {
        if (nameLines.last.length + 1 + tag.length <= nameW - 1) {
          nameLines.last = '${nameLines.last} $tag'.trim();
        } else {
          nameLines.add(tag);
        }
      }
      columns([
        _Col(nameLines.first, nameW, bold: true),
        _Col(q, cQtyW, right: true),
        _Col(receiptMoney(amount), cAmtW, right: true, bold: true),
      ]);
      for (final more in nameLines.skip(1)) {
        columns([_Col(more, nameW, bold: true)]);
      }
      continue;
    }
    dashed();
    if (wide) {
      columns([
        _Col(label, itemW, bold: true, wrapAt: itemW - 1),
        _Col(q, qtyW, right: true),
        _Col(receiptMoney(price), priceW, right: true),
        _Col(receiptMoney(amount), amtW, right: true, bold: true),
      ]);
    } else {
      columns([_Col(label, w, bold: true)]);
      lr('$q x ${receiptMoney(price)}', receiptMoney(amount), boldR: true);
    }
  }
  if (compact && usedTags.isNotEmpty) {
    columns([
      _Col(
        [
          for (final e in _unitTagLegend.entries)
            if (usedTags.contains(e.key)) '${e.key}=${e.value}',
        ].join(' '),
        w,
      ),
    ]);
  }
  section();

  // Totals.
  final units = cart.fold<double>(0, (a, i) => a + ReceiptFormat.num(i['qty']));
  final indent = wide ? 16 : 0;
  final vatLabel = vatRateBps != null
      ? 'VAT (${VatConfig(enabled: true, rateBps: vatRateBps).ratePercentLabel}%) included'
      : 'VAT included';
  lr(
    'Subtotal (${ReceiptFormat.qty(units)} ${units == 1 ? 'item' : 'items'})',
    receiptMoney(subtotal),
    indent: indent,
  );
  if (discount > 0) {
    lr('Discount', receiptMoney(-discount), indent: indent);
  }
  if (vatIncluded != null) {
    lr(vatLabel, receiptMoney(vatIncluded), indent: indent);
  }
  if (crateDeposit > 0) {
    lr('Crate deposit', receiptMoney(crateDeposit), indent: indent);
  }
  total_();
  lr(
    'TOTAL',
    receiptMoney(total),
    boldL: true,
    boldR: true,
    size: ReceiptTextSize.tall,
  );
  total_();

  // Payment.
  final totalKobo = (total * 100).round();
  final paidKobo = ((cashReceived ?? total) * 100).round();
  final diff = paidKobo - totalKobo;
  final pm = paymentMethod.toLowerCase();
  final method =
      (pm == 'wallet payment' || pm == 'wallet') ? 'Credit' : paymentMethod;
  final paid = receiptMoney(cashReceived ?? total);
  final lastLabel = diff < 0 ? 'Balance owed' : 'Change';
  final lastVal = receiptMoney(diff.abs() / 100.0);
  if (wide) {
    final cw = w ~/ 3;
    columns([
      _Col('Paid by', cw),
      _Col('Amount paid', cw),
      if (diff != 0) _Col(lastLabel, w - 2 * cw, right: true),
    ]);
    columns([
      _Col(method, cw, bold: true),
      _Col(paid, cw, bold: true),
      if (diff != 0) _Col(lastVal, w - 2 * cw, right: true, bold: true),
    ]);
  } else {
    lr('Paid by', method, boldR: true);
    lr('Amount paid', paid);
    if (diff != 0) lr(lastLabel, lastVal, boldR: true);
  }
  if (showWalletInfo && walletBalance != null) {
    lr('Credits balance', receiptMoney(walletBalance), boldR: true);
  }

  // Empty crates.
  final empties = tracksCrates
      ? ReceiptFormat.emptiesByManufacturer(cart)
      : const <String, double>{};
  if (empties.isNotEmpty) {
    final rows = buildReceiptCrateRows(
      taken: empties,
      returned: cratesReturnedByManufacturer,
      settledBrands: cratesSettledBrands,
      totalOwed: cratesTotalOwedByManufacturer,
    )..sort((a, b) => (manufacturerNames?[a.manufacturerId] ?? 'Unknown')
        .compareTo(manufacturerNames?[b.manufacturerId] ?? 'Unknown'));
    section();
    lines.add(ReceiptLine.text([seg('EMPTY CRATES', bold: true)]));
    if (compact) {
      // #656 figures for THIS sale; same rows and gate as the Full receipt.
      for (final r in rows) {
        final nm = manufacturerNames?[r.manufacturerId] ?? 'Unknown';
        columns([_Col(nm, w, bold: true)]);
        lr(
          'Took ${ReceiptFormat.qty(r.taken)}  Ret ${ReceiptFormat.qty(r.returned)}',
          'Owed ${ReceiptFormat.qty(r.owed)}',
          boldR: true,
        );
      }
    } else if (wide) {
      columns([
        const _Col('Product', 24),
        const _Col('Taken', 8, right: true),
        const _Col('Returned', 10, right: true),
        const _Col('Owed', 6, right: true),
      ]);
    }
    if (!compact) {
    for (final r in rows) {
      final nm = manufacturerNames?[r.manufacturerId] ?? 'Unknown';
      if (wide) {
        columns([
          _Col(nm, 24, bold: true),
          _Col(ReceiptFormat.qty(r.taken), 8, right: true),
          _Col(ReceiptFormat.qty(r.returned), 10, right: true),
          _Col(ReceiptFormat.qty(r.owed), 6, right: true, bold: true),
        ]);
      } else {
        columns([_Col(nm, w, bold: true)]);
        final a = 'Taken: ${ReceiptFormat.qty(r.taken)}';
        final b = 'Returned: ${ReceiptFormat.qty(r.returned)}';
        final c = 'Owed: ${ReceiptFormat.qty(r.owed)}';
        final gap = a.length + b.length + c.length + 6 <= w ? 3 : 1;
        if (a.length + b.length + c.length + 2 * gap <= w) {
          lines.add(ReceiptLine.text([
            seg('$a${' ' * gap}$b${' ' * gap}'),
            seg(c, bold: true),
          ]));
        } else {
          columns([_Col('$a $b', w)]);
          columns([_Col(c, w, bold: true)]);
        }
      }
    }
    }
    for (final r in rows) {
      if (r.totalOwed == null) continue;
      columns([
        _Col(
          receiptTotalOwedLine(
            manufacturerNames?[r.manufacturerId] ?? 'Unknown',
            ReceiptFormat.qty(r.totalOwed!),
          ),
          w,
          bold: true,
        ),
      ]);
    }
    if (crateDeposit > 0) {
      final note = (crateDepositFull != null && crateDepositFull > crateDeposit)
          ? 'Deposit paid ${receiptMoney(crateDeposit)} of ${receiptMoney(crateDepositFull)}.'
          : 'The ${receiptMoney(crateDeposit)} deposit is refunded when the crates are returned.';
      columns([_Col(note, w)]);
    }
  }

  // Footer.
  if (!compact) dashed();
  centered('Powered by Reebaplus');
  return lines;
}
