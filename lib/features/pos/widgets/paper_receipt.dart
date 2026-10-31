import 'dart:io';

import 'package:flutter/material.dart';
import 'package:reebaplus_pos/core/settings/vat_settings.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/utils/name_case.dart';
import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/core/utils/product_name.dart';
import 'package:reebaplus_pos/core/utils/stock_calculator.dart';
import 'package:reebaplus_pos/features/pos/services/receipt_paper_size.dart';
import 'package:reebaplus_pos/shared/widgets/receipt_format.dart';

/// The 58mm / 80mm paper receipt (#605), laid out at a fixed logical width
/// ([ReceiptPaperSize.rasterWidthPx] / 2) so that rendering at pixelRatio 2
/// gives a bitmap exactly as wide as the print head. Pure black on white.
class PaperReceipt extends StatelessWidget {
  final ReceiptPaperSize paperSize;
  final String orderId;
  final List<Map<String, dynamic>> cart;
  final double subtotal;
  final double discount;
  final double crateDeposit;
  final double total;
  final String paymentMethod;
  final String? customerName;
  final double? cashReceived;
  final double? walletBalance;
  final bool showWalletInfo;
  final DateTime? reprintDate;
  final DateTime? reshareDate;
  final String? orderStatus;
  final double? refundAmount;
  final Map<String, String>? manufacturerNames;
  final String? storeAddress;
  final String? businessName;
  final String? logoPath;
  final String? businessPhone;
  final String? businessEmail;
  final String? cashierName;
  final DateTime? saleDate;
  final int? vatRateBps;
  final double? vatIncluded;
  final Map<String, double>? cratesOwedByManufacturer;
  final bool tracksCrates;

  const PaperReceipt({
    super.key,
    required this.paperSize,
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
    required this.tracksCrates,
  });

  static const _ink = Colors.black;
  bool get _wide => paperSize == ReceiptPaperSize.mm80;
  double get _w => paperSize.rasterWidthPx / 2;
  double get _fs => _wide ? 11 : 9.5;
  double get _pad => _wide ? 12 : 8;

  TextStyle _t({bool bold = false, double? size, double? spacing}) => TextStyle(
        fontFamily: appFontFamily,
        fontSize: size ?? _fs,
        fontWeight: bold ? FontWeight.w800 : FontWeight.w400,
        color: _ink,
        letterSpacing: spacing,
        height: 1.25,
      );

