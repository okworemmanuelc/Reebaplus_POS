import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:flutter_svg/flutter_svg.dart';

import 'package:reebaplus_pos/core/theme/theme_settings_screen.dart';
import 'package:reebaplus_pos/core/settings/settings_screen.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/features/profile/screens/profile_screen.dart';
import 'package:reebaplus_pos/features/sync/screens/sync_issues_screen.dart';
import 'package:reebaplus_pos/shared/widgets/user_tips_modal.dart';

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
            primary.withValues(alpha: 0.3),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
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
          SizedBox(height: context.getRSize(16)),
          // Sync status indicator. Three signals nested so the badge reflects
          // pending, failed, and online state; tap opens Sync Issues.
          // Skip while logged out — the inline DAO streams below build a fresh
          // tenant-scoped query on every rebuild and would otherwise hit
          // requireBusinessId() with no current business.
          if (user == null)
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
          SizedBox(height: context.getRSize(4)),
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
    );
  }

  Widget _buildNavList(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    final roleTier = ref.read(authProvider).currentUser?.roleTier ?? 0;
    final isBelowManager = roleTier < 5;

    return ListView(
      padding: EdgeInsets.symmetric(
        horizontal: context.getRSize(12),
        vertical: context.getRSize(16),
      ),
      children: [
        // Dashboard — managers and above only
        if (!isBelowManager)
          _navItem(
            context,
            FontAwesomeIcons.chartLine,
            'Dashboard',
            active: activeRoute == 'dashboard',
            onTap: () => _navigateTo(context, ref, 'dashboard'),
          ),
        _navItem(
          context,
          FontAwesomeIcons.cashRegister,
          'Point of Sale',
          active: activeRoute == 'pos',
          onTap: () => _navigateTo(context, ref, 'pos'),
        ),
        _navItem(
          context,
          FontAwesomeIcons.boxesStacked,
          'Inventory',
          active: activeRoute == 'inventory',
          onTap: () => _navigateTo(context, ref, 'inventory'),
        ),
        _navItem(
          context,
          FontAwesomeIcons.truckFast,
          'Orders',
          active: activeRoute == 'orders',
          onTap: () => _navigateTo(context, ref, 'orders'),
        ),
        _navItem(
          context,
          FontAwesomeIcons.users,
          'Customers',
          active: activeRoute == 'customers',
          onTap: () => _navigateTo(context, ref, 'customers'),
        ),
        // Items below are for managers and above only
        if (!isBelowManager) ...[
          _navItem(
            context,
            FontAwesomeIcons.moneyBillWave,
            'Supplier Accounts',
            active:
                activeRoute == 'supplier_accounts' || activeRoute == 'payments',
            onTap: () => _navigateTo(context, ref, 'supplier_accounts'),
          ),
          _navItem(
            context,
            FontAwesomeIcons.fileInvoiceDollar,
            'Expenses',
            active: activeRoute == 'expenses',
            onTap: () => _navigateTo(context, ref, 'expenses'),
          ),
          _navItem(
            context,
            FontAwesomeIcons.warehouse,
            'Warehouse',
            active: activeRoute == 'warehouse',
            onTap: () => _navigateTo(context, ref, 'warehouse'),
          ),
          _navItem(
            context,
            FontAwesomeIcons.userGroup,
            'Staff Management',
            active: activeRoute == 'staff',
            onTap: () => _navigateTo(context, ref, 'staff'),
          ),
        ],
        SizedBox(height: context.getRSize(12)),
        Divider(color: t.dividerColor),
        SizedBox(height: context.getRSize(12)),
        // Activity Logs and Deliveries — managers and above only
        if (!isBelowManager) ...[
          _navItem(
            context,
            FontAwesomeIcons.clockRotateLeft,
            'Activity Logs',
            active: activeRoute == 'activity_logs',
            onTap: () => _navigateTo(context, ref, 'activity_logs'),
          ),
          _navItem(
            context,
            FontAwesomeIcons.truckArrowRight,
            'Deliveries',
            active: activeRoute == 'deliveries',
            onTap: () => _navigateTo(context, ref, 'deliveries'),
          ),
        ],
        _navItem(
          context,
          FontAwesomeIcons.cartShopping,
          'Cart',
          active: activeRoute == 'cart',
          onTap: () => _navigateTo(context, ref, 'cart'),
        ),
        _navItem(
          context,
          FontAwesomeIcons.gear,
          'Settings',
          active: false,
          onTap: () {
            Navigator.pop(context);
            Navigator.of(
              context,
            ).push(MaterialPageRoute(builder: (_) => const SettingsScreen()));
          },
        ),
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
        _navItem(
          context,
          FontAwesomeIcons.lightbulb,
          'Pro Tips',
          active: false,
          onTap: () {
            Navigator.pop(context);
            UserTipsModal.show(context);
          },
        ),
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
          height: MediaQuery.of(context).padding.bottom + context.getRSize(20),
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
    } else if (route == 'warehouse') {
      nav.setIndex(7);
    } else if (route == 'staff') {
      nav.setIndex(8);
    } else if (route == 'cart') {
      nav.setIndex(9);
    } else if (route == 'deliveries') {
      nav.setIndex(10);
    } else if (route == 'activity_logs') {
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
                      'Appearance',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: context.getRFontSize(14),
                        color: Colors.white,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      'Theme & Display',
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

