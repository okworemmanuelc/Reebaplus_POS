import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:screenshot/screenshot.dart';
import 'package:share_plus/share_plus.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/permissions/permissions.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:reebaplus_pos/core/theme/design_tokens.dart';
import 'package:reebaplus_pos/core/utils/notifications.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/features/payroll/payroll_money_providers.dart';
import 'package:reebaplus_pos/features/payroll/payslip.dart';
import 'package:reebaplus_pos/features/pos/services/receipt_builder.dart';
import 'package:reebaplus_pos/features/pos/services/receipt_paper_size.dart';
import 'package:reebaplus_pos/shared/services/printer_service.dart';
import 'package:reebaplus_pos/shared/widgets/glassy_scaffold.dart';
import 'package:reebaplus_pos/shared/widgets/printer_picker.dart';
import 'package:reebaplus_pos/shared/widgets/receipt_paper_size_prompt.dart';

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
  });

  final String workerId;
  final String statementId;

  @override
  ConsumerState<PayrollPayslipScreen> createState() =>
      _PayrollPayslipScreenState();
}

class _PayrollPayslipScreenState extends ConsumerState<PayrollPayslipScreen> {
  final ScreenshotController _shot = ScreenshotController();
  bool _printing = false;

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

  /// Prints on the receipt printer (USB first, then Bluetooth), falling back
  /// to the printer picker — the same path as a sale receipt.
  Future<void> _print(PayslipData data) async {
    if (!mounted) return;
    setState(() => _printing = true);
    try {
      final printer = ref.read(printerServiceProvider);
      final granted = await printer.requestPermissions();
      if (!mounted) return;
      if (!granted) {
        AppNotification.showError(context, 'Bluetooth permissions denied');
        return;
      }
      Future<List<int>> buildBytes(ReceiptPaperSize size) =>
          ThermalReceiptService.buildFromLines(
            buildPayslipLines(data, size),
            size,
          );
      final target = await prepareReceiptPrinter(context, printer);
      if (!mounted) return;
      if (target.connected) {
        final printed = await printer.printBytes(
          await buildBytes(target.paperSize),
        );
        if (!mounted) return;
        if (printed) {
          AppNotification.showSuccess(context, 'Print successful');
          return;
        }
      }
      _showPrinterPicker(printer, buildBytes);
    } catch (e) {
      if (mounted) AppNotification.showError(context, 'Print error: $e');
    } finally {
      if (mounted) setState(() => _printing = false);
    }
  }

  void _showPrinterPicker(
    PrinterService printer,
    Future<List<int>> Function(ReceiptPaperSize) buildBytes,
  ) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      constraints: BoxConstraints(maxHeight: context.sheetMaxHeight(0.5)),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(AppSpacing.borderRadiusL),
        ),
      ),
      builder: (_) => PrinterPicker(
        onSelected: (device) async {
          if (!mounted) return;
          Navigator.pop(context);
          setState(() => _printing = true);
          try {
            final connected = await printer.connect(device.macAdress);
            if (!mounted) return;
            if (connected) {
              final target = await prepareReceiptPrinter(context, printer);
              if (!mounted) return;
              await printer.printBytesDirectly(
                await buildBytes(target.paperSize),
              );
              if (!mounted) return;
              AppNotification.showSuccess(context, 'Print successful');
            } else {
              AppNotification.showError(context, 'Could not connect');
            }
          } catch (e) {
            if (mounted) AppNotification.showError(context, 'Print error: $e');
          } finally {
            if (mounted) setState(() => _printing = false);
          }
        },
      ),
    );
  }

  /// Captures the on-screen payslip (with signatures) for the share sheet.
  Future<void> _share(PayslipData data) async {
    try {
      final image = await _shot.capture(pixelRatio: 3.0);
      if (image == null) return;
      final dir = await getTemporaryDirectory();
      final file = File(
        '${dir.path}/payslip_${data.salaryMonth}_${widget.statementId}.png',
      );
      await file.writeAsBytes(image);
      await Share.shareXFiles([XFile(file.path)], text: 'Payslip');
    } catch (e) {
      if (mounted) AppNotification.showError(context, 'Share failed: $e');
    }
  }
}
