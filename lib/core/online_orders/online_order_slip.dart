import 'package:esc_pos_utils_plus/esc_pos_utils_plus.dart';
import 'package:intl/intl.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/features/pos/services/receipt_builder.dart';
import 'package:reebaplus_pos/features/pos/services/receipt_paper_size.dart';

/// What the order slip (#430) is built from, read from Drift in one go.
class OnlineOrderSlipLoad {
  const OnlineOrderSlipLoad({
    required this.order,
    required this.lines,
    required this.businessName,
    required this.businessPhone,
    required this.storeName,
    required this.storePhone,
    required this.trackEmptiesProductIds,
  });

  final OnlineOrderData order;
  final List<OnlineOrderLineData> lines;
  final String businessName;
  final String? businessPhone;
  final String? storeName;
  final String? storePhone;

  /// Products on the order that have `track_empties` set.
  final Set<String> trackEmptiesProductIds;
}

class OnlineOrderSlipLine {
  const OnlineOrderSlipLine({
    required this.name,
    required this.qty,
    required this.unitPriceKobo,
  });

  final String name;
  final int qty;
  final int unitPriceKobo;

  int get totalKobo => qty * unitPriceKobo;
}

/// The printable order slip of an accepted Online Order: who, where, and what
/// to take out, at the accepted quantities. A request document, not a receipt:
/// no payment, no change, no stock movement.
class OnlineOrderSlip {
  const OnlineOrderSlip({
    required this.businessName,
    required this.phone,
    required this.reference,
    required this.placedAt,
    required this.customerName,
    required this.customerPhone,
    required this.address,
    required this.note,
    required this.lines,
    required this.hasCrates,
  });

  /// Lines with accepted_qty 0 (removed) are skipped. [tracksCrates] is
  /// `businessTracksCrates(currentBusiness)`; a line is a crate product when its
  /// unit is 'bottle' AND its product tracks empties AND the business tracks
  /// empties (the same rule as the sale receipt).
  factory OnlineOrderSlip.from(
    OnlineOrderSlipLoad load, {
    required bool tracksCrates,
  }) {
    final o = load.order;
    final kept = load.lines
        .where((l) => (l.acceptedQty ?? l.requestedQty) > 0)
        .toList();
    final store = (load.storeName ?? '').trim();
    final storePhone = (load.storePhone ?? '').trim();
    final bizPhone = (load.businessPhone ?? '').trim();
    final noteText = (o.note ?? '').trim();
    return OnlineOrderSlip(
      businessName: store.isEmpty
          ? load.businessName
          : '${load.businessName} - $store',
      phone: storePhone.isNotEmpty ? storePhone : bizPhone,
      reference: o.reference,
      placedAt: o.placedAt,
      customerName: o.shopperName,
      customerPhone: o.deliveryPhone,
      address: [
        o.deliveryStreet,
        o.deliveryLga,
        o.deliveryState,
      ].where((p) => p.trim().isNotEmpty).join(', '),
      note: noteText.isEmpty ? null : noteText,
      lines: [
        for (final l in kept)
          OnlineOrderSlipLine(
            name: l.productName,
            qty: l.acceptedQty ?? l.requestedQty,
            unitPriceKobo: l.unitPriceKobo,
          ),
      ],
      hasCrates:
          tracksCrates &&
          kept.any(
            (l) =>
                (l.unit ?? '').toLowerCase() == 'bottle' &&
                load.trackEmptiesProductIds.contains(l.productId),
          ),
    );
  }

  final String businessName;
  final String phone;
  final String reference;
  final DateTime placedAt;
  final String customerName;
  final String customerPhone;
  final String address;
  final String? note;
  final List<OnlineOrderSlipLine> lines;
  final bool hasCrates;

  int get totalKobo => lines.fold(0, (s, l) => s + l.totalKobo);

  static const depositNote =
      'Crate deposit applies to the bottle crates on this order.';

