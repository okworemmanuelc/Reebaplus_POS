import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:reebaplus_pos/core/data/marketplace_categories.dart';
import 'package:reebaplus_pos/core/storefront/storefront_models.dart';
import 'package:reebaplus_pos/core/storefront/storefront_providers.dart';
import 'package:reebaplus_pos/core/theme/app_decorations.dart';
import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/theme/design_tokens.dart';
import 'package:reebaplus_pos/core/theme/fixed_colors.dart';
import 'package:reebaplus_pos/core/theme/scheme_colors.dart';
import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/core/utils/notifications.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/features/browse/widgets/add_to_cart_box.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:reebaplus_pos/shared/widgets/product_photo_gallery.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/redesign.dart';

/// Widest the Browse content column grows on a tablet / wide screen.
const double kBrowseMaxContentWidth = 1100;

/// Narrowest a product card may be before the grid drops a column.
const double kBrowseTileMinWidth = 180;

/// Grid columns for a content width: 2 on a phone, more as room allows.
int browseColumnsFor(double width) =>
    math.max(2, (width / kBrowseTileMinWidth).floor());

/// Card height: the photo flexes, the text block grows with the text scale.
double browseTileExtent(BuildContext context) {
  final scale = MediaQuery.textScalerOf(context).scale(1);
  return context.getRSize(120) + context.getRSize(214) * scale;
}

/// Side gutter that centres the content column in [width].
double browseGutter(BuildContext context, double width) => math.max(
  context.getRSize(16),
  (width - kBrowseMaxContentWidth) / 2,
);

/// Top-level Reebaplus categories for the filter bar ("Other" last).
List<MarketplaceCategory> browseFilterCategories() {
  final top = [
    for (final c in marketplaceCategories)
      if (c.parentSlug == null && c.slug != 'other') c,
  ]..sort((a, b) => a.sort.compareTo(b.sort));
  final other = marketplaceCategories.where((c) => c.slug == 'other');
  return [...top, ...other];
}

String _categoryName(String slug) {
  for (final c in marketplaceCategories) {
    if (c.slug == slug) return c.name;
  }
  return 'Other';
}

/// The solid Browse top bar (surface, hairline, soft shadow — PRD #346
/// decision 4) around a [ScreenHeader].
class BrowseTopBar extends StatelessWidget implements PreferredSizeWidget {
  const BrowseTopBar({super.key, required this.height, required this.header});

  final double height;
  final Widget header;

  static double heightFor(BuildContext context) => math.max(
    kToolbarHeight + 12,
    math.max(context.getRSize(44), kMinInteractiveDimension) +
        context.getRSize(16),
  );

  @override
  Size get preferredSize => Size.fromHeight(height);

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final shadow =
        t.extension<AppSchemeColors>()?.topBarShadow ?? Colors.transparent;
    return AppBar(
      automaticallyImplyLeading: false,
      toolbarHeight: preferredSize.height,
      titleSpacing: context.getRSize(8),
      centerTitle: false,
      backgroundColor: t.colorScheme.surface,
      elevation: 0,
      scrolledUnderElevation: 0,
      surfaceTintColor: Colors.transparent,
      flexibleSpace: Container(
        decoration: BoxDecoration(
          color: t.colorScheme.surface,
          border: Border(bottom: BorderSide(color: t.dividerColor, width: 1)),
          boxShadow: [
            BoxShadow(color: shadow, blurRadius: 4, offset: const Offset(0, 1)),
          ],
        ),
      ),
      title: header,
    );
  }
}

