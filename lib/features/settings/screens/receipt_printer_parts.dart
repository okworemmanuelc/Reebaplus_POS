import 'package:flutter/material.dart';

import 'package:reebaplus_pos/core/theme/app_decorations.dart';
import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/theme/design_tokens.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/features/pos/services/paper_end.dart';
import 'package:reebaplus_pos/features/pos/services/receipt_paper_size.dart';
import 'package:reebaplus_pos/features/settings/screens/settings_page_parts.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/redesign.dart';

/// Measured body width from which Receipt printer shows the list and the
/// settings side by side (#742). A sideways phone gets this too.
const double kPrinterTwoPaneMinWidth = 720;

/// Measured panel width from which the settings sit two to a row.
const double kPrinterTwoColumnMinWidth = 460;

const String kPrinterNotSetYet = 'Not set yet. Asked on first print.';

/// "No blank lines", "1 blank line", "3 blank lines".
String paperEndWords(int lines) => switch (lines) {
  0 => 'No blank lines',
  1 => '1 blank line',
  _ => '$lines blank lines',
};

/// The line under a printer's name: `58mm · Text · Compact · No blank lines`.
/// A printer without a paper width has not been set up.
String printerSummary({
  required ReceiptPaperSize? paperSize,
  required ReceiptPrintStyle style,
  required ReceiptSize receiptSize,
  required int paperEndLines,
}) {
  if (paperSize == null) return kPrinterNotSetYet;
  return [
    paperSize == ReceiptPaperSize.mm58 ? '58mm' : '80mm',
    style == ReceiptPrintStyle.text ? 'Text' : 'Picture',
    receiptSize == ReceiptSize.full ? 'Full' : 'Compact',
    paperEndWords(paperEndLines),
  ].join(' · ');
}

/// A small uppercase label above a group of printers.
class PrinterSectionLabel extends StatelessWidget {
  const PrinterSectionLabel(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Text(
      text,
      style: context
          .boldStyle(13)
          .copyWith(color: t.textTheme.bodySmall?.color, letterSpacing: 0.8),
    );
  }
}

/// A row of the printer list: icon tile, name, one line about it and, when
/// [chevronUp] is set, a chevron. [outlined] marks the printer showing its
/// settings. [body] opens under a hairline; [footer] always shows.
class PrinterCard extends StatelessWidget {
  const PrinterCard({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.strongIcon = true,
    this.outlined = false,
    this.chevronUp,
    this.body,
    this.footer,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final bool strongIcon;
  final bool outlined;

  /// True points the chevron up, false down, null hides it.
  final bool? chevronUp;
  final Widget? body;
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    final pad = context.getRSize(16);
    final decoration = AppDecorations.card(context);
    final radius = BorderRadius.circular(AppSpacing.borderRadiusXL);
    return DecoratedBox(
      decoration: outlined
          ? decoration.copyWith(
              border: Border.all(color: t.colorScheme.primary, width: 2),
            )
          : decoration,
      child: Material(
        type: MaterialType.transparency,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            InkWell(
              onTap: onTap,
              borderRadius: body == null && footer == null
                  ? radius
                  : BorderRadius.vertical(top: radius.topLeft),
              child: Padding(
                padding: EdgeInsets.all(pad),
                child: SettingsControlRow(
                  icon: icon,
                  tone: IconTileTone.neutral,
                  iconColor: strongIcon ? null : muted,
                  title: title,
                  subtitle: subtitle,
                  subtitleSize: 12,
                  tileSize: 42,
                  trailing: chevronUp == null
                      ? null
                      : AppIcon(
                          chevronUp!
                              ? AppIcons.chevronUp
                              : AppIcons.chevronDown,
                          size: context.getRSize(24),
                          color: muted,
                        ),
                ),
              ),
            ),
            AnimatedSize(
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOut,
              alignment: Alignment.topCenter,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (body != null) ...[
                    Divider(height: 1, thickness: 1, color: t.dividerColor),
                    Padding(
                      padding: EdgeInsets.fromLTRB(pad, pad, pad, 0),
                      child: body,
                    ),
                  ],
                  if (footer != null)
                    Padding(
                      padding: EdgeInsets.fromLTRB(
                        pad,
                        body == null ? 0 : pad,
                        pad,
                        pad,
                      ),
                      child: footer,
                    )
                  else if (body != null)
                    SizedBox(height: pad),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The Other devices row of the side-by-side layout: a label and a chevron.
class PrinterOthersHeader extends StatelessWidget {
  const PrinterOthersHeader({
    super.key,
    required this.label,
    required this.open,
    required this.onTap,
  });

  final String label;
  final bool open;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppSpacing.borderRadiusM),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: kMinInteractiveDimension),
        child: Row(
          children: [
            Expanded(child: PrinterSectionLabel(label)),
            AppIcon(
              open ? AppIcons.chevronUp : AppIcons.chevronDown,
              size: context.getRSize(22),
              color: t.textTheme.bodySmall?.color,
            ),
          ],
        ),
      ),
    );
  }
}

/// One setting: a label, its control ([child] under the label, or [trailing]
/// beside it) and an optional muted [help] line.
class PrinterSettingField extends StatelessWidget {
  const PrinterSettingField({
    super.key,
    required this.label,
    this.child,
    this.trailing,
    this.help,
  }) : assert((child == null) != (trailing == null));

