import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/settings/settings_screen.dart'
    show kSettingsMaxContentWidth;
import 'package:reebaplus_pos/core/theme/app_decorations.dart';
import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/theme/design_tokens.dart';
import 'package:reebaplus_pos/core/theme/fixed_colors.dart';
import 'package:reebaplus_pos/core/theme/scheme_colors.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/shared/widgets/notifications_modal.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/redesign.dart';

/// Keys for the Stores screens (#441, PRD #346 Wave 2 C).
abstract final class StoresKeys {
  static const topBar = ValueKey<String>('stores-top-bar');
  static const list = ValueKey<String>('stores-list');
  static const noAccess = ValueKey<String>('stores-no-access');
  static const empty = ValueKey<String>('stores-empty');
  static const sheetFrame = ValueKey<String>('stores-sheet-frame');
  static const detailsBody = ValueKey<String>('store-details-body');
  static const restricted = ValueKey<String>('store-details-restricted');
  static const settingsList = ValueKey<String>('stores-settings-list');
  static const detailsTopBar = ValueKey<String>('store-details-top-bar');
  static const storeValue = ValueKey<String>('store-details-value');
  static const customersTile = ValueKey<String>('store-details-customers');
  static const inventoryCard = ValueKey<String>('store-details-inventory');
  static const requestStock = ValueKey<String>('store-details-request');
  static const viewInventory = ValueKey<String>('store-details-view-inventory');
  static const transferHub = ValueKey<String>('store-transfer-hub');

  static Key card(String storeId) => ValueKey<String>('stores-card-$storeId');
  static Key edit(String storeId) =>
      ValueKey<String>('stores-card-edit-$storeId');
  static Key delete(String storeId) =>
      ValueKey<String>('stores-card-delete-$storeId');
}

/// Store Details' content cap: a fixed 960 (the Inventory and Customer detail
/// rule).
const double kStoreDetailsMaxContentWidth = 960;

/// The header cards sit side by side when the measured content width is at
/// least this (never a viewport predicate - PRD #239).
const double kStoreDetailsSideBySideWidth = 900;

/// Stores sheets cap at Material 3's 640.
const double kStoresSheetMaxWidth = 640;

/// The Stores top bar's height: CEO Settings' rule (#369). Repeated here
/// because a feature never reaches into another feature's widgets;
/// shared-part candidate (with `customerTopBarHeight`).
double storesTopBarHeight(BuildContext context) => math.max(
  kToolbarHeight + 12,
  math.max(context.getRSize(44), kMinInteractiveDimension) +
      context.getRSize(16),
);

/// Side gutter that centres a column of [cap] dp in [width] (the measured
/// width), never under `getRSize(16)`.
double storesGutter(BuildContext context, double width, {double? cap}) => math
    .max(context.getRSize(16), (width - (cap ?? kSettingsMaxContentWidth)) / 2);

/// Wraps [sliver] in the centred column, measured not predicated.
Widget storesSliver(
  Widget sliver, {
  double top = 0,
  double bottom = 0,
  double? cap,
}) => SliverLayoutBuilder(
  builder: (context, c) {
    final g = storesGutter(context, c.crossAxisExtent, cap: cap);
    return SliverPadding(
      padding: EdgeInsets.fromLTRB(g, top, g, bottom),
      sliver: sliver,
    );
  },
);

/// The solid top bar of the Stores screens: `colorScheme.surface`, a hairline
/// and the soft `topBarShadow`, never changing on scroll (PRD #346 decision
/// 4). [header] is the shared `ScreenHeader`. Shared-part candidate (a copy of
/// `CustomerTopBar`).
class StoresTopBar extends StatelessWidget implements PreferredSizeWidget {
  const StoresTopBar({super.key, required this.height, required this.header});

  final double height;
  final Widget header;

  @override
  Size get preferredSize => Size.fromHeight(height);

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final topBarShadow =
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
            BoxShadow(
              color: topBarShadow,
              blurRadius: 4,
              offset: const Offset(0, 1),
            ),
          ],
        ),
      ),
      title: header,
    );
  }
}

