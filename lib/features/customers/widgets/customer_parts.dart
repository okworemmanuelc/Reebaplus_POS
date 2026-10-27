import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:reebaplus_pos/core/utils/name_case.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/theme/app_decorations.dart';
import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/theme/design_tokens.dart';
import 'package:reebaplus_pos/core/theme/fixed_colors.dart';
import 'package:reebaplus_pos/core/theme/scheme_colors.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/shared/widgets/notifications_modal.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/redesign.dart';

/// Keys for the Customers screens and the Add / Edit Customer sheets (#395).
abstract final class CustomersKeys {
  static const Key topBar = ValueKey<String>('customers-top-bar');
  static const Key list = ValueKey<String>('customers-list');
  static const Key empty = ValueKey<String>('customers-empty');
  static const Key addSheet = ValueKey<String>('add-customer-sheet');
  static const Key editSheet = ValueKey<String>('edit-customer-sheet');
  static const Key editBack = ValueKey<String>('edit-customer-back');

  // Customer Detail (#395 PR 2).
  static const Key detailTopBar = ValueKey<String>('customer-detail-top-bar');
  static const Key detailBack = ValueKey<String>('customer-detail-back');
  static const Key detailDelete = ValueKey<String>('customer-detail-delete');
  static const Key detailEdit = ValueKey<String>('customer-detail-edit');
  static const Key profileCard = ValueKey<String>('customer-profile-card');
  static const Key creditsCard = ValueKey<String>('customer-credits-card');
  static const Key addCredit = ValueKey<String>('customer-add-credit');
  static const Key setLimit = ValueKey<String>('customer-set-limit');
  static const Key refundCash = ValueKey<String>('customer-refund-cash');
  static const Key recordCrateReturn = ValueKey<String>(
    'customer-record-crate-return',
  );
  static const Key sheetFrame = ValueKey<String>('customer-sheet-frame');
  static const Key refundAmount = ValueKey<String>('customer-refund-amount');
  static const Key refundNote = ValueKey<String>('customer-refund-note');
  static const Key refundSubmit = ValueKey<String>('customer-refund-submit');
  static const Key limitField = ValueKey<String>('customer-limit-field');
  static const Key limitSubmit = ValueKey<String>('customer-limit-submit');
  static const Key crateQty = ValueKey<String>('customer-crate-qty');
  static const Key crateSubmit = ValueKey<String>('customer-crate-submit');

  static Key refundMethod(String m) =>
      ValueKey<String>('customer-refund-method-$m');
  static Key voidTopup(String txnId) =>
      ValueKey<String>('customer-void-topup-$txnId');
  static Key orderRow(String orderId) =>
      ValueKey<String>('customer-order-row-$orderId');

  /// One customer's row on the Customers list.
  static Key row(String customerId) =>
      ValueKey<String>('customers-row-$customerId');
}

/// The Customers top bar's height: CEO Settings' rule (#369) — the theme's
/// 68dp, grown when the scaled header tile would touch its edges. Repeated
/// here because a feature never reaches into another feature's widgets;
/// shared-part candidate (with `homeTopBarHeight` / `posTopBarHeight`).
double customerTopBarHeight(BuildContext context) => math.max(
  kToolbarHeight + 12,
  math.max(context.getRSize(44), kMinInteractiveDimension) +
      context.getRSize(16),
);

