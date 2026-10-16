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

// Redesign parts for the Supplier Accounts screens and sheets (#411, PRD #346
// Wave 2 B). Plain data in, theme-only styling, 48dp targets. Each one is a
// shared-part candidate; they live here because a Wave 2 feature never adds
// files to the shared folder or imports another feature's widgets.

/// Keys for the Payments screens and sheets (#411).
abstract final class PaymentsKeys {
  static const Key topBar = ValueKey<String>('payments-top-bar');
  static const Key list = ValueKey<String>('payments-list');
  static const Key empty = ValueKey<String>('payments-empty');
  static const Key historyLink = ValueKey<String>('payments-history-link');
  static const Key transactionsTopBar = ValueKey<String>(
    'payments-transactions-top-bar',
  );
  static const Key transactionsBack = ValueKey<String>(
    'payments-transactions-back',
  );
  static const Key transactionsList = ValueKey<String>(
    'payments-transactions-list',
  );
  static const Key transactionsEmpty = ValueKey<String>(
    'payments-transactions-empty',
  );
  static const Key totalIn = ValueKey<String>('payments-total-in');
  static const Key totalOut = ValueKey<String>('payments-total-out');
  static const Key formSheet = ValueKey<String>('payments-supplier-form-sheet');
  static const Key invoiceSheet = ValueKey<String>('payments-invoice-sheet');
  static const Key paymentSheet = ValueKey<String>('payments-payment-sheet');
  static const Key chooserSheet = ValueKey<String>('payments-chooser-sheet');
  static const Key chooserInvoice = ValueKey<String>(
    'payments-chooser-invoice',
  );
  static const Key chooserPayment = ValueKey<String>(
    'payments-chooser-payment',
  );

  static Key supplierRow(String id) =>
      ValueKey<String>('payments-supplier-row-$id');
  static Key ledgerRow(String id) =>
      ValueKey<String>('payments-ledger-row-$id');
}

/// List and form content caps at the settings width (720, raw — the batch-wide
/// rule); under it the gutter is `getRSize(16)`.
double paymentsGutter(BuildContext context, double width) =>
    math.max(context.getRSize(16), (width - kSettingsMaxContentWidth) / 2);

/// The Payments top bars' height: Home's rule (the theme's 68dp, grown when the
/// scaled header tile or a 48dp control would touch its edges). Repeated
/// because a feature never reaches into another feature's widgets;
/// shared-part candidate.
double paymentsTopBarHeight(BuildContext context) => math.max(
  kToolbarHeight + 12,
  math.max(context.getRSize(44), kMinInteractiveDimension) +
      context.getRSize(16),
);

/// The solid top bar of the Payments screens: `colorScheme.surface`, a hairline
/// at the bottom and the soft `topBarShadow`, never changing on scroll (PRD
/// #346 decision 4). [header] is the shared `ScreenHeader`.
class PaymentsTopBar extends StatelessWidget implements PreferredSizeWidget {
  const PaymentsTopBar({super.key, required this.height, required this.header});

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

/// The live notification bell (same wiring as Home's), copied because features
/// do not import each other's widgets. Shared-part candidate.
class PaymentsLiveBell extends ConsumerWidget {
  const PaymentsLiveBell({super.key});

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

/// A 48dp back arrow for the pushed Transaction History screen.
class PaymentsBackButton extends StatelessWidget {
  const PaymentsBackButton({super.key, required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      key: PaymentsKeys.transactionsBack,
      onPressed: onPressed,
      tooltip: 'Back',
      constraints: const BoxConstraints(
        minWidth: kMinInteractiveDimension,
        minHeight: kMinInteractiveDimension,
      ),
      icon: AppIcon(
        AppIcons.arrowBack,
        size: context.getRSize(24),
        color: Theme.of(context).colorScheme.onSurface,
      ),
    );
  }
}

/// How a supplier's balance reads on the list (the sign mapping is the
/// screen's, unchanged).
enum PaymentsBalanceTone { owed, credit, settled }

/// One supplier on the Supplier Accounts list: a flat card, the whole card
/// taps (>= 48dp). Bank tile, name (Bold 15, 2 lines), contacts (muted),
/// balance line (Bold 13 in fixed danger / green / muted), chevron.
class PaymentsSupplierRow extends StatelessWidget {
  const PaymentsSupplierRow({
    super.key,
    required this.name,
    required this.contact,
    required this.balanceLabel,
    required this.tone,
    required this.onTap,
  });

