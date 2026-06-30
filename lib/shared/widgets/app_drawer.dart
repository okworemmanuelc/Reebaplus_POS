import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/theme/theme_settings_screen.dart';
import 'package:reebaplus_pos/core/settings/settings_screen.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/features/profile/screens/profile_screen.dart';
import 'package:reebaplus_pos/features/subscription/subscription_access.dart';
import 'package:reebaplus_pos/features/subscription/widgets/subscription_badge.dart';
import 'package:reebaplus_pos/features/settings/screens/staff_settings_screen.dart';
import 'package:reebaplus_pos/features/staff/screens/staff_management_screen.dart';
import 'package:reebaplus_pos/features/sync/screens/sync_issues_screen.dart';
import 'package:reebaplus_pos/features/sync/widgets/resolve_unsynced_data_dialog.dart';
import 'package:reebaplus_pos/shared/utils/role_display.dart';
import 'package:reebaplus_pos/shared/services/auth_service.dart';
import 'package:reebaplus_pos/shared/widgets/store_picker_sheet.dart';
import 'package:reebaplus_pos/core/utils/notifications.dart';

class AppDrawer extends ConsumerWidget {
  // Pass 'pos' or 'inventory' to highlight the correct nav item
  final String activeRoute;

  const AppDrawer({super.key, required this.activeRoute});