/// 48dp back button for pushed Browse screens.
class BrowseBackButton extends StatelessWidget {
  const BrowseBackButton({super.key, required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: kMinInteractiveDimension,
    child: IconButton(
      tooltip: 'Back',
      padding: EdgeInsets.zero,
      onPressed: onPressed,
      icon: AppIcon(
        AppIcons.arrowBack,
        size: context.getRSize(22),
        color: Theme.of(context).colorScheme.onSurface,
      ),
    ),
  );
}

/// "Sell on Reebaplus" — the way into today's Welcome screen. Always
/// tappable (offline too). Short "Sell" label under 380dp so the header never crowds.
class SellOnReebaplusButton extends StatelessWidget {
  const SellOnReebaplusButton({super.key, required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final compact = context.screenWidth < 380;
    final label = Text(
      'Sell on Reebaplus',
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: context.boldStyle(13).copyWith(color: t.colorScheme.primary),
    );
    final icon = AppIcon(
      AppIcons.store,
      filled: true,
      size: context.getRSize(20),
      color: t.colorScheme.primary,
    );
    return Semantics(
      button: true,
      label: compact ? 'Sell on Reebaplus' : null,
      child: InkWell(
        key: const Key('browse-sell-on-reebaplus'),
        customBorder: const StadiumBorder(),
        onTap: onPressed,
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            minHeight: kMinInteractiveDimension,
            minWidth: kMinInteractiveDimension,
          ),
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: context.getRSize(8)),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                icon,
                if (!compact) ...[
                  SizedBox(width: context.getRSize(6)),
                  label,
                ] else ...[
                  SizedBox(width: context.getRSize(4)),
                  Text(
                    'Sell',
                    style: context
                        .boldStyle(13)
                        .copyWith(color: t.colorScheme.primary),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// "Delivering to Keffi, Nasarawa · Change".
class BrowseAreaRow extends StatelessWidget {
  const BrowseAreaRow({super.key, required this.label, required this.onChange});

  final String label;
  final VoidCallback onChange;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    return InkWell(
      key: const Key('browse-change-area'),
      borderRadius: BorderRadius.circular(AppSpacing.borderRadiusL),
      onTap: onChange,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: kMinInteractiveDimension),
        child: Row(
          children: [
            AppIcon(
              AppIcons.location,
              filled: true,
              size: context.getRSize(20),
              color: t.colorScheme.primary,
            ),
            SizedBox(width: context.getRSize(8)),
            Flexible(
              child: Text.rich(
                TextSpan(
                  children: [
                    TextSpan(
                      text: 'Delivering to ',
                      style: context.regularStyle(13).copyWith(color: muted),
                    ),
                    TextSpan(
                      text: label,
                      style: context
                          .boldStyle(13)
                          .copyWith(color: t.colorScheme.onSurface),
                    ),
                  ],
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            SizedBox(width: context.getRSize(8)),
            Text(
              'Change',
              style: context.boldStyle(13).copyWith(color: t.colorScheme.primary),
            ),
          ],
        ),
      ),
    );
  }
}

/// The Reebaplus category chips: "All" first, "Other" last.
class BrowseCategoryBar extends StatelessWidget {
  const BrowseCategoryBar({
    super.key,
    required this.selected,
    required this.onSelected,
  });

  final String? selected;
  final ValueChanged<String?> onSelected;

  @override
  Widget build(BuildContext context) {
    final categories = browseFilterCategories();
    return SizedBox(
      height: kMinInteractiveDimension,
      child: ListView(
        key: const Key('browse-category-bar'),
        scrollDirection: Axis.horizontal,
        children: [
          CategoryChip(
            label: 'All',
            selected: selected == null,
            onTap: () => onSelected(null),
          ),
          for (final c in categories) ...[
            SizedBox(width: context.getRSize(8)),
            CategoryChip(
              key: ValueKey('browse-category-${c.slug}'),
              label: c.name,
              categoryName: c.name,
              selected: selected == c.slug,
              onTap: () => onSelected(c.slug),
            ),
          ],
        ],
      ),
    );
  }
}

/// A centred icon, title, text and optional buttons (offline, empty, error).
class BrowseMessage extends StatelessWidget {
  const BrowseMessage({
    super.key,
    required this.icon,
    required this.title,
    this.text,
    this.actionLabel,
    this.onAction,
    this.secondaryLabel,
    this.onSecondary,
    this.tone = IconTileTone.info,
  });

  final IconData icon;
  final String title;
  final String? text;
  final String? actionLabel;
  final VoidCallback? onAction;
  final String? secondaryLabel;
  final VoidCallback? onSecondary;
  final IconTileTone tone;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: context.getRSize(16),
            vertical: context.getRSize(24),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconTile(icon: icon, tone: tone, size: context.getRSize(56)),
              SizedBox(height: context.getRSize(14)),
              Text(
                title,
                textAlign: TextAlign.center,
                style: context
                    .extraBoldStyle(17)
                    .copyWith(color: t.colorScheme.onSurface),
              ),
              if (text != null) ...[
                SizedBox(height: context.getRSize(6)),
                Text(
                  text!,
                  textAlign: TextAlign.center,
                  style: context.regularStyle(14).copyWith(color: muted),
                ),
              ],
              if (actionLabel != null && onAction != null) ...[
                SizedBox(height: context.getRSize(18)),
                AppButton(
                  text: actionLabel!,
                  onPressed: onAction,
                  isFullWidth: false,
                ),
              ],
              if (secondaryLabel != null && onSecondary != null) ...[
                SizedBox(height: context.getRSize(8)),
                AppButton(
                  text: secondaryLabel!,
                  onPressed: onSecondary,
                  variant: AppButtonVariant.ghost,
                  isFullWidth: false,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// One product card (#425): photo, 18+ mark, name, unit, price in the store's
/// currency, stock label, crate-deposit note, "Business · LGA" (opens the
/// store page) and the stale-stock note. Out of stock is greyed. Tapping
/// opens the product sheet, where the Shopper adds it to the cart (#426).
class StorefrontCardTile extends StatelessWidget {
  const StorefrontCardTile({super.key, required this.card, this.onOpenStore});

  final StorefrontCard card;

  /// Null on the store page itself (the seller is already open).
  final VoidCallback? onOpenStore;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final f = t.extension<AppFixedColors>() ?? AppFixedColors.light;
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    final visual = categoryVisual(_categoryName(card.category), f);
    final out = !card.orderable;

    final (Color pillFill, Color pillDot) = switch (card.stock) {
      StorefrontStock.inStock => (f.greenTint, f.greenDot),
      StorefrontStock.lowStock ||
      StorefrontStock.onlyFewLeft => (f.warningTint, f.warning),
      StorefrontStock.outOfStock => (f.dangerTint, f.danger),
    };

    final fallback = Center(
      child: AppIcon(
        visual.icon,
        filled: true,
        size: context.getRSize(36),
        color: visual.iconColor,
      ),
    );
    final url = card.imageUrl;
    final art = ClipRRect(
      borderRadius: BorderRadius.circular(AppSpacing.borderRadiusL),
      child: ColoredBox(
        color: visual.tint,
        child: url == null
            ? fallback
            // Public product-photo URL (#500): a plain HTTP GET, never the
            // member-only authenticated Storage download.
            : Image.network(
                url,
                fit: BoxFit.cover,
                width: double.infinity,
                height: double.infinity,
                errorBuilder: (_, __, ___) => fallback,
              ),
      ),
    );

    final unitText = _unitText(card);
    final deposit = card.crateDepositKobo;

    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Stack(
            children: [
              Positioned.fill(child: art),
              if (card.ageRestricted)
                Positioned(
                  top: context.getRSize(6),
                  left: context.getRSize(6),
                  child: const TagPill(label: '18+', tone: TagPillTone.danger),
                ),
            ],
          ),
        ),
        SizedBox(height: context.getRSize(8)),
        if (card.brand != null)
          Text(
            card.brand!,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: context.semiBoldStyle(11).copyWith(color: muted),
          ),
        Text(
          card.name,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: context.boldStyle(15).copyWith(color: t.colorScheme.onSurface),
        ),
        if (unitText != null)
          Text(
            unitText,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: context.regularStyle(12).copyWith(color: muted),
          ),
        SizedBox(height: context.getRSize(6)),
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(
            formatCurrencyIn(card.priceKobo / 100, card.currency),
            maxLines: 1,
            style: context.boldStyle(16).copyWith(color: t.colorScheme.primary),
          ),
        ),
        SizedBox(height: context.getRSize(4)),
        Container(
          key: ValueKey('browse-stock-${card.productId}'),
          padding: EdgeInsets.symmetric(
            horizontal: context.getRSize(8),
            vertical: context.getRSize(3),
          ),
          decoration: ShapeDecoration(color: pillFill, shape: const StadiumBorder()),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: context.getRSize(7),
                height: context.getRSize(7),
                decoration: BoxDecoration(color: pillDot, shape: BoxShape.circle),
              ),
              SizedBox(width: context.getRSize(4)),
              Text(
                card.stockText,
                maxLines: 1,
                softWrap: false,
                style: context.boldStyle(12).copyWith(color: t.colorScheme.onSurface),
              ),
            ],
          ),
        ),
        if (deposit != null) ...[
          SizedBox(height: context.getRSize(4)),
          Text(
            '+ ${formatCurrencyIn(deposit / 100, card.currency)} deposit per crate '
            'if no empties are returned',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: context.regularStyle(11).copyWith(color: muted),
          ),
        ],
        if (card.stockMayBeStale) ...[
          SizedBox(height: context.getRSize(4)),
          Text(
            'Stock may be out of date',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: context.semiBoldStyle(11).copyWith(color: f.warning),
          ),
        ],
        _SellerLink(label: card.sellerLabel, onTap: onOpenStore),
      ],
    );

    return Semantics(
      container: true,
      enabled: !out,
      label: out ? '${card.name}, out of stock' : card.name,
      child: Container(
        key: ValueKey('browse-card-${card.productId}'),
        decoration: AppDecorations.card(context),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            borderRadius: BorderRadius.circular(AppSpacing.borderRadiusXL),
            onTap: () => showStorefrontProductSheet(
              context,
              card: card,
              onOpenStore: onOpenStore,
            ),
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                context.getRSize(10),
                context.getRSize(10),
                context.getRSize(10),
                context.getRSize(2),
              ),
              child: Opacity(opacity: out ? 0.5 : 1, child: body),
            ),
          ),
        ),
      ),
    );
  }

  static String? _unitText(StorefrontCard card) {
    final unit = card.unit?.trim();
    if (unit == null || unit.isEmpty) return null;
    final pack = card.unitsPerPack;
    return pack == null ? unit : '$unit of $pack';
  }
}

