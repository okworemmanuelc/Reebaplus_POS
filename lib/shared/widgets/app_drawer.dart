import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/permissions/permissions.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/settings/settings_screen.dart';
import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:reebaplus_pos/core/theme/theme_settings_screen.dart';
import 'package:reebaplus_pos/core/utils/frame_safe.dart';
import 'package:reebaplus_pos/core/utils/notifications.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/features/profile/screens/profile_screen.dart';
import 'package:reebaplus_pos/features/settings/screens/staff_settings_screen.dart';
import 'package:reebaplus_pos/features/staff/screens/staff_management_screen.dart';
import 'package:reebaplus_pos/features/subscription/subscription_access.dart';
import 'package:reebaplus_pos/features/sync/screens/sync_issues_screen.dart';
import 'package:reebaplus_pos/features/sync/widgets/resolve_unsynced_data_dialog.dart';
import 'package:reebaplus_pos/features/van_sales/screens/van_sales_hub_screen.dart';
import 'package:reebaplus_pos/shared/services/auth_service.dart';
import 'package:reebaplus_pos/shared/services/navigation_service.dart';
import 'package:reebaplus_pos/shared/widgets/app_drawer_parts.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/redesign.dart';
import 'package:reebaplus_pos/shared/widgets/spotlight_target.dart';
import 'package:reebaplus_pos/shared/widgets/store_picker_sheet.dart';

/// Below this much height (after the system insets) the header scrolls with
/// the list instead of staying pinned, so a sideways phone keeps room for the
/// items while the footer stays pinned (#368). Measured from the drawer's
/// own constraints, never from `isShortViewport` (PRD #239).
const double _kPinnedHeaderMinHeight = 560;

class AppDrawer extends ConsumerWidget {
  // Pass 'pos' or 'inventory' to highlight the correct nav item
  final String activeRoute;

  const AppDrawer({super.key, required this.activeRoute});

