import 'dart:math' as dm;
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:reebaplus_pos/core/theme/app_decorations.dart';
import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/theme/design_tokens.dart';
import 'package:reebaplus_pos/core/theme/fixed_colors.dart';
import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/core/utils/product_unit.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/features/inventory/widgets/product_detail_figures.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:reebaplus_pos/shared/widgets/app_input.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/redesign.dart';

// The cards of the redesigned Product Details (#487 PR 3). Plain data in,
// theme-only styling, no database: the screen reads and writes, these draw.

/// The widest the Product Details content grows (#487): 1400, centred. Fixed,
/// not scaled. Other detail screens keep [kDetailMaxContentWidth]'s 960.
const double kProductDetailMaxContentWidth = 1400;

/// The measured screen width from which Product Details shows three columns
/// and the wide top bar.
const double kProductDetailThreeColumnWidth = 1000;

/// The measured screen width from which Product Details shows two columns.
const double kProductDetailTwoColumnWidth = 600;

Color _muted(BuildContext context) {
  final t = Theme.of(context);
  return t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
}

AppFixedColors _fixed(BuildContext context) =>
    Theme.of(context).extension<AppFixedColors>() ?? AppFixedColors.light;

/// A padded card with a hairline and the soft shadow (`AppDecorations.card`).
class DetailPanel extends StatelessWidget {
  const DetailPanel({super.key, required this.child, this.padding});

  final Widget child;

  /// 16 scaled on every side when null.
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: padding ?? EdgeInsets.all(context.getRSize(16)),
      decoration: AppDecorations.card(context),
      child: child,
    );
  }
}

/// The top of a card: an [IconTile], a bold title with an optional muted
/// subtitle, and an optional [trailing] (a pencil, a total).
class DetailPanelHeader extends StatelessWidget {
  const DetailPanelHeader({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.trailing,
    this.tone = IconTileTone.info,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final IconTileTone tone;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: kMinInteractiveDimension),
      child: Row(
        children: [
          IconTile(icon: icon, tone: tone, size: 44),
          SizedBox(width: context.getRSize(12)),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: context
                      .boldStyle(17)
                      .copyWith(color: t.colorScheme.onSurface),
                ),
                if (subtitle != null)
                  Text(
                    subtitle!,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: context
                        .regularStyle(13)
                        .copyWith(color: _muted(context)),
                  ),
              ],
            ),
          ),
          if (trailing != null) ...[
            SizedBox(width: context.getRSize(8)),
            trailing!,
          ],
        ],
      ),
    );
  }
}

/// A primary pencil, a 48dp target.
class DetailPencil extends StatelessWidget {
  const DetailPencil({super.key, required this.tooltip, required this.onTap});

  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      constraints: const BoxConstraints(
        minWidth: kMinInteractiveDimension,
        minHeight: kMinInteractiveDimension,
      ),
      onPressed: onTap,
      icon: AppIcon(
        AppIcons.edit,
        size: context.getRSize(20),
        color: Theme.of(context).colorScheme.primary,
      ),
    );
  }
}

/// A tonal action button: [fill] under [ink], an optional icon, at least 48dp.
class DetailTonalButton extends StatelessWidget {
  const DetailTonalButton({
    super.key,
    required this.label,
    required this.onTap,
    required this.fill,
    required this.ink,
    this.icon,
    this.expand = true,
  });

  final String label;
  final VoidCallback onTap;
  final Color fill;
  final Color ink;
  final IconData? icon;

