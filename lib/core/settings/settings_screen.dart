import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:reebaplus_pos/core/theme/app_decorations.dart';
import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/theme/scheme_colors.dart';
import 'package:reebaplus_pos/core/permissions/permissions.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/settings/activity_logs_access_screen.dart';
import 'package:reebaplus_pos/core/settings/appearance_settings_screen.dart';
import 'package:reebaplus_pos/core/settings/business_info_screen.dart';
import 'package:reebaplus_pos/core/settings/delete_business_screen.dart';
import 'package:reebaplus_pos/core/settings/receipt_printer_settings_screen.dart';
import 'package:reebaplus_pos/core/settings/roles_permissions_screen.dart';
import 'package:reebaplus_pos/core/settings/security_settings_screen.dart';
import 'package:reebaplus_pos/core/settings/settings_widgets.dart';
import 'package:reebaplus_pos/core/settings/stores_settings_screen.dart';
import 'package:reebaplus_pos/core/settings/subscription_screen.dart';
import 'package:reebaplus_pos/core/settings/sync_issues_access_screen.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/features/subscription/subscription_access.dart';
import 'package:reebaplus_pos/shared/widgets/notifications_modal.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/redesign.dart';

/// One row in the CEO Settings menu.
typedef _SettingEntry = ({
  IconData icon,
  IconTileTone tone,
  String title,
  String subtitle,
  Widget screen,
});

/// A titled group of rows (#369).
typedef _SettingGroup = ({String title, List<_SettingEntry> entries});

/// The widest the settings content grows on a wide screen (#369): rows stay
/// readable instead of stretching across 1280dp, centred in the space.
const double kSettingsMaxContentWidth = 720;

/// The Danger Zone's search keywords: it surfaces for an empty search or one
/// that matches these.
const String _kDangerZoneKeywords = 'danger zone delete business account';