/// The live notification bell (a copy of Home's). Shared-part candidate.
class StoresLiveBell extends ConsumerWidget {
  const StoresLiveBell({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifService = ref.read(notificationProvider);
    return ValueListenableBuilder(
      valueListenable: notifService,
      builder: (context, _, _) => HeaderBell(
        count: notifService.unreadCount,
        onPressed: () => NotificationsModal.show(context),
      ),
    );
  }
}

/// A 48dp back arrow for the top bar. [onPressed] keeps the screen's own
/// behaviour (a plain pop on Store Details).
class StoresBackButton extends StatelessWidget {
  const StoresBackButton({super.key, required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
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
}

/// A centred, muted message (no access / nothing here yet).
class StoresMessage extends StatelessWidget {
  const StoresMessage({super.key, required this.text, this.title, this.icon});

  final String text;
  final String? title;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    return Center(
      child: Padding(
        padding: EdgeInsets.all(context.getRSize(32)),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              IconTile(icon: icon!, tone: IconTileTone.neutral, size: 64),
              SizedBox(height: context.getRSize(16)),
            ],
            if (title != null) ...[
              Text(
                title!,
                textAlign: TextAlign.center,
                style: context
                    .boldStyle(18)
                    .copyWith(color: t.colorScheme.onSurface),
              ),
              SizedBox(height: context.getRSize(6)),
            ],
            Text(
              text,
              textAlign: TextAlign.center,
              style: context
                  .regularStyle(14)
                  .copyWith(color: muted, height: 1.5),
            ),
          ],
        ),
      ),
    );
  }
}

/// A tinted notice card (info / warning / danger) with an icon and text.
class StoresNotice extends StatelessWidget {
  const StoresNotice({
    super.key,
    required this.text,
    this.tone = IconTileTone.info,
    this.icon = AppIcons.infoCircle,
  });

  final String text;
  final IconTileTone tone;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final f =
        Theme.of(context).extension<AppFixedColors>() ?? AppFixedColors.light;
    final (fill, ink) = tone.resolve(f);
    return Container(
      padding: EdgeInsets.all(context.getRSize(12)),
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(AppSpacing.borderRadiusL),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AppIcon(icon, size: context.getRSize(18), color: ink, filled: true),
          SizedBox(width: context.getRSize(10)),
          Expanded(
            child: Text(
              text,
              style: context
                  .semiBoldStyle(12)
                  .copyWith(color: ink, height: 1.4),
            ),
          ),
        ],
      ),
    );
  }
}

/// One figure of a store card: value over label.
class StoreFigure extends StatelessWidget {
  const StoreFigure({
    super.key,
    required this.icon,
    required this.tone,
    required this.value,
    required this.label,
  });