  String get dateLabel => DateFormat('d MMM yyyy, h:mm a').format(placedAt);

  static String _money(int kobo) => formatCurrency(kobo / 100.0);

  /// Plain text of the slip: the Share fallback and the unit-test contract.
  String toText() {
    final b = StringBuffer()..writeln(businessName);
    if (phone.isNotEmpty) b.writeln('Tel: $phone');
    b
      ..writeln('ORDER SLIP')
      ..writeln('Order: $reference')
      ..writeln('Date: $dateLabel')
      ..writeln()
      ..writeln('Customer: $customerName')
      ..writeln('Phone: $customerPhone')
      ..writeln('Deliver to: $address');
    if (note != null) b.writeln('Note: $note');
    b.writeln();
    for (final l in lines) {
      b.writeln('${l.qty} x ${l.name}  ${_money(l.totalKobo)}');
    }
    b.writeln('Estimated total: ${_money(totalKobo)}');
    if (hasCrates) b..writeln()..writeln(depositNote);
    return b.toString().trimRight();
  }

  /// ESC/POS bytes for the thermal printer, laid out for [paperSize].
  Future<List<int>> toBytes(ReceiptPaperSize paperSize) async {
    final generator = Generator(paperSize.escPos, await CapabilityProfile.load());
    final width = paperSize.charsPerLine;
    // Thermal fonts have no currency glyphs beyond ASCII: same swap the sale
    // receipt makes.
    String money(int kobo) => _money(kobo).replaceAll('₦', 'N');
    const center = PosStyles(align: PosAlign.center);
    var bytes = <int>[...generator.reset()];
    bytes += generator.text(
      businessName,
      styles: const PosStyles(
        align: PosAlign.center,
        height: PosTextSize.size2,
        width: PosTextSize.size2,
        bold: true,
      ),
    );
    if (phone.isNotEmpty) bytes += generator.text('Tel: $phone', styles: center);
    bytes += generator.text(
      'ORDER SLIP',
      styles: const PosStyles(align: PosAlign.center, bold: true),
    );
    bytes += generator.hr();
    bytes += generator.text('Order: $reference', styles: const PosStyles(bold: true));
    bytes += generator.text('Date: $dateLabel');
    bytes += generator.hr();
    bytes += generator.text(customerName, styles: const PosStyles(bold: true));
    bytes += generator.text(customerPhone);
    bytes += generator.text(address);
    if (note != null) bytes += generator.text('Note: $note');
    bytes += generator.hr();
    for (final l in lines) {
      bytes += generator.text(
        ThermalReceiptService.formatItemLine(
          qtyLabel: '${l.qty}x ',
          name: l.name,
          priceLabel: money(l.totalKobo),
          charsPerLine: width,
        ),
      );
    }
    bytes += generator.hr();
    bytes += generator.text(
      ThermalReceiptService.formatTwoColumnLine(
        label: 'EST. TOTAL',
        value: money(totalKobo),
        charsPerLine: width,
      ),
      styles: const PosStyles(bold: true),
    );
    if (hasCrates) {
      bytes += generator.hr();
      bytes += generator.text(depositNote);
    }
    bytes += generator.feed(2);
    bytes += generator.cut();
    return bytes;
  }
}

enum OnlineOrderSlipOutcome { printed, shared }

/// Prints the slip; when [print] reports it did not print (no printer set,
/// could not connect) or throws, hands the slip text to [share] instead, the
/// way a receipt falls back to Share.
Future<OnlineOrderSlipOutcome> printOrShareOnlineOrderSlip({
  required OnlineOrderSlip slip,
  required Future<bool> Function() print,
  required Future<void> Function(String text) share,
}) async {
  var printed = false;
  try {
    printed = await print();
  } catch (_) {
    printed = false;
  }
  if (printed) return OnlineOrderSlipOutcome.printed;
  await share(slip.toText());
  return OnlineOrderSlipOutcome.shared;
}