/// CEO Settings menu (§10.1; restyled to the redesign mockup in #369). Each
/// row opens its own sub-page. Reached from the drawer, which already hides
/// this for non-CEO roles; the guard below is defense-in-depth (hard rule #6).
/// A search box filters the rows by title / subtitle so a specific setting is
/// quick to find; a group whose rows all miss hides its header.
class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  final _searchCtrl = TextEditingController();
  String _query = '';

  // Const instances are canonicalised (no per-build construction cost). Icon
  // tints are the fixed pairs (AppFixedColors via IconTileTone).
  static const List<_SettingGroup> _groups = [
    (
      title: 'Business',
      entries: [
        (
          icon: AppIcons.business,
          tone: IconTileTone.info,
          title: 'Business Info',
          subtitle: 'Name, type, and currency',
          screen: BusinessInfoScreen(),
        ),
        (
          icon: AppIcons.premium,
          tone: IconTileTone.warning,
          title: 'Subscription',
          subtitle: 'Plan, status, and renewal',
          screen: SubscriptionScreen(),
        ),
        (
          icon: AppIcons.store,
          tone: IconTileTone.green,
          title: 'Stores',
          subtitle: 'Your store locations',
          screen: StoresSettingsScreen(),
        ),
      ],
    ),
    (
      title: 'Access & Security',
      entries: [
        (
          icon: AppIcons.lock,
          tone: IconTileTone.danger,
          title: 'Security',
          subtitle: 'Auto-lock and biometric login',
          screen: SecuritySettingsScreen(),
        ),
        (
          icon: AppIcons.adminPanel,
          tone: IconTileTone.info,
          title: 'Roles & Permissions',
          subtitle: 'What each role can do',
          screen: RolesPermissionsScreen(),
        ),
        (
          icon: AppIcons.auditCheck,
          tone: IconTileTone.neutral,
          title: 'Activity Logs access',
          subtitle: 'Which roles can view activity logs',
          screen: ActivityLogsAccessScreen(),
        ),
        (
          icon: AppIcons.cloudSync,
          tone: IconTileTone.neutral,
          title: 'Sync Issues access',
          subtitle: 'Which roles can open Sync Issues',
          screen: SyncIssuesAccessScreen(),
        ),
      ],
    ),
    (
      title: 'Devices & Appearance',
      entries: [
        (
          icon: AppIcons.print,
          tone: IconTileTone.neutral,
          title: 'Receipt printer',
          subtitle: 'Paper size for each printer (58mm or 80mm)',
          screen: ReceiptPrinterSettingsScreen(),
        ),
        (
          icon: AppIcons.palette,
          tone: IconTileTone.info,
          title: 'Appearance',
          subtitle: 'Business colour (applies to all devices)',
          screen: AppearanceSettingsScreen(),
        ),
      ],
    ),
  ];

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final canManage = Gates.manageSettings.allows(ref);
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;

    final q = _query.trim().toLowerCase();
    bool matches(_SettingEntry e) =>
        e.title.toLowerCase().contains(q) ||
        e.subtitle.toLowerCase().contains(q);
    final groups = q.isEmpty
        ? _groups
        : [
            for (final g in _groups)
              if (g.entries.any(matches))
                (title: g.title, entries: g.entries.where(matches).toList()),
          ];
    // Danger Zone (§10.3) — CEO-only, pinned at the bottom. Gated on
    // Gates.deleteBusiness (only the CEO holds settings.delete_business),
    // compounded with the search-match condition.
    final showDangerZone =
        Gates.deleteBusiness.allows(ref) &&
        (q.isEmpty || _kDangerZoneKeywords.contains(q));

    final gap = context.getRSize(12);
    final groupGap = context.getRSize(24);
    // The mockup's group-label spacing: 16 above a label, 10 below it.
    final labelAbove = context.getRSize(16);
    final labelBelow = context.getRSize(10);

    return Container(
      decoration: AppDecorations.pageBackground(context),
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: _SettingsAppBar(
          storeLabel: ref.watch(activeStoreLabelProvider),
          // The theme's bar height, grown when the scaled header tile would
          // touch its edges (tablets and wide screens).
          height: math.max(
            kToolbarHeight + 12,
            context.getRSize(44) + context.getRSize(16),
          ),
        ),
        body: !canManage
            ? const SettingsNoAccess()
            : SettingsFadeIn(
                // Side insets (a cutout, a sideways nav bar) are cleared here;
                // under MainLayout they are already removed, so this is a no-op
                // there.
                child: SafeArea(
                  top: false,
                  bottom: false,
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final gutter = math.max(
                        context.getRSize(16),
                        (constraints.maxWidth - kSettingsMaxContentWidth) / 2,
                      );
                      return ListView(
                        key: const Key('settings-list'),
                        padding: EdgeInsets.fromLTRB(
                          gutter,
                          context.getRSize(16),
                          gutter,
                          groupGap + context.deviceBottomPadding,
                        ),
                        children: [
                          const _BusinessProfileCard(),
                          SizedBox(height: gap),
                          _SearchCard(
                            controller: _searchCtrl,
                            showClear: q.isNotEmpty,
                            onChanged: (v) => setState(() => _query = v),
                            onClear: () {
                              _searchCtrl.clear();
                              setState(() => _query = '');
                            },
                          ),
                          if (groups.isEmpty)
                            Padding(
                              padding: EdgeInsets.only(top: groupGap),
                              child: Center(
                                child: Text(
                                  'No settings match "${_query.trim()}".',
                                  textAlign: TextAlign.center,
                                  style: context
                                      .regularStyle(14)
                                      .copyWith(color: muted),
                                ),
                              ),
                            ),
                          for (final g in groups) ...[
                            SizedBox(height: labelAbove),
                            SectionHeader(
                              title: g.title,
                              variant: SectionHeaderVariant.group,
                            ),
                            SizedBox(height: labelBelow),
                            for (final (i, e) in g.entries.indexed) ...[
                              if (i > 0) SizedBox(height: gap),
                              SettingsRow(
                                icon: e.icon,
                                tone: e.tone,
                                title: e.title,
                                subtitle: e.subtitle,
                                onTap: () => _open(context, e.screen),
                              ),
                            ],
                          ],
                          if (showDangerZone) ...[
                            SizedBox(height: labelAbove),
                            const SectionHeader(
                              title: 'Danger zone',
                              variant: SectionHeaderVariant.group,
                            ),
                            SizedBox(height: labelBelow),
                            SettingsRow(
                              key: const Key('settings-delete-business'),
                              icon: AppIcons.deleteForever,
                              tone: IconTileTone.danger,
                              title: 'Delete Business',
                              subtitle:
                                  'Permanently delete this business and your '
                                  'account',
                              onTap: () =>
                                  _open(context, const DeleteBusinessScreen()),
                            ),
                          ],
                        ],
                      );
                    },
                  ),
                ),
              ),
      ),
    );
  }

  void _open(BuildContext context, Widget screen) {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));
  }
}