  /// Fill the width it is given (true) or hug the label.
  final bool expand;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: fill,
      borderRadius: BorderRadius.circular(AppSpacing.borderRadiusL),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppSpacing.borderRadiusL),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            minHeight: dm.max(context.getRSize(48), kMinInteractiveDimension),
          ),
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: context.getRSize(16),
              vertical: context.getRSize(8),
            ),
            child: Row(
              mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (icon != null) ...[
                  AppIcon(icon, size: context.getRSize(20), color: ink),
                  SizedBox(width: context.getRSize(8)),
                ],
                Flexible(
                  child: Text(
                    label,
                    maxLines: 2,
                    textAlign: TextAlign.center,
                    overflow: TextOverflow.ellipsis,
                    style: context.boldStyle(15).copyWith(color: ink),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ── Hero ─────────────────────────────────────────────────────────────────────

/// The hero card: the photo (or the category icon on a tinted band), the
/// category and stock pills, the name, the kind line, the barcode and the
/// retail price.
class ProductHeroCard extends StatelessWidget {
  const ProductHeroCard({
    super.key,
    required this.name,
    required this.kindLine,
    required this.barcode,
    required this.retailPrice,
    required this.perNoun,
    required this.stockLabel,
    required this.stockLevel,
    required this.fallbackIcon,
    required this.fallbackColor,
    this.categoryName,
    this.imagePath,
    this.expiry,
    this.archived = false,
    this.onChangePhoto,
  });

  final String name;
  final String kindLine;
  final String? barcode;

  /// Already formatted ("₦15,000").
  final String retailPrice;

  /// The singular count word the price is per ("crate").
  final String perNoun;
  final String? categoryName;
  final String stockLabel;
  final StockLevel stockLevel;
  final String? imagePath;
  final IconData fallbackIcon;
  final Color fallbackColor;
  final ({String label, ExpiryTone tone})? expiry;
  final bool archived;

  /// Null hides the camera badge and makes the photo a plain picture.
  final VoidCallback? onChangePhoto;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = _muted(context);
    final code = barcode?.trim() ?? '';
    final radius = BorderRadius.circular(AppSpacing.borderRadiusXL);
    final band = SizedBox(
      height: context.getRSize(150),
      width: double.infinity,
      child: Stack(
        fit: StackFit.expand,
        children: [
          _photo(context),
          if (onChangePhoto != null)
            Positioned(
              right: context.getRSize(8),
              bottom: context.getRSize(8),
              child: IgnorePointer(
                child: Container(
                  padding: EdgeInsets.all(context.getRSize(8)),
                  decoration: BoxDecoration(
                    color: t.colorScheme.primary,
                    shape: BoxShape.circle,
                  ),
                  child: AppIcon(
                    AppIcons.edit,
                    size: context.getRSize(16),
                    color: t.colorScheme.onPrimary,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
    return Container(
      width: double.infinity,
      clipBehavior: Clip.antiAlias,
      decoration: AppDecorations.card(context),
      child: ClipRRect(
        borderRadius: radius,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (onChangePhoto != null)
              Semantics(
                button: true,
                label: 'Change photo',
                child: InkWell(onTap: onChangePhoto, child: band),
              )
            else
              band,
            Padding(
              padding: EdgeInsets.all(context.getRSize(16)),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: context.getRSize(8),
                    runSpacing: context.getRSize(6),
                    children: [
                      if (categoryName != null && categoryName!.isNotEmpty)
                        TagPill(
                          label: categoryName!,
                          tone: TagPillTone.neutral,
                        ),
                      TagPill(
                        label: stockLabel,
                        tone: switch (stockLevel) {
                          StockLevel.ok => TagPillTone.info,
                          StockLevel.low => TagPillTone.warning,
                          StockLevel.out => TagPillTone.danger,
                        },
                      ),
                      if (archived)
                        const TagPill(
                          label: 'Archived',
                          tone: TagPillTone.neutral,
                          icon: AppIcons.archive,
                        ),
                      if (expiry != null)
                        TagPill(
                          label: expiry!.label,
                          tone: switch (expiry!.tone) {
                            ExpiryTone.expired => TagPillTone.danger,
                            ExpiryTone.soon => TagPillTone.warning,
                            ExpiryTone.later => TagPillTone.neutral,
                          },
                        ),
                    ],
                  ),
                  SizedBox(height: context.getRSize(10)),
                  Text(
                    name,
                    style: context
                        .extraBoldStyle(22)
                        .copyWith(color: t.colorScheme.onSurface),
                  ),
                  if (kindLine.isNotEmpty) ...[
                    SizedBox(height: context.getRSize(2)),
                    Text(
                      kindLine,
                      style: context.regularStyle(14).copyWith(color: muted),
                    ),
                  ],
                  SizedBox(height: context.getRSize(4)),
                  Row(
                    children: [
                      AppIcon(
                        AppIcons.barcode,
                        size: context.getRSize(16),
                        color: muted,
                      ),
                      SizedBox(width: context.getRSize(6)),
                      Expanded(
                        child: Text(
                          code.isEmpty ? 'No barcode yet' : code,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: context
                              .regularStyle(14)
                              .copyWith(color: muted),
                        ),
                      ),
                    ],
                  ),
                  SizedBox(height: context.getRSize(12)),
                  Wrap(
                    crossAxisAlignment: WrapCrossAlignment.end,
                    spacing: context.getRSize(8),
                    children: [
                      Text(
                        retailPrice,
                        style: context
                            .extraBoldStyle(30)
                            .copyWith(color: t.colorScheme.primary),
                      ),
                      Padding(
                        padding: EdgeInsets.only(bottom: context.getRSize(4)),
                        child: Text(
                          'retail, per $perNoun',
                          style: context
                              .regularStyle(14)
                              .copyWith(color: muted),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _photo(BuildContext context) {
    final fallback = Container(
      color: fallbackColor.withValues(alpha: 0.15),
      alignment: Alignment.center,
      child: AppIcon(
        fallbackIcon,
        filled: true,
        size: context.getRSize(56),
        color: fallbackColor,
      ),
    );
    final path = imagePath;
    if (path == null) return fallback;
    return Image.file(
      File(path),
      fit: BoxFit.cover,
      errorBuilder: (_, __, ___) => fallback,
    );
  }
}

// ── Description ──────────────────────────────────────────────────────────────

class ProductDescriptionCard extends StatelessWidget {
  const ProductDescriptionCard({super.key, required this.text, this.onEdit});

  final String text;

  /// Null hides the pencil.
  final VoidCallback? onEdit;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final has = text.trim().isNotEmpty;
    return DetailPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DetailPanelHeader(
            icon: AppIcons.document,
            title: 'Description',
            trailing: onEdit == null
                ? null
                : DetailPencil(tooltip: 'Edit description', onTap: onEdit!),
          ),
          SizedBox(height: context.getRSize(8)),
          Text(
            has ? text.trim() : 'No description yet',
            style: context
                .regularStyle(15)
                .copyWith(
                  color: has ? t.colorScheme.onSurface : _muted(context),
                  height: 1.4,
                ),
          ),
        ],
      ),
    );
  }
}

// ── Prices & Profit ──────────────────────────────────────────────────────────

class ProductPricesCard extends StatelessWidget {
  const ProductPricesCard({
    super.key,
    required this.perNoun,
    required this.retailKobo,
    required this.wholesaleKobo,
    this.costKobo,
    this.showProfit = false,
  });

  final String perNoun;
  final int retailKobo;
  final int wholesaleKobo;

  /// Null hides the Cost tile (no `products.edit_buying_price`).
  final int? costKobo;

  /// True only with the buying-price permission AND a cost above 0.
  final bool showProfit;

  @override
  Widget build(BuildContext context) {
    final gap = SizedBox(width: context.getRSize(8));
    return DetailPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DetailPanelHeader(
            icon: AppIcons.cash,
            title: 'Prices & Profit',
            subtitle: 'All prices are per $perNoun.',
          ),
          SizedBox(height: context.getRSize(12)),
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (costKobo != null) ...[
                  Expanded(
                    child: _PriceTile(label: 'Cost', kobo: costKobo!),
                  ),
                  gap,
                ],
                Expanded(
                  child: _PriceTile(label: 'Retail', kobo: retailKobo),
                ),
                gap,
                Expanded(
                  child: _PriceTile(label: 'Wholesale', kobo: wholesaleKobo),
                ),
              ],
            ),
          ),
          if (showProfit && costKobo != null) ...[
            SizedBox(height: context.getRSize(8)),
            _ProfitRow(
              label: 'Retail profit',
              profitKobo: retailKobo - costKobo!,
              percent: profitPercentOfPrice(retailKobo, costKobo!),
            ),
            Divider(height: 1, color: Theme.of(context).dividerColor),
            _ProfitRow(
              label: 'Wholesale profit',
              profitKobo: wholesaleKobo - costKobo!,
              percent: profitPercentOfPrice(wholesaleKobo, costKobo!),
            ),
          ],
        ],
      ),
    );
  }
}

class _PriceTile extends StatelessWidget {
  const _PriceTile({required this.label, required this.kobo});

  final String label;
  final int kobo;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: context.getRSize(10),
        vertical: context.getRSize(10),
      ),
      decoration: BoxDecoration(
        color: t.scaffoldBackgroundColor,
        borderRadius: BorderRadius.circular(AppSpacing.borderRadiusL),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              label,
              maxLines: 1,
              style: context.semiBoldStyle(12).copyWith(color: _muted(context)),
            ),
          ),
          SizedBox(height: context.getRSize(2)),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              formatCurrency(kobo / 100),
              maxLines: 1,
              style: context
                  .extraBoldStyle(16)
                  .copyWith(color: t.colorScheme.onSurface),
            ),
          ),
        ],
      ),
    );
  }
}