  void _pushRoute(BuildContext context, WidgetRef ref, Widget screen) {
    if (!context.isDesktop) {
      Navigator.pop(context);
    }
    final nav = ref.read(navigationProvider);
    if (context.isDesktop) {
      final tabState = nav.tabNavigatorKeys[nav.currentIndex.value].currentState;
      tabState?.push(MaterialPageRoute(builder: (_) => screen));
    } else {
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    final content = Column(
      children: [
        _buildHeader(context, ref),
        Expanded(child: _buildNavList(context, ref)),
      ],
    );

    if (context.isDesktop) {
      return Container(
        color: t.colorScheme.surface,
        child: content,
      );
    }

    return Drawer(
      backgroundColor: t.colorScheme.surface,
      child: content,
    );
  }

  Widget _buildHeader(BuildContext context, WidgetRef ref) {
    final primary = Theme.of(context).colorScheme.primary;
    // Watch (not read) so this widget rebuilds the moment AuthService.value
    // flips to null during fullLogout. Drawer may still be mounted (popping
    // animation) when the sync streams below would otherwise be re-built and
    // trip requireBusinessId(). See plan: curried-tinkering-hinton.md.
    final user = ref.watch(authProvider).currentUser;
    // Role tag for the profile area (§27.1). Null until the membership + role
    // rows resolve locally; fall back to the theme primary while null.
    final role = ref.watch(currentUserRoleProvider);
    final roleColor = role == null ? primary : roleTagColor(role.slug);
    // §32 PRO / FREE TRIAL tag next to the name — only when the business is paid
    // or in trial (the badge itself decides which label).
    final showSubBadge =
        ref.watch(currentBusinessSubscriptionProvider).badgeLabel != null;
    return Container(
      width: double.infinity,
      padding: EdgeInsets.fromLTRB(
        context.getRSize(20),
        context.getRSize(60),
        context.getRSize(20),
        context.getRSize(28),
      ),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            Theme.of(context).scaffoldBackgroundColor,
            roleColor.withValues(alpha: 0.3),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Material(
                color: Colors.transparent,
                child: InkWell(
                  borderRadius: BorderRadius.circular(14),
                  onTap: () => _pushRoute(context, ref, const ProfileScreen()),
                  child: Container(
                    width: context.getRSize(56),
                    height: context.getRSize(56),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(14),
                      boxShadow: [
                        BoxShadow(
                          color: primary.withValues(alpha: 0.4),
                          blurRadius: 16,
                          spreadRadius: 2,
                        ),
                      ],
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(14),
                      child: SvgPicture.asset(
                        'assets/images/logo.svg',
                        fit: BoxFit.contain,
                      ),
                    ),
                  ),
                ),
              ),
              if (user != null)
                IconButton(
                  // Switch User — returns to the Who Is Working picker
                  // (master plan §8.5), not a full logout.
                  icon: const FaIcon(FontAwesomeIcons.rightLeft, size: 18),
                  tooltip: 'Switch User',
                  color: Theme.of(
                    context,
                  ).colorScheme.onSurface.withValues(alpha: 0.85),
                  onPressed: () async {
                    // Pop the drawer first — mirrors the Log Out pattern below
                    // so the watched currentUser flipping to null doesn't trip
                    // tenant-scoped widgets while the drawer is still painting.
                    if (!context.isDesktop) Navigator.pop(context);
                    // Drop any stale paused-time marker so a rapid
                    // background→resume right after lock doesn't double-fire
                    // the auto-lock branch.
                    final prefs = await SharedPreferences.getInstance();
                    await prefs.remove('app_paused_time');
                    ref.read(authProvider).lockApp();
                  },
                ),
            ],
          ),
          SizedBox(height: context.getRSize(16)),
          // Sync status indicator. Three signals nested so the badge reflects
          // pending, failed, and online state; tap opens Sync Issues.
          // Gated on sync.view (CEO always + whoever the CEO granted it), so
          // non-permitted roles never tap into a screen they can't open (hard
          // rule #7). Skip while logged out — the inline DAO streams below build
          // a fresh tenant-scoped query on every rebuild and would otherwise hit
          // requireBusinessId() with no current business.
          if (user == null || !canViewSyncIssues(ref))
            const SizedBox.shrink()
          else
            StreamBuilder<int>(
              stream: ref.read(databaseProvider).syncDao.watchPendingCount(),
              builder: (context, pendingSnap) {
                return StreamBuilder<int>(
                  stream: ref.read(databaseProvider).syncDao.watchFailedCount(),
                  builder: (context, failedSnap) {
                    return ValueListenableBuilder<bool>(
                      valueListenable: ref
                          .read(supabaseSyncServiceProvider)
                          .isOnline,
                      builder: (context, online, _) {
                        final pending = pendingSnap.data ?? 0;
                        final failed = failedSnap.data ?? 0;
                        if (pending == 0 && failed == 0) {
                          return const SizedBox.shrink();
                        }
                        final hasFailures = failed > 0;
                        final accent = hasFailures
                            ? Theme.of(context).colorScheme.error
                            : Theme.of(context).colorScheme.primary;
                        final label = !online && pending > 0
                            ? 'Offline — $pending queued'
                            : hasFailures && pending == 0
                            ? '$failed failed'
                            : pending > 0 && hasFailures
                            ? 'Syncing $pending · $failed failed'
                            : 'Syncing $pending file${pending == 1 ? '' : 's'}…';
                        return InkWell(
                          borderRadius: BorderRadius.circular(10),
                          onTap: () => _pushRoute(context, ref, const SyncIssuesScreen()),
                          child: Container(
                            margin: const EdgeInsets.only(bottom: 12),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 6,
                            ),
                            decoration: BoxDecoration(
                              color: accent.withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (!hasFailures)
                                  SizedBox(
                                    width: 10,
                                    height: 10,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 1.5,
                                      color: accent,
                                    ),
                                  )
                                else
                                  Icon(
                                    Icons.error_outline,
                                    size: 12,
                                    color: accent,
                                  ),
                                const SizedBox(width: 8),
                                Text(
                                  label,
                                  style: TextStyle(
                                    color: accent.withValues(alpha: 0.9),
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    );
                  },
                );
              },
            ),
          Row(
            children: [
              Flexible(
                child: Text(
                  user?.name ?? '',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurface,
                    fontSize: context.getRFontSize(18),
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              // §32 PRO / FREE TRIAL tag — sits right after the name.
              if (showSubBadge) ...[
                SizedBox(width: context.getRSize(8)),
                const SubscriptionBadge(),
              ],
            ],
          ),
          SizedBox(height: context.getRSize(6)),
          Wrap(
            spacing: context.getRSize(8),
            runSpacing: context.getRSize(6),
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              // Role tag — colour by role (§27.1). Hidden until the role
              // resolves locally.
              if (role != null)
                Container(
                  padding: EdgeInsets.symmetric(
                    horizontal: context.getRSize(10),
                    vertical: context.getRSize(4),
                  ),
                  decoration: BoxDecoration(
                    color: roleColor.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    role.name,
                    style: TextStyle(
                      color: roleColor,
                      fontSize: context.getRFontSize(12),
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              Container(
                padding: EdgeInsets.symmetric(
                  horizontal: context.getRSize(10),
                  vertical: context.getRSize(4),
                ),
                decoration: BoxDecoration(
                  color: Theme.of(
                    context,
                  ).colorScheme.onSurface.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  'Terminal 01',
                  style: TextStyle(
                    color: Theme.of(
                      context,
                    ).colorScheme.onSurface.withValues(alpha: 0.8),
                    fontSize: context.getRFontSize(12),
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildNavList(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    // Role slug drives the two staff-vs-CEO splits below: the self-service
    // "Settings" item (roles below CEO) and where the "Display" tile lives.
    final slug = ref.watch(currentUserRoleProvider)?.slug;
    final isBelowCeo = slug != null && slug != 'ceo';

    return ListView(
      padding: EdgeInsets.symmetric(
        horizontal: context.getRSize(12),
        vertical: context.getRSize(16),
      ),
      children: [
        // §12.1 store picker — the one app-wide active-store control. Sits above
        // Home; only shows when the user can choose more than one store.
        _buildStorePicker(context, ref),
        _navItem(
          context,
          FontAwesomeIcons.chartLine.data,
          'Home',
          active: activeRoute == 'dashboard',
          onTap: () => _navigateTo(context, ref, 'dashboard'),
        ),
        // Point of Sale — hidden for Stock keeper (§27.3 / §12). sales.make is
        // held by CEO, Manager, Cashier — not Stock keeper.
        if (hasPermission(ref, 'sales.make'))
          _navItem(
            context,
            FontAwesomeIcons.cashRegister.data,
            'Point of Sale',
            active: activeRoute == 'pos',
            onTap: () => _navigateTo(context, ref, 'pos'),
          ),
        // Inventory — gated on stock.view (§16.7). Held by all four roles by
        // default, so visible to all unless the CEO revokes it for a role.
        if (hasPermission(ref, 'stock.view'))
          _navItem(
            context,
            FontAwesomeIcons.boxesStacked.data,
            'Inventory',
            active: activeRoute == 'inventory',
            onTap: () => _navigateTo(context, ref, 'inventory'),
          ),
        // Orders — visible to all four roles (§27.3).
        _navItem(
          context,
          FontAwesomeIcons.truckFast.data,
          'Orders',
          active: activeRoute == 'orders',
          onTap: () => _navigateTo(context, ref, 'orders'),
        ),
        // Customers — hidden for Stock keeper (§27.3). customers.add is held by
        // CEO, Manager, Cashier — not Stock keeper.
        if (hasPermission(ref, 'customers.add'))
          _navItem(
            context,
            FontAwesomeIcons.users.data,
            'Customers',
            active: activeRoute == 'customers',
            onTap: () => _navigateTo(context, ref, 'customers'),
          ),
        // Gated to roles that can invite staff (CEO + Manager). Hidden
        // entirely for Cashier / Stock keeper (hard rule #7 — hide, don't
        // grey out). Routes to a pushed screen, like CEO Settings below.
        if (hasPermission(ref, 'staff.invite'))
          _navItem(
            context,
            FontAwesomeIcons.userGroup.data,
            'Staff Management',
            active: false,
            onTap: () => _pushRoute(context, ref, const StaffManagementScreen()),
          ),
        // Supplier Accounts — CEO always; Manager only if the CEO granted
        // suppliers.manage ("if toggled", §27.3); hidden for Cashier/Stock keeper.
        if (hasPermission(ref, 'suppliers.manage'))
          _navItem(
            context,
            FontAwesomeIcons.moneyBillWave.data,
            'Supplier Accounts',
            active:
                activeRoute == 'supplier_accounts' || activeRoute == 'payments',
            onTap: () => _navigateTo(context, ref, 'supplier_accounts'),
          ),
        // Expenses — opens the expense report/list, so gate on the viewing key
        // `reports.see_expenses` (hard rule #6), not `expenses.create` (that's
        // only the Add-Expense action). Neither is held by Cashier/Stock keeper.
        if (hasPermission(ref, 'reports.see_expenses'))
          _navItem(
            context,
            FontAwesomeIcons.fileInvoiceDollar.data,
            'Expenses',
            active: activeRoute == 'expenses',
            onTap: () => _navigateTo(context, ref, 'expenses'),
          ),
        // Stores — CEO (stores.manage) plus any Manager who can take part in
        // the store-scoped transfer flow (§16.8.2): request / dispatch / receive.
        // The store list itself is read-only browsing for non-CEOs; full
        // per-store actions are gated inside the store details screen.
        if (hasPermission(ref, 'stores.manage') ||
            hasPermission(ref, 'stores.request_transfer') ||
            hasPermission(ref, 'stores.dispatch_transfer') ||
            hasPermission(ref, 'stores.receive_transfer'))
          _navItem(
            context,
            FontAwesomeIcons.store.data,
            'Stores',
            active: activeRoute == 'store',
            onTap: () => _navigateTo(context, ref, 'store'),
          ),
        SizedBox(height: context.getRSize(12)),
        Divider(color: t.dividerColor),
        SizedBox(height: context.getRSize(12)),
        // Activity Logs — CEO always; Manager only if the CEO granted
        // activity_logs.view ("if toggled", §27.3); hidden for Cashier/Stock keeper.
        if (hasPermission(ref, 'activity_logs.view'))
          _navItem(
            context,
            FontAwesomeIcons.clockRotateLeft.data,
            'Activity Logs',
            active: activeRoute == 'activity_logs',
            onTap: () => _navigateTo(context, ref, 'activity_logs'),
          ),
        // Deliveries (Phase 3) and Cart (bottom nav only) removed from the
        // sidebar per master plan §27.5.
        // Gated to CEO (settings.manage is CEO-only by default; migration
        // 0043). Hidden entirely for other roles (hard rule #7 — hide, don't
        // grey out), mirroring the Staff Management gate above.
        if (hasPermission(ref, 'settings.manage'))
          _navItem(
            context,
            FontAwesomeIcons.gear.data,
            'CEO Settings',
            active: false,
            onTap: () => _pushRoute(context, ref, const SettingsScreen()),
          ),
        // Staff Settings (§10.5) — self-service settings home for roles BELOW
        // CEO (profile edit, change PIN, Display mode). Mutually exclusive with
        // CEO Settings above: the CEO uses that, never this. Hidden entirely for
        // the CEO (hard rule #7).
        if (isBelowCeo)
          _navItem(
            context,
            FontAwesomeIcons.gear.data,
            'Settings',
            active: false,
            onTap: () => _pushRoute(context, ref, const StaffSettingsScreen()),
          ),
        // Sync Issues — troubleshooting screen gated on sync.view (CEO always +
        // whoever the CEO granted it via Sync Issues access). Hidden entirely
        // for other roles (hard rule #7).
        if (canViewSyncIssues(ref))
          _navItem(
            context,
            FontAwesomeIcons.cloudArrowUp.data,
            'Sync Issues',
            active: false,
            onTap: () => _pushRoute(context, ref, const SyncIssuesScreen()),
          ),
        // Pro Tips removed from the sidebar (decision Q7 — not surfaced in
        // Phase 1; UserTipsModal stays in code for Phase 2).
        SizedBox(height: context.getRSize(12)),
        Divider(color: t.dividerColor),
        SizedBox(height: context.getRSize(12)),
        _navItem(
          context,
          FontAwesomeIcons.rightFromBracket.data,
          'Log Out',
          active: false,
          outlined: true,
          iconColor: t.colorScheme.error,
          labelColor: t.colorScheme.error,
          onTap: () async {
            // Log Out (master plan §7.6): signs THIS user out and resets their
            // PIN so the old PIN can't unlock again — they re-auth with email +
            // a code and a new PIN. It is NOT a device wipe: the till's data and
            // other staff's PINs are kept. All roles use this one button.
            // Capture the provider up front — `ref` is invalidated once this
            // widget unmounts mid-await.
            final auth = ref.read(authProvider);
            final db = ref.read(databaseProvider);
            final user = auth.currentUser;

            int deviceStaffCount = 0;
            if (user != null) {
              deviceStaffCount = await db.userBusinessesDao.countDeviceStaffForBusiness(user.businessId);
            }
            final isSoleUser = deviceStaffCount <= 1;

            if (!context.mounted) return;

            final confirmed = await showDialog<bool>(
              context: context,
              builder: (ctx) => AlertDialog(
                title: Text(isSoleUser ? 'Log out and erase all data?' : 'Log out of this device?'),
                content: Text(
                  isSoleUser
                      ? "Logging out of the sole user on this device will erase all local data. You will re-download it after signing in again.\n\n"
                          "You'll need your email + a one-time code, and a new PIN, to sign back in."
                      : "You'll need your email + a one-time code, and a new PIN, to "
                          'sign back in. The till keeps its data and other staff stay '
                          'signed in.\n\n'
                          'To just switch staff, use Switch User instead.',
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.of(ctx).pop(false),
                    child: const Text('Cancel'),
                  ),
                  TextButton(
                    onPressed: () => Navigator.of(ctx).pop(true),
                    child: Text(isSoleUser ? 'Log out & Erase' : 'Log out'),
                  ),
                ],
              ),
            );
            if (confirmed != true) return;
            if (context.mounted && !context.isDesktop) Navigator.pop(context); // close the drawer
            try {
              await auth.logOutCurrentUser(); // → main.dart routes to Welcome
            } on LogoutBlockedByUnsyncedDataException catch (e) {
              // §3.1 two-tier resolution: un-pushable orphans block the wipe but
              // must never trap the user. Route to the export → typed-confirm
              // discard → logout flow instead of refusing outright.
              if (context.mounted) {
                await showResolveUnsyncedDataDialog(
                  context,
                  ref,
                  pendingCount: e.pendingCount,
                  orphanCount: e.orphanCount,
                );
              }
            } on LogoutWipeException catch (e) {
              if (context.mounted) {
                AppNotification.showError(context, e.message);
              }
            } catch (e) {
              if (context.mounted) {
                AppNotification.showError(context, 'An unexpected error occurred during logout.');
              }
            }
          },
        ),
        SizedBox(height: context.getRSize(12)),
        Divider(color: t.dividerColor),
        SizedBox(height: context.getRSize(12)),
        // "Display" (light/dark mode) — stays in the side menu for the CEO (and
        // while the role is still resolving, so it's never unreachable). For
        // roles below CEO it now lives inside Staff Settings (§10.5).
        if (!isBelowCeo) _buildAppearanceTile(context),
        // Extra space for system navigation bar
        SizedBox(height: context.deviceBottomPadding + context.getRSize(20)),
      ],
    );
  }

  // ── Navigation logic — now uses NavigationService shell ────────────────────
  void _navigateTo(BuildContext context, WidgetRef ref, String route) {
    if (!context.isDesktop) Navigator.pop(context);
    final nav = ref.read(navigationProvider);

    if (route == 'dashboard') {
      nav.setIndex(0);
    } else if (route == 'pos') {
      nav.setIndex(1);
    } else if (route == 'inventory') {
      nav.setIndex(2);
    } else if (route == 'orders') {
      nav.setIndex(3);
    } else if (route == 'customers') {
      nav.setIndex(4);
    } else if (route == 'supplier_accounts' || route == 'payments') {
      nav.setIndex(5);
    } else if (route == 'expenses') {
      nav.setIndex(6);
    } else if (route == 'store') {
      nav.setIndex(7);
    } else if (route == 'cart') {
      nav.setIndex(8);
    } else if (route == 'activity_logs') {
      nav.setIndex(9);
    }
  }

  Widget _navItem(
    BuildContext context,
    IconData icon,
    String label, {
    bool active = false,
    bool outlined = false,
    VoidCallback? onTap,
    Color? iconColor,
    Color? labelColor,
  }) {
    final t = Theme.of(context);
    final primary = t.colorScheme.primary;
    final cardColor = t.cardColor;
    final subtextColor = t.textTheme.bodySmall?.color ?? t.iconTheme.color!;
    final textColor = t.colorScheme.onSurface;

    return Container(
      margin: EdgeInsets.only(bottom: context.getRSize(6)),
      decoration: outlined
          ? BoxDecoration(
              border: Border.all(
                color: t.colorScheme.error.withValues(alpha: 0.5),
              ),
              borderRadius: BorderRadius.circular(14),
            )
          : null,
      child: Material(
        color: active ? primary.withValues(alpha: 0.1) : Colors.transparent,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onTap ?? () {},
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: context.getRSize(16),
              vertical: context.getRSize(12),
            ),
            child: Row(
              children: [
                Container(
                  width: context.getRSize(36),
                  height: context.getRSize(36),
                  decoration: BoxDecoration(
                    color: active ? primary.withValues(alpha: 0.2) : cardColor,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(
                    icon,
                    size: context.getRSize(16),
                    color: iconColor ?? (active ? primary : subtextColor),
                  ),
                ),
                SizedBox(width: context.getRSize(14)),
                Expanded(
                  child: Text(
                    label,
                    style: TextStyle(
                      fontWeight: active ? FontWeight.bold : FontWeight.w600,
                      fontSize: context.getRFontSize(14.5),
                      color: labelColor ?? (active ? primary : textColor),
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (active) ...[
                  SizedBox(width: context.getRSize(8)),
                  Container(
                    width: context.getRSize(6),
                    height: context.getRSize(6),
                    decoration: BoxDecoration(
                      color: primary,
                      shape: BoxShape.circle,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// §12.1 store picker — the single app-wide active-store control. Drives the
  /// view on Home/Inventory/POS/Customers/Activity Log via `lockedStoreId`
  /// (null = "All Stores"). Hidden unless the user can choose >1 store. Styled to
  /// match `_navItem` so it reads as part of the nav and follows the active theme.
  Widget _buildStorePicker(BuildContext context, WidgetRef ref) {
    final selectable = ref.watch(selectableStoresProvider);
    if (selectable.length < 2) return const SizedBox.shrink();

    final canViewAll = ref.watch(canViewAllStoresProvider);
    final activeId = ref.watch(lockedStoreProvider).value;

    final t = Theme.of(context);
    final primary = t.colorScheme.primary;
    final subtextColor = t.textTheme.bodySmall?.color ?? t.iconTheme.color!;
    final textColor = t.colorScheme.onSurface;

    StoreData? activeStore;
    for (final s in selectable) {
      if (s.id == activeId) {
        activeStore = s;
        break;
      }
    }
    final label =
        activeStore?.name ??
        (canViewAll ? 'All Stores' : selectable.first.name);

    return Container(
      margin: EdgeInsets.only(bottom: context.getRSize(6)),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () => showStorePickerSheet(
            context,
            ref,
            onSelected: () => ref.read(navigationProvider).closeDrawer(),
          ),
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: context.getRSize(16),
              vertical: context.getRSize(10),
            ),
            child: Row(
              children: [
                Container(
                  width: context.getRSize(36),
                  height: context.getRSize(36),
                  decoration: BoxDecoration(
                    color: primary.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(
                    FontAwesomeIcons.store.data,
                    size: context.getRSize(15),
                    color: primary,
                  ),
                ),
                SizedBox(width: context.getRSize(14)),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'Store',
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: context.getRFontSize(11),
                          color: subtextColor,
                        ),
                      ),
                      Text(
                        label,
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: context.getRFontSize(14.5),
                          color: textColor,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                SizedBox(width: context.getRSize(8)),
                Icon(
                  FontAwesomeIcons.chevronDown.data,
                  size: context.getRSize(13),
                  color: subtextColor,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Appearance tile that navigates to the full Theme Settings screen.
  Widget _buildAppearanceTile(BuildContext context) {
    final t = Theme.of(context);
    final primary = t.colorScheme.primary;

    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: context.getRSize(16),
        vertical: context.getRSize(12),
      ),
      child: GestureDetector(
        onTap: () {
          Navigator.pop(context); // close drawer
          Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const ThemeSettingsScreen()),
          );
        },
        child: Container(
          width: double.infinity,
          padding: EdgeInsets.symmetric(
            horizontal: context.getRSize(16),
            vertical: context.getRSize(14),
          ),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [primary, primary.withValues(alpha: 0.7)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(14),
            boxShadow: [
              BoxShadow(
                color: primary.withValues(alpha: 0.3),
                blurRadius: 8,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Row(
            children: [
              Container(
                width: context.getRSize(32),
                height: context.getRSize(32),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Center(
                  child: Icon(
                    FontAwesomeIcons.palette.data,
                    size: context.getRSize(14),
                    color: Colors.white,
                  ),
                ),
              ),
              SizedBox(width: context.getRSize(14)),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Display',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: context.getRFontSize(14),
                        color: Colors.white,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      'Light & dark mode',
                      style: TextStyle(
                        fontSize: context.getRFontSize(11),
                        color: Colors.white.withValues(alpha: 0.7),
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                FontAwesomeIcons.chevronRight.data,
                size: context.getRSize(14),
                color: Colors.white.withValues(alpha: 0.8),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Navigation Registration (Now Legacy/Optional) ───────────────────────────
// These were used to break circular imports before the MainLayout shell refactor.
// Current MainLayout directly imports screens, but keeping definitions for reference
// or until all feature-to-drawer links are fully migrated to NvigationService.