  final String label;
  final Widget? child;
  final Widget? trailing;
  final String? help;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final title = Text(
      label,
      style: context.semiBoldStyle(14).copyWith(color: t.colorScheme.onSurface),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (trailing != null)
          Row(
            children: [
              Expanded(child: title),
              SizedBox(width: context.getRSize(8)),
              trailing!,
            ],
          )
        else ...[
          title,
          SizedBox(height: context.getRSize(8)),
          child!,
        ],
        if (help != null) ...[
          SizedBox(height: context.getRSize(8)),
          Text(
            help!,
            style: context
                .regularStyle(12)
                .copyWith(color: t.textTheme.bodySmall?.color),
          ),
        ],
      ],
    );
  }
}

/// The − / + for blank paper after a receipt, held to
/// [kPaperEndLineChoices]. Shows the number, or with [showWords] fills its
/// width and spells it out.
class PaperEndStepper extends StatelessWidget {
  const PaperEndStepper({
    super.key,
    required this.lines,
    required this.onChanged,
    this.showWords = false,
  });

  final int lines;
  final ValueChanged<int> onChanged;
  final bool showWords;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final value = Text(
      showWords ? paperEndWords(lines) : '$lines',
      textAlign: TextAlign.center,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: context.boldStyle(16).copyWith(color: t.colorScheme.onSurface),
    );
    return Container(
      padding: EdgeInsets.all(context.getRSize(4)),
      decoration: BoxDecoration(
        color: t.inputDecorationTheme.fillColor ?? t.dividerColor,
        borderRadius: BorderRadius.circular(AppSpacing.borderRadiusL),
      ),
      child: Row(
        mainAxisSize: showWords ? MainAxisSize.max : MainAxisSize.min,
        children: [
          _StepButton(
            tooltip: 'Less blank paper',
            icon: AppIcons.minus,
            onPressed: lines > kPaperEndLineChoices.first
                ? () => onChanged(lines - 1)
                : null,
          ),
          if (showWords)
            Expanded(child: value)
          else
            ConstrainedBox(
              constraints: BoxConstraints(minWidth: context.getRSize(36)),
              child: value,
            ),
          _StepButton(
            tooltip: 'More blank paper',
            icon: AppIcons.add,
            onPressed: lines < kPaperEndLineChoices.last
                ? () => onChanged(lines + 1)
                : null,
          ),
        ],
      ),
    );
  }
}

class _StepButton extends StatelessWidget {
  const _StepButton({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final enabled = onPressed != null;
    final radius = BorderRadius.circular(AppSpacing.borderRadiusM);
    const side = kMinInteractiveDimension - 4;
    return Tooltip(
      message: tooltip,
      child: Material(
        color: t.colorScheme.surface.withValues(alpha: enabled ? 1 : 0.4),
        borderRadius: radius,
        child: InkWell(
          borderRadius: radius,
          onTap: onPressed,
          child: SizedBox(
            width: side,
            height: side,
            child: Center(
              child: AppIcon(
                icon,
                size: context.getRSize(22),
                color: enabled ? t.colorScheme.onSurface : t.disabledColor,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