/// The solid top bar (flat with a soft fade): back arrow, the gradient gear
/// tile, "CEO Settings", the active store in primary and the live bell — the
/// shared [ScreenHeader] inside an `AppBar`, as its doc describes.
class _SettingsAppBar extends StatelessWidget implements PreferredSizeWidget {
  const _SettingsAppBar({required this.storeLabel, required this.height});

  final String storeLabel;
  final double height;

  @override
  Size get preferredSize => Size.fromHeight(height);

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final topBarShadow =
        t.extension<AppSchemeColors>()?.topBarShadow ?? Colors.transparent;
    // The back arrow shows exactly when the AppBar would imply one.
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
        icon: AppIcons.settings,
        title: 'CEO Settings',
        subtitle: storeLabel,
        leading: canGoBack
            ? IconButton(
                key: const Key('settings-back'),
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
        actions: const [_LiveBell()],
      ),
    );
  }
}

/// The shared [HeaderBell] fed by the live notification service; a tap opens
/// the same notifications modal as the app's `NotificationBell`.
class _LiveBell extends ConsumerWidget {
  const _LiveBell();

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

/// The business profile card: the shared [ProfileCard] with the business
/// name, the signed-in person, the PRO / FREE TRIAL tag (the drawer's §32
/// rule: `SubscriptionAccess.badgeLabel`) and the role tag. Display only.
///
/// The business logo, when set, fills the card's tile instead of the initial.
class _BusinessProfileCard extends ConsumerWidget {
  const _BusinessProfileCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final businessName = ref.watch(currentBusinessNameProvider);
    final userName = ref.watch(authProvider).currentUser?.name;
    final role = ref.watch(currentUserRoleProvider);
    final access = ref.watch(currentBusinessSubscriptionProvider);
    final logoPath = ref.watch(currentBusinessLogoPathProvider).valueOrNull;
    final subLabel = access.badgeLabel;

    final card = ProfileCard(
      logo: logoPath == null ? null : FileImage(File(logoPath)),
      key: const Key('settings-profile-card'),
      title: businessName,
      subtitle: userName,
      tags: [
        if (subLabel != null)
          (
            label: subLabel,
            tone: access == SubscriptionAccess.active
                ? TagPillTone.solidInfo
                : TagPillTone.warning,
          ),
        if (role != null) (label: role.name, tone: TagPillTone.info),
      ],
    );
    return card;
  }
}

/// Today's search field as a flat card with a primary search icon. The clear
/// button shows while there is a query.
class _SearchCard extends StatelessWidget {
  const _SearchCard({
    required this.controller,
    required this.showClear,
    required this.onChanged,
    required this.onClear,
  });

  final TextEditingController controller;
  final bool showClear;
  final ValueChanged<String> onChanged;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    return DecoratedBox(
      decoration: AppDecorations.card(context),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: kMinInteractiveDimension),
        child: Center(
          child: TextField(
            key: const Key('settings-search'),
            controller: controller,
            onChanged: onChanged,
            textInputAction: TextInputAction.search,
            style: context
                .mediumStyle(16)
                .copyWith(color: t.colorScheme.onSurface),
            decoration: InputDecoration(
              hintText: 'Search settings',
              hintStyle: context.regularStyle(16).copyWith(color: muted),
              prefixIcon: Padding(
                padding: EdgeInsets.only(
                  left: context.getRSize(14),
                  right: context.getRSize(8),
                ),
                child: AppIcon(
                  AppIcons.search,
                  size: context.getRSize(24),
                  color: t.colorScheme.primary,
                ),
              ),
              prefixIconConstraints: const BoxConstraints(
                minWidth: kMinInteractiveDimension,
                minHeight: kMinInteractiveDimension,
              ),
              suffixIcon: showClear
                  ? IconButton(
                      icon: AppIcon(AppIcons.close, color: muted),
                      tooltip: 'Clear',
                      onPressed: onClear,
                    )
                  : null,
              filled: false,
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,
              contentPadding: EdgeInsets.symmetric(
                vertical: context.getRSize(14),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