/// The solid top bar of the Customers screens (#395): `colorScheme.surface`,
/// a hairline at the bottom and the soft `topBarShadow`, never changing on
/// scroll (PRD #346 decision 4). [header] is the shared `ScreenHeader`.
class CustomerTopBar extends StatelessWidget implements PreferredSizeWidget {
  const CustomerTopBar({super.key, required this.height, required this.header});

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

/// The live notification bell: [HeaderBell] fed by the unread count, opening
/// the notifications modal — the same wiring as Home's and POS's bells,
/// copied because features do not import each other's widgets. Shared-part
/// candidate.
class CustomerLiveBell extends ConsumerWidget {
  const CustomerLiveBell({super.key});

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

/// One customer on the Customers list (#395): a flat card, the whole card
/// taps. Initial tile, name (Bold 15, 2 lines), address (muted, 2 lines), the
/// price-tier tag, then "Credits Balance" over the figure — green, or red
/// when the customer owes.
class CustomerListRow extends StatelessWidget {
  const CustomerListRow({
    super.key,
    required this.name,
    required this.address,
    required this.tierLabel,
    required this.balanceLabel,
    required this.owes,
    required this.onTap,
    this.showTier = true,
  });

  final String name;
  final String address;
  final String tierLabel;

  /// The formatted Credits Balance.
  final String balanceLabel;

  /// Whether the balance is below zero (drawn red).
  final bool owes;
  final VoidCallback onTap;

  /// Whether to show the price tier pill (#493). False in one-price shops.
  final bool showTier;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final f = t.extension<AppFixedColors>() ?? AppFixedColors.light;
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    final radius = BorderRadius.circular(AppSpacing.borderRadiusXL);
    final tile = context.getRSize(44);
    final initial = name.isNotEmpty ? name.substring(0, 1).toUpperCase() : '?';
    return DecoratedBox(
      decoration: AppDecorations.card(context),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: radius,
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              minHeight: kMinInteractiveDimension,
            ),
            child: Padding(
              padding: EdgeInsets.all(context.getRSize(14)),
              child: Row(
                children: [
                  Container(
                    width: tile,
                    height: tile,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: f.infoTint,
                      borderRadius: BorderRadius.circular(
                        AppSpacing.borderRadiusL,
                      ),
                    ),
                    child: Text(
                      initial,
                      style: context.boldStyle(18).copyWith(color: f.info),
                    ),
                  ),
                  SizedBox(width: context.getRSize(12)),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          toNameCase(name),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: context
                              .boldStyle(15)
                              .copyWith(color: t.colorScheme.onSurface),
                        ),
                        if (address.isNotEmpty) ...[
                          SizedBox(height: context.getRSize(2)),
                          Text(
                            address,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: context
                                .regularStyle(12)
                                .copyWith(color: muted),
                          ),
                        ],
                        if (showTier) ...[
                          SizedBox(height: context.getRSize(6)),
                          TagPill(label: tierLabel, dense: true),
                        ],
                      ],
                    ),
                  ),
                  SizedBox(width: context.getRSize(12)),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        'Credits Balance',
                        style: context.regularStyle(12).copyWith(color: muted),
                      ),
                      SizedBox(height: context.getRSize(2)),
                      Text(
                        balanceLabel,
                        style: context
                            .boldStyle(16)
                            .copyWith(color: owes ? f.danger : f.green),
                      ),
                    ],
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

/// The empty Customers list: a neutral tile over the message.
class CustomersEmptyMessage extends StatelessWidget {
  const CustomersEmptyMessage({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    return Column(
      key: CustomersKeys.empty,
      mainAxisSize: MainAxisSize.min,
      children: [
        const IconTile(
          icon: AppIcons.customers,
          tone: IconTileTone.neutral,
          size: 64,
        ),
        SizedBox(height: context.getRSize(12)),
        Text(
          message,
          textAlign: TextAlign.center,
          style: context.semiBoldStyle(14).copyWith(color: muted),
        ),
      ],
    );
  }
}

/// The hairline handle at the top of a customer sheet (40×4, `dividerColor`),
/// as on the customer payment sheet.
class CustomerSheetHandle extends StatelessWidget {
  const CustomerSheetHandle({super.key});

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

/// The theme's bottom-sheet shape (`bottomSheetTheme.shape`, rounded top),
/// for a customer sheet that draws its own surface — a
/// `DraggableScrollableSheet` fills the whole route, so the modal's own
/// background cannot be used.
ShapeBorder customerSheetShape(BuildContext context) =>
    Theme.of(context).bottomSheetTheme.shape ??
    const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(
        top: Radius.circular(AppSpacing.borderRadiusXL),
      ),
    );

/// Below this much sheet height (base dp, scaled) the Add / Edit Customer
/// sheets stop pinning their header and Save button and scroll them with the
/// fields instead — a phone held sideways with the keyboard up (#395). A
/// measured height, not a viewport predicate (PRD #239).
const double kCustomerFormPinnedMinHeight = 340;

/// The body of the Add / Edit Customer sheets (#395): [header] and [footer]
/// pinned around the scrolling [fields] when the sheet has room
/// ([kCustomerFormPinnedMinHeight]); otherwise all three scroll as one list,
/// so the fields never get squeezed to nothing. Both shapes scroll with the
/// `DraggableScrollableSheet`'s [scrollController].
class CustomerFormSheetLayout extends StatelessWidget {
  const CustomerFormSheetLayout({
    super.key,
    required this.scrollController,
    required this.header,
    required this.fields,
    required this.footer,
  });