  final IconData icon;
  final IconTileTone tone;
  final String value;
  final String label;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    return Padding(
      padding: EdgeInsets.symmetric(
        vertical: context.getRSize(10),
        horizontal: context.getRSize(12),
      ),
      child: Row(
        children: [
          IconTile(icon: icon, tone: tone, size: 32),
          SizedBox(width: context.getRSize(10)),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: context
                      .boldStyle(15)
                      .copyWith(color: t.colorScheme.onSurface),
                ),
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: context.regularStyle(12).copyWith(color: muted),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A 48dp text action of a card (Edit / Delete).
class StoreCardAction extends StatelessWidget {
  const StoreCardAction({
    super.key,
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: kMinInteractiveDimension),
        child: Center(
          child: Padding(
            padding: EdgeInsets.symmetric(vertical: context.getRSize(8)),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                AppIcon(icon, size: context.getRSize(18), color: color),
                SizedBox(width: context.getRSize(6)),
                Text(
                  label,
                  style: context.boldStyle(14).copyWith(color: color),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A flat card shell with an optional tap (the whole card).
class StoresCardShell extends StatelessWidget {
  const StoresCardShell({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: AppDecorations.card(context),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AppSpacing.borderRadiusXL),
        child: child,
      ),
    );
  }
}

/// The frame of the Stores sheets: hairline handle, an [IconTile] + title
/// header, then [children]. One shrink-wrapped scroll view capped at 90% of
/// the screen height, with `deviceBottomPadding` below - so it scrolls with
/// the keyboard up. The theme draws the Surface and shape; open it with
/// [showStoresSheet]. Shared-part candidate (with `CustomerSheetFrame`).
class StoreSheetFrame extends StatelessWidget {
  const StoreSheetFrame({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    required this.children,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    final gutter = context.getRSize(20);
    return ConstrainedBox(
      key: StoresKeys.sheetFrame,
      constraints: BoxConstraints(maxHeight: context.screenHeight * 0.9),
      child: CustomScrollView(
        shrinkWrap: true,
        slivers: [
          SliverPadding(
            padding: EdgeInsets.fromLTRB(
              gutter,
              context.getRSize(12),
              gutter,
              context.getRSize(16) + context.deviceBottomPadding,
            ),
            sliver: SliverToBoxAdapter(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Center(
                    child: Container(
                      width: context.getRSize(40),
                      height: context.getRSize(4),
                      decoration: BoxDecoration(
                        color: t.dividerColor,
                        borderRadius: BorderRadius.circular(
                          AppSpacing.borderRadiusS,
                        ),
                      ),
                    ),
                  ),
                  SizedBox(height: context.getRSize(14)),
                  Row(
                    children: [
                      IconTile(icon: icon, size: 44),
                      SizedBox(width: context.getRSize(12)),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              title,
                              style: context.screenTitleStyle.copyWith(
                                color: t.colorScheme.onSurface,
                              ),
                            ),
                            if (subtitle != null)
                              Text(
                                subtitle!,
                                style: context
                                    .regularStyle(13)
                                    .copyWith(color: muted),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  SizedBox(height: context.getRSize(18)),
                  ...children,
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Opens a [StoreSheetFrame] sheet: the theme's surface, capped at
/// [kStoresSheetMaxWidth].
Future<T?> showStoresSheet<T>(BuildContext context, WidgetBuilder builder) =>
    showModalBottomSheet<T>(
      context: context,
      isScrollControlled: true,
      constraints: const BoxConstraints(maxWidth: kStoresSheetMaxWidth),
      builder: builder,
    );

/// A labelled autocomplete field (the Country picker): the label over an
/// `AppInput`, the options in a Surface card with 48dp rows.
class StoresAutocompleteField extends StatelessWidget {
  const StoresAutocompleteField({
    super.key,
    required this.label,
    required this.icon,
    required this.initial,
    required this.options,
    required this.onChanged,
    required this.fieldBuilder,
  });

  final String label;
  final IconData icon;
  final String initial;
  final List<String> options;
  final ValueChanged<String> onChanged;

  /// Builds the text field from the autocomplete's controller and focus node.
  final Widget Function(
    BuildContext context,
    TextEditingController controller,
    FocusNode focusNode,
    VoidCallback onSubmitted,
  )
  fieldBuilder;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label, style: context.boldStyle(12).copyWith(color: muted)),
        SizedBox(height: context.getRSize(8)),
        Autocomplete<String>(
          initialValue: TextEditingValue(text: initial),
          optionsBuilder: (value) {
            final q = value.text.trim().toLowerCase();
            if (q.isEmpty) return options;
            return options.where((o) => o.toLowerCase().contains(q));
          },
          onSelected: onChanged,
          fieldViewBuilder: (ctx, controller, focusNode, onSubmitted) =>
              fieldBuilder(ctx, controller, focusNode, onSubmitted),
          optionsViewBuilder: (ctx, onSelected, opts) {
            return Align(
              alignment: Alignment.topLeft,
              child: Material(
                color: t.colorScheme.surface,
                elevation: 4,
                borderRadius: BorderRadius.circular(AppSpacing.borderRadiusL),
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: context.getRSize(220),
                    maxWidth: 320,
                  ),
                  child: ListView(
                    padding: EdgeInsets.zero,
                    shrinkWrap: true,
                    children: [
                      for (final o in opts)
                        InkWell(
                          onTap: () => onSelected(o),
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(
                              minHeight: kMinInteractiveDimension,
                            ),
                            child: Padding(
                              padding: EdgeInsets.symmetric(
                                horizontal: context.getRSize(16),
                                vertical: context.getRSize(12),
                              ),
                              child: Text(
                                o,
                                style: context
                                    .regularStyle(14)
                                    .copyWith(color: t.colorScheme.onSurface),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ],
    );
  }
}

/// One figure tile of Store Details (Products / Low Stock / Customers): a
/// flat card with an [IconTile] over the value and its label. With [onTap]
/// the whole tile is tappable (the Customers tile).
class StoreStatTile extends StatelessWidget {
  const StoreStatTile({
    super.key,
    required this.icon,
    required this.tone,
    required this.label,
    required this.value,
    this.onTap,
  });

  final IconData icon;
  final IconTileTone tone;
  final String label;
  final String value;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    final content = Padding(
      padding: EdgeInsets.all(context.getRSize(14)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          IconTile(icon: icon, tone: tone, size: 40),
          SizedBox(height: context.getRSize(10)),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              value,
              maxLines: 1,
              style: context.extraBoldStyle(20).copyWith(
                color: t.colorScheme.onSurface,
              ),
            ),
          ),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: context.regularStyle(12).copyWith(color: muted),
          ),
        ],
      ),
    );
    return DecoratedBox(
      decoration: AppDecorations.card(context),
      child: onTap == null
          ? content
          : Material(
              type: MaterialType.transparency,
              child: InkWell(
                borderRadius: BorderRadius.circular(AppSpacing.borderRadiusXL),
                onTap: onTap,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(
                    minHeight: kMinInteractiveDimension,
                  ),
                  child: content,
                ),
              ),
            ),
    );
  }
}