class _ProfitRow extends StatelessWidget {
  const _ProfitRow({
    required this.label,
    required this.profitKobo,
    required this.percent,
  });

  final String label;
  final int profitKobo;
  final int percent;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final f = _fixed(context);
    final negative = profitKobo < 0;
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: kMinInteractiveDimension),
      child: Padding(
        padding: EdgeInsets.symmetric(vertical: context.getRSize(8)),
        child: Row(
          children: [
            IconTile(
              icon: negative ? AppIcons.trendingDown : AppIcons.profit,
              tone: negative ? IconTileTone.danger : IconTileTone.green,
              size: 40,
            ),
            SizedBox(width: context.getRSize(12)),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: context
                        .boldStyle(14)
                        .copyWith(color: t.colorScheme.onSurface),
                  ),
                  Text(
                    '$percent% of selling price',
                    style: context
                        .regularStyle(13)
                        .copyWith(color: _muted(context)),
                  ),
                ],
              ),
            ),
            SizedBox(width: context.getRSize(8)),
            Text(
              formatCurrency(profitKobo / 100),
              style: context
                  .extraBoldStyle(16)
                  .copyWith(
                    color: negative ? f.danger : t.colorScheme.onSurface,
                  ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Stock by Store ───────────────────────────────────────────────────────────

/// One store's line on the Stock by Store card.
class StoreStockRow {
  const StoreStockRow({
    required this.storeId,
    required this.name,
    required this.quantity,
  });

  final String storeId;
  final String name;
  final int quantity;
}

class ProductStockByStoreCard extends StatelessWidget {
  const ProductStockByStoreCard({
    super.key,
    required this.rows,
    required this.alertAt,
    required this.unit,
  });

  final List<StoreStockRow> rows;

  /// The product's one low-stock alert level.
  final int alertAt;
  final String? unit;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final total = rows.fold<int>(0, (s, r) => s + r.quantity);
    return DetailPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DetailPanelHeader(
            icon: AppIcons.warehouse,
            title: 'Stock by Store',
            trailing: Text(
              '$total ${unitCountNoun(unit, total)}',
              style: context
                  .extraBoldStyle(16)
                  .copyWith(color: t.colorScheme.onSurface),
            ),
          ),
          for (final r in rows) ...[
            SizedBox(height: context.getRSize(8)),
            _StoreRow(row: r, alertAt: alertAt, unit: unit),
          ],
        ],
      ),
    );
  }
}