  final ScrollController scrollController;
  final Widget header;
  final List<Widget> fields;
  final Widget footer;

  @override
  Widget build(BuildContext context) {
    final fieldsPadding = EdgeInsets.fromLTRB(
      context.getRSize(20),
      context.getRSize(10),
      context.getRSize(20),
      context.getRSize(20),
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final pinned =
            constraints.maxHeight >=
            context.getRSize(kCustomerFormPinnedMinHeight);
        if (!pinned) {
          return ListView(
            controller: scrollController,
            children: [
              header,
              Padding(
                padding: fieldsPadding,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: fields,
                ),
              ),
              footer,
            ],
          );
        }
        return Column(
          children: [
            header,
            Expanded(
              child: ListView(
                controller: scrollController,
                padding: fieldsPadding,
                children: fields,
              ),
            ),
            footer,
          ],
        );
      },
    );
  }
}

// ── Customer Detail (#395 PR 2) ───────────────────────────────────────────

/// Customer Detail's content cap: a fixed 960 (the Inventory detail screens'
/// rule), applied to every sliver and the tab bar and centred.
const double kCustomerDetailMaxContentWidth = 960;

/// The profile and credits cards sit side by side when the measured content
/// width is at least this (never a viewport predicate — PRD #239).
const double kCustomerDetailSideBySideWidth = 900;

/// Customer sheets cap at Material 3's 640.
const double kCustomerSheetMaxWidth = 640;

/// The side gutter that centres a [kCustomerDetailMaxContentWidth] column in
/// [width] (the measured width of the sliver or bar), never under
/// `getRSize(20)`.
double customerDetailGutter(BuildContext context, double width) => math.max(
  context.getRSize(20),
  (width - kCustomerDetailMaxContentWidth) / 2,
);

/// Wraps [sliver] in the centred 960 column. Measured, not predicated.
Widget customerDetailSliver(
  Widget sliver, {
  double top = 0,
  double bottom = 0,
}) => SliverLayoutBuilder(
  builder: (context, c) {
    final g = customerDetailGutter(context, c.crossAxisExtent);
    return SliverPadding(
      padding: EdgeInsets.fromLTRB(g, top, g, bottom),
      sliver: sliver,
    );
  },
);

/// The two header cards: stacked, or side by side once the measured content
/// column is at least [kCustomerDetailSideBySideWidth].
class CustomerHeaderSliver extends StatelessWidget {
  const CustomerHeaderSliver({
    super.key,
    required this.profile,
    required this.credits,
  });

  final Widget profile;
  final Widget credits;

