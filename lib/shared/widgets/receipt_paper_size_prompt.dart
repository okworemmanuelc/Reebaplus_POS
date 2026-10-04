import 'package:flutter/material.dart';

import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:reebaplus_pos/core/theme/design_tokens.dart';
import 'package:reebaplus_pos/features/pos/services/receipt_paper_size.dart';
import 'package:reebaplus_pos/shared/services/printer_service.dart';

/// What a print flow needs to know before it builds the receipt bytes: is a
/// printer connected, and which paper width is it loaded with.
typedef ReceiptPrinterTarget = ({bool connected, ReceiptPaperSize paperSize});

/// Connects to the receipt printer (reusing a live link, else auto-connecting)
/// and returns that printer's paper width.
///
/// Printers cannot tell the app their paper width — ESC/POS has no standard
/// query and the Bluetooth plugin only sends — so the first time the app
/// prints to a printer it has not seen before, it asks the user once and
/// remembers the answer for that printer. Later prints never ask again.
///
/// When no printer could be connected, `connected` is false and the caller
/// should open the printer picker, then call this again once the picked
/// printer is connected (which asks for that printer if it is new).
Future<ReceiptPrinterTarget> prepareReceiptPrinter(
  BuildContext context,
  PrinterService printer,
) async {
  final connected = await printer.isConnected || await printer.autoConnect();
  final mac = await printer.lastConnectedMac();
  if (mac == null) {
    return (connected: connected, paperSize: ReceiptPaperSize.mm58);
  }
  final saved = await printer.paperSizeFor(mac);
  if (saved != null) return (connected: connected, paperSize: saved);
  // Only ask about a printer that is actually reachable right now; an offline
  // one is asked about once the user picks/connects it.
  if (!connected || !context.mounted) {
    return (connected: connected, paperSize: ReceiptPaperSize.mm58);
  }
  final chosen = await showReceiptPaperSizeDialog(context);
  await printer.savePaperSizeFor(mac, chosen);
  return (connected: connected, paperSize: chosen);
}

/// Asks which paper roll the printer uses. Cannot be dismissed without an
/// answer — the receipt cannot be laid out without one.
Future<ReceiptPaperSize> showReceiptPaperSizeDialog(BuildContext context) async {
  final chosen = await showDialog<ReceiptPaperSize>(
    context: context,
    barrierDismissible: false,
    builder: (_) => const _PaperSizeDialog(),
  );
  return chosen ?? ReceiptPaperSize.mm58;
}

class _PaperSizeDialog extends StatelessWidget {
  const _PaperSizeDialog();

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final subtext = t.colorScheme.onSurface.withValues(alpha: 0.65);

    return PopScope(
      canPop: false,
      child: AlertDialog(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppSpacing.borderRadiusL),
        ),
        title: const Text('Which paper does this printer use?'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Check the width of the paper roll. You only answer this '
                'once for each printer. You can change it later in Settings '
                '→ Receipt printer.',
                style: TextStyle(color: subtext),
              ),
              const SizedBox(height: 16),
              _option(
                context,
                ReceiptPaperSize.mm58,
                '58mm',
                'Small roll, about 2 inches wide',
              ),
              const SizedBox(height: 12),
              _option(
                context,
                ReceiptPaperSize.mm80,
                '80mm',
                'Large roll, about 3 inches wide',
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _option(
    BuildContext context,
    ReceiptPaperSize size,
    String title,
    String subtitle,
  ) {
    final t = Theme.of(context);
    return Material(
      color: t.colorScheme.primary.withValues(alpha: 0.08),
      borderRadius: BorderRadius.circular(AppSpacing.borderRadiusM),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppSpacing.borderRadiusM),
        onTap: () => Navigator.of(context).pop(size),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            children: [
              Icon(AppIcons.orders, color: t.colorScheme.primary),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: TextStyle(
                        fontSize: 12.5,
                        color: t.colorScheme.onSurface.withValues(alpha: 0.6),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
