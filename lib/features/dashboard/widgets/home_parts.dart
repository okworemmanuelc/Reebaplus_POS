import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/theme/app_decorations.dart';
import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/theme/design_tokens.dart';
import 'package:reebaplus_pos/core/theme/fixed_colors.dart';
import 'package:reebaplus_pos/core/theme/scheme_colors.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/shared/widgets/notifications_modal.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/redesign.dart';

/// Test and layout keys for the Home screen (#374).
abstract final class HomeKeys {
  static const topBar = Key('home-top-bar');
  static const periodHeader = Key('home-period-header');
  static const periodPill = Key('home-period-pill');
  static const reportsPill = Key('home-reports-pill');
  static const reportsDot = Key('home-reports-dot');
  static const grid = Key('home-card-grid');
  static const sales = Key('home-card-sales');
  static const profit = Key('home-card-profit');
  static const pending = Key('home-card-pending');
  static const expenses = Key('home-card-expenses');
  static const stockValue = Key('home-card-stock-value');
  static const credits = Key('home-card-credits');
  static const creditsFull = Key('home-credits-full');
  static const creditsCompact = Key('home-credits-compact');
  static const skus = Key('home-card-skus');
  static const skuBreakdown = Key('home-sku-breakdown');
  static const staffSales = Key('home-staff-sales');
}

/// How many card columns Home uses (PRD #346, revised 2026-10-03), from the
/// width the cards really get (the rail and a cart panel already taken off):
/// 3 on a wide screen or a sideways screen at least 600dp wide, 2 on an
/// upright tablet (600–1023) or a narrower sideways phone, 1 on an upright
/// phone.
int homeGridColumns({required double width, required bool landscape}) {
  if (width >= kWideLayoutMinWidth) return 3;
  if (landscape && width >= kRailLayoutMinWidth) return 3;
  if (width >= kRailLayoutMinWidth) return 2;
  // A sideways phone under 600dp (no rail): one card per row would waste it.
  if (landscape && width >= 480) return 2;
  return 1;
}

/// The Home top bar: the solid surface bar (as CEO Settings, #369) with the
/// shared [ScreenHeader] — trending-up tile, business name, active store and
/// the live bell. [periodActions] (the period + Reports pills) sit before the
/// bell when the screen puts them in the bar (rail layout).
class HomeTopBar extends StatelessWidget implements PreferredSizeWidget {
  const HomeTopBar({
    super.key,
    required this.title,
    required this.storeLabel,
    required this.height,
    this.leading,
    this.periodActions = const [],
  });

  final String title;
  final String storeLabel;
  final double height;
  final Widget? leading;
  final List<Widget> periodActions;

  @override
  Size get preferredSize => Size.fromHeight(height);

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final topBarShadow =
        t.extension<AppSchemeColors>()?.topBarShadow ?? Colors.transparent;
    final gap = context.getRSize(10);
    return AppBar(
      key: HomeKeys.topBar,
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
        icon: AppIcons.analytics,
        title: title,
        subtitle: storeLabel,
        leading: leading,
        actions: [
          for (final a in periodActions) ...[SizedBox(width: gap), a],
          SizedBox(width: gap),
          const HomeLiveBell(),
        ],
      ),
    );
  }
}

/// The shared [HeaderBell] fed by the live notification service; a tap opens
/// the same notifications modal as the app's `NotificationBell`. (Same as CEO
/// Settings' bell — a shared-part candidate.)
class HomeLiveBell extends ConsumerWidget {
  const HomeLiveBell({super.key});

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

/// The "Today ⌄" outlined pill with a calendar icon. A tap opens the period
/// list; [onSelected] gets the chosen label (the caller handles "Custom").
class HomePeriodPill extends StatelessWidget {
  const HomePeriodPill({
    super.key,
    required this.label,
    required this.options,
    required this.onSelected,
  });

