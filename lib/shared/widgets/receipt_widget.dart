import 'dart:io';

import 'package:flutter/material.dart';
import 'package:reebaplus_pos/core/settings/vat_settings.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/core/utils/name_case.dart';
import 'package:reebaplus_pos/core/utils/product_name.dart';
import 'package:reebaplus_pos/core/utils/stock_calculator.dart';
import 'package:reebaplus_pos/shared/widgets/receipt_format.dart';

class ReceiptWidget extends StatelessWidget {
  final String orderId;
  final List<Map<String, dynamic>> cart;
  final double subtotal;

  /// Discount given on this sale (#200 / US 33). [subtotal] is always the goods
  /// at their FULL price, so the discount prints on its own line between the
  /// subtotal and the total — otherwise a discounted receipt shows a total that
  /// is lower than its subtotal with nothing on paper explaining why. 0 (the
  /// default) prints no line. See [ReceiptTotals].
  final double discount;

  final double crateDeposit;
  final double total;
  final String paymentMethod;
  final String? customerName;
  final double? cashReceived;
  final double? walletBalance;

  /// §15.1 — wallet info is printed only when the cashier ticked the
  /// "Add wallet info to receipt" checkbox at checkout. Off by default.
  final bool showWalletInfo;

  final DateTime? reprintDate;
  final DateTime? reshareDate;
  final String? orderStatus;
  final double? refundAmount;

  /// manufacturerId → name — used to label crate rows by manufacturer.
  final Map<String, String>? manufacturerNames;

  /// Address of the store that processed this sale, country excluded (§15.1).
  final String? storeAddress;

  /// The business name (§15.1) — shown as the receipt header.
  final String? businessName;

  /// Local file path of the business logo. Shown only when set AND the file
  /// exists; otherwise nothing renders (no box, no placeholder).
  final String? logoPath;

  /// Business contact line ("phone · email"); each part shows only when set.
  final String? businessPhone;
  final String? businessEmail;

  /// The staff member who made the sale.
  final String? cashierName;

  /// When the sale happened. Null falls back to now (fresh checkout).
  final DateTime? saleDate;

  /// VAT included in the price (display only — never changes [total]). The row
  /// shows only when [vatIncluded] is non-null.
  final int? vatRateBps;
  final double? vatIncluded;

  /// manufacturerId → the customer's total crates owed. Falls back to this
  /// sale's crates when a manufacturer is missing (walk-ins).
  final Map<String, double>? cratesOwedByManufacturer;

  /// The full deposit when only part was paid. Non-null AND above
  /// [crateDeposit] switches the crates note to "Deposit paid ₦X of ₦Y."
  final double? crateDepositFull;

  /// Whether the business counts empty crates —
  /// `businessTracksCrates(currentBusiness)`. Only then does a `Bottle` line
  /// read "Bottle Crate <name>" (#487); every other shop prints "Bottle".
  final bool tracksCrates;

  const ReceiptWidget({
    super.key,
    required this.orderId,
    required this.cart,
    required this.subtotal,
    this.discount = 0,
    required this.crateDeposit,
    required this.total,
    required this.paymentMethod,
    this.customerName,
    this.cashReceived,
    this.walletBalance,
    this.showWalletInfo = false,
    this.reprintDate,
    this.reshareDate,
    this.orderStatus,
    this.refundAmount,
    this.manufacturerNames,
    this.storeAddress,
    this.businessName,
    this.logoPath,
    this.businessPhone,
    this.businessEmail,
    this.cashierName,
    this.saleDate,
    this.vatRateBps,
    this.vatIncluded,
    this.cratesOwedByManufacturer,
    this.crateDepositFull,
    required this.tracksCrates,
  });

  static const _textCol = Color(0xFF111111);
  static const _sub = Color(0xFF555555);
  static const _divCol = Color(0xFFDDDDDD);

  static int _kobo(double v) => (v * 100).round();

  static String _qty(double q) => ReceiptFormat.qty(q);

  static double _num(dynamic v) => ReceiptFormat.num(v);

