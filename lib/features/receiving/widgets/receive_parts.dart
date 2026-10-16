import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/theme/design_tokens.dart';
import 'package:reebaplus_pos/core/theme/fixed_colors.dart';
import 'package:reebaplus_pos/core/theme/scheme_colors.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/screen_header.dart';

/// Screen height (after the top and bottom system insets) under which the
/// Receive Stock tile art shrinks so a full row of tiles shows on first view —
/// a sideways phone. The same measured rule as POS's `kPosShortHeight` (#384),
/// never `isShortViewport` (PRD #239); the keyboard never flips it.
const double kReceiveShortHeight = 480;

/// Whether this screen is short enough to compact the tiles
/// ([kReceiveShortHeight]).
bool receiveShortHeight(BuildContext context) {
  final mq = MediaQuery.of(context);
  return mq.size.height - mq.padding.vertical < kReceiveShortHeight;
}

/// The receiving top bars' height (#394): the theme's 68dp, grown when the
/// scaled header tile or a 48dp control would touch its edges, shrunk with the
/// scale on a short sideways phone — POS's `posTopBarHeight` rule, repeated
/// here because a feature never reaches into another feature's widgets.
/// Shared-part candidate (Home, POS, CEO Settings and Receiving each carry
/// one).
double receiveTopBarHeight(BuildContext context) => math.max(
  math.min(kToolbarHeight + 12, context.getRSize(kToolbarHeight + 12)),
  math.max(context.getRSize(44), kMinInteractiveDimension) +
      context.getRSize(16),
);

/// The solid receiving top bar (#394): `colorScheme.surface`, a hairline at
/// the bottom and the soft `topBarShadow`, never changing on scroll, with the
/// shared [ScreenHeader]. The back arrow shows exactly when the route implies
/// one (the screens are pushed), as the plain `AppBar` did before. Copy of
/// CEO Settings' / POS's bar; shared-part candidate.
class ReceiveTopBar extends StatelessWidget implements PreferredSizeWidget {
  const ReceiveTopBar({
    super.key,
    required this.height,
    required this.icon,
    required this.title,
    this.subtitle,
    this.actions = const [],
  });

  final double height;
  final IconData icon;
  final String title;
  final String? subtitle;
  final List<Widget> actions;

  @override
  Size get preferredSize => Size.fromHeight(height);

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final topBarShadow =
        t.extension<AppSchemeColors>()?.topBarShadow ?? Colors.transparent;
    final canGoBack = ModalRoute.of(context)?.impliesAppBarDismissal ?? false;
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
            BoxShadow(
              color: topBarShadow,
              blurRadius: 4,
              offset: const Offset(0, 1),
            ),
          ],
        ),
      ),
      title: ScreenHeader(
        icon: icon,
        title: title,
        subtitle: subtitle,
        leading: canGoBack
            ? IconButton(
                key: ReceiveKeys.back,
                tooltip: MaterialLocalizations.of(context).backButtonTooltip,
                constraints: const BoxConstraints(
                  minWidth: kMinInteractiveDimension,
                  minHeight: kMinInteractiveDimension,
                ),
                onPressed: () => Navigator.of(context).maybePop(),
                icon: AppIcon(
                  AppIcons.arrowBack,
                  size: context.getRSize(24),
                  color: t.colorScheme.onSurface,
                ),
              )
            : null,
        actions: actions,
      ),
    );
  }
}

