import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:screenshot/screenshot.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/utils/share_file.dart';
import 'package:reebaplus_pos/core/permissions/permissions.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:reebaplus_pos/core/utils/notifications.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/features/payroll/payroll_money_providers.dart';
import 'package:reebaplus_pos/features/payroll/payslip.dart';
import 'package:reebaplus_pos/features/payroll/widgets/payroll_print.dart';
import 'package:reebaplus_pos/shared/widgets/glassy_scaffold.dart';

/// Keys for tests.
class PayslipKeys {
  static const print = Key('payslip-print');
  static const share = Key('payslip-share');
  static Key statementRow(String id) => Key('payroll-statement-$id');
}

/// One signed payslip (#671): on screen with both signatures, printed on the
/// receipt printer as text (the receipt's own printing), or shared as an
/// image (the receipt's own share).
class PayrollPayslipScreen extends ConsumerStatefulWidget {
  const PayrollPayslipScreen({
    super.key,
    required this.workerId,
    required this.statementId,
    this.autoPrint = false,
  });

  final String workerId;
  final String statementId;

  /// #723: "Print Payslip After Saving" — prints once when the slip opens.
  final bool autoPrint;

  @override
  ConsumerState<PayrollPayslipScreen> createState() =>
      _PayrollPayslipScreenState();
}

class _PayrollPayslipScreenState extends ConsumerState<PayrollPayslipScreen> {
  final ScreenshotController _shot = ScreenshotController();
  bool _printing = false;
  bool _autoPrinted = false;

  PayslipData? _data(PayrollStatementData s) {
    final worker = (ref.watch(payrollWorkersProvider).valueOrNull ?? const [])
        .where((w) => w.id == widget.workerId)
        .firstOrNull;
    if (worker == null) return null;
    final entries =
        ref.watch(payrollWorkerEntriesProvider(widget.workerId)).valueOrNull ??
        const <PayrollEntryData>[];
    final stores = ref.watch(allStoresProvider).valueOrNull ?? const [];
    final users = ref.watch(usersByBusinessProvider).valueOrNull ?? const {};
    return PayslipData.fromStatement(
      statement: s,
      salaryEntry: entries.where((e) => e.id == s.salaryEntryId).firstOrNull,
      businessName: ref.watch(currentBusinessNameProvider),
      workerName: worker.name,
      storeName:
          stores.where((st) => st.id == s.storeId).firstOrNull?.name ?? 'Store',
      loanOwedKobo: PayrollMoneyPosition.outstandingLoanKobo(entries),
      payerName: users[s.signedBy]?.name,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!Gates.managePayroll.allows(ref)) {
      return const GlassyScaffold(
        title: 'Payslip',
        body: Center(child: Text('You no longer have access to Payroll.')),
      );
    }
    final statement =
        (ref
                    .watch(payrollWorkerStatementsProvider(widget.workerId))
                    .valueOrNull ??
                const <PayrollStatementData>[])
            .where((s) => s.id == widget.statementId)
            .firstOrNull;
    final data = statement == null ? null : _data(statement);
    if (statement == null || data == null) {
      return const GlassyScaffold(
        title: 'Payslip',
        body: Center(child: CircularProgressIndicator()),
      );
    }
    if (widget.autoPrint && !_autoPrinted) {
      _autoPrinted = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_print(data));
      });
    }
    final pad = context.getRSize(16);
    return GlassyScaffold(
      title: 'Payslip',
      subtitle: '${data.workerName} • ${payrollMonthLabel(data.salaryMonth)}',
      body: ListView(
        padding: EdgeInsets.fromLTRB(
          pad,
          pad,
          pad,
          pad + context.deviceBottomPadding,
        ),
        children: [
          Screenshot(
            controller: _shot,
            child: PayslipCard(
              data: data,
              workerSignaturePng: statement.workerSignaturePng,
              payerSignaturePng: statement.payerSignaturePng,
            ),
          ),
          SizedBox(height: pad),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  key: PayslipKeys.print,
                  onPressed: _printing ? null : () => unawaited(_print(data)),
                  icon: Icon(AppIcons.print, size: context.getRSize(14)),
                  label: Text(_printing ? 'Printing…' : 'Print'),
                ),
              ),
              SizedBox(width: context.getRSize(12)),
              Expanded(
                child: OutlinedButton.icon(
                  key: PayslipKeys.share,
                  onPressed: () => unawaited(_share(data)),
                  icon: Icon(AppIcons.share, size: context.getRSize(14)),
                  label: const Text('Share'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// Prints on the receipt printer (the same path as a sale receipt).
  Future<void> _print(PayslipData data) => printPayrollLines(
    context,
    ref,
    (size) => buildPayslipLines(data, size),
    onBusy: (busy) {
      if (mounted) setState(() => _printing = busy);
    },
  );

  /// Captures the on-screen payslip (with signatures) for the share sheet.
  Future<void> _share(PayslipData data) async {
    try {
      final image = await _shot.capture(pixelRatio: 3.0);
      if (image == null) return;
      await shareFileBytes(
        bytes: image,
        fileName: 'payslip_${data.salaryMonth}_${widget.statementId}.png',
        mimeType: 'image/png',
        text: 'Payslip',
      );
    } catch (e) {
      if (mounted) AppNotification.showError(context, 'Share failed: $e');
    }
  }
}
