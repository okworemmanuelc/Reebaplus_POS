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

/// Keys for the Customers screens and the Add / Edit Customer sheets (#395).
abstract final class CustomersKeys {
  static const Key topBar = ValueKey<String>('customers-top-bar');
  static const Key list = ValueKey<String>('customers-list');
  static const Key empty = ValueKey<String>('customers-empty');
  static const Key addSheet = ValueKey<String>('add-customer-sheet');
  static const Key editSheet = ValueKey<String>('edit-customer-sheet');
  static const Key editBack = ValueKey<String>('edit-customer-back');

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
  });

  final String name;
  final String address;
  final String tierLabel;

  /// The formatted Credits Balance.
  final String balanceLabel;

  /// Whether the balance is below zero (drawn red).
  final bool owes;
  final VoidCallback onTap;

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
                          name,
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
                        SizedBox(height: context.getRSize(6)),
                        TagPill(label: tierLabel, dense: true),
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
