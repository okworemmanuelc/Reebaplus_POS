import 'dart:convert';

import 'package:flutter/material.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/utils/name_case.dart';
import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/features/pos/services/receipt_lines.dart';
import 'package:reebaplus_pos/features/pos/services/receipt_paper_size.dart';

/// Plain-language label for a payment method.
String payrollPaymentMethodLabel(String method) => switch (method) {
  'cash' => 'Cash',
  'transfer' => 'Transfer',
  'other' => 'Other',
  _ => method,
};

/// Everything a payslip shows (#671), read from the signed statement and its
/// salary entry. Pure data, so the paper and on-screen layouts share it.
class PayslipData {
  const PayslipData({
    required this.businessName,
    required this.workerName,
    required this.storeName,
    required this.salaryMonth,
    required this.paydayDate,
    required this.salaryKobo,
    required this.allowancesKobo,
    required this.bonusesKobo,
    required this.advancesKobo,
    required this.loanRepaidKobo,
    required this.cashPaidKobo,
    required this.totalPayKobo,
    required this.paymentMethod,
    this.loanOwedKobo = 0,
    this.reason,
    this.payerName,
  });

  factory PayslipData.fromStatement({
    required PayrollStatementData statement,
    PayrollEntryData? salaryEntry,
    required String businessName,
    required String workerName,
    required String storeName,
    int loanOwedKobo = 0,
    String? payerName,
  }) {
    final note = salaryEntry?.note;
    const prefix = 'Different amount this month: ';
    return PayslipData(
      businessName: businessName,
      workerName: toNameCase(workerName),
      storeName: storeName,
      salaryMonth: statement.salaryMonth,
      paydayDate:
          salaryEntry?.entryDate ??
          payrollDayKey((statement.signedAt ?? statement.createdAt).toLocal()),
      salaryKobo: statement.salaryKobo,
      allowancesKobo: statement.allowancesKobo,
      bonusesKobo: statement.bonusesKobo,
      advancesKobo: statement.advancesKobo,
      loanRepaidKobo: statement.loanRepaidKobo,
      cashPaidKobo: statement.cashPaidKobo,
      totalPayKobo: statement.totalPayKobo,
      paymentMethod: salaryEntry?.paymentMethod ?? 'cash',
      loanOwedKobo: loanOwedKobo,
      reason: note != null && note.startsWith(prefix)
          ? note.substring(prefix.length)
          : null,
      payerName: payerName == null ? null : toNameCase(payerName),
    );
  }

  final String businessName;
  final String workerName;
  final String storeName;
  final String salaryMonth;
  final String paydayDate;
  final int salaryKobo;
  final int allowancesKobo;
  final int bonusesKobo;
  final int advancesKobo;
  final int loanRepaidKobo;
  final int cashPaidKobo;
  final int totalPayKobo;
  final String paymentMethod;

  /// What is still owed on staff loans (its own line, never in Total Pay).
  final int loanOwedKobo;

  /// Why this month's salary differs from the normal one.
  final String? reason;
  final String? payerName;

  /// The rows of the "Total Pay" block: label, kobo.
  List<(String, int)> get earnings => [
    ('Salary', salaryKobo),
    ('Daily allowances', allowancesKobo),
    ('Bonuses', bonusesKobo),
  ];

  /// The rows of the payday block: label, kobo (deductions negative).
  List<(String, int)> get payday => [
    ('Salary', salaryKobo),
    if (advancesKobo != 0) ('Less advances', -advancesKobo),
    if (loanRepaidKobo != 0) ('Less loan repayment', -loanRepaidKobo),
  ];
}

String _money(int kobo) =>
    kobo < 0 ? '-${formatCurrency(-kobo / 100)}' : formatCurrency(kobo / 100);

