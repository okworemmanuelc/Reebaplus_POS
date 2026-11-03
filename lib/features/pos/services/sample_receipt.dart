import 'package:reebaplus_pos/features/pos/services/receipt_lines.dart';
import 'package:reebaplus_pos/features/pos/services/receipt_paper_size.dart';
import 'package:reebaplus_pos/features/pos/widgets/paper_receipt.dart';

/// The made-up receipt behind Test print (#702). One set of sample data feeds
/// the printer bytes and the on-screen preview, so what the owner sees is what
/// the printer is sent: text and Compact go through [buildReceiptLines], the
/// picture style through [PaperReceipt].
class SampleReceipt {
  SampleReceipt._();

  static const orderId = 'TEST-0001';
  static const cart = <Map<String, dynamic>>[
    {'name': 'Spaghetti 500g', 'price': 1200.0, 'qty': 4.0},
    {'name': 'Vegetable Oil 1L', 'price': 3500.0, 'qty': 1.0},
    {'name': 'Malt Drink 33cl', 'price': 500.0, 'qty': 6.0},
  ];
  static const subtotal = 11300.0;
  static const total = 11300.0;
  static const cashReceived = 15000.0;
  static const paymentMethod = 'Cash';
  static const cashierName = 'Sample cashier';

  /// A Compact receipt is always text; Full follows the print style.
  static bool isText(ReceiptPrintStyle style, ReceiptSize size) =>
      style == ReceiptPrintStyle.text || size == ReceiptSize.compact;

  /// The receipt as lines. Compact ends with a column ruler as wide as the
  /// receipt: if it wraps, the font is wrong.
  static List<ReceiptLine> lines({
    required ReceiptPaperSize paperSize,
    required ReceiptSize receiptSize,
    required DateTime saleDate,
    String? businessName,
  }) {
    final out = buildReceiptLines(
      paperSize: paperSize,
      orderId: orderId,
      cart: cart,
      subtotal: subtotal,
      crateDeposit: 0,
      total: total,
      paymentMethod: paymentMethod,
      tracksCrates: false,
      cashReceived: cashReceived,
      businessName: businessName,
      cashierName: cashierName,
      saleDate: saleDate,
      receiptSize: receiptSize,
    );
    if (receiptSize != ReceiptSize.compact) return out;
    final cols = paperSize.compactCharsPerLine;
    return [
      ...out,
      ReceiptLine.text([
        ReceiptSegment(
          List.generate(
            cols,
            (i) => (i + 1) % 10 == 0 ? '0' : '${(i + 1) % 10}',
          ).join(),
        ),
      ]),
      const ReceiptLine.feed(2),
    ];
  }

  /// The picture-style receipt widget (Full only).
  static PaperReceipt paper({
    required ReceiptPaperSize paperSize,
    required DateTime saleDate,
    String? businessName,
  }) => PaperReceipt(
    paperSize: paperSize,
    orderId: orderId,
    cart: cart,
    subtotal: subtotal,
    crateDeposit: 0,
    total: total,
    paymentMethod: paymentMethod,
    cashReceived: cashReceived,
    businessName: businessName,
    cashierName: cashierName,
    saleDate: saleDate,
    tracksCrates: false,
  );
}
