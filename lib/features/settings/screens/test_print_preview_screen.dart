import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:reebaplus_pos/core/theme/app_decorations.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/theme/semantic_colors.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/features/pos/services/receipt_lines.dart';
import 'package:reebaplus_pos/features/pos/services/receipt_paper_size.dart';
import 'package:reebaplus_pos/features/pos/services/sample_receipt.dart';
import 'package:reebaplus_pos/features/settings/screens/settings_page_parts.dart';
import 'package:reebaplus_pos/shared/services/printer_service.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';

/// Sends the sample receipt to one printer; true when it printed.
typedef TestPrintSender =
    Future<bool> Function(
      PrinterService printer,
      String? businessName,
      DateTime saleDate,
    );

enum _PrintStatus { printing, printed, failed }

/// Test print (#702): sends the sample receipt to the printer the moment it
/// opens, and shows that same receipt (same lines, same paper widget) in the
/// printer's own paper size, print style and Full / Compact size. The print
/// never waits for the preview; the screen stays open afterwards.
class TestPrintPreviewScreen extends ConsumerStatefulWidget {
  const TestPrintPreviewScreen({
    super.key,
    required this.printerName,
    required this.printerId,
    required this.send,
    this.saleDate,
  });

  final String printerName;
  final String printerId;
  final TestPrintSender send;

  /// Fixed in tests so the preview does not change with the clock.
  final DateTime? saleDate;

  @override
  ConsumerState<TestPrintPreviewScreen> createState() =>
      _TestPrintPreviewScreenState();
}

class _PreviewConfig {
  const _PreviewConfig(this.paperSize, this.printStyle, this.receiptSize);
  final ReceiptPaperSize paperSize;
  final ReceiptPrintStyle printStyle;
  final ReceiptSize receiptSize;
}

class _TestPrintPreviewScreenState
    extends ConsumerState<TestPrintPreviewScreen> {
  late final DateTime _saleDate = widget.saleDate ?? DateTime.now();
  late final Future<_PreviewConfig> _config = _loadConfig();
  _PrintStatus _status = _PrintStatus.printing;

  @override
  void initState() {
    super.initState();
    // Starts at once; nothing here waits for the preview to build.
    _print();
  }

  Future<_PreviewConfig> _loadConfig() async {
    final printer = ref.read(printerServiceProvider);
    return _PreviewConfig(
      await printer.paperSizeFor(widget.printerId) ?? ReceiptPaperSize.mm58,
      await printer.printStyleFor(widget.printerId),
      await printer.receiptSizeFor(widget.printerId),
    );
  }

  Future<void> _print() async {
    if (_status != _PrintStatus.printing) {
      setState(() => _status = _PrintStatus.printing);
    }
    var ok = false;
    try {
      ok = await widget.send(
        ref.read(printerServiceProvider),
        ref.read(currentBusinessNameProvider),
        _saleDate,
      );
    } catch (_) {
      ok = false;
    }
    if (!mounted) return;
    setState(() => _status = ok ? _PrintStatus.printed : _PrintStatus.failed);
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<_PreviewConfig>(
      future: _config,
      builder: (context, snap) {
        final cfg = snap.data;
        return SettingsPageScaffold(
          icon: AppIcons.print,
          title: 'Test print',
          subtitle: cfg == null
              ? widget.printerName
              : '${widget.printerName} · ${_describe(cfg)}',
          body: Column(
            children: [
              _StatusStrip(
                status: _status,
                onPrintAgain: _status == _PrintStatus.printing ? null : _print,
              ),
              Expanded(
                child: cfg == null
                    ? const SizedBox.shrink()
                    : _Preview(config: cfg, saleDate: _saleDate),
              ),
            ],
          ),
        );
      },
    );
  }

  static String _describe(_PreviewConfig c) {
    final paper = c.paperSize == ReceiptPaperSize.mm80 ? '80mm' : '58mm';
    final size = c.receiptSize == ReceiptSize.compact ? 'Compact' : 'Full';
    return '$paper · $size';
  }
}

class _StatusStrip extends StatelessWidget {
  const _StatusStrip({required this.status, required this.onPrintAgain});

