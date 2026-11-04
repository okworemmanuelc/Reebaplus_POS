import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/theme/design_tokens.dart';
import 'package:reebaplus_pos/core/utils/notifications.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/features/pos/services/receipt_builder.dart';
import 'package:reebaplus_pos/features/pos/services/receipt_lines.dart';
import 'package:reebaplus_pos/features/pos/services/receipt_paper_size.dart';
import 'package:reebaplus_pos/shared/services/printer_service.dart';
import 'package:reebaplus_pos/shared/widgets/printer_picker.dart';
import 'package:reebaplus_pos/shared/widgets/receipt_paper_size_prompt.dart';

/// Prints [lines] on the receipt printer (USB first, then Bluetooth), falling
/// back to the printer picker — the same path as a sale receipt. Used by the
/// payslip and the month's report. [onBusy] tracks the print for a spinner.
Future<void> printPayrollLines(
  BuildContext context,
  WidgetRef ref,
  List<ReceiptLine> Function(ReceiptPaperSize size) lines, {
  ValueChanged<bool>? onBusy,
}) async {
  Future<List<int>> buildBytes(ReceiptPaperSize size) =>
      ThermalReceiptService.buildFromLines(lines(size), size);

  onBusy?.call(true);
  try {
    final printer = ref.read(printerServiceProvider);
    final granted = await printer.requestPermissions();
    if (!context.mounted) return;
    if (!granted) {
      AppNotification.showError(context, 'Bluetooth permissions denied');
      return;
    }
    final target = await prepareReceiptPrinter(context, printer);
    if (!context.mounted) return;
    if (target.connected) {
      final printed = await printer.printBytes(
        await buildBytes(target.paperSize),
      );
      if (!context.mounted) return;
      if (printed) {
        AppNotification.showSuccess(context, 'Print successful');
        return;
      }
    }
    _showPicker(context, printer, buildBytes, onBusy);
  } catch (e) {
    if (context.mounted) {
      AppNotification.showError(context, 'Print error: $e');
    }
  } finally {
    onBusy?.call(false);
  }
}

void _showPicker(
  BuildContext context,
  PrinterService printer,
  Future<List<int>> Function(ReceiptPaperSize) buildBytes,
  ValueChanged<bool>? onBusy,
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
    builder: (sheet) => PrinterPicker(
      onSelected: (device) async {
        Navigator.pop(sheet);
        if (!context.mounted) return;
        onBusy?.call(true);
        try {
          final connected = await printer.connect(device.macAdress);
          if (!context.mounted) return;
          if (connected) {
            final target = await prepareReceiptPrinter(context, printer);
            if (!context.mounted) return;
            await printer.printBytesDirectly(
              await buildBytes(target.paperSize),
            );
            if (!context.mounted) return;
            AppNotification.showSuccess(context, 'Print successful');
          } else {
            AppNotification.showError(context, 'Could not connect');
          }
        } catch (e) {
          if (context.mounted) {
            AppNotification.showError(context, 'Print error: $e');
          }
        } finally {
          onBusy?.call(false);
        }
      },
    ),
  );
}
