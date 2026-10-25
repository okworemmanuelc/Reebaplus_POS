import 'package:flutter/material.dart';

import 'package:reebaplus_pos/core/theme/app_decorations.dart';
import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/features/browse/widgets/browse_parts.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/redesign.dart';

// Shared parts of the Shopper screens (#426): cart, sign-in, details, place
// order, My Orders. No Claude Design files exist in the repo for these
// screens; they follow ui-context tokens and Browse's shared parts.

/// Widest a Shopper form / list column grows on a tablet.
const double kShopperMaxContentWidth = 640;

/// A pushed Shopper page: Browse's solid top bar with a back button, the page
/// background, and a centred, capped content column.
class ShopperPage extends StatelessWidget {
  const ShopperPage({
    super.key,
    required this.icon,
    required this.title,
    required this.body,
    this.subtitle,
    this.actions = const [],
    this.bottom,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final List<Widget> actions;
  final Widget body;

  /// A pinned bar under the content (e.g. the Place order button).
  final Widget? bottom;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: AppDecorations.pageBackground(context),
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: BrowseTopBar(
          height: BrowseTopBar.heightFor(context),
          header: ScreenHeader(
            leading: BrowseBackButton(
              onPressed: () => Navigator.maybePop(context),
            ),
            icon: icon,
            title: title,
            subtitle: subtitle,
            actions: actions,
          ),
        ),
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              maxWidth: kShopperMaxContentWidth,
            ),
            child: body,
          ),
        ),
        // The pinned bar steps aside while the keyboard is up, so the field
        // being typed in keeps the room (a landscape phone has very little).
        bottomNavigationBar:
            bottom == null || MediaQuery.viewInsetsOf(context).bottom > 0
            ? null
            : ShopperBottomBar(child: bottom!),
      ),
    );
  }
}

/// A solid bar pinned to the bottom, above the system inset.
class ShopperBottomBar extends StatelessWidget {
  const ShopperBottomBar({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Container(
      decoration: BoxDecoration(
        color: t.colorScheme.surface,
        border: Border(top: BorderSide(color: t.dividerColor, width: 1)),
      ),
      padding: EdgeInsets.fromLTRB(
        context.getRSize(16),
        context.getRSize(10),
        context.getRSize(16),
        context.getRSize(10) + context.deviceBottomPadding,
      ),
      child: Center(
        heightFactor: 1,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: kShopperMaxContentWidth),
          child: child,
        ),
      ),
    );
  }
}

/// A plain card section with an optional title.
class ShopperSection extends StatelessWidget {
  const ShopperSection({super.key, this.title, required this.child});

  final String? title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Container(
      margin: EdgeInsets.only(bottom: context.getRSize(12)),
      padding: EdgeInsets.all(context.getRSize(14)),
      decoration: AppDecorations.card(context),
      // Its own Material so list tiles inside keep their ink on the card.
      child: Material(
        type: MaterialType.transparency,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (title != null) ...[
              Text(
                title!,
                style: context
                    .boldStyle(15)
                    .copyWith(color: t.colorScheme.onSurface),
              ),
              SizedBox(height: context.getRSize(8)),
            ],
            child,
          ],
        ),
      ),
    );
  }
}

/// A 48dp icon button for the Browse top bar, with an optional count badge.
class ShopperBarButton extends StatelessWidget {
  const ShopperBarButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.count = 0,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;
  final int count;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return SizedBox.square(
      dimension: kMinInteractiveDimension,
      child: IconButton(
        tooltip: tooltip,
        padding: EdgeInsets.zero,
        onPressed: onPressed,
        icon: Badge(
          isLabelVisible: count > 0,
          label: Text('$count'),
          backgroundColor: t.colorScheme.primary,
          textColor: t.colorScheme.onPrimary,
          child: AppIcon(
            icon,
            size: context.getRSize(22),
            color: t.colorScheme.onSurface,
          ),
        ),
      ),
    );
  }
}