  @override
  Widget build(BuildContext context) {
    return SliverLayoutBuilder(
      builder: (context, c) {
        final g = customerDetailGutter(context, c.crossAxisExtent);
        final content = c.crossAxisExtent - 2 * g;
        final wide = content >= kCustomerDetailSideBySideWidth;
        final gap = context.getRSize(16);
        return SliverPadding(
          padding: EdgeInsets.fromLTRB(g, context.getRSize(16), g, 0),
          sliver: SliverToBoxAdapter(
            child: wide
                ? IntrinsicHeight(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(child: profile),
                        SizedBox(width: gap),
                        Expanded(child: credits),
                      ],
                    ),
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      profile,
                      SizedBox(height: gap),
                      credits,
                    ],
                  ),
          ),
        );
      },
    );
  }
}

/// A 48dp icon button for the Customer Detail bar.
class CustomerBarAction extends StatelessWidget {
  const CustomerBarAction({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.color,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: kMinInteractiveDimension,
      child: IconButton(
        tooltip: tooltip,
        padding: EdgeInsets.zero,
        onPressed: onPressed,
        icon: AppIcon(
          icon,
          size: context.getRSize(22),
          color: color ?? Theme.of(context).colorScheme.onSurface,
        ),
      ),
    );
  }
}

/// A muted icon + text line of the profile card.
class _CustomerInfoLine extends StatelessWidget {
  const _CustomerInfoLine({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    return Row(
      children: [
        AppIcon(icon, size: context.getRSize(14), color: muted),
        SizedBox(width: context.getRSize(8)),
        Expanded(
          child: Text(
            text,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: context.regularStyle(13).copyWith(color: muted),
          ),
        ),
      ],
    );
  }
}

/// The customer's profile card (#395 PR 2): gradient initials tile, name in
/// ExtraBold, the tier tag, muted phone / address / "Since" lines, and the
/// edit pencil (48dp) when [onEdit] is given.
class CustomerProfileCard extends StatelessWidget {
  const CustomerProfileCard({
    super.key,
    required this.initials,
    required this.name,
    required this.wholesaler,
    required this.phone,
    required this.address,
    required this.since,
    this.onEdit,
    this.showTier = true,
  });

  final String initials;
  final String name;
  final bool wholesaler;
  final String phone;
  final String address;
  final String since;
  final VoidCallback? onEdit;

  /// Whether to show the Wholesaler/Retailer tier pill (#493). False in one-price shops.
  final bool showTier;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final tile = context.getRSize(60);
    return DecoratedBox(
      key: CustomersKeys.profileCard,
      decoration: AppDecorations.card(context),
      child: Padding(
        padding: EdgeInsets.all(context.getRSize(16)),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: tile,
              height: tile,
              alignment: Alignment.center,
              decoration: AppDecorations.primaryButtonGradient(
                context,
                radius: AppSpacing.borderRadiusXL,
              ),
              child: Text(
                initials,
                style: context
                    .extraBoldStyle(22)
                    .copyWith(color: t.colorScheme.onPrimary),
              ),
            ),
            SizedBox(width: context.getRSize(14)),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: EdgeInsets.only(
                      top: onEdit == null ? 0 : context.getRSize(10),
                    ),
                    child: Text(
                      toNameCase(name),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: context
                          .extraBoldStyle(18)
                          .copyWith(color: t.colorScheme.onSurface),
                    ),
                  ),
                  if (showTier) ...[
                    SizedBox(height: context.getRSize(6)),
                    TagPill(
                      label: wholesaler ? 'Wholesaler' : 'Retailer',
                      tone: wholesaler
                          ? TagPillTone.green
                          : TagPillTone.warning,
                      dense: true,
                    ),
                  ],
                  if (phone.isNotEmpty) ...[
                    SizedBox(height: context.getRSize(10)),
                    _CustomerInfoLine(icon: AppIcons.phone, text: phone),
                  ],
                  if (address.isNotEmpty && address != 'N/A') ...[
                    SizedBox(height: context.getRSize(6)),
                    _CustomerInfoLine(icon: AppIcons.location, text: address),
                  ],
                  SizedBox(height: context.getRSize(6)),
                  _CustomerInfoLine(icon: AppIcons.calendarCheck, text: since),
                ],
              ),
            ),
            if (onEdit != null)
              SizedBox.square(
                dimension: kMinInteractiveDimension,
                child: IconButton(
                  key: CustomersKeys.detailEdit,
                  tooltip: 'Edit customer',
                  padding: EdgeInsets.zero,
                  onPressed: onEdit,
                  icon: AppIcon(
                    AppIcons.edit,
                    size: context.getRSize(20),
                    color: t.colorScheme.primary,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// A labelled figure box inside the credits card: a neutral box for the debt
/// limit, an `infoTint` box for the held deposit.
class _CustomerStatBox extends StatelessWidget {
  const _CustomerStatBox({
    required this.icon,
    required this.label,
    required this.value,
    this.tinted = false,
  });

  final IconData icon;
  final String label;
  final String value;
  final bool tinted;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final f = t.extension<AppFixedColors>() ?? AppFixedColors.light;
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    final accent = tinted ? f.info : muted;
    return Container(
      padding: EdgeInsets.all(context.getRSize(12)),
      decoration: BoxDecoration(
        color: tinted ? f.infoTint : f.neutralTile,
        borderRadius: BorderRadius.circular(AppSpacing.borderRadiusL),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              AppIcon(icon, size: context.getRSize(14), color: accent),
              SizedBox(width: context.getRSize(6)),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: context.semiBoldStyle(12).copyWith(color: accent),
                ),
              ),
            ],
          ),
          SizedBox(height: context.getRSize(4)),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: context
                .boldStyle(15)
                .copyWith(color: tinted ? f.info : t.colorScheme.onSurface),
          ),
        ],
      ),
    );
  }
}

