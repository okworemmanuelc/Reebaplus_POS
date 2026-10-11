import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:reebaplus_pos/core/theme/design_tokens.dart';
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
/// It only frames [child] — the Cart screen, whose own header carries the
/// panel's ✕ (`CartScreen.onClosePanel`). The frame is a solid Surface with a
/// hairline edge on the left; the slide-in panel also casts
/// `AppSchemeColors.panelShadow` over the dimmed grid, while the fixed panel
/// sits flat beside POS behind its hairline (`wide-pos-cart-*.png`, #385).
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
          if (scheme != null && !context.isWideLayout)
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
/// screen's header (#352): a square outlined button (hairline border on
/// Surface, #385) inside a full 48dp tap target.
class CartPanelCloseButton extends StatelessWidget {
  const CartPanelCloseButton({super.key, required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final square = math.min(context.getRSize(40), kMinInteractiveDimension);
    final radius = BorderRadius.circular(AppSpacing.borderRadiusM);
    return Tooltip(
      message: MaterialLocalizations.of(context).closeButtonTooltip,
      child: Semantics(
        button: true,
        child: InkWell(
          key: const Key('cart-panel-close'),
          onTap: onPressed,
          borderRadius: radius,
          child: SizedBox.square(
            dimension: kMinInteractiveDimension,
            child: Center(
              child: Container(
                width: square,
                height: square,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: t.colorScheme.surface,
                  borderRadius: radius,
                  border: Border.all(color: t.dividerColor),
                ),
                child: AppIcon(
                  AppIcons.close,
                  size: context.getRSize(20),
                  color: t.colorScheme.onSurface,
                ),
              ),
            ),
          ),
        ),
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