  Widget _thick() => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Container(height: 2, color: _ink),
      );

  Widget _double() => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Column(children: [
          Container(height: 1.5, color: _ink),
          const SizedBox(height: 2),
          Container(height: 1.5, color: _ink),
        ]),
      );

  Widget _dashed() => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: LayoutBuilder(
          builder: (_, c) {
            final n = (c.maxWidth / 5).floor();
            return Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: List.generate(
                n,
                (_) => Container(width: 3, height: 1, color: _ink),
              ),
            );
          },
        ),
      );

  Widget _lr(String l, String r, {bool boldL = false, bool boldR = false}) =>
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 1.5),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l, style: _t(bold: boldL)),
            const SizedBox(width: 6),
            Expanded(
              child: Text(r, textAlign: TextAlign.right, style: _t(bold: boldR)),
            ),
          ],
        ),
      );

  Widget _center(String s, {bool bold = false, double? size, double? spacing}) =>
      Padding(
        padding: const EdgeInsets.only(top: 2),
        child: Text(
          s,
          textAlign: TextAlign.center,
          style: _t(bold: bold, size: size, spacing: spacing),
        ),
      );

  Widget _stamp(String s) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              border: Border.all(color: _ink, width: 1.5),
              borderRadius: BorderRadius.circular(3),
            ),
            child: Text(s, style: _t(bold: true, size: _fs + 2, spacing: 1)),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final hasLogo = logoPath != null && File(logoPath!).existsSync();
    final name = businessName?.trim() ?? '';
    final addr = storeAddress?.trim() ?? '';
    final phone = businessPhone?.trim() ?? '';
    final email = businessEmail?.trim() ?? '';
    final cust = customerName?.trim() ?? '';
    final showCustomer = !ReceiptFormat.isWalkIn(customerName);
    final cashier = cashierName?.trim() ?? '';

    final totalKobo = (total * 100).round();
    final paidKobo = ((cashReceived ?? total) * 100).round();
    final diff = paidKobo - totalKobo;
    final pm = paymentMethod.toLowerCase();
    final methodLabel =
        (pm == 'wallet payment' || pm == 'wallet') ? 'Credit' : paymentMethod;
    final units = cart.fold<double>(0, (a, i) => a + ReceiptFormat.num(i['qty']));
    final date = ReceiptFormat.paperDate(saleDate ?? DateTime.now());

    final vatLabel = vatRateBps != null
        ? 'VAT (${VatConfig(enabled: true, rateBps: vatRateBps!).ratePercentLabel}%) included'
        : 'VAT included';
    final totals = <Widget>[
      _lr('Subtotal (${ReceiptFormat.qty(units)} ${units == 1 ? 'item' : 'items'})',
          formatCurrency(subtotal)),
      if (discount > 0) _lr('Discount', formatCurrency(-discount)),
      if (vatIncluded != null) _lr(vatLabel, formatCurrency(vatIncluded!)),
      if (crateDeposit > 0) _lr('Crate deposit', formatCurrency(crateDeposit)),
    ];

    return Container(
      width: _w,
      color: Colors.white,
      padding: EdgeInsets.fromLTRB(_pad, 10, _pad, 12),
      child: DefaultTextStyle(
        style: _t(),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (reprintDate != null) _stamp('REPRINTED'),
            if (reshareDate != null) _stamp('RESHARED'),
            if (orderStatus == 'Refunded')
              _stamp('REFUNDED ${formatCurrency(refundAmount ?? total)}'),
            if (hasLogo)
              Center(
                child: Container(
                  width: _wide ? 60 : 48,
                  height: _wide ? 60 : 48,
                  padding: const EdgeInsets.all(5),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: _ink, width: 1.5),
                  ),
                  child: Image.file(File(logoPath!), fit: BoxFit.contain),
                ),
              ),
            if (name.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: _center(name.toUpperCase(),
                    bold: true, size: _wide ? 16 : 13),
              ),
            if (addr.isNotEmpty) _center(addr),
            if (_wide && (phone.isNotEmpty || email.isNotEmpty))
              _center([if (phone.isNotEmpty) 'Tel: $phone', if (email.isNotEmpty) email]
                  .join(' · '))
            else ...[
              if (phone.isNotEmpty) _center('Tel: $phone'),
              if (email.isNotEmpty) _center(email),
            ],
            _thick(),
            if (_wide) ...[
              // Real receipt numbers (ORD-NNNNNN-XXXXXX) are too long for a
              // half-width cell, so the details stack as full-width rows (no 2x2 grid).
              _lr('Receipt No.', orderId, boldR: true),
              _lr('Date', date),
              if (cashier.isNotEmpty) _lr('Cashier', toNameCase(cashier)),
              if (showCustomer) _lr('Customer', toNameCase(cust)),
            ]
            else ...[
              _lr('Receipt No.', orderId, boldR: true),
              _lr('Date', date),
              if (cashier.isNotEmpty) _lr('Cashier', toNameCase(cashier)),
              if (showCustomer) _lr('Customer', toNameCase(cust)),
            ],
            _thick(),
            _itemsHeader(),
            ...cart.map(_itemRow),
            _thick(),
            if (_wide)
              Row(children: [
                const Spacer(),
                Expanded(flex: 2, child: Column(children: totals)),
              ])
            else
              ...totals,
            _double(),
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Text('TOTAL', style: _t(bold: true, size: _wide ? 15 : 12)),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    formatCurrency(total),
                    textAlign: TextAlign.right,
                    style: _t(bold: true, size: _wide ? 20 : 16),
                  ),
                ),
              ],
            ),
            _double(),
            _payment(methodLabel, diff),
            ..._crates(),
            const SizedBox(height: 4),
            _dashed(),
            _center('Powered by Reebaplus'),
          ],
        ),
      ),
    );
  }

  Widget _itemsHeader() {
    final h = _t(bold: true, spacing: 0.4);
    if (!_wide) {
      return Row(children: [
        Text('ITEM', style: h),
        const Spacer(),
        Text('AMOUNT', style: h),
      ]);
    }
    return Row(children: [
      Expanded(child: Text('ITEM', style: h)),
      SizedBox(width: 30, child: Text('QTY', textAlign: TextAlign.right, style: h)),
      SizedBox(width: 62, child: Text('PRICE', textAlign: TextAlign.right, style: h)),
      SizedBox(width: 72, child: Text('AMOUNT', textAlign: TextAlign.right, style: h)),
    ]);
  }

  Widget _itemRow(Map<String, dynamic> item) {
    final qty = ReceiptFormat.num(item['qty']);
    final price = ReceiptFormat.num(item['price']);
    final line = stockValue(price, qty).round();
    final label = productDisplayName(
      item['name'].toString(),
      item['size'] as String?,
      unit: item['unit'] as String?,
      crates: tracksCrates,
    );
    final q = ReceiptFormat.qty(qty);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _dashed(),
        if (_wide)
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: Text(label, style: _t(bold: true))),
              SizedBox(width: 30, child: Text(q, textAlign: TextAlign.right, style: _t())),
              SizedBox(
                width: 62,
                child: Text(formatCurrency(price),
                    textAlign: TextAlign.right, style: _t()),
              ),
              SizedBox(
                width: 72,
                child: Text(formatCurrency(line),
                    textAlign: TextAlign.right, style: _t(bold: true)),
              ),
            ],
          )
        else ...[
          Text(label, style: _t(bold: true)),
          _lr('$q x ${formatCurrency(price)}', formatCurrency(line), boldR: true),
        ],
      ],
    );
  }

  Widget _payment(String methodLabel, int diff) {
    final paid = formatCurrency(cashReceived ?? total);
    final lastLabel = diff < 0 ? 'Balance owed' : 'Change';
    final lastVal = formatCurrency(diff.abs() / 100.0);
    final showLast = diff != 0;
    final wallet = (showWalletInfo && walletBalance != null)
        ? _lr('Credits balance', formatCurrency(walletBalance!), boldR: true)
        : const SizedBox.shrink();
    if (!_wide) {
      return Column(children: [
        _lr('Paid by', methodLabel, boldR: true),
        _lr('Amount paid', paid, boldR: true),
        if (showLast) _lr(lastLabel, lastVal, boldR: true),
        wallet,
      ]);
    }
    Widget cell(String l, String v, CrossAxisAlignment a) => Column(
          crossAxisAlignment: a,
          children: [
            Text(l, style: _t()),
            Text(v, style: _t(bold: true)),
          ],
        );
    return Column(children: [
      Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          cell('Paid by', methodLabel, CrossAxisAlignment.start),
          cell('Amount paid', paid, CrossAxisAlignment.start),
          if (showLast) cell(lastLabel, lastVal, CrossAxisAlignment.end),
        ],
      ),
      wallet,
    ]);
  }

  List<Widget> _crates() {
    final empties = ReceiptFormat.emptiesByManufacturer(cart);
    if (empties.isEmpty) return const [];
    final entries = empties.entries.toList()
      ..sort((a, b) => (manufacturerNames?[a.key] ?? 'Unknown')
          .compareTo(manufacturerNames?[b.key] ?? 'Unknown'));
    Widget num(String s, double w, {bool bold = false}) => SizedBox(
          width: w,
          child: Text(s, textAlign: TextAlign.right, style: _t(bold: bold)),
        );
    return [
      _thick(),
      Text('EMPTY CRATES', style: _t(bold: true, spacing: 0.4)),
      const SizedBox(height: 3),
      if (_wide)
        Row(children: [
          Expanded(child: Text('Product', style: _t())),
          num('Taken', 44),
          num('Returned', 58),
          num('Owed', 40),
        ]),
      ...entries.map((e) {
        final owed = cratesOwedByManufacturer?[e.key] ?? e.value;
        final nm = manufacturerNames?[e.key] ?? 'Unknown';
        if (_wide) {
          return Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Row(children: [
              Expanded(child: Text(nm, style: _t(bold: true))),
              num(ReceiptFormat.qty(e.value), 44),
              num('0', 58),
              num(ReceiptFormat.qty(owed), 40, bold: true),
            ]),
          );
        }
        return Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(nm, style: _t(bold: true)),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('Taken: ${ReceiptFormat.qty(e.value)}', style: _t()),
                  Text('Returned: 0', style: _t()),
                  Text('Owed: ${ReceiptFormat.qty(owed)}', style: _t(bold: true)),
                ],
              ),
            ],
          ),
        );
      }),
      if (crateDeposit > 0)
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            'The ${formatCurrency(crateDeposit)} deposit is refunded when the crates are returned.',
            style: _t(),
          ),
        ),
    ];
  }
}