/// The credits card (#395 PR 2): wallet tile + "Credits Balance" and the
/// figure (ExtraBold, danger below zero), the period picker, the Debt Limit
/// box, the Deposit Held box (only when [depositLabel] is given) and the
/// gated actions (each ≥ 48dp; a null callback hides its button).
class CustomerCreditsCard extends StatelessWidget {
  const CustomerCreditsCard({
    super.key,
    required this.balanceLabel,
    required this.owes,
    required this.periodPicker,
    required this.limitLabel,
    this.depositLabel,
    this.onAddCredit,
    this.onSetLimit,
    this.onRefund,
  });

  final String balanceLabel;
  final bool owes;
  final Widget periodPicker;
  final String limitLabel;
  final String? depositLabel;
  final VoidCallback? onAddCredit;
  final VoidCallback? onSetLimit;
  final VoidCallback? onRefund;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final f = t.extension<AppFixedColors>() ?? AppFixedColors.light;
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    final gap = context.getRSize(10);
    return DecoratedBox(
      key: CustomersKeys.creditsCard,
      decoration: AppDecorations.card(context),
      child: Padding(
        padding: EdgeInsets.all(context.getRSize(16)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const IconTile(
                            icon: AppIcons.creditBalance,
                            size: 32,
                          ),
                          SizedBox(width: context.getRSize(8)),
                          Flexible(
                            child: Text(
                              'Credits Balance',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: context
                                  .semiBoldStyle(13)
                                  .copyWith(color: muted),
                            ),
                          ),
                        ],
                      ),
                      SizedBox(height: context.getRSize(8)),
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: AlignmentDirectional.centerStart,
                        child: Text(
                          balanceLabel,
                          style: context
                              .extraBoldStyle(28)
                              .copyWith(
                                color: owes
                                    ? f.danger
                                    : t.colorScheme.onSurface,
                              ),
                        ),
                      ),
                    ],
                  ),
                ),
                SizedBox(width: gap),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      'Period:',
                      style: context.semiBoldStyle(11).copyWith(color: muted),
                    ),
                    SizedBox(height: context.getRSize(4)),
                    periodPicker,
                  ],
                ),
              ],
            ),
            SizedBox(height: context.getRSize(14)),
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: _CustomerStatBox(
                      icon: AppIcons.creditCard,
                      label: 'Debt Limit',
                      value: limitLabel,
                    ),
                  ),
                  if (depositLabel != null) ...[
                    SizedBox(width: gap),
                    Expanded(
                      child: _CustomerStatBox(
                        icon: AppIcons.box,
                        label: 'Deposit Held',
                        value: depositLabel!,
                        tinted: true,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (onAddCredit != null || onSetLimit != null) ...[
              SizedBox(height: context.getRSize(14)),
              Row(
                children: [
                  if (onAddCredit != null)
                    Expanded(
                      child: AppButton(
                        key: CustomersKeys.addCredit,
                        text: 'Add Credit',
                        icon: AppIcons.add,
                        onPressed: onAddCredit,
                      ),
                    ),
                  if (onAddCredit != null && onSetLimit != null)
                    SizedBox(width: gap),
                  if (onSetLimit != null)
                    Expanded(
                      child: AppButton(
                        key: CustomersKeys.setLimit,
                        text: 'Set Limit',
                        icon: AppIcons.edit,
                        variant: AppButtonVariant.outline,
                        onPressed: onSetLimit,
                      ),
                    ),
                ],
              ),
            ],
            if (onRefund != null) ...[
              SizedBox(height: gap),
              AppButton(
                key: CustomersKeys.refundCash,
                text: 'Refund Cash',
                icon: AppIcons.transfer,
                variant: AppButtonVariant.outline,
                onPressed: onRefund,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// A Total In / Total Out figure card.
class CustomerFigureCard extends StatelessWidget {
  const CustomerFigureCard({
    super.key,
    required this.label,
    required this.value,
    required this.color,
  });

  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    return DecoratedBox(
      decoration: AppDecorations.card(context),
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: context.getRSize(14),
          vertical: context.getRSize(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: context.semiBoldStyle(12).copyWith(color: muted),
            ),
            SizedBox(height: context.getRSize(4)),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: AlignmentDirectional.centerStart,
              child: Text(
                value,
                style: context.extraBoldStyle(17).copyWith(color: color),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A flat card row of the Customer Detail tabs: leading tile, [title] (Bold
/// 14), [subtitle] (muted), a [trailing] block. [onTap] makes the whole card
/// tap (≥ 48dp).
class CustomerDetailRow extends StatelessWidget {
  const CustomerDetailRow({
    super.key,
    required this.leading,
    required this.title,
    this.subtitle,
    this.trailing,
    this.onTap,
  });

  final Widget leading;
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    final radius = BorderRadius.circular(AppSpacing.borderRadiusXL);
    return DecoratedBox(
      decoration: AppDecorations.card(context),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: radius,
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              minHeight: kMinInteractiveDimension,
            ),
            child: Padding(
              padding: EdgeInsets.all(context.getRSize(12)),
              child: Row(
                children: [
                  leading,
                  SizedBox(width: context.getRSize(12)),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: context
                              .boldStyle(14)
                              .copyWith(color: t.colorScheme.onSurface),
                        ),
                        if (subtitle != null)
                          Text(
                            subtitle!,
                            style: context
                                .regularStyle(12)
                                .copyWith(color: muted),
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
            ),
          ),
        ),
      ),
    );
  }
}

/// The empty state of a Customer Detail tab: neutral tile over the message.
class CustomerDetailEmpty extends StatelessWidget {
  const CustomerDetailEmpty({
    super.key,
    required this.icon,
    required this.message,
  });

  final IconData icon;
  final String message;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    return Center(
      child: Padding(
        padding: EdgeInsets.all(context.getRSize(24)),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconTile(icon: icon, tone: IconTileTone.neutral, size: 56),
            SizedBox(height: context.getRSize(12)),
            Text(
              message,
              textAlign: TextAlign.center,
              style: context.semiBoldStyle(14).copyWith(color: muted),
            ),
          ],
        ),
      ),
    );
  }
}

/// The frame of the Refund / Set Limit / Record Crate Return sheets (#395
/// PR 2): hairline handle, `screenTitleStyle` title, primary subtitle, then
/// [children]. One shrink-wrapped scroll view capped at 90% of the screen
/// height, with `deviceBottomPadding` below — so it scrolls at 360dp @1.3 and
/// at 844×390 with the keyboard up (the old sheets overflowed). The theme
/// draws the Surface and shape; open it with [showCustomerSheet].
class CustomerSheetFrame extends StatelessWidget {
  const CustomerSheetFrame({
    super.key,
    required this.title,
    required this.subtitle,
    required this.children,
  });

  final String title;
  final String subtitle;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final gutter = context.getRSize(20);
    return ConstrainedBox(
      key: CustomersKeys.sheetFrame,
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
                  const CustomerSheetHandle(),
                  SizedBox(height: context.getRSize(14)),
                  Text(
                    title,
                    style: context.screenTitleStyle.copyWith(
                      color: t.colorScheme.onSurface,
                    ),
                  ),
                  SizedBox(height: context.getRSize(2)),
                  Text(
                    subtitle,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: context
                        .semiBoldStyle(13)
                        .copyWith(color: t.colorScheme.primary),
                  ),
                  SizedBox(height: context.getRSize(16)),
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

/// Opens a [CustomerSheetFrame] sheet: the theme's surface, capped at
/// [kCustomerSheetMaxWidth].
Future<T?> showCustomerSheet<T>(BuildContext context, WidgetBuilder builder) =>
    showModalBottomSheet<T>(
      context: context,
      isScrollControlled: true,
      constraints: const BoxConstraints(maxWidth: kCustomerSheetMaxWidth),
      builder: builder,
    );

/// One selectable option card (refund methods): icon + label; the selected
/// one has a primary border and a pale primary fill. A copy of the payment
/// sheet's private `_MethodOption` (kept private there so its goldens are
/// untouched) — shared-part candidate.
class CustomerOptionCard extends StatelessWidget {
  const CustomerOptionCard({
    super.key,
    required this.label,
    required this.icon,
    required this.isSelected,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    final primary = t.colorScheme.primary;
    final radius = BorderRadius.circular(AppSpacing.borderRadiusM);
    final base = AppDecorations.card(context, radius: AppSpacing.borderRadiusM);
    return Semantics(
      selected: isSelected,
      button: true,
      child: DecoratedBox(
        decoration: isSelected
            ? base.copyWith(
                color: Color.alphaBlend(
                  t.extension<AppSchemeColors>()?.primaryTint ??
                      primary.withValues(alpha: 0.12),
                  t.colorScheme.surface,
                ),
                border: Border.all(color: primary, width: 1.5),
              )
            : base,
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            borderRadius: radius,
            onTap: onTap,
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                minHeight: kMinInteractiveDimension,
              ),
              child: Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: context.getRSize(12),
                  vertical: context.getRSize(10),
                ),
                child: Row(
                  children: [
                    AppIcon(
                      icon,
                      filled: isSelected,
                      size: context.getRSize(20),
                      color: isSelected ? primary : muted,
                    ),
                    SizedBox(width: context.getRSize(8)),
                    Flexible(
                      child: Text(
                        label,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: context
                            .semiBoldStyle(14)
                            .copyWith(
                              color: isSelected
                                  ? primary
                                  : t.colorScheme.onSurface,
                            ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A Customer Detail dialog's red text action (Delete / Void).
TextStyle customerDangerActionStyle(BuildContext context) => context
    .boldStyle(14)
    .copyWith(
      color:
          (Theme.of(context).extension<AppFixedColors>() ??
                  AppFixedColors.light)
              .danger,
    );

/// Currency-sign hint for the amount inputs, e.g. "Amount to refund (₦)".
String customerAmountLabel(String label) => '$label ($activeCurrencySymbol)';
