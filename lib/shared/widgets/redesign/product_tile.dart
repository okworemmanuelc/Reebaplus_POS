import 'dart:io';

import 'package:flutter/material.dart';

import 'package:reebaplus_pos/core/theme/app_decorations.dart';
import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/theme/design_tokens.dart';
import 'package:reebaplus_pos/core/theme/fixed_colors.dart';
import 'package:reebaplus_pos/core/theme/scheme_colors.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/category_visual.dart';

/// How much stock a [ProductTile] reports; picks the stock pill's colour.
enum StockLevel { ok, low, out }

/// A POS / Receive Stock product tile (#352 PR 2; `phone-pos-light.png`,
/// `tablet-pos-*.png`).
///
/// **Photo first**: when [photoPath] (the product's local photo copy — the
/// same `imagePath` the POS grid shows today through `Image.file`) is set and
/// readable it fills the top. Otherwise the top is the category's pale tint
/// with its keyword icon, from [categoryVisual]. A product's stored
/// `icon_code_point` is not used here: the category rule replaces it on tiles,
/// while cart and checkout lines keep `productIconFromCodePoint`.
///
/// Below: the name, a muted [subtitle] ("60cl · Crate of 12"), the price in
/// primary and a stock pill with a dot. [inCartQty] > 0 draws the primary
/// border and the count badge. Out of stock dims the tile and ignores taps.
/// The whole tile is one tap target.
class ProductTile extends StatelessWidget {
  const ProductTile({
    super.key,
    required this.name,
    this.subtitle,
    required this.priceLabel,
    required this.stockLabel,
    this.stockLevel = StockLevel.ok,
    this.categoryName,
    this.photoPath,
    this.inCartQty = 0,
    this.onTap,
    this.onLongPress,
  });

  final String name;
  final String? subtitle;

  /// Formatted by the caller (e.g. `formatCurrency`).
  final String priceLabel;

  /// Text in the stock pill, e.g. "38".
  final String stockLabel;
  final StockLevel stockLevel;
  final String? categoryName;
  final String? photoPath;

  /// Lines of this product already in the cart; 0 hides the badge.
  final int inCartQty;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final f = t.extension<AppFixedColors>() ?? AppFixedColors.light;
    final scheme = t.extension<AppSchemeColors>();
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    final visual = categoryVisual(categoryName, f);
    final out = stockLevel == StockLevel.out;
    final inCart = inCartQty > 0;
    final radius = BorderRadius.circular(AppSpacing.borderRadiusXL);

    final (Color pillFill, Color pillDot) = switch (stockLevel) {
      StockLevel.ok => (f.greenTint, f.greenDot),
      StockLevel.low => (f.warningTint, f.warning),
      StockLevel.out => (f.dangerTint, f.danger),
    };

    final fallback = Center(
      child: AppIcon(
        visual.icon,
        filled: true,
        size: context.getRSize(36),
        color: visual.iconColor,
      ),
    );

    final art = ClipRRect(
      borderRadius: BorderRadius.circular(AppSpacing.borderRadiusL),
      child: ColoredBox(
        color: visual.tint,
        child: photoPath == null
            ? fallback
            : Image.file(
                File(photoPath!),
                fit: BoxFit.cover,
                width: double.infinity,
                height: double.infinity,
                errorBuilder: (_, __, ___) => fallback,
              ),
      ),
    );

    final card = Container(
      decoration: AppDecorations.card(context).copyWith(
        border: Border.all(
          color: inCart ? t.colorScheme.primary : t.dividerColor,
          width: inCart ? 2 : 1,
        ),
      ),
      padding: EdgeInsets.all(context.getRSize(10)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // The art takes whatever height the text leaves (ui-context
          // "Responsive Grid & Card Layouts").
          Expanded(child: art),
          SizedBox(height: context.getRSize(10)),
          Text(
            name,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: context
                .boldStyle(15)
                .copyWith(color: t.colorScheme.onSurface),
          ),
          if (subtitle != null)
            Text(
              subtitle!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: context.regularStyle(12).copyWith(color: muted),
            ),
          SizedBox(height: context.getRSize(8)),
          Row(
            children: [
              Expanded(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(
                    priceLabel,
                    maxLines: 1,
                    style: context
                        .boldStyle(16)
                        .copyWith(color: t.colorScheme.primary),
                  ),
                ),
              ),
              SizedBox(width: context.getRSize(6)),
              Container(
                padding: EdgeInsets.symmetric(
                  horizontal: context.getRSize(8),
                  vertical: context.getRSize(3),
                ),
                decoration: ShapeDecoration(
                  color: pillFill,
                  shape: const StadiumBorder(),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: context.getRSize(7),
                      height: context.getRSize(7),
                      decoration: BoxDecoration(
                        color: pillDot,
                        shape: BoxShape.circle,
                      ),
                    ),
                    SizedBox(width: context.getRSize(4)),
                    Text(
                      stockLabel,
                      maxLines: 1,
                      softWrap: false,
                      style: context
                          .boldStyle(12)
                          .copyWith(color: t.colorScheme.onSurface),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );

    return Semantics(
      button: true,
      enabled: !out,
      label: name,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned.fill(
            child: Material(
              type: MaterialType.transparency,
              child: InkWell(
                borderRadius: radius,
                onTap: out ? null : onTap,
                onLongPress: out ? null : onLongPress,
                child: Opacity(opacity: out ? 0.5 : 1, child: card),
              ),
            ),
          ),
          if (inCart)
            Positioned(
              top: -context.getRSize(6),
              right: -context.getRSize(6),
              child: Container(
                constraints: BoxConstraints(
                  minWidth: context.getRSize(26),
                  minHeight: context.getRSize(26),
                ),
                padding: EdgeInsets.symmetric(horizontal: context.getRSize(6)),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: t.colorScheme.primary,
                  shape: BoxShape.circle,
                  border: Border.all(color: t.colorScheme.surface, width: 2),
                  boxShadow: [
                    if (scheme != null)
                      BoxShadow(color: scheme.primaryGlow, blurRadius: 6),
                  ],
                ),
                child: Text(
                  '$inCartQty',
                  style: context
                      .boldStyle(12)
                      .copyWith(color: t.colorScheme.onPrimary),
                ),
              ),
            ),
          if (out)
            Positioned.fill(
              child: IgnorePointer(
                child: Center(
                  child: Container(
                    padding: EdgeInsets.symmetric(
                      horizontal: context.getRSize(10),
                      vertical: context.getRSize(4),
                    ),
                    decoration: ShapeDecoration(
                      color: f.dangerTint,
                      shape: const StadiumBorder(),
                    ),
                    child: Text(
                      'Out of stock',
                      style: context.boldStyle(12).copyWith(color: f.danger),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