class _StoreRow extends StatelessWidget {
  const _StoreRow({
    required this.row,
    required this.alertAt,
    required this.unit,
  });

  final StoreStockRow row;
  final int alertAt;
  final String? unit;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final level = stockLevelOf(row.quantity, alertAt);
    final Widget sub = switch (level) {
      StockLevel.low => TagPill(
        label: 'Low stock, alert at $alertAt',
        tone: TagPillTone.warning,
        icon: AppIcons.warning,
      ),
      StockLevel.out => const TagPill(
        label: 'Out of stock',
        tone: TagPillTone.danger,
        icon: AppIcons.alertCircle,
      ),
      StockLevel.ok => Text(
        'Alert at $alertAt ${unitCountNoun(unit, alertAt)}',
        style: context.regularStyle(13).copyWith(color: _muted(context)),
      ),
    };
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: context.getRSize(14),
        vertical: context.getRSize(12),
      ),
      decoration: BoxDecoration(
        color: t.scaffoldBackgroundColor,
        borderRadius: BorderRadius.circular(AppSpacing.borderRadiusL),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  row.name,
                  style: context
                      .boldStyle(16)
                      .copyWith(color: t.colorScheme.onSurface),
                ),
                SizedBox(height: context.getRSize(4)),
                sub,
              ],
            ),
          ),
          SizedBox(width: context.getRSize(8)),
          Text(
            '${row.quantity}',
            style: context
                .extraBoldStyle(22)
                .copyWith(color: t.colorScheme.onSurface),
          ),
        ],
      ),
    );
  }
}