  final String label;
  final List<String> options;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    final radius = BorderRadius.circular(AppSpacing.borderRadiusL);
    return PopupMenuButton<String>(
      key: HomeKeys.periodPill,
      tooltip: 'Period',
      initialValue: options.contains(label) ? label : null,
      onSelected: onSelected,
      position: PopupMenuPosition.under,
      shape: RoundedRectangleBorder(borderRadius: radius),
      itemBuilder: (_) => [
        for (final p in options)
          PopupMenuItem<String>(
            value: p,
            child: Text(
              p,
              style: context
                  .mediumStyle(14)
                  .copyWith(color: t.colorScheme.onSurface),
            ),
          ),
      ],
      child: ConstrainedBox(
        constraints: const BoxConstraints(
          minHeight: kMinInteractiveDimension,
          minWidth: kMinInteractiveDimension,
        ),
        child: Container(
          padding: EdgeInsets.symmetric(horizontal: context.getRSize(14)),
          decoration: BoxDecoration(
            borderRadius: radius,
            border: Border.all(color: t.dividerColor, width: 1),
          ),
          child: LayoutBuilder(
            builder: (context, c) => Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                AppIcon(
                  AppIcons.calendar,
                  size: context.getRSize(20),
                  color: t.colorScheme.primary,
                ),
                SizedBox(width: context.getRSize(8)),
                _PillLabel(
                  text: label,
                  bounded: c.hasBoundedWidth,
                  style: context
                      .boldStyle(15)
                      .copyWith(color: t.colorScheme.onSurface),
                ),
                SizedBox(width: context.getRSize(6)),
                AppIcon(
                  AppIcons.chevronDown,
                  size: context.getRSize(20),
                  color: muted,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// "Reports" as a primary-tint pill, with the red attention dot (#119) when
/// [showDot]. One tap target.
class HomeReportsPill extends StatelessWidget {
  const HomeReportsPill({
    super.key,
    required this.showDot,
    required this.onPressed,
  });

  final bool showDot;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final f = t.extension<AppFixedColors>() ?? AppFixedColors.light;
    final tint =
        t.extension<AppSchemeColors>()?.primaryTint ??
        t.colorScheme.primary.withValues(alpha: 0.12);
    final radius = BorderRadius.circular(AppSpacing.borderRadiusL);
    final dot = context.getRSize(8);
    return Material(
      key: HomeKeys.reportsPill,
      color: tint,
      borderRadius: radius,
      child: InkWell(
        onTap: onPressed,
        borderRadius: radius,
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            minHeight: kMinInteractiveDimension,
            minWidth: kMinInteractiveDimension,
          ),
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: context.getRSize(16)),
            child: LayoutBuilder(
              builder: (context, c) => Row(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  AppIcon(
                    AppIcons.terms,
                    filled: true,
                    size: context.getRSize(20),
                    color: t.colorScheme.primary,
                  ),
                  SizedBox(width: context.getRSize(8)),
                  _PillLabel(
                    text: 'Reports',
                    bounded: c.hasBoundedWidth,
                    style: context
                        .boldStyle(15)
                        .copyWith(color: t.colorScheme.primary),
                  ),
                  if (showDot) ...[
                    SizedBox(width: context.getRSize(6)),
                    Container(
                      key: HomeKeys.reportsDot,
                      width: dot,
                      height: dot,
                      decoration: BoxDecoration(
                        color: f.danger,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A pill's one-line label. A pill in the top bar gets unbounded width (it
/// takes its natural size); one in the upright period row is bounded and
/// ends the label in "…" rather than overflow at large text sizes.
class _PillLabel extends StatelessWidget {
  const _PillLabel({
    required this.text,
    required this.style,
    required this.bounded,
  });

  final String text;
  final TextStyle style;

  /// Whether the pill's row has a width limit (so the label may shrink).
  final bool bounded;

  @override
  Widget build(BuildContext context) {
    final label = Text(
      text,
      maxLines: 1,
      softWrap: false,
      overflow: TextOverflow.ellipsis,
      style: style,
    );
    return bounded ? Flexible(child: label) : label;
  }
}

/// Lays Home's cards out in [homeGridColumns] columns measured from the real
/// width. Cards in a row share a height; a short last row keeps the column
/// widths. [cardsFor] builds the visible cards for the chosen column count,
/// so a gated card leaves no gap.
class HomeCardGrid extends StatelessWidget {
  const HomeCardGrid({super.key, required this.cardsFor});

  final List<Widget> Function(int columns) cardsFor;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      key: HomeKeys.grid,
      builder: (context, constraints) {
        final columns = homeGridColumns(
          width: constraints.maxWidth,
          landscape: MediaQuery.orientationOf(context) == Orientation.landscape,
        );
        final cards = cardsFor(columns);
        final gap = context.getRSize(12);
        if (cards.isEmpty) return const SizedBox.shrink();
        if (columns == 1) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final (i, card) in cards.indexed) ...[
                if (i > 0) SizedBox(height: gap),
                card,
              ],
            ],
          );
        }
        final rows = <Widget>[];
        for (var start = 0; start < cards.length; start += columns) {
          if (rows.isNotEmpty) rows.add(SizedBox(height: gap));
          rows.add(
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var j = 0; j < columns; j++) ...[
                    if (j > 0) SizedBox(width: gap),
                    Expanded(
                      child: start + j < cards.length
                          ? cards[start + j]
                          : const SizedBox.shrink(),
                    ),
                  ],
                ],
              ),
            ),
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: rows,
        );
      },
    );
  }
}

/// Customer Credits Balance (`phone-home-*.png`): wallet tile, title, chevron
/// and two tinted boxes, "Credit" (info tint) and "Debt" (danger tint).
///
/// [compact] is the grid-cell form: a smaller title over "Credit and debt".
/// The two values stay visible in it too, because the card opens the
/// Customers list, which shows each customer's balance but not these totals.
class HomeCreditsCard extends StatelessWidget {
  const HomeCreditsCard({
    super.key,
    required this.credit,
    required this.debt,
    required this.compact,
    required this.onTap,
  });

  final String credit;
  final String debt;
  final bool compact;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final f = t.extension<AppFixedColors>() ?? AppFixedColors.light;
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    final pad = context.getRSize(compact ? 14 : 16);
    final gap = context.getRSize(compact ? 10 : 12);
    final header = Row(
      children: [
        const IconTile(
          icon: AppIcons.creditBalance,
          tone: IconTileTone.info,
          size: 44,
        ),
        SizedBox(width: context.getRSize(compact ? 12 : 14)),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Customer Credits Balance',
                style: context
                    .boldStyle(compact ? 15 : 17)
                    .copyWith(color: t.colorScheme.onSurface),
              ),
              if (compact)
                Text(
                  'Credit and debt',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: context.regularStyle(13).copyWith(color: muted),
                ),
            ],
          ),
        ),
        SizedBox(width: context.getRSize(8)),
        AppIcon(
          AppIcons.chevronRight,
          size: context.getRSize(24),
          color: t.colorScheme.onSurface,
        ),
      ],
    );
    Widget box(String label, String value, Color fill, Color ink) => Container(
      padding: EdgeInsets.symmetric(
        horizontal: context.getRSize(compact ? 12 : 16),
        vertical: context.getRSize(compact ? 10 : 14),
      ),
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(AppSpacing.borderRadiusL),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: context
                .semiBoldStyle(compact ? 13 : 14)
                .copyWith(color: muted),
          ),
          SizedBox(height: context.getRSize(4)),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              value,
              maxLines: 1,
              style: context.boldStyle(compact ? 18 : 20).copyWith(color: ink),
            ),
          ),
        ],
      ),
    );
    final content = Padding(
      padding: EdgeInsets.all(pad),
      child: Column(
        key: compact ? HomeKeys.creditsCompact : HomeKeys.creditsFull,
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          header,
          SizedBox(height: gap),
          Row(
            children: [
              Expanded(
                child: box(
                  'Credit',
                  credit,
                  f.infoTint,
                  t.colorScheme.onSurface,
                ),
              ),
              SizedBox(width: gap),
              Expanded(child: box('Debt', debt, f.dangerTint, f.danger)),
            ],
          ),
        ],
      ),
    );
    return DecoratedBox(
      decoration: AppDecorations.card(context),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: BorderRadius.circular(AppSpacing.borderRadiusXL),
          onTap: onTap,
          child: content,
        ),
      ),
    );
  }
}