  final String name;
  final String contact;
  final String balanceLabel;
  final PaymentsBalanceTone tone;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final f = t.extension<AppFixedColors>() ?? AppFixedColors.light;
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    final radius = BorderRadius.circular(AppSpacing.borderRadiusXL);
    final balColor = switch (tone) {
      PaymentsBalanceTone.owed => f.danger,
      PaymentsBalanceTone.credit => f.green,
      PaymentsBalanceTone.settled => muted,
    };
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
                  const IconTile(
                    icon: AppIcons.bank,
                    tone: IconTileTone.info,
                    size: 44,
                  ),
                  SizedBox(width: context.getRSize(12)),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          name,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: context
                              .boldStyle(15)
                              .copyWith(color: t.colorScheme.onSurface),
                        ),
                        if (contact.isNotEmpty) ...[
                          SizedBox(height: context.getRSize(2)),
                          Text(
                            contact,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: context
                                .regularStyle(12)
                                .copyWith(color: muted),
                          ),
                        ],
                        SizedBox(height: context.getRSize(4)),
                        Text(
                          balanceLabel,
                          style: context
                              .boldStyle(13)
                              .copyWith(color: balColor),
                        ),
                      ],
                    ),
                  ),
                  SizedBox(width: context.getRSize(8)),
                  AppIcon(
                    AppIcons.chevronRight,
                    color: muted,
                    size: context.getRSize(22),
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

/// An empty list: a neutral tile over the message.
class PaymentsEmptyMessage extends StatelessWidget {
  const PaymentsEmptyMessage({
    super.key,
    required this.message,
    this.icon = AppIcons.bank,
  });

  final String message;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconTile(icon: icon, tone: IconTileTone.neutral, size: 64),
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

/// A Total In / Total Out figure card (Transaction History): label over a
/// ExtraBold figure that scales down rather than ellipsising.
class PaymentsFigureCard extends StatelessWidget {
  const PaymentsFigureCard({
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

// ── Sheets ───────────────────────────────────────────────────────────────────

/// How far a bottom sheet with a text box lifts its content above the keyboard.
/// A modal sheet sits on the root navigator, above `MainLayout`'s Scaffold, so
/// nothing resizes it for the keyboard. Pair it with `deviceBottomPadding`,
/// which collapses to 0 while the keyboard is up, so the two never
/// double-count. A copy of `inventorySheetKeyboardLift`; shared-part candidate.
double paymentsSheetKeyboardLift(BuildContext context) =>
    MediaQuery.viewInsetsOf(context).bottom;

/// The Surface and theme shape of a sheet that fills its route (a
/// `DraggableScrollableSheet` cannot use the modal's own background).
Decoration paymentsSheetDecoration(BuildContext context) {
  final t = Theme.of(context);
  return ShapeDecoration(
    color: t.colorScheme.surface,
    shape:
        t.bottomSheetTheme.shape ??
        const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(AppSpacing.borderRadiusXL),
          ),
        ),
  );
}

/// The hairline handle (40x4, `dividerColor`).
class PaymentsSheetHandle extends StatelessWidget {
  const PaymentsSheetHandle({super.key});

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

/// A form sheet's header: handle, then the shared `ScreenHeader` (gradient tile,
/// `screenTitleStyle` title, primary subtitle).
class PaymentsSheetHeader extends StatelessWidget {
  const PaymentsSheetHeader({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    this.subtitleColor,
  });

  final IconData icon;
  final String title;
  final String subtitle;

  /// The entry type's colour cue (fixed danger for an invoice, green for a
  /// payment). Null keeps the shared header's primary subtitle.
  final Color? subtitleColor;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final tile = context.getRSize(44);
    final Widget header = subtitleColor == null
        ? ScreenHeader(icon: icon, title: title, subtitle: subtitle)
        : Row(
            children: [
              Container(
                width: tile,
                height: tile,
                alignment: Alignment.center,
                decoration: AppDecorations.primaryButtonGradient(
                  context,
                  radius: AppSpacing.borderRadiusL,
                ),
                child: AppIcon(
                  icon,
                  filled: true,
                  size: tile * 0.5,
                  color: t.colorScheme.onPrimary,
                ),
              ),
              SizedBox(width: context.getRSize(12)),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: context.screenTitleStyle.copyWith(
                        color: t.colorScheme.onSurface,
                      ),
                    ),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: context
                          .semiBoldStyle(13)
                          .copyWith(color: subtitleColor),
                    ),
                  ],
                ),
              ),
            ],
          );
    return Padding(
      padding: EdgeInsets.fromLTRB(
        context.getRSize(20),
        context.getRSize(12),
        context.getRSize(20),
        context.getRSize(10),
      ),
      child: Column(
        children: [
          const PaymentsSheetHandle(),
          SizedBox(height: context.getRSize(16)),
          header,
        ],
      ),
    );
  }
}

/// Below this much sheet height (base dp, scaled) the form sheets stop pinning
/// their header and button and scroll them with the fields instead: a phone
/// held sideways with the keyboard up. A measured height, not a viewport
/// predicate (PRD #239).
const double kPaymentsFormPinnedMinHeight = 340;