// ── Sales Target ─────────────────────────────────────────────────────────────

class ProductSalesTargetCard extends StatelessWidget {
  const ProductSalesTargetCard({
    super.key,
    required this.figures,
    required this.unit,
    this.onEdit,
  });

  final SalesTargetFigures figures;
  final String? unit;

  /// Null hides the pencil (CEO only).
  final VoidCallback? onEdit;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = _muted(context);
    final fg = figures;
    final soldNoun = unitCountNoun(unit, fg.target > 0 ? fg.target : fg.sold);
    final String note;
    if (!fg.hasTarget) {
      note = 'No target set';
    } else if (fg.reached) {
      note = 'Target reached.';
    } else {
      note =
          '${fg.remaining} ${unitCountNoun(unit, fg.remaining)} to go. '
          'That is about ${fg.perDay} ${unitCountNoun(unit, fg.perDay)} a day.';
    }
    return DetailPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DetailPanelHeader(
            icon: AppIcons.flag,
            title: 'Sales Target',
            subtitle: fg.headline,
            trailing: onEdit == null
                ? null
                : DetailPencil(tooltip: 'Set sales target', onTap: onEdit!),
          ),
          SizedBox(height: context.getRSize(8)),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                '${fg.sold}',
                style: context
                    .extraBoldStyle(30)
                    .copyWith(color: t.colorScheme.onSurface),
              ),
              SizedBox(width: context.getRSize(6)),
              Expanded(
                child: Text(
                  fg.hasTarget
                      ? 'of ${fg.target} $soldNoun sold'
                      : '${unitCountNoun(unit, fg.sold)} sold',
                  style: context.regularStyle(15).copyWith(color: muted),
                ),
              ),
              if (fg.hasTarget)
                Text(
                  '${fg.percent}%',
                  style: context
                      .extraBoldStyle(18)
                      .copyWith(color: t.colorScheme.primary),
                ),
            ],
          ),
          if (fg.hasTarget) ...[
            SizedBox(height: context.getRSize(10)),
            ClipRRect(
              borderRadius: BorderRadius.circular(AppSpacing.borderRadiusS),
              child: LinearProgressIndicator(
                value: fg.fraction,
                minHeight: context.getRSize(8),
                backgroundColor: t.dividerColor,
                valueColor: AlwaysStoppedAnimation<Color>(
                  t.colorScheme.primary,
                ),
              ),
            ),
          ],
          SizedBox(height: context.getRSize(10)),
          Text(note, style: context.regularStyle(14).copyWith(color: muted)),
        ],
      ),
    );
  }
}

// ── Manage Product ───────────────────────────────────────────────────────────

class ProductManageCard extends StatelessWidget {
  const ProductManageCard({
    super.key,
    required this.archived,
    required this.sideBySide,
    this.onArchiveToggle,
    this.onDelete,
  });

  final bool archived;

  /// Archive and Delete share a row (wide) instead of stacking (phone).
  final bool sideBySide;

  /// Null hides the Archive / Unarchive button.
  final VoidCallback? onArchiveToggle;