/// The Total SKUs breakdown (§11.5) shown under its card when open: one row
/// per manufacturer with its SKU count, or [emptyText] when there is nothing
/// (null = blank, while the first download runs).
class HomeSkuBreakdown extends StatelessWidget {
  const HomeSkuBreakdown({super.key, required this.rows, this.emptyText});

  final List<MapEntry<String, int>> rows;
  final String? emptyText;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    final hPad = context.getRSize(16);
    // Blank (no card at all) while the first download runs (#313).
    if (rows.isEmpty && emptyText == null) return const SizedBox.shrink();
    Widget body;
    if (rows.isEmpty) {
      body = Padding(
        padding: EdgeInsets.all(hPad),
        child: Text(
          emptyText!,
          style: context.regularStyle(13).copyWith(color: muted),
        ),
      );
    } else {
      body = Column(
        children: [
          for (final (i, r) in rows.indexed) ...[
            if (i > 0) Divider(height: 1, color: t.dividerColor),
            Padding(
              padding: EdgeInsets.symmetric(
                horizontal: hPad,
                vertical: context.getRSize(10),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      r.key,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: context
                          .semiBoldStyle(14)
                          .copyWith(color: t.colorScheme.onSurface),
                    ),
                  ),
                  Text(
                    '${r.value}',
                    style: context
                        .boldStyle(14)
                        .copyWith(color: t.colorScheme.onSurface),
                  ),
                ],
              ),
            ),
          ],
        ],
      );
    }
    return Container(
      key: HomeKeys.skuBreakdown,
      decoration: AppDecorations.card(context),
      child: body,
    );
  }
}

