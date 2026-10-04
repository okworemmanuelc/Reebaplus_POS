import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:reebaplus_pos/core/theme/scheme_colors.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';

/// Slide-in panel width as a share of the screen, and its cap (logical px; a
/// panel's width is a share of the window, not a scaled spacing value).
/// 460 matches `tablet-cart-panel-*.png` at 800 wide.
const double _kSlideInShare = 0.6;
const double _kSlideInMax = 460.0;

/// Fixed panel width as a share of the screen, and its bounds. 384 at 1280
/// wide, close to `wide-pos-cart-*.png`.
const double _kFixedShare = 0.3;
const double _kFixedMin = 360.0;
const double _kFixedMax = 440.0;

/// Width of the cart panel at the current size (#352): fixed on the right at
/// 1024dp+, sliding in from the right at 600–1023dp.
double cartPanelWidth(BuildContext context) {
  final w = context.screenWidth;
  if (context.isWideLayout) {
    return (w * _kFixedShare).clamp(_kFixedMin, _kFixedMax);
  }
  return math.min(w * _kSlideInShare, _kSlideInMax);
}

/// The container that hosts the cart on POS at 600dp+ (#352).
///
/// It only frames [child] — the existing Cart screen, whose own header carries
/// the panel's ✕ (`CartScreen.onClosePanel`); the rest of its restyle is Wave
/// 1's Cart agent: solid Surface, the slide-in panel shadow and a hairline edge
/// on the left.
///
/// The panel sits at the right edge of the screen, so it owns the right system
/// inset (a landscape navigation bar): its Surface extends under the inset,
/// while the Cart screen is laid out beside it. The top inset is left to the
/// Cart screen's own app bar, which pads for the status bar exactly once.
class CartPanel extends StatelessWidget {
  const CartPanel({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final scheme = t.extension<AppSchemeColors>();
    final rightInset = MediaQuery.paddingOf(context).right;
    return Container(
      key: const Key('cart-panel'),
      width: cartPanelWidth(context) + rightInset,
      decoration: BoxDecoration(
        color: t.colorScheme.surface,
        border: Border(left: BorderSide(color: t.dividerColor)),
        boxShadow: [
          if (scheme != null)
            BoxShadow(
              color: scheme.panelShadow,
              blurRadius: 24,
              offset: const Offset(-4, 0),
            ),
        ],
      ),
      child: Padding(
        padding: EdgeInsets.only(right: rightInset),
        child: MediaQuery.removePadding(
          context: context,
          removeLeft: true,
          removeRight: true,
          child: child,
        ),
      ),
    );
  }
}

/// The ✕ that hides the cart panel, placed at the end of the hosted Cart
/// screen's header (#352). A full 48dp tap target.
class CartPanelCloseButton extends StatelessWidget {
  const CartPanelCloseButton({super.key, required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(right: context.getRSize(4)),
      child: IconButton(
        key: const Key('cart-panel-close'),
        tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
        constraints: const BoxConstraints(
          minWidth: kMinInteractiveDimension,
          minHeight: kMinInteractiveDimension,
        ),
        icon: AppIcon(
          AppIcons.close,
          size: context.getRSize(22),
          color: Theme.of(context).colorScheme.onSurface,
        ),
        onPressed: onPressed,
      ),
    );
  }
}

/// The dim behind the slide-in cart panel (`AppSchemeColors.scrim`). Tapping
/// it closes the panel.
class CartPanelScrim extends StatelessWidget {
  const CartPanelScrim({super.key, required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final scrim =
        t.extension<AppSchemeColors>()?.scrim ??
        t.colorScheme.scrim.withValues(alpha: 0.35);
    return Semantics(
      label: MaterialLocalizations.of(context).modalBarrierDismissLabel,
      button: true,
      child: GestureDetector(
        key: const Key('cart-panel-scrim'),
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: ColoredBox(color: scrim),
      ),
    );
  }
}