/// The payslip as text lines for a thermal printer (reusing the receipt's
/// text printing). No signatures on paper: it says both people signed.
List<ReceiptLine> buildPayslipLines(PayslipData d, ReceiptPaperSize paperSize) {
  final w = paperSize.charsPerLine;
  ReceiptLine text(String s, {bool bold = false, ReceiptAlign? align}) =>
      ReceiptLine.text([
        ReceiptSegment(receiptSafe(s), bold: bold),
      ], align: align ?? ReceiptAlign.left);
  ReceiptLine row(String label, int kobo, {bool bold = false}) {
    final l = receiptSafe(label);
    final v = receiptSafe(_money(kobo));
    final gap = w - l.length - v.length;
    return ReceiptLine.text([
      ReceiptSegment('$l${' ' * (gap < 1 ? 1 : gap)}$v', bold: bold),
    ]);
  }

  final rule = text('-' * w);
  return [
    if (d.businessName.trim().isNotEmpty)
      text(
        d.businessName.toUpperCase(),
        bold: true,
        align: ReceiptAlign.center,
      ),
    text('PAYSLIP', bold: true, align: ReceiptAlign.center),
    const ReceiptLine.feed(1),
    for (final l in wrapReceiptText(receiptSafe('Name: ${d.workerName}'), w))
      text(l),
    for (final l in wrapReceiptText(receiptSafe('Store: ${d.storeName}'), w))
      text(l),
    text('Salary month: ${payrollMonthLabel(d.salaryMonth)}'),
    text('Payday: ${d.paydayDate}'),
    rule,
    for (final (label, kobo) in d.earnings) row(label, kobo),
    row('TOTAL PAY', d.totalPayKobo, bold: true),
    rule,
    for (final (label, kobo) in d.payday) row(label, kobo),
    row('PAID ON PAYDAY', d.cashPaidKobo, bold: true),
    text('Paid by: ${payrollPaymentMethodLabel(d.paymentMethod)}'),
    if (d.loanOwedKobo > 0) ...[rule, row('Loan still owed', d.loanOwedKobo)],
    if (d.reason != null) ...[
      rule,
      for (final l in wrapReceiptText(
        receiptSafe('Different amount this month: ${d.reason}'),
        w,
      ))
        text(l),
    ],
    rule,
    text('Signed on screen by the worker'),
    text('and by ${d.payerName ?? 'the payer'}.'),
    const ReceiptLine.feed(3),
  ];
}

/// The payslip on screen (white paper whatever the theme, like a receipt),
/// with both signatures. What Share captures.
class PayslipCard extends StatelessWidget {
  const PayslipCard({
    super.key,
    required this.data,
    this.workerSignaturePng,
    this.payerSignaturePng,
  });

  final PayslipData data;
  final String? workerSignaturePng;
  final String? payerSignaturePng;

  static const _ink = Colors.black;

  @override
  Widget build(BuildContext context) {
    final d = data;
    const normal = TextStyle(color: _ink, fontSize: 13);
    const bold = TextStyle(
      color: _ink,
      fontSize: 13,
      fontWeight: FontWeight.w700,
    );
    Widget row(String label, int kobo, {bool strong = false}) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Expanded(child: Text(label, style: strong ? bold : normal)),
          Text(_money(kobo), style: strong ? bold : normal),
        ],
      ),
    );
    Widget rule() => const Padding(
      padding: EdgeInsets.symmetric(vertical: 8),
      child: Divider(height: 1, color: _ink),
    );
    Widget signature(String label, String? png) {
      final bytes = png == null ? null : base64Decode(png);
      return Expanded(
        child: Column(
          children: [
            SizedBox(
              height: 56,
              child: bytes == null
                  ? const SizedBox.shrink()
                  : Image.memory(bytes, fit: BoxFit.contain),
            ),
            const Divider(height: 1, color: _ink),
            const SizedBox(height: 4),
            Text(label, style: normal),
          ],
        ),
      );
    }

    return Container(
      color: Colors.white,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (d.businessName.trim().isNotEmpty)
            Text(
              d.businessName.toUpperCase(),
              textAlign: TextAlign.center,
              style: bold.copyWith(fontSize: 15),
            ),
          const Text('PAYSLIP', textAlign: TextAlign.center, style: bold),
          const SizedBox(height: 10),
          Text('Name: ${d.workerName}', style: normal),
          Text('Store: ${d.storeName}', style: normal),
          Text(
            'Salary month: ${payrollMonthLabel(d.salaryMonth)}',
            style: normal,
          ),
          Text('Payday: ${d.paydayDate}', style: normal),
          rule(),
          for (final (label, kobo) in d.earnings) row(label, kobo),
          row('Total Pay', d.totalPayKobo, strong: true),
          rule(),
          for (final (label, kobo) in d.payday) row(label, kobo),
          row('Paid on payday', d.cashPaidKobo, strong: true),
          Text(
            'Paid by: ${payrollPaymentMethodLabel(d.paymentMethod)}',
            style: normal,
          ),
          if (d.loanOwedKobo > 0) ...[
            rule(),
            row('Loan still owed', d.loanOwedKobo),
          ],
          if (d.reason != null) ...[
            rule(),
            Text('Different amount this month: ${d.reason}', style: normal),
          ],
          const SizedBox(height: 16),
          Row(
            children: [
              signature('Worker', workerSignaturePng),
              const SizedBox(width: 16),
              signature(d.payerName ?? 'Payer', payerSignaturePng),
            ],
          ),
        ],
      ),
    );
  }
}
