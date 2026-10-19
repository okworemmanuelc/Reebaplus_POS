import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:intl/intl.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/theme/app_decorations.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/theme/fixed_colors.dart';
import 'package:reebaplus_pos/core/utils/notifications.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/core/widgets/app_fab.dart';
import 'package:reebaplus_pos/features/staff/screens/invite_staff_screen.dart';
import 'package:reebaplus_pos/features/staff/screens/staff_detail_screen.dart';
import 'package:reebaplus_pos/features/staff/widgets/staff_parts.dart';
import 'package:reebaplus_pos/shared/utils/role_display.dart';
import 'package:reebaplus_pos/shared/widgets/app_dropdown.dart';
import 'package:reebaplus_pos/shared/widgets/app_input.dart';
import 'package:reebaplus_pos/shared/widgets/menu_button.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/redesign.dart';
import 'package:reebaplus_pos/shared/widgets/shared_scaffold.dart';
import 'package:reebaplus_pos/shared/widgets/app_refresh_wrapper.dart';

/// One-shot, read-only pull of the current business so newly-joined members'
/// users / user_businesses rows reach this device. The CEO's roster can be
/// stale because the device only pulled at login, before later staff joined.
Future<void> _pullStaffRoster(WidgetRef ref) {
  final businessId = ref.read(authProvider).currentUser?.businessId;
  if (businessId == null) return Future.value();
  return ref.read(supabaseSyncServiceProvider).pullChanges(businessId);
}

/// Staff Management (master plan §9). Two tabs — Staff and Invites — each with
/// a search field and a shared "Invite new staff" FAB. Reached only by users
/// whose role grants `staff.invite` (CEO + Manager); the drawer entry that
/// pushes this screen is itself permission-gated (hard rule #7).
class StaffManagementScreen extends ConsumerStatefulWidget {
  const StaffManagementScreen({super.key});

  @override
  ConsumerState<StaffManagementScreen> createState() =>
      _StaffManagementScreenState();
}

class _StaffManagementScreenState extends ConsumerState<StaffManagementScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  String _staffQuery = '';
  String _inviteQuery = '';

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _tabController.addListener(() => setState(() {}));
    // Fire-and-forget refresh on open so a stale roster (device pulled at
    // login, before later staff joined) catches up without a re-login.
    // Deferred to a post-frame callback: _pullStaffRoster → pullChanges writes
    // pullStatus.value synchronously, which is bridged into Riverpod via
    // pullStatusProvider. Mutating a watched provider during the build phase is
    // illegal, so wait until the first frame is committed.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_pullStaffRoster(ref));
    });
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // §9 access: Staff Management is gated by `staff.invite` (CEO + Manager by
    // default; revocable per staff via override). The drawer entry is already
    // permission-gated (hard rule #7), but guard the screen too (coding rule #1)
    // so an alternate/stale entry can't bypass it and a per-user override takes
    // effect. The FAB below builds only past this gate. Fail CLOSED: `perms` is
    // empty while grants load → spinner, not a flash of no-access.
    final perms = ref.watch(currentUserPermissionsProvider);
    final activeStoreLabel = ref.watch(activeStoreLabelProvider);
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    if (!perms.contains('staff.invite')) {
      return Container(
        decoration: AppDecorations.pageBackground(context),
        child: SharedScaffold(
          activeRoute: 'staff',
          backgroundColor: Colors.transparent,
          appBar: StaffTopBar(
            key: StaffKeys.topBar,
            height: staffTopBarHeight(context),
            header: _header(context, 'Staff', activeStoreLabel),
          ),
          body: Center(
            child: perms.isEmpty
                ? const CircularProgressIndicator()
                : Padding(
                    padding: EdgeInsets.all(context.getRSize(16)),
                    child: Text(
                      'You don’t have access to Staff Management.',
                      textAlign: TextAlign.center,
                      style: context.regularStyle(14).copyWith(color: muted),
                    ),
                  ),
          ),
        ),
      );
    }
    return Container(
      decoration: AppDecorations.pageBackground(context),
      child: SharedScaffold(
        activeRoute: 'staff',
        backgroundColor: Colors.transparent,
        appBar: StaffTopBar(
          key: StaffKeys.topBar,
          height: staffTopBarHeight(context),
          header: _header(context, 'Staff Management', activeStoreLabel),
          bottom: _tabBar(context),
        ),
        body: SafeArea(
          top: false,
          bottom: false,
          child: TabBarView(
            controller: _tabController,
            children: [
              _StaffTab(query: _staffQuery, onSearch: (v) => _staffQuery = v),
              _InvitesTab(
                query: _inviteQuery,
                onSearch: (v) => _inviteQuery = v,
              ),
            ],
          ),
        ),
        // Pushed full-screen route with no bottomNavigationBar, so lift the FAB
        // clear of the Android gesture/nav bar (the system bottom inset). The
        // Builder reads the physical view inset (never stripped by the widget
        // tree) so the lift still works if MediaQuery padding resolves to 0 here.
        floatingActionButton: Builder(
          builder: (context) {
            return AppFAB(
              heroTag: 'staff_fab',
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const InviteStaffScreen()),
                );
              },
              icon: AppIcons.userAdd,
              label: 'Invite new staff',
            );
          },
        ),
      ),
    );
  }

  Widget _header(BuildContext context, String title, String store) {
    return ScreenHeader(
      icon: AppIcons.staff,
      title: title,
      subtitle: store,
      leading: context.isRailLayout
          ? null
          : const SizedBox.square(
              dimension: kMinInteractiveDimension,
              child: MenuButton(),
            ),
    );
  }

  PreferredSizeWidget _tabBar(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    return TabBar(
      controller: _tabController,
      labelColor: t.colorScheme.primary,
      unselectedLabelColor: muted,
      indicatorColor: t.colorScheme.primary,
      indicatorWeight: 3,
      dividerColor: Colors.transparent,
      labelStyle: context.boldStyle(13),
      unselectedLabelStyle: context.boldStyle(13),
      tabs: const [
        Tab(icon: Icon(AppIcons.customers, size: 16), text: 'Staff'),
        Tab(icon: Icon(AppIcons.discount, size: 16), text: 'Invites'),
      ],
    );
  }
}

