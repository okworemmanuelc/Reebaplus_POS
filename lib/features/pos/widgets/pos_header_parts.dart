import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:reebaplus_pos/core/theme/design_tokens.dart';
import 'package:reebaplus_pos/core/theme/scheme_colors.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/shared/widgets/notifications_modal.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/screen_header.dart';

/// The POS top bar's key (#384).
const Key kPosTopBarKey = ValueKey<String>('pos-top-bar');

/// The view selector (grid / list) in the POS top bar.
const Key kPosViewSelectorKey = ValueKey<String>('pos-view-selector');

/// The POS coach hint banner.
const Key kPosHintKey = ValueKey<String>('pos-coach-hint');

/// The "Select store" button on the All Stores placeholder.
const Key kPosSelectStoreKey = ValueKey<String>('pos-select-store');

/// The POS top bar's height: Home's rule (`homeTopBarHeight`, #374: the
/// theme's 68dp, grown when the scaled header tile or a 48dp control would
/// touch its edges), except that the 68dp shrinks with the screen's scale on a
/// short sideways phone, so the grid keeps some room there (the old POS bar
/// was 56dp). Never taller than Home's, so a toast (`AppNotification`,
/// placed under the tallest bar) never covers it. Repeated here because a
/// feature never reaches into another feature's widgets; shared-part
/// candidate.
double posTopBarHeight(BuildContext context) => math.max(
  math.min(kToolbarHeight + 12, context.getRSize(kToolbarHeight + 12)),
  math.max(context.getRSize(44), kMinInteractiveDimension) +
      context.getRSize(16),
);

/// The solid POS top bar (#384): `colorScheme.surface`, a hairline at the
/// bottom and the soft `topBarShadow`, never changing on scroll (ui-context
/// "Flat with a soft fade"). [header] is the shared `ScreenHeader`.
class PosTopBar extends StatelessWidget implements PreferredSizeWidget {
  const PosTopBar({super.key, required this.height, required this.header});

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
      key: kPosTopBarKey,
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
/// the notifications modal — the same wiring as Home's `HomeLiveBell` (#374),
/// copied because features do not import each other's widgets. Shared-part
/// candidate (CEO Settings, Home and POS each have one now).
class PosLiveBell extends ConsumerWidget {
  const PosLiveBell({super.key});

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

/// The Quick Sale button (not in the mockups, kept, #384): a 48dp square in
/// the pale primary tint with a primary bolt, beside the tier and
/// manufacturer pickers.
class PosQuickSaleButton extends StatelessWidget {
  const PosQuickSaleButton({super.key, required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final primary = t.colorScheme.primary;
    final tint =
        t.extension<AppSchemeColors>()?.primaryTint ??
        primary.withValues(alpha: 0.12);
    final radius = BorderRadius.circular(AppSpacing.borderRadiusM);
    final side = math.max(context.getRSize(48), kMinInteractiveDimension);
    return Tooltip(
      message: 'Quick Sale',
      child: Material(
        color: tint,
        shape: RoundedRectangleBorder(
          borderRadius: radius,
          side: BorderSide(color: primary.withValues(alpha: 0.2)),
        ),
        child: InkWell(
          borderRadius: radius,
          onTap: onPressed,
          child: SizedBox.square(
            dimension: side,
            child: Center(
              child: AppIcon(
                AppIcons.quickSale,
                filled: true,
                size: context.getRSize(22),
                color: primary,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