class _SellerLink extends StatelessWidget {
  const _SellerLink({required this.label, this.onTap});

  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    final color = onTap == null ? muted : t.colorScheme.primary;
    final row = Row(
      children: [
        AppIcon(
          AppIcons.storefront,
          size: context.getRSize(14),
          color: color,
        ),
        SizedBox(width: context.getRSize(4)),
        Expanded(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: context.semiBoldStyle(12).copyWith(color: color),
          ),
        ),
      ],
    );
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppSpacing.borderRadiusS),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: kMinInteractiveDimension),
        child: Align(alignment: Alignment.centerLeft, child: row),
      ),
    );
  }
}

/// A grid of cards, centred and capped, with a loading row at the end.
class BrowseCardGrid extends StatelessWidget {
  const BrowseCardGrid({
    super.key,
    required this.cards,
    required this.onOpenStore,
  });

  final List<StorefrontCard> cards;

  /// Null on the store page.
  final void Function(StorefrontCard card)? onOpenStore;

  @override
  Widget build(BuildContext context) {
    return SliverLayoutBuilder(
      builder: (context, c) {
        final gutter = browseGutter(context, c.crossAxisExtent);
        final width = c.crossAxisExtent - gutter * 2;
        return SliverPadding(
          padding: EdgeInsets.symmetric(horizontal: gutter),
          sliver: SliverGrid(
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: browseColumnsFor(width),
              mainAxisExtent: browseTileExtent(context),
              crossAxisSpacing: context.getRSize(12),
              mainAxisSpacing: context.getRSize(12),
            ),
            delegate: SliverChildBuilderDelegate(
              (context, i) {
                final card = cards[i];
                final open = onOpenStore;
                return StorefrontCardTile(
                  card: card,
                  onOpenStore: open == null ? null : () => open(card),
                );
              },
              childCount: cards.length,
            ),
          ),
        );
      },
    );
  }
}