  final _PrintStatus status;
  final Future<void> Function()? onPrintAgain;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final semantic = t.extension<AppSemanticColors>()!;
    final (label, color) = switch (status) {
      _PrintStatus.printing => ('Printing...', t.colorScheme.primary),
      _PrintStatus.printed => ('Printed', semantic.success),
      _PrintStatus.failed => (
        "Failed. Check the printer is on, has paper and is plugged in.",
        t.colorScheme.error,
      ),
    };
    return Padding(
      padding: EdgeInsets.fromLTRB(
        context.getRSize(16),
        context.getRSize(12),
        context.getRSize(16),
        context.getRSize(8),
      ),
      child: DecoratedBox(
        key: const Key('test-print-status'),
        decoration: AppDecorations.card(context),
        child: Padding(
          padding: EdgeInsets.all(context.getRSize(12)),
          child: Row(
            children: [
              if (status == _PrintStatus.printing)
                SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: color,
                  ),
                )
              else
                Icon(
                  status == _PrintStatus.printed
                      ? Icons.check_circle
                      : Icons.error,
                  color: color,
                  size: 20,
                ),
              SizedBox(width: context.getRSize(10)),
              Expanded(
                child: Text(
                  label,
                  style: context.mediumStyle(14).copyWith(color: color),
                ),
              ),
              AppButton(
                key: const Key('test-print-again'),
                text: 'Print again',
                variant: AppButtonVariant.outline,
                icon: AppIcons.print,
                isFullWidth: false,
                onAsyncPressed: onPrintAgain,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The receipt as it will come out: white paper in every theme.
class _Preview extends StatelessWidget {
  const _Preview({required this.config, required this.saleDate});

  final _PreviewConfig config;
  final DateTime saleDate;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Consumer(
      builder: (context, ref, _) {
        final business = ref.watch(currentBusinessNameProvider);
        final isText = SampleReceipt.isText(
          config.printStyle,
          config.receiptSize,
        );
        return SingleChildScrollView(
          key: const Key('test-print-preview'),
          padding: EdgeInsets.all(context.getRSize(16)),
          child: Center(
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.white,
                border: Border.all(color: t.dividerColor),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x22000000),
                    blurRadius: 8,
                    offset: Offset(0, 2),
                  ),
                ],
              ),
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: isText
                    ? ReceiptLinesPreview(
                        lines: SampleReceipt.lines(
                          paperSize: config.paperSize,
                          receiptSize: config.receiptSize,
                          saleDate: saleDate,
                          businessName: business,
                        ),
                        columns: config.receiptSize == ReceiptSize.compact
                            ? config.paperSize.compactCharsPerLine
                            : config.paperSize.charsPerLine,
                      )
                    : SampleReceipt.paper(
                        paperSize: config.paperSize,
                        saleDate: saleDate,
                        businessName: business,
                      ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Text receipt lines in a monospace face at the true column width, so a
/// line that is too long for the paper wraps here as it would there.
class ReceiptLinesPreview extends StatelessWidget {
  const ReceiptLinesPreview({
    super.key,
    required this.lines,
    required this.columns,
  });

  final List<ReceiptLine> lines;
  final int columns;

  static const _fontSize = 12.0;

  @override
  Widget build(BuildContext context) {
    const base = TextStyle(
      fontFamily: 'monospace',
      fontSize: _fontSize,
      height: 1.25,
      color: Colors.black,
    );
    final painter = TextPainter(
      text: TextSpan(text: 'M' * columns, style: base),
      textDirection: TextDirection.ltr,
    )..layout();
    final width = painter.width;
    painter.dispose();
    return FittedBox(
      fit: BoxFit.scaleDown,
      child: SizedBox(
        width: width,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final line in lines)
              switch (line.kind) {
                ReceiptLineKind.logo => const SizedBox(height: 24),
                ReceiptLineKind.feed => SizedBox(
                  height: _fontSize * 1.25 * line.feedLines,
                ),
                ReceiptLineKind.text => Text.rich(
                  TextSpan(
                    children: [
                      for (final s in line.segments)
                        TextSpan(
                          text: s.text,
                          style: TextStyle(
                            fontWeight: s.bold
                                ? FontWeight.w800
                                : FontWeight.w400,
                          ),
                        ),
                    ],
                  ),
                  softWrap: false,
                  textAlign: switch (line.align) {
                    ReceiptAlign.left => TextAlign.left,
                    ReceiptAlign.center => TextAlign.center,
                    ReceiptAlign.right => TextAlign.right,
                  },
                  style: base.copyWith(
                    fontSize: line.size == ReceiptTextSize.big
                        ? _fontSize * 2
                        : _fontSize,
                  ),
                ),
              },
          ],
        ),
      ),
    );
  }
}