/// A 48dp icon action for a [ReceiveTopBar] (Receive Stock's search toggle).
class ReceiveTopBarAction extends StatelessWidget {
  const ReceiveTopBarAction({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return IconButton(
      tooltip: tooltip,
      constraints: const BoxConstraints(
        minWidth: kMinInteractiveDimension,
        minHeight: kMinInteractiveDimension,
      ),
      onPressed: onPressed,
      icon: AppIcon(
        icon,
        size: context.getRSize(22),
        color: t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface,
      ),
    );
  }
}

/// Keys on the receiving screens' controls, for tests.
abstract final class ReceiveKeys {
  static const back = Key('receive-back');
  static const searchToggle = Key('receive-search-toggle');
  static const search = Key('receive-search');
  static const hint = Key('receive-hint');
  static const scroll = Key('receive-scroll');
  static const reviewBar = Key('receive-review-bar');
  static const newProduct = Key('receive-new-product');
  static const clear = Key('receive-clear');
  static const cartList = Key('receive-cart-list');
  static const cartFooter = Key('receive-cart-footer');
  static const continueButton = Key('receive-continue');
  static const checkoutScroll = Key('receive-checkout-scroll');
  static const confirmButton = Key('receive-confirm');
  static const supplierField = Key('receive-supplier-field');
  static const supplierClear = Key('receive-supplier-clear');
  static const dateField = Key('receive-date-field');
  static const paymentMethod = Key('receive-payment-method');
  static const editSheet = Key('receive-edit-sheet');
  static const editClose = Key('receive-edit-close');
  static const editMinus = Key('receive-edit-minus');
  static const editPlus = Key('receive-edit-plus');
  static const supplierSheet = Key('receive-supplier-sheet');
}

/// The key on the receive cart's line for [productId] (#394).
ValueKey<String> receiveCartLineKey(String productId) =>
    ValueKey<String>('receive-cart-line-$productId');

/// The key on the supplier picker's row for [supplierId] (#394).
ValueKey<String> receiveSupplierRowKey(String supplierId) =>
    ValueKey<String>('receive-supplier-$supplierId');

/// The widest the receive cart and checkout content gets (#394, the
/// batch-wide list / form cap): `kSettingsMaxContentWidth`'s 720dp, as CEO
/// Settings and Inventory → Manufacturers use it. Repeated as a value because a
/// feature does not import another feature's screen.
const double kReceiveMaxContentWidth = 720;

/// The widest a receiving bottom sheet gets (#394): 640dp, centred.
const double kReceiveSheetMaxWidth = 640;

/// Side padding that keeps content [width] dp wide within
/// [kReceiveMaxContentWidth], centred, never under the `getRSize(16)` gutter.
double receiveSidePadding(BuildContext context, double width) =>
    math.max(context.getRSize(16), (width - kReceiveMaxContentWidth) / 2);

/// The receive cart's red-tint "Clear" pill (#394): a copy of the Cart's
/// `CartClearButton` (a feature does not import another feature's widgets);
/// shared-part candidate. 48dp tap target.
class ReceiveClearButton extends StatelessWidget {
  const ReceiveClearButton({super.key, required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final f =
        Theme.of(context).extension<AppFixedColors>() ?? AppFixedColors.light;
    final radius = BorderRadius.circular(AppSpacing.borderRadiusM);
    return Semantics(
      button: true,
      child: InkWell(
        key: ReceiveKeys.clear,
        onTap: onPressed,
        borderRadius: radius,
        child: SizedBox(
          height: kMinInteractiveDimension,
          child: Center(
            child: Container(
              height: math.min(context.getRSize(40), kMinInteractiveDimension),
              // Tighter than the Cart's pill so "Receive Stock Cart" keeps
              // its whole title on a 390dp phone.
              padding: EdgeInsets.symmetric(horizontal: context.getRSize(8)),
              decoration: BoxDecoration(
                color: f.dangerTint,
                borderRadius: radius,
                border: Border.all(color: f.dangerOutline),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  AppIcon(
                    AppIcons.delete,
                    size: context.getRSize(16),
                    color: f.danger,
                  ),
                  SizedBox(width: context.getRSize(4)),
                  Text(
                    'Clear',
                    maxLines: 1,
                    style: context.boldStyle(14).copyWith(color: f.danger),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The hairline handle at the top of a receiving bottom sheet (40×4).
class ReceiveSheetHandle extends StatelessWidget {
  const ReceiveSheetHandle({super.key});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        width: context.getRSize(40),
        height: context.getRSize(4),
        decoration: BoxDecoration(
          color: Theme.of(context).dividerColor,
          borderRadius: BorderRadius.circular(AppSpacing.borderRadiusS),
        ),
      ),
    );
  }
}