  /// Closes the drawer, then opens [screen] inside the current tab, so the
  /// bottom bar / rail stays put. Under 600dp the drawer sits in the tab's own
  /// Scaffold, so the tab Navigator is also the nearest one; at 600dp+ (#352)
  /// it sits in MainLayout's Scaffold, whose nearest Navigator is the root one,
  /// so the tab Navigator is named explicitly.
  void _pushRoute(BuildContext context, WidgetRef ref, Widget screen) {
    final nav = ref.read(navigationProvider);
    final tabState = nav.currentIndex.value < nav.tabNavigatorKeys.length
        ? nav.tabNavigatorKeys[nav.currentIndex.value].currentState
        : null;
    final target = tabState ?? Navigator.of(context);
    Navigator.pop(context); // close the drawer
    target.push(MaterialPageRoute(builder: (_) => screen));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    final insets = MediaQuery.paddingOf(context);
    // Roles below CEO find "Display" inside Staff Settings (§10.5); the CEO
    // (and anyone whose role is still resolving) gets it in the footer.
    final slug = ref.watch(currentUserRoleProvider)?.slug;
    final isBelowCeo = slug != null && slug != 'ceo';

    final side = context.getRSize(14);
    // The header's own padding; inside the scrolling list (short window) the
    // list's side padding already supplies most of it.
    Widget header({required bool isInList}) => Padding(
      padding: EdgeInsets.fromLTRB(
        context.getRSize(isInList ? 4 : 18),
        insets.top + context.getRSize(16),
        isInList ? 0 : context.getRSize(8),
        context.getRSize(16),
      ),
      child: _buildHeader(context, ref),
    );
    final footer = DrawerFooter(
      bottomPadding: context.deviceBottomPadding,
      onDisplay: isBelowCeo
          ? null
          : () => _pushRoute(context, ref, const ThemeSettingsScreen()),
      onLogOut: () => _logOut(context, ref),
    );

    // A pop-over drawer at every size (#352); the permanent desktop sidebar
    // is gone. The Surface runs under a left cutout; the content stays clear.
    return Drawer(
      width: appDrawerWidth(context),
      backgroundColor: t.colorScheme.surface,
      child: DrawerPresence(
        child: Padding(
          padding: EdgeInsets.only(left: insets.left),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final available =
                  constraints.maxHeight - insets.top - insets.bottom;
              final pinHeader = available >= _kPinnedHeaderMinHeight;
              final list = _buildNavList(
                context,
                ref,
                isBelowCeo: isBelowCeo,
                leading: pinHeader ? null : header(isInList: true),
                padding: EdgeInsets.fromLTRB(
                  side,
                  pinHeader ? context.getRSize(14) : 0,
                  side,
                  context.getRSize(14),
                ),
              );
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (pinHeader) ...[
                    header(isInList: false),
                    Divider(height: 1, thickness: 1, color: t.dividerColor),
                  ],
                  Expanded(child: list),
                  footer,
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context, WidgetRef ref) {
    // Watch (not read) so this widget rebuilds the moment AuthService.value
    // flips to null during fullLogout. Drawer may still be mounted (popping
    // animation) when the sync streams below would otherwise be re-built and
    // trip requireBusinessId(). See plan: curried-tinkering-hinton.md.
    final user = ref.watch(authProvider).currentUser;
    // Role tag for the profile area (§27.1). Null until the membership + role
    // rows resolve locally; hidden while null.
    final role = ref.watch(currentUserRoleProvider);
    // §32 PRO / FREE TRIAL tag — only when the business is paid or in trial
    // (`badgeLabel` decides which label). Fixed tag colours (PRD #346 decision
    // 6): PRO solid blue as in the mockup, FREE TRIAL amber as before.
    final subscription = ref.watch(currentBusinessSubscriptionProvider);
    final subscriptionLabel = subscription.badgeLabel;
    final businessName = ref.watch(currentBusinessNameProvider);
    final logoPath = ref.watch(currentBusinessLogoPathProvider).valueOrNull;

    return DrawerHeaderBlock(
      businessName: businessName,
      logoPath: logoPath,
      userName: user?.name ?? '',
      terminalLabel: 'Terminal 01',
      tags: [
        if (subscriptionLabel != null)
          (
            label: subscriptionLabel,
            tone: subscription == SubscriptionAccess.active
                ? TagPillTone.solidInfo
                : TagPillTone.warning,
          ),
        if (role != null) (label: role.name, tone: TagPillTone.info),
      ],
      onOpenProfile: () => _pushRoute(context, ref, const ProfileScreen()),
      onClose: () => Navigator.pop(context),
      // Lock — a quick lock back to the PIN screen, not a full logout.
      onLock: user == null
          ? null
          : () async {
              // Pop the drawer first — mirrors the Log Out pattern below so
              // the watched currentUser flipping to null doesn't trip
              // tenant-scoped widgets while the drawer is still painting.
              Navigator.pop(context);
              // Drop any stale paused-time marker so a rapid
              // background→resume right after lock doesn't double-fire the
              // auto-lock branch.
              final prefs = await SharedPreferences.getInstance();
              await prefs.remove('app_paused_time');
              ref.read(authProvider).lockApp();
            },
      banner: _buildSyncBanner(context, ref, isSignedIn: user != null),
    );
  }

  /// Sync status banner. Three signals nested so it reflects pending, failed,
  /// and online state; tap opens Sync Issues. Gated on Gates.viewSyncIssues —
  /// the same entry as the menu item and the screen's body-guard — so
  /// non-permitted roles never tap into a screen they can't open (hard rule
  /// #7). Skipped while logged out — the inline DAO streams below build a
  /// fresh tenant-scoped query on every rebuild and would otherwise hit
  /// requireBusinessId() with no current business.
  Widget? _buildSyncBanner(
    BuildContext context,
    WidgetRef ref, {
    required bool isSignedIn,
  }) {
    if (!isSignedIn || !Gates.viewSyncIssues.allows(ref)) return null;
    return StreamBuilder<int>(
      stream: ref.read(databaseProvider).syncDao.watchPendingCount(),
      builder: (context, pendingSnap) {
        return StreamBuilder<int>(
          stream: ref.read(databaseProvider).syncDao.watchFailedCount(),
          builder: (context, failedSnap) {
            return ValueListenableBuilder<bool>(
              valueListenable: ref.read(supabaseSyncServiceProvider).isOnline,
              builder: (context, online, _) {
                final pending = pendingSnap.data ?? 0;
                final failed = failedSnap.data ?? 0;
                if (pending == 0 && failed == 0) {
                  return const SizedBox.shrink();
                }
                final hasFailures = failed > 0;
                // The pending-only line is the mockup's new wording; the
                // offline / failed / failed-while-syncing lines are today's.
                final label = !online && pending > 0
                    ? 'Offline — $pending queued'
                    : hasFailures && pending == 0
                    ? '$failed failed'
                    : pending > 0 && hasFailures
                    ? 'Syncing $pending · $failed failed'
                    : '$pending record${pending == 1 ? '' : 's'} '
                          'waiting to sync';
                return DrawerSyncBanner(
                  label: label,
                  tone: hasFailures
                      ? DrawerSyncTone.failed
                      : DrawerSyncTone.waiting,
                  onTap: () =>
                      _pushRoute(context, ref, const SyncIssuesScreen()),
                );
              },
            );
          },
        );
      },
    );
  }

  Widget _buildNavList(
    BuildContext context,
    WidgetRef ref, {
    required bool isBelowCeo,
    required EdgeInsets padding,
    Widget? leading,
  }) {
    final t = Theme.of(context);

    Widget sectionBreak() => Padding(
      padding: EdgeInsets.symmetric(vertical: context.getRSize(8)),
      child: Divider(height: 1, thickness: 1, color: t.dividerColor),
    );

    return SpotlightTarget(
      id: SpotlightTargetId.drawerMenuList,
      child: NotificationListener<ScrollNotification>(
        onNotification: (notification) {
          SpotlightTargetRegistry.notifyTargetsMoved();
          return false;
        },
        child: ListView(
          key: AppDrawerKeys.list,
          padding: padding,
          children: [
            // On a short window the header scrolls with the list.
            if (leading != null) ...[
              leading,
              Divider(height: 1, thickness: 1, color: t.dividerColor),
              SizedBox(height: context.getRSize(14)),
            ],
            // §12.1 store picker — the one app-wide active-store control. Sits
            // above Home; only shows when the user can choose more than one
            // store.
            _buildStorePicker(context, ref),
            DrawerNavTile(
              icon: AppIcons.home,
              label: 'Home',
              isActive: activeRoute == 'dashboard',
              onTap: () => _navigateTo(context, ref, 'dashboard'),
            ),
            // Point of Sale — hidden for Stock keeper (§27.3 / §12). Same gate
            // as the POS screen's body-guard and bottom-nav tab. sales.make is
            // held by CEO, Manager, Cashier — not Stock keeper.
            if (Gates.makeSale.allows(ref))
              DrawerNavTile(
                icon: AppIcons.pos,
                label: 'Point of Sale',
                isActive: activeRoute == 'pos',
                onTap: () => _navigateTo(context, ref, 'pos'),
              ),
            // Inventory — gated on stock.view (§16.7) via the same entry as the
            // Stock tab and screen. Held by all four roles by default, so
            // visible to all unless the CEO revokes it for a role.
            if (Gates.viewInventory.allows(ref))
              DrawerNavTile(
                icon: AppIcons.inventory,
                label: 'Inventory',
                isActive: activeRoute == 'inventory',
                onTap: () => _navigateTo(context, ref, 'inventory'),
              ),
            // Orders — visible to all four roles (§27.3).
            DrawerNavTile(
              icon: AppIcons.orders,
              label: 'Orders',
              isActive: activeRoute == 'orders',
              onTap: () => _navigateTo(context, ref, 'orders'),
            ),
            // Customers — hidden for Stock keeper (§27.3). customers.add is
            // held by CEO, Manager, Cashier — not Stock keeper.
            if (Gates.viewCustomers.allows(ref))
              DrawerNavTile(
                icon: AppIcons.customers,
                label: 'Customers',
                isActive: activeRoute == 'customers',
                onTap: () => _navigateTo(context, ref, 'customers'),
              ),
            // Gated to roles that can invite staff (CEO + Manager). Hidden
            // entirely for Cashier / Stock keeper (hard rule #7 — hide, don't
            // grey out). Routes to a pushed screen, like CEO Settings below.
            if (Gates.manageStaff.allows(ref))
              DrawerNavTile(
                icon: AppIcons.staff,
                label: 'Staff Management',
                onTap: () =>
                    _pushRoute(context, ref, const StaffManagementScreen()),
              ),
            // Supplier Accounts — CEO always; Manager only if the CEO granted
            // suppliers.manage ("if toggled", §27.3); hidden for Cashier/Stock
            // keeper.
            if (Gates.manageSuppliers.allows(ref))
              DrawerNavTile(
                icon: AppIcons.supplier,
                label: 'Supplier Accounts',
                isActive:
                    activeRoute == 'supplier_accounts' ||
                    activeRoute == 'payments',
                onTap: () => _navigateTo(context, ref, 'supplier_accounts'),
              ),
            // Expenses — opens the expense report/list, so it gates on the
            // viewing entry (Gates.viewExpenses = reports.see_expenses, hard
            // rule #6), not expenses.create (that's only the Add-Expense
            // action). Neither key is held by Cashier/Stock keeper.
            if (Gates.viewExpenses.allows(ref))
              DrawerNavTile(
                icon: AppIcons.expenses,
                label: 'Expenses',
                isActive: activeRoute == 'expenses',
                onTap: () => _navigateTo(context, ref, 'expenses'),
              ),
            // Stores — CEO (stores.manage) plus any Manager who can take part
            // in the store-scoped transfer flow (§16.8.2): request / dispatch /
            // receive. The store list itself is read-only browsing for
            // non-CEOs; full per-store actions are gated inside the store
            // details screen.
            if (Gates.viewStores.allows(ref))
              SpotlightTarget(
                id: SpotlightTargetId.drawerStoresItem,
                child: DrawerNavTile(
                  icon: AppIcons.store,
                  label: 'Stores',
                  isActive: activeRoute == 'store',
                  onTap: () => _navigateTo(context, ref, 'store'),
                ),
              ),
            // Van Sales (#141) — CEO + Manager (`van.manage`). Hidden entirely
            // for everyone else (hard rule #7 — hide, don't grey out), which
            // includes the Driver: a driver holds `van.sell` and sells from the
            // terminal, and never reaches the manager side that records their
            // own payments (van-sales spec §9.5 #21). A pushed screen, like
            // Staff Management.
            if (Gates.vanManage.allows(ref))
              DrawerNavTile(
                icon: AppIcons.supplier,
                label: 'Van Sales',
                onTap: () =>
                    _pushRoute(context, ref, const VanSalesHubScreen()),
              ),
            sectionBreak(),
            // Activity Logs — CEO always; Manager only if the CEO granted
            // activity_logs.view ("if toggled", §27.3); hidden for
            // Cashier/Stock keeper.
            if (Gates.viewActivityLogs.allows(ref))
              DrawerNavTile(
                icon: AppIcons.history,
                label: 'Activity Logs',
                isActive: activeRoute == 'activity_logs',
                onTap: () => _navigateTo(context, ref, 'activity_logs'),
              ),
            // Deliveries (Phase 3) and Cart (bottom nav only) removed from the
            // sidebar per master plan §27.5.
            // Gated to CEO (settings.manage is CEO-only by default; migration
            // 0043) via the same entry as the settings screens' body-guards.
            // Hidden entirely for other roles (hard rule #7 — hide, don't grey
            // out), mirroring the Staff Management gate above.
            if (Gates.manageSettings.allows(ref))
              DrawerNavTile(
                icon: AppIcons.settings,
                label: 'CEO Settings',
                onTap: () => _pushRoute(context, ref, const SettingsScreen()),
              ),
            // Staff Settings (§10.5) — self-service settings home for roles
            // BELOW CEO (profile edit, change PIN, Display mode). Mutually
            // exclusive with CEO Settings above: the CEO uses that, never this.
            // Hidden entirely for the CEO (hard rule #7).
            if (isBelowCeo)
              DrawerNavTile(
                icon: AppIcons.settings,
                label: 'Settings',
                onTap: () =>
                    _pushRoute(context, ref, const StaffSettingsScreen()),
              ),
            // Sync Issues — troubleshooting screen gated on
            // Gates.viewSyncIssues (sync.view OR CEO — whoever the CEO granted
            // it via Sync Issues access), the same entry as the header banner
            // and the screen's body-guard. Hidden entirely for other roles
            // (hard rule #7).
            if (Gates.viewSyncIssues.allows(ref))
              DrawerNavTile(
                icon: AppIcons.syncIssues,
                label: 'Sync Issues',
                onTap: () => _pushRoute(context, ref, const SyncIssuesScreen()),
              ),
            // Pro Tips removed from the sidebar (decision Q7 — not surfaced in
            // Phase 1; UserTipsModal stays in code for Phase 2).
          ],
        ),
      ),
    );
  }

  /// Log Out (master plan §7.6): a device is used by one user at a time, so
  /// logging out wipes the device's local data — the user re-auths with email
  /// + a code and a new PIN, and the data is re-downloaded. All roles use this
  /// one button.
  Future<void> _logOut(BuildContext context, WidgetRef ref) async {
    // Capture the provider up front — `ref` is invalidated once this widget
    // unmounts mid-await.
    final auth = ref.read(authProvider);

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Log out and erase all data?'),
        content: const Text(
          'Logging out will erase all local data on this device. You '
          'will re-download it after signing in again.\n\n'
          "You'll need your email + a one-time code, and a new PIN, to "
          'sign back in.\n\n'
          'To step away without signing out, use the lock button instead.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Log out & Erase'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    if (context.mounted) Navigator.pop(context); // close the drawer
    try {
      await auth.logOutCurrentUser(); // → main.dart routes to Welcome
    } on LogoutBlockedByUnsyncedDataException catch (e) {
      // §3.1 two-tier resolution: un-pushable orphans block the wipe but must
      // never trap the user. Route to the export → typed-confirm discard →
      // logout flow instead of refusing outright.
      if (context.mounted) {
        await showResolveUnsyncedDataDialog(
          context,
          ref,
          pendingCount: e.pendingCount,
          orphanCount: e.orphanCount,
          photoCount: e.photoCount,
        );
      }
    } on LogoutWipeException catch (e) {
      if (context.mounted) {
        AppNotification.showError(context, e.message);
      }
    } catch (e) {
      if (context.mounted) {
        AppNotification.showError(
          context,
          'An unexpected error occurred during logout.',
        );
      }
    }
  }

  // ── Navigation logic — now uses NavigationService shell ────────────────────
  void _navigateTo(BuildContext context, WidgetRef ref, String route) {
    Navigator.pop(context); // close the drawer
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

  /// §12.1 store picker — the single app-wide active-store control. Drives the
  /// view on Home/Inventory/POS/Customers/Activity Log via `lockedStoreId`
  /// (null = "All Stores"). Hidden unless the user can choose >1 store.
  Widget _buildStorePicker(BuildContext context, WidgetRef ref) {
    final selectable = ref.watch(selectableStoresProvider);
    if (selectable.length < 2) return const SizedBox.shrink();

    final canViewAll = ref.watch(canViewAllStoresProvider);
    final activeId = ref.watch(lockedStoreProvider).value;

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

    return Padding(
      padding: EdgeInsets.only(bottom: context.getRSize(12)),
      child: DrawerStoreRow(
        storeName: label,
        onTap: () => showStorePickerSheet(
          context,
          ref,
          onSelected: () => ref.read(navigationProvider).closeDrawer(),
        ),
      ),
    );
  }
}

// ── Navigation Registration (Now Legacy/Optional) ───────────────────────────
// These were used to break circular imports before the MainLayout shell refactor.
// Current MainLayout directly imports screens, but keeping definitions for reference
// or until all feature-to-drawer links are fully migrated to NvigationService.

/// Reports the drawer's existence to [NavigationService] for as long as it is
/// mounted.
///
/// Flutter's `DrawerController` does not build its child while the drawer is
/// dismissed, so "an [AppDrawer] is mounted" is the same statement as "a drawer
/// is open or animating" — and unlike `Scaffold.onDrawerChanged`, it is true
/// wherever the drawer was declared — a screen's own Scaffold under 600dp
/// wide, MainLayout's at 600dp+ (#352).
///
/// Both edges are deferred past the current frame: the tour's overlay listens
/// to `drawerOpenNotifier` from a sibling `Stack` entry, and marking a sibling
/// dirty from `initState`/`dispose` is the crash ADR 0026 §7 exists to prevent.
class DrawerPresence extends StatefulWidget {
  const DrawerPresence({super.key, required this.child});

  final Widget child;

  @override
  State<DrawerPresence> createState() => _DrawerPresenceState();
}

class _DrawerPresenceState extends State<DrawerPresence> {
  /// Closes the drawer through the Scaffold that actually declares it — this
  /// widget sits inside that Scaffold's `drawer:`, so it can reach it, while
  /// `NavigationService.mainScaffoldKey` cannot. Resolved lazily: the lookup is
  /// illegal from `initState` and the owning Scaffold can change under us.
  ///
  /// Registered and unregistered as a tear-off, which Dart canonicalises per
  /// instance, so the `dispose` unregister matches the `initState` register.
  void _closeOwningDrawer() {
    if (!mounted) return;
    Scaffold.maybeOf(context)?.closeDrawer();
  }

  @override
  void initState() {
    super.initState();
    frameSafe(NavigationService().drawerMounted);
    NavigationService().registerModalDrawerCloser(_closeOwningDrawer);
  }

  @override
  void dispose() {
    NavigationService().unregisterModalDrawerCloser(_closeOwningDrawer);
    frameSafe(NavigationService().drawerDismounted);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Publishes "the Scaffold I sit in can open a drawer" to [NavigationService],
/// so `NavigationService.openDrawer()` can reach the drawer of whichever screen
/// is actually on show.
///
/// Counterpart to [DrawerPresence], and necessarily a *separate* widget: that
/// one lives inside [AppDrawer], which Flutter builds only while the drawer is
/// open, so it is absent at exactly the moment you want to open one. This widget
/// goes in the Scaffold's `body`, where it stays mounted whether the drawer is
/// open or shut.
///
/// Placement rule: it must be a *descendant* of the Scaffold that declares the
/// drawer — wrapping the Scaffold instead would resolve `Scaffold.maybeOf` to
/// MainLayout's drawerless one and reintroduce the very bug this fixes.
/// `test/tour/drawer_presence_ban_test.dart` enforces that every file declaring
/// a `drawer:` also mounts one of these.
class DrawerHost extends StatefulWidget {
  const DrawerHost({super.key, required this.child});

  final Widget child;

  @override
  State<DrawerHost> createState() => _DrawerHostState();
}

class _DrawerHostState extends State<DrawerHost> {
  /// Opens the drawer of the Scaffold this widget sits in, but only if that
  /// Scaffold is the one the user can see. Returns whether it opened anything,
  /// which is how [NavigationService.openDrawer] skips past the hosts belonging
  /// to offstage tabs and pages buried under a pushed route.
  ///
  /// Registered as an instance tear-off, which Dart canonicalises per object, so
  /// the `dispose` unregister matches the `initState` register.
  bool _openOwningDrawer() {
    if (!mounted) return false;
    final scaffold = Scaffold.maybeOf(context);
    // No drawer to open — notably every screen at 600dp+ wide, where the
    // screens pass `drawer: null` and MainLayout's Scaffold owns it (#352).
    if (scaffold == null || !scaffold.hasDrawer) return false;
    // Buried under a pushed page within this tab.
    if (ModalRoute.of(context)?.isCurrent == false) return false;
    // Belongs to a tab that is mounted but offstage.
    if (!NavigationService().isActiveTabNavigator(Navigator.maybeOf(context))) {
      return false;
    }
    scaffold.openDrawer();
    return true;
  }

  @override
  void initState() {
    super.initState();
    NavigationService().registerDrawerOpener(_openOwningDrawer);
  }

  @override
  void dispose() {
    NavigationService().unregisterDrawerOpener(_openOwningDrawer);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