/// The slivers for one storefront list: loading, offline, failed, empty, or
/// the card grid with a loading row while the next page arrives.
List<Widget> browseListSlivers(
  BuildContext context, {
  required StorefrontListState state,
  required VoidCallback onRetry,
  required Widget empty,
  void Function(StorefrontCard card)? onOpenStore,
}) {
  final bottom = context.getRSize(24) + context.deviceBottomPadding;
  // A message scrolls with the header (a landscape phone has little room).
  Widget fill(Widget child) => SliverPadding(
    padding: EdgeInsets.only(bottom: bottom),
    sliver: SliverToBoxAdapter(child: child),
  );
  switch (state.status) {
    case StorefrontListStatus.loading:
      return [
        fill(
          const Center(
            key: Key('browse-loading'),
            child: CircularProgressIndicator(),
          ),
        ),
      ];
    case StorefrontListStatus.offline:
      return [
        fill(
          BrowseMessage(
            key: const Key('browse-offline'),
            icon: AppIcons.cloudOff,
            tone: IconTileTone.warning,
            title: 'Connect to the internet to browse',
            text: 'Browsing shops needs a connection. You can still set up '
                'your own business with Sell on Reebaplus.',
            actionLabel: 'Try again',
            onAction: onRetry,
          ),
        ),
      ];
    case StorefrontListStatus.failed:
      return [
        fill(
          BrowseMessage(
            key: const Key('browse-failed'),
            icon: AppIcons.warning,
            tone: IconTileTone.warning,
            title: "Couldn't load products",
            text: 'Something went wrong on our side. Please try again.',
            actionLabel: 'Try again',
            onAction: onRetry,
          ),
        ),
      ];
    case StorefrontListStatus.ready:
      if (state.cards.isEmpty) return [fill(empty)];
      return [
        BrowseCardGrid(cards: state.cards, onOpenStore: onOpenStore),
        SliverPadding(
          padding: EdgeInsets.only(top: context.getRSize(12), bottom: bottom),
          sliver: SliverToBoxAdapter(
            child: state.loadingMore
                ? const Center(child: CircularProgressIndicator())
                : const SizedBox.shrink(),
          ),
        ),
      ];
  }
}