// ── Search field shared by both tabs ─────────────────────────────────────────
class _SearchField extends StatelessWidget {
  final Key fieldKey;
  final String hint;
  final ValueChanged<String> onChanged;
  const _SearchField({
    required this.fieldKey,
    required this.hint,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    return AppInput(
      key: fieldKey,
      hintText: hint,
      onChanged: onChanged,
      prefixIcon: Icon(AppIcons.search, size: 16, color: muted),
    );
  }
}

// ── Staff tab (§9.2) ─────────────────────────────────────────────────────────
class _StaffTab extends ConsumerStatefulWidget {
  final String query;
  final ValueChanged<String> onSearch;
  const _StaffTab({required this.query, required this.onSearch});

  @override
  ConsumerState<_StaffTab> createState() => _StaffTabState();
}

class _StaffTabState extends ConsumerState<_StaffTab> {
  late String _query = widget.query;
  String? _storeFilter;

  @override
  Widget build(BuildContext context) {
    final memberships =
        ref.watch(userBusinessesProvider).valueOrNull ?? const [];
    final users = ref.watch(usersByBusinessProvider).valueOrNull ?? const {};
    final roles = ref.watch(allRolesProvider).valueOrNull ?? const [];
    final rolesById = {for (final r in roles) r.id: r};
    final mySlug = ref.watch(currentUserRoleProvider)?.slug;
    final isManager = mySlug == 'manager';
    final currentUserId = ref.read(authProvider).currentUser?.id;
    final allStores = ref.watch(allStoresProvider).valueOrNull ?? const [];

    // Build display rows, filtered by the search query (name/email) and store filter.
    final q = _query.trim().toLowerCase();
    final rows = <_StaffRow>[];
    for (final m in memberships) {
      final user = users[m.userId];
      if (user == null) continue;
      if (q.isNotEmpty &&
          !user.name.toLowerCase().contains(q) &&
          !(user.email ?? '').toLowerCase().contains(q)) {
        continue;
      }

      if (_storeFilter != null) {
        final assignedStores =
            ref.watch(myUserStoresProvider(user.id)).valueOrNull ?? [];
        final isAssigned = assignedStores.any((s) => s.storeId == _storeFilter);
        if (!isAssigned) continue;
      }

      final role = rolesById[m.roleId];
      final isSelf = m.userId == currentUserId;
      // Manager can't manage CEO or other Managers — those render faded and
      // read-only (§9.2 / §9.7). You can never manage your own row either
      // (can't suspend/demote yourself), but it must not be faded.
      final manageable =
          !isSelf &&
          (!isManager || (role?.slug != 'ceo' && role?.slug != 'manager'));
      rows.add(
        _StaffRow(
          membership: m,
          user: user,
          role: role,
          manageable: manageable,
          isSelf: isSelf,
        ),
      );
    }

    // Arrange staff by role (CEO → Manager → Cashier → Stock keeper), then
    // alphabetically by name within each role (master plan §9.2).
    int byRoleThenName(_StaffRow a, _StaffRow b) {
      final r = roleRank(a.role?.slug).compareTo(roleRank(b.role?.slug));
      return r != 0 ? r : a.user.name.compareTo(b.user.name);
    }

    final active = rows.where((r) => r.membership.status == 'active').toList()
      ..sort(byRoleThenName);
    final suspended =
        rows.where((r) => r.membership.status == 'suspended').toList()
          ..sort(byRoleThenName);

    return LayoutBuilder(
      builder: (context, c) {
        final g = staffGutter(context, c.maxWidth);
        final search = _SearchField(
          fieldKey: StaffKeys.searchStaff,
          hint: 'Search staff',
          onChanged: (v) {
            setState(() => _query = v);
            widget.onSearch(v);
          },
        );
        final storePicker = allStores.isEmpty
            ? null
            : AppDropdown<String?>(
                value: _storeFilter,
                hintText: 'All Stores',
                items: [
                  const DropdownMenuItem(
                    value: null,
                    child: Text(
                      'All Stores',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  for (final s in allStores)
                    DropdownMenuItem(
                      value: s.id,
                      child: Text(
                        s.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: (val) {
                  setState(() {
                    _storeFilter = val;
                  });
                },
              );
        // Side by side when the measured column is wide enough, else stacked.
        final sideBySide = storePicker != null && c.maxWidth - 2 * g >= 420;
        return Column(
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(
                g,
                context.getRSize(12),
                g,
                context.getRSize(8),
              ),
              child: storePicker == null
                  ? search
                  : sideBySide
                  ? Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Expanded(child: search),
                        SizedBox(width: context.getRSize(12)),
                        SizedBox(
                          width: context.getRSize(180),
                          child: storePicker,
                        ),
                      ],
                    )
                  : Column(
                      children: [
                        search,
                        SizedBox(height: context.getRSize(8)),
                        storePicker,
                      ],
                    ),
            ),
            Expanded(
              child: AppRefreshWrapper(
                child: ListView(
                  key: StaffKeys.list,
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: EdgeInsets.fromLTRB(
                    g,
                    context.getRSize(4),
                    g,
                    context.getRSize(100) + context.deviceBottomPadding,
                  ),
                  children: rows.isEmpty
                      ? [
                          SizedBox(height: context.getRSize(96)),
                          const StaffEmpty(
                            icon: AppIcons.customers,
                            label: 'No staff found',
                          ),
                        ]
                      : [
                          for (final r in active) ...[
                            _StaffCard(row: r),
                            SizedBox(height: context.getRSize(12)),
                          ],
                          if (suspended.isNotEmpty) ...[
                            SizedBox(height: context.getRSize(8)),
                            const SectionHeader(
                              title: 'SUSPENDED',
                              variant: SectionHeaderVariant.group,
                            ),
                            SizedBox(height: context.getRSize(10)),
                            for (final r in suspended) ...[
                              _StaffCard(row: r),
                              SizedBox(height: context.getRSize(12)),
                            ],
                          ],
                        ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _StaffRow {
  final UserBusinessData membership;
  final UserData user;
  final RoleData? role;
  final bool manageable;
  final bool isSelf;
  const _StaffRow({
    required this.membership,
    required this.user,
    required this.role,
    required this.manageable,
    required this.isSelf,
  });
}

class _StaffCard extends StatelessWidget {
  final _StaffRow row;
  const _StaffCard({required this.row});

  @override
  Widget build(BuildContext context) {
    final suspended = row.membership.status == 'suspended';
    // CEO / other-Manager rows fade for a Manager viewer (read-only, §9.2/§9.7),
    // but the viewer's own row must never fade even though it isn't manageable.
    final faded = suspended || (!row.manageable && !row.isSelf);

    final lastLogin = row.membership.lastLoginAt;
    final lastLoginStr = lastLogin == null
        ? 'Never logged in'
        : 'Last login ${DateFormat('MMM d, h:mm a').format(lastLogin)}';

    // Faded non-self rows (CEO / other Managers a Manager can't act on) stay
    // non-tappable. Your own card opens a view-only detail (§9.5); manageable
    // rows open the full detail. row.isSelf is false for manageable rows, so
    // readOnly is true only for your own card.
    final tappable = row.manageable || row.isSelf;
    return StaffListRow(
      key: StaffKeys.row(row.membership.id),
      name: row.user.name,
      avatarColorHex: row.user.avatarColor,
      roleName: row.role?.name ?? 'Unknown',
      roleSlug: row.role?.slug,
      lines: [
        if (row.user.email != null && row.user.email!.isNotEmpty)
          row.user.email!,
        if (row.user.phone != null && row.user.phone!.isNotEmpty)
          row.user.phone!,
        if (row.user.address != null && row.user.address!.isNotEmpty)
          row.user.address!,
      ],
      lastLoginLabel: lastLoginStr,
      isSelf: row.isSelf,
      suspended: suspended,
      faded: faded,
      showChevron: tappable,
      onTap: tappable
          ? () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => StaffDetailScreen(
                    membershipId: row.membership.id,
                    readOnly: row.isSelf,
                  ),
                ),
              );
            }
          : null,
    );
  }
}

// ── Invites tab (§9.3) ───────────────────────────────────────────────────────
class _InvitesTab extends ConsumerStatefulWidget {
  final String query;
  final ValueChanged<String> onSearch;
  const _InvitesTab({required this.query, required this.onSearch});

  @override
  ConsumerState<_InvitesTab> createState() => _InvitesTabState();
}

class _InvitesTabState extends ConsumerState<_InvitesTab> {
  late String _query = widget.query;

  Future<void> _revoke(InviteCodeData invite) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Revoke invite?'),
        content: Text(
          'The code ${invite.code} for ${invite.email} can no longer be '
          'used to sign up.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(
              foregroundColor:
                  (Theme.of(ctx).extension<AppFixedColors>() ??
                          AppFixedColors.light)
                      .danger,
            ),
            child: const Text('Revoke'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    final db = ref.read(databaseProvider);
    final currentUser = ref.read(authProvider).currentUser;
    try {
      await db.inviteCodesDao.revoke(invite.id);
      await db.activityLogDao.log(
        action: 'staff.invite',
        description: 'Revoked invite code for ${invite.email}',
        staffId: currentUser?.id,
        storeId: invite.storeId,
      );
      if (!mounted) return;
      AppNotification.showSuccess(context, 'Invite revoked.');
    } catch (e) {
      if (!mounted) return;
      AppNotification.showError(
        context,
        'Could not revoke invite. Please try again.',
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final invites =
        ref.watch(activeInviteCodesProvider).valueOrNull ?? const [];
    final roles = ref.watch(allRolesProvider).valueOrNull ?? const [];
    final users = ref.watch(usersByBusinessProvider).valueOrNull ?? const {};
    final rolesById = {for (final r in roles) r.id: r};

    final q = _query.trim().toLowerCase();
    final filtered = q.isEmpty
        ? invites
        : invites
              .where(
                (i) =>
                    i.code.toLowerCase().contains(q) ||
                    i.email.toLowerCase().contains(q),
              )
              .toList();

    return LayoutBuilder(
      builder: (context, c) {
        final g = staffGutter(context, c.maxWidth);
        return Column(
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(
                g,
                context.getRSize(12),
                g,
                context.getRSize(8),
              ),
              child: _SearchField(
                fieldKey: StaffKeys.searchInvites,
                hint: 'Search invites',
                onChanged: (v) {
                  setState(() => _query = v);
                  widget.onSearch(v);
                },
              ),
            ),
            Expanded(
              child: AppRefreshWrapper(
                child: filtered.isEmpty
                    ? ListView(
                        physics: const AlwaysScrollableScrollPhysics(),
                        children: [
                          SizedBox(height: context.getRSize(96)),
                          const StaffEmpty(
                            icon: AppIcons.discount,
                            label: 'No pending invites',
                          ),
                        ],
                      )
                    : ListView.separated(
                        key: StaffKeys.invitesList,
                        physics: const AlwaysScrollableScrollPhysics(),
                        padding: EdgeInsets.fromLTRB(
                          g,
                          context.getRSize(4),
                          g,
                          context.getRSize(100) + context.deviceBottomPadding,
                        ),
                        itemCount: filtered.length,
                        separatorBuilder: (_, _) =>
                            SizedBox(height: context.getRSize(12)),
                        itemBuilder: (context, i) {
                          final invite = filtered[i];
                          final role = rolesById[invite.roleId];
                          final daysLeft = invite.expiresAt
                              .difference(DateTime.now())
                              .inDays;
                          final daysLabel = daysLeft <= 0
                              ? 'Expires today'
                              : '$daysLeft day${daysLeft == 1 ? '' : 's'} left';
                          final by =
                              users[invite.generatedByUserId]?.name ??
                              'Unknown';
                          return StaffInviteCard(
                            key: StaffKeys.invite(invite.id),
                            revokeKey: StaffKeys.revoke(invite.id),
                            code: invite.code,
                            roleName: role?.name ?? 'Unknown',
                            roleSlug: role?.slug,
                            email: invite.email,
                            byLine:
                                '$by • ${DateFormat('MMM d, y').format(invite.createdAt)}',
                            expiryLabel: daysLabel,
                            onRevoke: () => _revoke(invite),
                          );
                        },
                      ),
              ),
            ),
          ],
        );
      },
    );
  }
}