  @override
  Widget build(BuildContext context) {
    // Receipts always use black-on-white regardless of app theme.
    final primary = Theme.of(context).colorScheme.primary;
    final hasLogo = logoPath != null && File(logoPath!).existsSync();
    final name = businessName?.trim() ?? '';
    final contact = [
      if (businessPhone != null && businessPhone!.trim().isNotEmpty)
        businessPhone!.trim(),
      if (businessEmail != null && businessEmail!.trim().isNotEmpty)
        businessEmail!.trim(),
    ].join(' · ');
    final cust = customerName?.trim() ?? '';
    final showCustomer = cust.isNotEmpty && cust.toLowerCase() != 'walk-in customer';
    final cashier = cashierName?.trim() ?? '';

    final totalKobo = _kobo(total);
    final paidKobo = _kobo(cashReceived ?? total);
    final changeKobo = paidKobo - totalKobo;
    final pm = paymentMethod.toLowerCase();
    final methodLabel = (pm == 'wallet payment' || pm == 'wallet')
        ? 'Credit'
        : paymentMethod;

    final unitsTotal = cart.fold<double>(0, (a, i) => a + _num(i['qty']));

    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(context.getRSize(20)),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _divCol),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (reprintDate != null) _stamp(context, 'REPRINTED', Colors.red, 16, 2),
          if (reshareDate != null) _stamp(context, 'RESHARED', Colors.red, 16, 2),
          if (orderStatus == 'Refunded')
            _stamp(
              context,
              'REFUNDED ${formatCurrency(refundAmount ?? total)}',
              primary,
              14,
              1,
            ),
          if (hasLogo) ...[
            Center(
              child: Container(
                width: context.getRSize(72),
                height: context.getRSize(72),
                padding: EdgeInsets.all(context.getRSize(6)),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: _textCol),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Image.file(File(logoPath!), fit: BoxFit.contain),
                ),
              ),
            ),
            SizedBox(height: context.getRSize(10)),
          ],
          if (name.isNotEmpty)
            Text(
              toNameCase(name),
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: context.getRFontSize(22),
                fontWeight: FontWeight.w800,
                color: _textCol,
              ),
            ),
          if (storeAddress != null && storeAddress!.trim().isNotEmpty)
            Padding(
              padding: EdgeInsets.only(top: context.getRSize(4)),
              child: Text(
                storeAddress!,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: context.getRFontSize(12), color: _sub),
              ),
            ),
          if (contact.isNotEmpty)
            Padding(
              padding: EdgeInsets.only(top: context.getRSize(2)),
              child: Text(
                contact,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: context.getRFontSize(12), color: _sub),
              ),
            ),
          _rule(context, 14),

          // Details grid (2 x 2).
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: _detail(context, 'Receipt No.', orderId)),
              SizedBox(width: context.getRSize(12)),
              Expanded(
                child: _detail(
                  context,
                  'Date and time',
                  _formatDate(saleDate ?? DateTime.now()),
                ),
              ),
            ],
          ),
          if (cashier.isNotEmpty || showCustomer) ...[
            SizedBox(height: context.getRSize(10)),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: cashier.isNotEmpty
                      ? _detail(context, 'Cashier', toNameCase(cashier))
                      : const SizedBox.shrink(),
                ),
                SizedBox(width: context.getRSize(12)),
                Expanded(
                  child: showCustomer
                      ? _detail(context, 'Customer', toNameCase(cust))
                      : const SizedBox.shrink(),
                ),
              ],
            ),
          ],
          _rule(context, 14),

          // Items.
          Row(
            children: [
              Text('ITEM', style: _caps(context)),
              const Spacer(),
              Text('AMOUNT', style: _caps(context)),
            ],
          ),
          SizedBox(height: context.getRSize(6)),
          ...cart.map((item) {
            final qty = _num(item['qty']);
            final price = _num(item['price']);
            final lineTotal = stockValue(price, qty).round();
            final label = productDisplayName(
              item['name'] as String,
              item['size'] as String?,
              unit: item['unit'] as String?,
              crates: tracksCrates,
            );
            return Container(
              padding: EdgeInsets.symmetric(vertical: context.getRSize(8)),
              decoration: const BoxDecoration(
                border: Border(top: BorderSide(color: _divCol)),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          label,
                          style: TextStyle(
                            fontSize: context.getRFontSize(14),
                            fontWeight: FontWeight.w700,
                            color: _textCol,
                          ),
                        ),
                        Text(
                          '${_qty(qty)} × ${formatCurrency(price)}',
                          style: TextStyle(
                            fontSize: context.getRFontSize(12),
                            color: _sub,
                          ),
                        ),
                      ],
                    ),
                  ),
                  SizedBox(width: context.getRSize(8)),
                  Text(
                    formatCurrency(lineTotal),
                    style: TextStyle(
                      fontSize: context.getRFontSize(14),
                      fontWeight: FontWeight.w700,
                      color: _textCol,
                    ),
                  ),
                ],
              ),
            );
          }),
          Container(height: 1, color: _divCol),
          SizedBox(height: context.getRSize(10)),

          _row(
            context,
            'Subtotal (${_qty(unitsTotal)} ${unitsTotal == 1 ? 'item' : 'items'})',
            formatCurrency(subtotal),
          ),
          // #200 / US 33 — the discount that explains Total < Subtotal.
          if (discount > 0) _row(context, 'Discount', formatCurrency(-discount)),
          if (vatIncluded != null)
            _row(
              context,
              vatRateBps != null
                  ? 'VAT (${VatConfig(enabled: true, rateBps: vatRateBps!).ratePercentLabel}%) included'
                  : 'VAT included',
              formatCurrency(vatIncluded!),
            ),
          if (crateDeposit > 0)
            _row(context, 'Crate deposit', formatCurrency(crateDeposit)),

          SizedBox(height: context.getRSize(8)),
          Container(height: 1, color: _divCol),
          Padding(
            padding: EdgeInsets.symmetric(vertical: context.getRSize(10)),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Text(
                  'TOTAL',
                  style: TextStyle(
                    fontSize: context.getRFontSize(16),
                    fontWeight: FontWeight.w800,
                    color: _textCol,
                  ),
                ),
                SizedBox(width: context.getRSize(8)),
                Expanded(
                  child: Text(
                    formatCurrency(total),
                    textAlign: TextAlign.right,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: context.getRFontSize(24),
                      fontWeight: FontWeight.w800,
                      color: primary,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Container(height: 1, color: _divCol),
          SizedBox(height: context.getRSize(10)),

          _row(context, 'Payment method', methodLabel, boldValue: true),
          _row(context, 'Amount paid', formatCurrency(cashReceived ?? total),
              boldValue: true),
          if (changeKobo > 0)
            _row(context, 'Change', formatCurrency(changeKobo / 100.0),
                boldValue: true)
          else if (changeKobo < 0)
            _row(context, 'Balance owed', formatCurrency(-changeKobo / 100.0),
                boldValue: true),
          // §15.1 — wallet info, only when ticked at checkout.
          if (showWalletInfo && walletBalance != null)
            // Sign conveys credit vs debt — no "(credit)/(debt)" suffix.
            _row(context, 'Credits balance', formatCurrency(walletBalance!),
                boldValue: true),

          _cratesPanel(context),

          _rule(context, 14),
          Center(
            child: Text(
              'Powered by Reebaplus',
              style: TextStyle(fontSize: context.getRFontSize(11), color: _sub),
            ),
          ),
        ],
      ),
    );
  }

  Widget _stamp(BuildContext context, String text, Color color, double size,
      double spacing) {
    return Padding(
      padding: EdgeInsets.only(bottom: context.getRSize(12)),
      child: Center(
        child: Container(
          padding: EdgeInsets.symmetric(
            horizontal: context.getRSize(12),
            vertical: context.getRSize(4),
          ),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.1),
            border: Border.all(color: color.withValues(alpha: 0.5)),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(
            text,
            style: TextStyle(
              fontSize: context.getRFontSize(size),
              fontWeight: FontWeight.w900,
              color: color,
              letterSpacing: spacing,
            ),
          ),
        ),
      ),
    );
  }

  Widget _rule(BuildContext context, double gap) => Padding(
    padding: EdgeInsets.symmetric(vertical: context.getRSize(gap)),
    child: Container(height: 1, color: _divCol),
  );

  TextStyle _caps(BuildContext context) => TextStyle(
    fontSize: context.getRFontSize(11),
    fontWeight: FontWeight.w700,
    color: _sub,
    letterSpacing: 0.5,
  );

  Widget _detail(BuildContext context, String label, String value) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label,
          style: TextStyle(fontSize: context.getRFontSize(12), color: _sub)),
      Text(
        value,
        style: TextStyle(
          fontSize: context.getRFontSize(14),
          fontWeight: FontWeight.w700,
          color: _textCol,
        ),
      ),
    ],
  );

  Widget _row(BuildContext context, String label, String value,
      {bool boldValue = false}) {
    return Padding(
      padding: EdgeInsets.symmetric(vertical: context.getRSize(3)),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Text(
              label,
              style: TextStyle(fontSize: context.getRFontSize(14), color: _sub),
            ),
          ),
          SizedBox(width: context.getRSize(8)),
          Text(
            value,
            textAlign: TextAlign.right,
            style: TextStyle(
              fontSize: context.getRFontSize(14),
              fontWeight: boldValue ? FontWeight.w700 : FontWeight.w400,
              color: boldValue ? _textCol : _sub,
            ),
          ),
        ],
      ),
    );
  }

  Widget _cratesPanel(BuildContext context) {
    final empties = _computeEmpties();
    if (empties.isEmpty) return const SizedBox.shrink();
    final entries = empties.entries.toList()
      ..sort((a, b) => (manufacturerNames?[a.key] ?? 'Unknown')
          .compareTo(manufacturerNames?[b.key] ?? 'Unknown'));

    TextStyle head() =>
        TextStyle(fontSize: context.getRFontSize(12), color: _sub);
    final numW = context.getRSize(56);
    final retW = context.getRSize(64);

    Widget numCell(String t, double w, {bool bold = false, bool header = false}) =>
        SizedBox(
          width: w,
          child: Text(
            t,
            textAlign: TextAlign.right,
            style: header
                ? head()
                : TextStyle(
                    fontSize: context.getRFontSize(14),
                    fontWeight: FontWeight.w700,
                    color: _textCol,
                  ),
          ),
        );

    return Container(
      margin: EdgeInsets.only(top: context.getRSize(12)),
      padding: EdgeInsets.all(context.getRSize(14)),
      decoration: BoxDecoration(
        color: const Color(0xFFF0F2F6),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Empty Crates',
            style: TextStyle(
              fontSize: context.getRFontSize(14),
              fontWeight: FontWeight.w700,
              color: _textCol,
            ),
          ),
          SizedBox(height: context.getRSize(8)),
          Row(
            children: [
              Expanded(child: Text('Product', style: head())),
              numCell('Taken', numW, header: true),
              numCell('Returned', retW, header: true),
              numCell('Owed', numW, header: true),
            ],
          ),
          ...entries.map((e) {
            final owed = cratesOwedByManufacturer?[e.key] ?? e.value;
            return Padding(
              padding: EdgeInsets.only(top: context.getRSize(6)),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      manufacturerNames?[e.key] ?? 'Unknown',
                      style: TextStyle(
                        fontSize: context.getRFontSize(14),
                        fontWeight: FontWeight.w700,
                        color: _textCol,
                      ),
                    ),
                  ),
                  numCell(_qty(e.value), numW),
                  numCell('0', retW),
                  numCell(_qty(owed), numW),
                ],
              ),
            );
          }),
          if (crateDeposit > 0) ...[
            SizedBox(height: context.getRSize(8)),
            Text(
              (crateDepositFull != null && crateDepositFull! > crateDeposit)
                  ? 'Deposit paid ${formatCurrency(crateDeposit)} of ${formatCurrency(crateDepositFull!)}.'
                  : 'The ${formatCurrency(crateDeposit)} deposit is refunded when the crates are returned.',
              style: TextStyle(fontSize: context.getRFontSize(12), color: _sub),
            ),
          ],
        ],
      ),
    );
  }

  String _formatDate(DateTime dt) {
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    final h12 = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
    final ampm = dt.hour < 12 ? 'AM' : 'PM';
    return '${dt.day} ${months[dt.month - 1]} ${dt.year}, '
        '$h12:${dt.minute.toString().padLeft(2, '0')}\u00A0$ampm';
  }

  Map<String, double> _computeEmpties() =>
      ReceiptFormat.emptiesByManufacturer(cart);
}