/// Product details (#425 + #473 listing content): photo, brand, name, the
/// shop's online description, unit, price, stock, deposit and the order
/// quantity rule, plus quantity + Add to cart (#426).
Future<void> showStorefrontProductSheet(
  BuildContext context, {
  required StorefrontCard card,
  VoidCallback? onOpenStore,
}) => showModalBottomSheet<void>(
  context: context,
  useSafeArea: true,
  isScrollControlled: true,
  constraints: const BoxConstraints(maxWidth: 640),
  builder: (sheetContext) => _ProductSheet(
    card: card,
    onOpenStore: onOpenStore == null
        ? null
        : () {
            Navigator.of(sheetContext).pop();
            onOpenStore();
          },
  ),
);

class _ProductSheet extends ConsumerWidget {
  const _ProductSheet({required this.card, this.onOpenStore});

  final StorefrontCard card;
  final VoidCallback? onOpenStore;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    final f = t.extension<AppFixedColors>() ?? AppFixedColors.light;
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    final visual = categoryVisual(_categoryName(card.category), f);
    final url = card.imageUrl;
    final fallback = Center(
      child: AppIcon(visual.icon, filled: true, size: context.getRSize(48),
          color: visual.iconColor),
    );
    final unit = StorefrontCardTile._unitText(card);
    final rule = card.orderRuleText;
    final deposit = card.crateDepositKobo;
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: context.screenHeight * 0.9),
      child: SingleChildScrollView(
        key: const Key('browse-product-sheet'),
        padding: EdgeInsets.fromLTRB(
          context.getRSize(16),
          context.getRSize(16),
          context.getRSize(16),
          context.getRSize(16) + context.deviceBottomPadding,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    card.sellerLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.semiBoldStyle(13).copyWith(color: muted),
                  ),
                ),
                SizedBox.square(
                  dimension: kMinInteractiveDimension,
                  child: IconButton(
                    tooltip: 'Close',
                    onPressed: () => Navigator.of(context).pop(),
                    icon: AppIcon(AppIcons.close, size: context.getRSize(22),
                        color: t.colorScheme.onSurface),
                  ),
                ),
              ],
            ),
            ClipRRect(
              borderRadius: BorderRadius.circular(AppSpacing.borderRadiusL),
              child: ColoredBox(
                color: visual.tint,
                // #474: swipeable gallery, cover first; the card's cover
                // while the photo list loads or if it fails.
                child: ProductPhotoGallery(
                  height: context.getRSize(180),
                  photos: ref.watch(storefrontProductPhotosProvider((
                        storeId: card.storeId,
                        productId: card.productId,
                      ))).valueOrNull?.nonEmptyOrNull ??
                      [?url],
                  placeholder: fallback,
                  photoBuilder: (_, photo) => Image.network(photo,
                      fit: BoxFit.cover,
                      width: double.infinity,
                      errorBuilder: (_, __, ___) => fallback),
                ),
              ),
            ),
            SizedBox(height: context.getRSize(12)),
            if (card.brand != null)
              Text(card.brand!,
                  style: context.semiBoldStyle(13).copyWith(color: muted)),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(card.name,
                      style: context.extraBoldStyle(19)
                          .copyWith(color: t.colorScheme.onSurface)),
                ),
                if (card.ageRestricted)
                  const TagPill(label: '18+', tone: TagPillTone.danger),
              ],
            ),
            if (unit != null)
              Text(unit, style: context.regularStyle(13).copyWith(color: muted)),
            SizedBox(height: context.getRSize(8)),
            Text(
              formatCurrencyIn(card.priceKobo / 100, card.currency),
              style: context.boldStyle(20).copyWith(color: t.colorScheme.primary),
            ),
            SizedBox(height: context.getRSize(4)),
            Text(card.stockText,
                style: context.semiBoldStyle(13)
                    .copyWith(color: card.orderable ? t.colorScheme.onSurface : f.danger)),
            if (card.stockMayBeStale)
              Text('Stock may be out of date',
                  style: context.semiBoldStyle(12).copyWith(color: f.warning)),
            if (deposit != null)
              Text(
                '+ ${formatCurrencyIn(deposit / 100, card.currency)} deposit per crate '
                'if no empties are returned',
                style: context.regularStyle(12).copyWith(color: muted),
              ),
            if (rule != null) ...[
              SizedBox(height: context.getRSize(4)),
              Text(rule, key: const Key('browse-order-rule'),
                  style: context.regularStyle(12).copyWith(color: muted)),
            ],
            if (card.onlineDescription != null) ...[
              SizedBox(height: context.getRSize(12)),
              Text(card.onlineDescription!,
                  key: const Key('browse-product-description'),
                  style: context.regularStyle(14)
                      .copyWith(color: t.colorScheme.onSurface)),
            ],
            if (card.orderable) ...[
              SizedBox(height: context.getRSize(16)),
              AddToCartBox(
                card: card,
                onAdded: () {
                  AppNotification.showSuccess(context, 'Added to your cart');
                  Navigator.of(context).pop();
                },
              ),
            ],
            if (onOpenStore != null) ...[
              SizedBox(height: context.getRSize(16)),
              AppButton(
                text: 'See this store',
                icon: AppIcons.storefront,
                variant: AppButtonVariant.outline,
                onPressed: onOpenStore,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

extension on List<String> {
  List<String>? get nonEmptyOrNull => isEmpty ? null : this;
}
