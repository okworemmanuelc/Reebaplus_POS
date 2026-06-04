import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:reebaplus_pos/core/theme/theme_settings_screen.dart';
import 'package:reebaplus_pos/core/settings/settings_screen.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/features/profile/screens/profile_screen.dart';
import 'package:reebaplus_pos/features/staff/screens/staff_management_screen.dart';
import 'package:reebaplus_pos/features/sync/screens/sync_issues_screen.dart';
import 'package:reebaplus_pos/shared/utils/role_display.dart';

class AppDrawer extends ConsumerWidget {
  // Pass 'pos' or 'inventory' to highlight the correct nav item
  final String activeRoute;

  const AppDrawer({super.key, required this.activeRoute});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    return Drawer(
      backgroundColor: t.colorScheme.surface,
      child: Column(
        children: [
          _buildHeader(context, ref),
          Expanded(child: _buildNavList(context, ref)),
        ],
      ),
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
                  onTap: () {
                    Navigator.pop(context);
                    Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const ProfileScreen()),
                    );
                  },
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
                    Navigator.pop(context);
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
          else StreamBuilder<int>(
            stream: ref.read(databaseProvider).syncDao.watchPendingCount(),
            builder: (context, pendingSnap) {
              return StreamBuilder<int>(
                stream:
                    ref.read(databaseProvider).syncDao.watchFailedCount(),
                builder: (context, failedSnap) {
                  return ValueListenableBuilder<bool>(
                    valueListenable:
                        ref.read(supabaseSyncServiceProvider).isOnline,
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
                    onTap: () {
                      Navigator.pop(context);
                      Navigator.of(context).push(
                        MaterialPageRoute(
                            builder: (_) => const SyncIssuesScreen()),
                      );
                    },
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
                            Icon(Icons.error_outline,
                                size: 12, color: accent),
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
          Text(
            user?.name ?? '',
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurface,
              fontSize: context.getRFontSize(18),
              fontWeight: FontWeight.bold,
            ),
          ),
          SizedBox(height: context.getRSize(6)),
          Row(
            children: [
              // Role tag — colour by role (§27.1). Hidden until the role
              // resolves locally.
              if (role != null) ...[
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
                SizedBox(width: context.getRSize(8)),
              ],
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

    return ListView(
      padding: EdgeInsets.symmetric(
        horizontal: context.getRSize(12),
        vertical: context.getRSize(16),
      ),
      children: [
        _navItem(
          context,
          FontAwesomeIcons.chartLine,
          'Home',
          active: activeRoute == 'dashboard',
          onTap: () => _navigateTo(context, ref, 'dashboard'),
        ),
        // Point of Sale — hidden for Stock keeper (§27.3 / §12). sales.make is
        // held by CEO, Manager, Cashier — not Stock keeper.
        if (hasPermission(ref, 'sales.make'))
          _navItem(
            context,
            FontAwesomeIcons.cashRegister,
            'Point of Sale',
            active: activeRoute == 'pos',
            onTap: () => _navigateTo(context, ref, 'pos'),
          ),
        // Inventory — gated on stock.view (§16.7). Held by all four roles by
        // default, so visible to all unless the CEO revokes it for a role.
        if (hasPermission(ref, 'stock.view'))
          _navItem(
            context,
            FontAwesomeIcons.boxesStacked,
            'Inventory',
            active: activeRoute == 'inventory',
            onTap: () => _navigateTo(context, ref, 'inventory'),
          ),
        // Orders — visible to all four roles (§27.3).
        _navItem(
          context,
          FontAwesomeIcons.truckFast,
          'Orders',
          active: activeRoute == 'orders',
          onTap: () => _navigateTo(context, ref, 'orders'),
        ),
        // Funds Register — Manager/CEO only (§23.7). Replaces the old Cash
        // Register item (hard rule #8). funds.* are CEO + Manager permissions.
        if (hasPermission(ref, 'funds.view') ||
            hasPermission(ref, 'funds.open_day'))
          _navItem(
            context,
            FontAwesomeIcons.vault,
            'Funds Register',
            active: activeRoute == 'funds_register',
            onTap: () => _navigateTo(context, ref, 'funds_register'),
          ),
        // Customers — hidden for Stock keeper (§27.3). customers.add is held by
        // CEO, Manager, Cashier — not Stock keeper.
        if (hasPermission(ref, 'customers.add'))
          _navItem(
            context,
            FontAwesomeIcons.users,
            'Customers',
            active: activeRoute == 'customers',
            onTap: () => _navigateTo(context, ref, 'customers'),
          ),
        // Supplier Accounts — CEO always; Manager only if the CEO granted
        // suppliers.manage ("if toggled", §27.3); hidden for Cashier/Stock keeper.
        if (hasPermission(ref, 'suppliers.manage'))
          _navItem(
            context,
            FontAwesomeIcons.moneyBillWave,
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
            FontAwesomeIcons.fileInvoiceDollar,
            'Expenses',
            active: activeRoute == 'expenses',
            onTap: () => _navigateTo(context, ref, 'expenses'),
          ),
        // Stores — CEO only (§27.3). settings.manage is CEO-only by default.
        if (hasPermission(ref, 'settings.manage'))
          _navItem(
            context,
            FontAwesomeIcons.store,
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
            FontAwesomeIcons.clockRotateLeft,
            'Activity Logs',
            active: activeRoute == 'activity_logs',
            onTap: () => _navigateTo(context, ref, 'activity_logs'),
          ),
        // Deliveries (Phase 3) and Cart (bottom nav only) removed from the
        // sidebar per master plan §27.5.
        // Gated to roles that can invite staff (CEO + Manager). Hidden
        // entirely for Cashier / Stock keeper (hard rule #7 — hide, don't
        // grey out). Routes to a pushed screen, like CEO Settings below.
        if (hasPermission(ref, 'staff.invite'))
          _navItem(
            context,
            FontAwesomeIcons.userGroup,
            'Staff Management',
            active: false,
            onTap: () {
              Navigator.pop(context);
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => const StaffManagementScreen(),
                ),
              );
            },
          ),
        // Gated to CEO (settings.manage is CEO-only by default; migration
        // 0043). Hidden entirely for other roles (hard rule #7 — hide, don't
        // grey out), mirroring the Staff Management gate above.
        if (hasPermission(ref, 'settings.manage'))
          _navItem(
            context,
            FontAwesomeIcons.gear,
            'CEO Settings',
            active: false,
            onTap: () {
              Navigator.pop(context);
              Navigator.of(
                context,
              ).push(MaterialPageRoute(builder: (_) => const SettingsScreen()));
            },
          ),
        // Sync Issues — troubleshooting screen gated on sync.view (CEO always +
        // whoever the CEO granted it via Sync Issues access). Hidden entirely
        // for other roles (hard rule #7).
        if (canViewSyncIssues(ref))
          _navItem(
            context,
            FontAwesomeIcons.cloudArrowUp,
            'Sync Issues',
            active: false,
            onTap: () {
              Navigator.pop(context);
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const SyncIssuesScreen()),
              );
            },
          ),
        // Pro Tips removed from the sidebar (decision Q7 — not surfaced in
        // Phase 1; UserTipsModal stays in code for Phase 2).
        SizedBox(height: context.getRSize(12)),
        Divider(color: t.dividerColor),
        SizedBox(height: context.getRSize(12)),
        _navItem(
          context,
          FontAwesomeIcons.rightFromBracket,
          'Log Out',
          active: false,
          outlined: true,
          iconColor: t.colorScheme.error,
          labelColor: t.colorScheme.error,
          onTap: () {
            Navigator.pop(context); // close the drawer first
            ref
                .read(authProvider)
                .fullLogout(); // terminally logs out → main.dart shows email screen
          },
        ),
        SizedBox(height: context.getRSize(12)),
        Divider(color: t.dividerColor),
        SizedBox(height: context.getRSize(12)),
        _buildAppearanceTile(context),
        // Extra space for system navigation bar
        SizedBox(
          height: context.deviceBottomInset + context.getRSize(20),
        ),
      ],
    );
  }

  // ── Navigation logic — now uses NavigationService shell ────────────────────
  void _navigateTo(BuildContext context, WidgetRef ref, String route) {
    Navigator.pop(context);
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
    } else if (route == 'deliveries') {
      nav.setIndex(9);
    } else if (route == 'activity_logs') {
      nav.setIndex(10);
    } else if (route == 'funds_register') {
      nav.setIndex(11);
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
                    FontAwesomeIcons.palette,
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
                FontAwesomeIcons.chevronRight,
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