  /// Null hides the Delete button.
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final f = _fixed(context);
    final archiveLabel = archived
        ? (sideBySide ? 'Unarchive' : 'Unarchive Product')
        : (sideBySide ? 'Archive' : 'Archive Product');
    final deleteLabel = sideBySide ? 'Delete' : 'Delete Product';
    final archive = onArchiveToggle == null
        ? null
        : DetailTonalButton(
            label: archiveLabel,
            icon: archived ? AppIcons.unarchive : AppIcons.archive,
            fill: f.neutralTile,
            ink: t.colorScheme.onSurface,
            onTap: onArchiveToggle!,
          );
    final delete = onDelete == null
        ? null
        : DetailTonalButton(
            label: deleteLabel,
            icon: AppIcons.delete,
            fill: f.dangerTint,
            ink: f.danger,
            onTap: onDelete!,
          );
    final gap = context.getRSize(10);
    final Widget buttons;
    if (sideBySide) {
      buttons = Row(
        children: [
          if (archive != null) Expanded(child: archive),
          if (archive != null && delete != null) SizedBox(width: gap),
          if (delete != null) Expanded(child: delete),
        ],
      );
    } else {
      buttons = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (archive != null) archive,
          if (archive != null && delete != null) SizedBox(height: gap),
          if (delete != null) delete,
        ],
      );
    }
    return DetailPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Manage Product',
            style: context
                .boldStyle(17)
                .copyWith(color: t.colorScheme.onSurface),
          ),
          SizedBox(height: context.getRSize(12)),
          buttons,
          SizedBox(height: context.getRSize(10)),
          Text(
            'Archiving hides it from sale. Its sales history is kept.',
            style: context.regularStyle(13).copyWith(color: _muted(context)),
          ),
        ],
      ),
    );
  }
}

// ── The small edit pop-up ────────────────────────────────────────────────────

/// A small pop-up with one text box (the Description and the Sales Target).
///
/// `scrollable: true`, so a raised keyboard or a sideways phone scrolls it
/// instead of overflowing. It owns its controller and disposes it with the
/// dialog. [onSave] gets the trimmed text and returns an error message to show
/// (the pop-up stays open) or null on success (it closes).
class ProductEditDialog extends StatefulWidget {
  const ProductEditDialog({
    super.key,
    required this.title,
    required this.initialText,
    required this.onSave,
    this.hint,
    this.helper,
    this.numbersOnly = false,
    this.maxLines = 1,
    this.fieldLabel,
  });

  final String title;
  final String initialText;
  final String? hint;
  final String? helper;
  final String? fieldLabel;
  final bool numbersOnly;
  final int maxLines;
  final Future<String?> Function(String text) onSave;

  @override
  State<ProductEditDialog> createState() => _ProductEditDialogState();
}

class _ProductEditDialogState extends State<ProductEditDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initialText,
  );
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    final error = await widget.onSave(_controller.text.trim());
    if (!mounted) return;
    if (error == null) {
      Navigator.pop(context);
    } else {
      setState(() {
        _saving = false;
        _error = error;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final f = _fixed(context);
    return AlertDialog(
      scrollable: true,
      backgroundColor: t.colorScheme.surface,
      title: Text(
        widget.title,
        style: context.screenTitleStyle.copyWith(
          color: t.colorScheme.onSurface,
        ),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AppInput(
            controller: _controller,
            labelText: widget.fieldLabel,
            hintText: widget.hint,
            autofocus: true,
            keyboardType: widget.numbersOnly
                ? TextInputType.number
                : TextInputType.multiline,
            inputFormatters: widget.numbersOnly
                ? [FilteringTextInputFormatter.digitsOnly]
                : null,
            minLines: widget.maxLines > 1 ? 3 : 1,
            maxLines: widget.maxLines,
            textCapitalization: widget.numbersOnly
                ? TextCapitalization.none
                : TextCapitalization.sentences,
          ),
          if (widget.helper != null) ...[
            SizedBox(height: context.getRSize(8)),
            Text(
              widget.helper!,
              style: context.regularStyle(13).copyWith(color: _muted(context)),
            ),
          ],
          if (_error != null) ...[
            SizedBox(height: context.getRSize(8)),
            Text(
              _error!,
              style: context.regularStyle(13).copyWith(color: f.danger),
            ),
          ],
        ],
      ),
      actions: [
        AppButton(
          text: 'Cancel',
          variant: AppButtonVariant.ghost,
          isFullWidth: false,
          onPressed: _saving ? null : () => Navigator.pop(context),
        ),
        AppButton(
          text: 'Save',
          isFullWidth: false,
          isLoading: _saving,
          onPressed: _save,
        ),
      ],
    );
  }
}