/// One Staff Sales row: the person's initial in their avatar colour, name and
/// their share of Total Sales (already formatted).
typedef HomeStaffRow = ({String name, Color color, String amount});

/// Staff Sales (§11.4): a [SectionHeader] over one flat card with a row per
/// staff member, or [emptyText] when nobody sold in the period.
class HomeStaffSalesSection extends StatelessWidget {
  const HomeStaffSalesSection({
    super.key,
    required this.rows,
    required this.emptyText,
  });

  final List<HomeStaffRow> rows;
  final String emptyText;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    final hPad = context.getRSize(16);
    return Column(
      key: HomeKeys.staffSales,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionHeader(title: 'Staff Sales'),
        SizedBox(height: context.getRSize(10)),
        DecoratedBox(
          decoration: AppDecorations.card(context),
          child: rows.isEmpty
              ? Padding(
                  padding: EdgeInsets.all(hPad),
                  child: Text(
                    emptyText,
                    style: context.regularStyle(13).copyWith(color: muted),
                  ),
                )
              : Column(
                  children: [
                    for (final (i, r) in rows.indexed) ...[
                      if (i > 0) Divider(height: 1, color: t.dividerColor),
                      Padding(
                        padding: EdgeInsets.symmetric(
                          horizontal: hPad,
                          vertical: context.getRSize(10),
                        ),
                        child: Row(
                          children: [
                            CircleAvatar(
                              radius: context.getRSize(18),
                              backgroundColor: r.color.withValues(alpha: 0.15),
                              child: Text(
                                r.name.isEmpty ? '?' : r.name[0].toUpperCase(),
                                style: context
                                    .boldStyle(14)
                                    .copyWith(color: r.color),
                              ),
                            ),
                            SizedBox(width: context.getRSize(12)),
                            Expanded(
                              child: Text(
                                r.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: context
                                    .semiBoldStyle(14)
                                    .copyWith(color: t.colorScheme.onSurface),
                              ),
                            ),
                            SizedBox(width: context.getRSize(8)),
                            Text(
                              r.amount,
                              style: context
                                  .boldStyle(14)
                                  .copyWith(color: t.colorScheme.onSurface),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
        ),
      ],
    );
  }
}

/// The top bar's height: the theme's 68dp, grown when the scaled header tile
/// (or a 48dp pill) would touch its edges (as CEO Settings, #369).
double homeTopBarHeight(BuildContext context) => math.max(
  kToolbarHeight + 12,
  math.max(context.getRSize(44), kMinInteractiveDimension) +
      context.getRSize(16),
);
