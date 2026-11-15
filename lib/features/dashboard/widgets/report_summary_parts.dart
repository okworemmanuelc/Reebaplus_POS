import 'package:flutter/material.dart';
import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:reebaplus_pos/core/theme/app_decorations.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/theme/design_tokens.dart';
import 'package:reebaplus_pos/core/theme/fixed_colors.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';

// Look-only parts of the daily report (#831). They take finished strings and
// colours; no figure is worked out here.

AppFixedColors _fx(ThemeData t) =>
    t.extension<AppFixedColors>() ?? AppFixedColors.light;

/// One headline figure: label, big figure, one-line note.
class ReportSummaryItem {
  const ReportSummaryItem({
    required this.label,
    required this.value,
    this.note,
    this.valueColor,
  });

  final String label;
  final String value;
  final String? note;
  final Color? valueColor;
}

/// Phone header: a primary-coloured card, first item big, the rest as inner
/// tiles underneath.
class ReportHeroCard extends StatelessWidget {
  const ReportHeroCard({super.key, required this.items});

  final List<ReportSummaryItem> items;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fg = theme.colorScheme.onPrimary;
    final main = items.first;
    final rest = items.skip(1).toList();
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.primary,
        borderRadius: BorderRadius.circular(context.getRSize(20)),
      ),
      child: Padding(
        padding: EdgeInsets.all(context.getRSize(16)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              main.label,
              style: context.mediumStyle(13).copyWith(color: fg),
            ),
            SizedBox(height: context.getRSize(4)),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                main.value,
                style: context.extraBoldStyle(30).copyWith(color: fg),
              ),
            ),
            if (main.note != null)
              Text(
                main.note!,
                style: context.bodySmall.copyWith(
                  color: fg.withValues(alpha: 0.85),
                ),
              ),
            if (rest.isNotEmpty) ...[
              SizedBox(height: context.getRSize(12)),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (var i = 0; i < rest.length; i++) ...[
                    if (i > 0) SizedBox(width: context.getRSize(10)),
                    Expanded(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: fg.withValues(alpha: 0.14),
                          borderRadius: BorderRadius.circular(
                            context.getRSize(14),
                          ),
                        ),
                        child: Padding(
                          padding: EdgeInsets.all(context.getRSize(12)),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                rest[i].label,
                                style: context
                                    .mediumStyle(12)
                                    .copyWith(color: fg),
                              ),
                              SizedBox(height: context.getRSize(2)),
                              FittedBox(
                                fit: BoxFit.scaleDown,
                                alignment: Alignment.centerLeft,
                                child: Text(
                                  rest[i].value,
                                  style: context
                                      .extraBoldStyle(18)
                                      .copyWith(color: fg),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Tablet and desktop header: one white tile per item, side by side.
class ReportSummaryTiles extends StatelessWidget {
  const ReportSummaryTiles({super.key, required this.items});

  final List<ReportSummaryItem> items;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final gap = context.getRSize(12);
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < items.length; i++) ...[
            if (i > 0) SizedBox(width: gap),
            Expanded(
              child: DecoratedBox(
                decoration: AppDecorations.card(context),
                child: Padding(
                  padding: EdgeInsets.all(context.getRSize(14)),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        items[i].label,
                        style: context
                            .mediumStyle(13)
                            .copyWith(color: theme.hintColor),
                      ),
                      SizedBox(height: context.getRSize(4)),
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: Text(
                          items[i].value,
                          style: context
                              .extraBoldStyle(24)
                              .copyWith(
                                color:
                                    items[i].valueColor ??
                                    theme.colorScheme.onSurface,
                              ),
                        ),
                      ),
                      if (items[i].note != null) ...[
                        SizedBox(height: context.getRSize(2)),
                        Text(
                          items[i].note!,
                          style: context.bodySmall.copyWith(
                            color: theme.hintColor,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// The amber bar shown when most sales were on credit.
class ReportCreditWarning extends StatelessWidget {
  const ReportCreditWarning({
    super.key,
    required this.lead,
    required this.rest,
  });

  final String lead;
  final String rest;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fx = _fx(theme);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: fx.warningTint,
        borderRadius: BorderRadius.circular(context.getRSize(14)),
        border: Border.all(color: fx.warningOutline),
      ),
      child: Padding(
        padding: EdgeInsets.all(context.getRSize(14)),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              AppIcons.infoCircle,
              size: context.getRSize(18),
              color: fx.warning,
            ),
            SizedBox(width: context.getRSize(10)),
            Expanded(
              child: Text.rich(
                TextSpan(
                  children: [
                    TextSpan(text: '$lead ', style: context.boldStyle(13)),
                    TextSpan(text: rest, style: context.mediumStyle(13)),
                  ],
                ),
                style: TextStyle(color: theme.colorScheme.onSurface),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// "How customers paid": a two-part bar with its legend.
class ReportPaidBar extends StatelessWidget {
  const ReportPaidBar({
    super.key,
    required this.paidNowKobo,
    required this.onCreditKobo,
    required this.paidNowText,
    required this.onCreditText,
  });

  final int paidNowKobo;
  final int onCreditKobo;
  final String paidNowText;
  final String onCreditText;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fx = _fx(theme);
    final paid = paidNowKobo < 0 ? 0 : paidNowKobo;
    final credit = onCreditKobo < 0 ? 0 : onCreditKobo;
    final total = paid + credit;
    final paidFlex = total == 0 ? 1 : paid;
    final creditFlex = total == 0 ? 1 : credit;
    Widget legend(Color c, String label, String value) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(color: c, shape: BoxShape.circle),
        ),
        SizedBox(width: context.getRSize(6)),
        Flexible(
          child: Text(
            '$label  $value',
            style: context.mediumStyle(12),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('How customers paid', style: context.boldStyle(13)),
        SizedBox(height: context.getRSize(8)),
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: SizedBox(
            height: context.getRSize(10),
            child: Row(
              children: [
                if (paidFlex > 0)
                  Expanded(
                    flex: paidFlex,
                    child: ColoredBox(
                      color: theme.colorScheme.primary,
                      child: const SizedBox.expand(),
                    ),
                  ),
                if (creditFlex > 0)
                  Expanded(
                    flex: creditFlex,
                    child: ColoredBox(
                      color: fx.warning,
                      child: const SizedBox.expand(),
                    ),
                  ),
              ],
            ),
          ),
        ),
        SizedBox(height: context.getRSize(8)),
        Wrap(
          spacing: context.getRSize(16),
          runSpacing: context.getRSize(4),
          children: [
            legend(theme.colorScheme.primary, 'Paid now', paidNowText),
            legend(fx.warning, 'On credit', onCreditText),
          ],
        ),
      ],
    );
  }
}

/// A tinted box inside the "worth" card ("What you have" / "What you owe").
class ReportWorthBox extends StatelessWidget {
  const ReportWorthBox({
    super.key,
    required this.title,
    required this.tint,
    required this.titleColor,
    required this.children,
  });

  final String title;
  final Color tint;
  final Color titleColor;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: tint,
        borderRadius: BorderRadius.circular(context.getRSize(14)),
      ),
      child: Padding(
        padding: EdgeInsets.all(context.getRSize(14)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title.toUpperCase(),
              style: context.extraBoldStyle(12).copyWith(color: titleColor),
            ),
            SizedBox(height: context.getRSize(6)),
            ...children,
          ],
        ),
      ),
    );
  }
}