/// The body of the supplier form and the Record Invoice / Payment sheets:
/// [header] and [footer] pinned around the scrolling [fields] when the sheet
/// has room, otherwise all three scroll as one list. Both shapes scroll with
/// the `DraggableScrollableSheet`'s [scrollController], and the footer lifts
/// above the keyboard ([paymentsSheetKeyboardLift]).
class PaymentsFormSheetLayout extends StatelessWidget {
  const PaymentsFormSheetLayout({
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
    final lift = paymentsSheetKeyboardLift(context);
    final liftedFooter = Padding(
      padding: EdgeInsets.only(bottom: lift),
      child: footer,
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final pinned =
            constraints.maxHeight >=
            context.getRSize(kPaymentsFormPinnedMinHeight);
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
              liftedFooter,
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
            liftedFooter,
          ],
        );
      },
    );
  }
}

/// The footer of a form sheet: the button with the sheet's side gutters and
/// `deviceBottomPadding` below.
class PaymentsSheetFooter extends StatelessWidget {
  const PaymentsSheetFooter({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        context.getRSize(20),
        context.getRSize(16),
        context.getRSize(20),
        context.deviceBottomPadding + context.getRSize(16),
      ),
      child: child,
    );
  }
}

/// The Record Activity chooser's frame: keyed, one scroll, handle + title +
/// primary subtitle, `deviceBottomPadding` below. The theme draws the Surface
/// and shape.
class PaymentsChooserFrame extends StatelessWidget {
  const PaymentsChooserFrame({
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
      key: PaymentsKeys.chooserSheet,
      constraints: BoxConstraints(maxHeight: context.screenHeight * 0.9),
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
          gutter,
          context.getRSize(12),
          gutter,
          context.getRSize(24) + context.deviceBottomPadding,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const PaymentsSheetHandle(),
            SizedBox(height: context.getRSize(16)),
            Text(
              title,
              style: context.screenTitleStyle.copyWith(
                color: t.colorScheme.onSurface,
              ),
            ),
            SizedBox(height: context.getRSize(2)),
            Text(
              subtitle,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: context
                  .semiBoldStyle(13)
                  .copyWith(color: t.colorScheme.primary),
            ),
            SizedBox(height: context.getRSize(20)),
            ...children,
          ],
        ),
      ),
    );
  }
}

/// "Recording for: <store>" banner (a primary-tint card), shown in the Record
/// Activity sheets so the target store is explicit.
class PaymentsStoreBanner extends StatelessWidget {
  const PaymentsStoreBanner({super.key, required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    final primary = t.colorScheme.primary;
    return Container(
      constraints: const BoxConstraints(minHeight: kMinInteractiveDimension),
      padding: EdgeInsets.symmetric(
        horizontal: context.getRSize(12),
        vertical: context.getRSize(10),
      ),
      decoration: BoxDecoration(
        color: primary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(AppSpacing.borderRadiusM),
        border: Border.all(color: t.dividerColor),
      ),
      child: Row(
        children: [
          AppIcon(
            AppIcons.store,
            filled: true,
            size: context.getRSize(16),
            color: primary,
          ),
          SizedBox(width: context.getRSize(8)),
          Expanded(
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: 'Recording for: ',
                    style: context.regularStyle(12).copyWith(color: muted),
                  ),
                  TextSpan(
                    text: label,
                    style: context.boldStyle(12).copyWith(color: primary),
                  ),
                ],
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

/// The "Attach receipt" box of the payment sheet: a card with a leading icon,
/// the file name (or the prompt) and, once attached, a 48dp clear button.
class PaymentsReceiptBox extends StatelessWidget {
  const PaymentsReceiptBox({
    super.key,
    required this.fileName,
    required this.onPick,
    required this.onClear,
  });

  final String? fileName;
  final VoidCallback onPick;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    final attached = fileName != null;
    final radius = BorderRadius.circular(AppSpacing.borderRadiusM);
    return Material(
      color: t.cardColor,
      shape: RoundedRectangleBorder(
        borderRadius: radius,
        side: BorderSide(color: t.dividerColor),
      ),
      child: InkWell(
        borderRadius: radius,
        onTap: onPick,
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            minHeight: kMinInteractiveDimension,
          ),
          child: Padding(
            padding: EdgeInsets.only(
              left: context.getRSize(14),
              top: context.getRSize(4),
              bottom: context.getRSize(4),
              right: attached ? context.getRSize(4) : context.getRSize(14),
            ),
            child: Row(
              children: [
                AppIcon(
                  attached ? AppIcons.document : AppIcons.attachment,
                  size: context.getRSize(20),
                  color: attached ? t.colorScheme.primary : muted,
                ),
                SizedBox(width: context.getRSize(12)),
                Expanded(
                  child: Text(
                    fileName ?? 'Attach receipt (photo or file)',
                    style: context
                        .semiBoldStyle(13)
                        .copyWith(
                          color: attached ? t.colorScheme.onSurface : muted,
                        ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (attached)
                  IconButton(
                    onPressed: onClear,
                    tooltip: 'Remove receipt',
                    constraints: const BoxConstraints(
                      minWidth: kMinInteractiveDimension,
                      minHeight: kMinInteractiveDimension,
                    ),
                    icon: AppIcon(
                      AppIcons.close,
                      size: context.getRSize(20),
                      color: muted,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
