import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:intl/intl.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/utils/notifications.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/core/widgets/app_fab.dart';
import 'package:reebaplus_pos/features/staff/screens/invite_staff_screen.dart';
import 'package:reebaplus_pos/features/staff/screens/staff_detail_screen.dart';
import 'package:reebaplus_pos/shared/utils/role_display.dart';
import 'package:reebaplus_pos/shared/widgets/app_dropdown.dart';
import 'package:reebaplus_pos/shared/widgets/glassy_card.dart';
import 'package:reebaplus_pos/shared/widgets/menu_button.dart';
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

  Color get _surface => Theme.of(context).colorScheme.surface;
  Color get _text => Theme.of(context).colorScheme.onSurface;
  Color get _subtext =>
      Theme.of(context).textTheme.bodySmall?.color ??
      Theme.of(context).iconTheme.color!;

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
    if (!perms.contains('staff.invite')) {
      return SharedScaffold(
        activeRoute: 'staff',
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        appBar: AppBar(
          backgroundColor: _surface,
          elevation: 0,
          leading: context.isDesktop ? null : const MenuButton(),
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Staff',
                style: TextStyle(
                  color: _text,
                  fontSize: context.getRFontSize(16),
                  fontWeight: FontWeight.w800,
                ),
              ),
              Text(
                activeStoreLabel,
                style: TextStyle(
                  fontSize: context.getRFontSize(11),
                  color: Theme.of(context).colorScheme.primary,
                  fontWeight: FontWeight.w600,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
        body: Center(
          child: perms.isEmpty
              ? const CircularProgressIndicator()
              : Text(
                  'You don’t have access to Staff Management.',
                  style: TextStyle(
                    color: _subtext,
                    fontSize: context.getRFontSize(14),
                  ),
                ),
        ),
      );
    }
    return SharedScaffold(
      activeRoute: 'staff',
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: _buildAppBar(context, activeStoreLabel),
      body: TabBarView(
        controller: _tabController,
        children: [
          _StaffTab(query: _staffQuery, onSearch: (v) => _staffQuery = v),
          _InvitesTab(query: _inviteQuery, onSearch: (v) => _inviteQuery = v),
        ],
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
                MaterialPageRoute(
                  builder: (_) => const InviteStaffScreen(),
                ),
              );
            },
            icon: FontAwesomeIcons.userPlus.data,
            label: 'Invite new staff',
          );
        },
      ),
    );
  }

  PreferredSizeWidget _buildAppBar(BuildContext context, String activeStoreLabel) {
    return AppBar(
      backgroundColor: _surface,
      elevation: 0,
      iconTheme: IconThemeData(color: _text),
      leading: context.isDesktop ? null : const MenuButton(),
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'Staff Management',
            style: TextStyle(
              fontSize: context.getRFontSize(18),
              fontWeight: FontWeight.w800,
              color: _text,
              letterSpacing: -0.5,
            ),
          ),
          Text(
            activeStoreLabel,
            style: TextStyle(
              fontSize: context.getRFontSize(11),
              color: Theme.of(context).colorScheme.primary,
              fontWeight: FontWeight.w600,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
      bottom: TabBar(
        controller: _tabController,
        labelColor: Theme.of(context).colorScheme.primary,
        unselectedLabelColor: _subtext,
        indicatorColor: Theme.of(context).colorScheme.primary,
        indicatorWeight: 3,
        dividerColor: Colors.transparent,
        labelStyle: TextStyle(
          fontWeight: FontWeight.bold,
          fontSize: context.getRFontSize(14),
        ),
        tabs: [
          Tab(icon: Icon(FontAwesomeIcons.users.data, size: 16), text: 'Staff'),
          Tab(
            icon: Icon(FontAwesomeIcons.ticket.data, size: 16),
            text: 'Invites',
          ),
        ],
      ),
    );
  }
}

// ── Search field shared by both tabs ─────────────────────────────────────────
class _SearchField extends StatelessWidget {
  final String hint;
  final ValueChanged<String> onChanged;
  const _SearchField({required this.hint, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final subtext = t.textTheme.bodySmall?.color ?? t.iconTheme.color!;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        context.getRSize(16),
        context.getRSize(12),
        context.getRSize(16),
        context.getRSize(8),
      ),
      child: TextField(
        onChanged: onChanged,
        style: TextStyle(color: t.colorScheme.onSurface, fontSize: 14),
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: TextStyle(color: subtext, fontSize: 14),
          prefixIcon: Icon(
            FontAwesomeIcons.magnifyingGlass.data,
            size: 14,
            color: subtext,
          ),
          filled: true,
          fillColor: t.cardColor,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 14,
            vertical: 12,
          ),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide.none,
          ),
        ),
      ),
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
        final assignedStores = ref.watch(myUserStoresProvider(user.id)).valueOrNull ?? [];
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

    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: _SearchField(
                hint: 'Search staff',
                onChanged: (v) {
                  setState(() => _query = v);
                  widget.onSearch(v);
                },
              ),
            ),
            if (allStores.isNotEmpty)
              Padding(
                padding: EdgeInsets.only(right: context.getRSize(16)),
                child: SizedBox(
                  width: context.getRSize(140),
                  child: AppDropdown<String?>(
                    value: _storeFilter,
                    hintText: 'All Stores',
                    items: [
                      const DropdownMenuItem(
                        value: null,
                        child: Text('All Stores', maxLines: 1, overflow: TextOverflow.ellipsis),
                      ),
                      for (final s in allStores)
                        DropdownMenuItem(
                          value: s.id,
                          child: Text(s.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                        ),
                    ],
                    onChanged: (val) {
                      setState(() {
                        _storeFilter = val;
                      });
                    },
                  ),
                ),
              ),
          ],
        ),
        Expanded(
          child: AppRefreshWrapper(
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: EdgeInsets.only(
                bottom: context.getRSize(100) + context.deviceBottomPadding,
              ),
              children: rows.isEmpty
                  ? [
                      SizedBox(height: context.getRSize(120)),
                      _EmptyState(
                        icon: FontAwesomeIcons.users.data,
                        label: 'No staff found',
                      ),
                    ]
                  : [
                      ...active.map((r) => _StaffCard(row: r)),
                      if (suspended.isNotEmpty) ...[
                        Padding(
                          padding: EdgeInsets.fromLTRB(
                            context.getRSize(20),
                            context.getRSize(20),
                            context.getRSize(20),
                            context.getRSize(8),
                          ),
                          child: Text(
                            'SUSPENDED',
                            style: TextStyle(
                              color: Theme.of(context)
                                  .textTheme
                                  .bodySmall
                                  ?.color
                                  ?.withValues(alpha: 0.7),
                              fontSize: context.getRFontSize(12),
                              fontWeight: FontWeight.bold,
                              letterSpacing: 1.2,
                            ),
                          ),
                        ),
                        ...suspended.map((r) => _StaffCard(row: r)),
                      ],
                    ],
            ),
          ),
        ),
      ],
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

  Color _avatarColor() {
    final hex = row.user.avatarColor.replaceFirst('#', '');
    final value = int.tryParse('FF$hex', radix: 16);
    return value != null ? Color(value) : const Color(0xFF3B82F6);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final text = t.colorScheme.onSurface;
    final subtext = t.textTheme.bodySmall?.color ?? t.iconTheme.color!;
    final suspended = row.membership.status == 'suspended';
    // CEO / other-Manager rows fade for a Manager viewer (read-only, §9.2/§9.7),
    // but the viewer's own row must never fade even though it isn't manageable.
    final faded = suspended || (!row.manageable && !row.isSelf);

    final lastLogin = row.membership.lastLoginAt;
    final lastLoginStr = lastLogin == null
        ? 'Never logged in'
        : 'Last login ${DateFormat('MMM d, h:mm a').format(lastLogin)}';

    final card = GlassyCard(
      margin: EdgeInsets.symmetric(
        horizontal: context.getRSize(16),
        vertical: context.getRSize(6),
      ),
      padding: EdgeInsets.all(context.getRSize(14)),
      child: Row(
          children: [
            CircleAvatar(
              radius: context.getRSize(22),
              backgroundColor: _avatarColor(),
              child: Text(
                row.user.name.isNotEmpty ? row.user.name[0].toUpperCase() : '?',
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            SizedBox(width: context.getRSize(14)),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    row.user.name,
                    style: TextStyle(
                      color: text,
                      fontWeight: FontWeight.bold,
                      fontSize: context.getRFontSize(15),
                    ),
                  ),
                  if (row.user.email != null && row.user.email!.isNotEmpty) ...[
                    SizedBox(height: context.getRSize(4)),
                    Text(
                      row.user.email!,
                      style: TextStyle(
                        color: subtext,
                        fontSize: context.getRFontSize(13),
                      ),
                    ),
                  ],
                  if (row.user.phone != null && row.user.phone!.isNotEmpty) ...[
                    SizedBox(height: context.getRSize(2)),
                    Text(
                      row.user.phone!,
                      style: TextStyle(
                        color: subtext,
                        fontSize: context.getRFontSize(13),
                      ),
                    ),
                  ],
                  if (row.user.address != null && row.user.address!.isNotEmpty) ...[
                    SizedBox(height: context.getRSize(2)),
                    Text(
                      row.user.address!,
                      style: TextStyle(
                        color: subtext,
                        fontSize: context.getRFontSize(13),
                      ),
                    ),
                  ],
                  SizedBox(height: context.getRSize(6)),
                  Row(
                    children: [
                      _RoleTag(role: row.role),
                      if (row.isSelf) ...[
                        SizedBox(width: context.getRSize(8)),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: t.colorScheme.primary.withValues(
                              alpha: 0.15,
                            ),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            'You',
                            style: TextStyle(
                              color: t.colorScheme.primary,
                              fontSize: context.getRFontSize(10),
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ],
                      if (suspended) ...[
                        SizedBox(width: context.getRSize(8)),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: subtext.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            'Suspended',
                            style: TextStyle(
                              color: subtext,
                              fontSize: context.getRFontSize(10),
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  SizedBox(height: context.getRSize(6)),
                  Text(
                    lastLoginStr,
                    style: TextStyle(
                      color: subtext,
                      fontSize: context.getRFontSize(12),
                    ),
                  ),
                ],
              ),
            ),
            if (row.manageable || row.isSelf)
              Icon(
                FontAwesomeIcons.chevronRight.data,
                size: context.getRSize(13),
                color: subtext,
              ),
          ],
        ),
    );

    final wrapped = faded ? Opacity(opacity: 0.55, child: card) : card;

    // Faded non-self rows (CEO / other Managers a Manager can't act on) stay
    // non-tappable. Your own card opens a view-only detail (§9.5); manageable
    // rows open the full detail. row.isSelf is false for manageable rows, so
    // readOnly is true only for your own card.
    if (!row.manageable && !row.isSelf) return wrapped;
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: () {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => StaffDetailScreen(
              membershipId: row.membership.id,
              readOnly: row.isSelf,
            ),
          ),
        );
      },
      child: wrapped,
    );
  }
}

class _RoleTag extends StatelessWidget {
  final RoleData? role;
  const _RoleTag({required this.role});

  @override
  Widget build(BuildContext context) {
    final color = roleTagColor(role?.slug);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        role?.name ?? 'Unknown',
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.bold,
        ),
      ),
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
              foregroundColor: Theme.of(ctx).colorScheme.error,
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

    return Column(
      children: [
        _SearchField(
          hint: 'Search invites',
          onChanged: (v) {
            setState(() => _query = v);
            widget.onSearch(v);
          },
        ),
        Expanded(
          child: AppRefreshWrapper(
            child: filtered.isEmpty
                ? ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    children: [
                      SizedBox(height: context.getRSize(120)),
                      _EmptyState(
                        icon: FontAwesomeIcons.ticket.data,
                        label: 'No pending invites',
                      ),
                    ],
                  )
                : ListView.builder(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: EdgeInsets.only(
                      bottom:
                          context.getRSize(100) + context.deviceBottomPadding,
                    ),
                    itemCount: filtered.length,
                    itemBuilder: (context, i) {
                      final invite = filtered[i];
                      return _InviteCard(
                        invite: invite,
                        role: rolesById[invite.roleId],
                        generatedBy: users[invite.generatedByUserId]?.name,
                        onRevoke: () => _revoke(invite),
                      );
                    },
                  ),
          ),
        ),
      ],
    );
  }
}

class _InviteCard extends StatelessWidget {
  final InviteCodeData invite;
  final RoleData? role;
  final String? generatedBy;
  final VoidCallback onRevoke;
  const _InviteCard({
    required this.invite,
    required this.role,
    required this.generatedBy,
    required this.onRevoke,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final text = t.colorScheme.onSurface;

    final daysLeft = invite.expiresAt.difference(DateTime.now()).inDays;
    final daysLabel = daysLeft <= 0
        ? 'Expires today'
        : '$daysLeft day${daysLeft == 1 ? '' : 's'} left';

    return GlassyCard(
      margin: EdgeInsets.symmetric(
        horizontal: context.getRSize(16),
        vertical: context.getRSize(6),
      ),
      padding: EdgeInsets.all(context.getRSize(16)),
      child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  invite.code,
                  style: TextStyle(
                    color: text,
                    fontSize: context.getRFontSize(18),
                    fontWeight: FontWeight.bold,
                    letterSpacing: 2,
                    fontFamily: 'monospace',
                  ),
                ),
                _RoleTag(role: role),
              ],
            ),
            SizedBox(height: context.getRSize(8)),
            _InviteMeta(
              icon: FontAwesomeIcons.envelope.data,
              text: invite.email,
            ),
            SizedBox(height: context.getRSize(4)),
            _InviteMeta(
              icon: FontAwesomeIcons.userPen.data,
              text:
                  '${generatedBy ?? 'Unknown'} • ${DateFormat('MMM d, y').format(invite.createdAt)}',
            ),
            SizedBox(height: context.getRSize(4)),
            _InviteMeta(icon: FontAwesomeIcons.clock.data, text: daysLabel),
            SizedBox(height: context.getRSize(12)),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: onRevoke,
                icon: Icon(
                  FontAwesomeIcons.ban.data,
                  size: 13,
                  color: t.colorScheme.error,
                ),
                label: Text(
                  'Revoke',
                  style: TextStyle(color: t.colorScheme.error),
                ),
              ),
            ),
          ],
        ),
    );
  }
}

class _InviteMeta extends StatelessWidget {
  final IconData icon;
  final String text;
  const _InviteMeta({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    final subtext =
        Theme.of(context).textTheme.bodySmall?.color ??
        Theme.of(context).iconTheme.color!;
    return Row(
      children: [
        Icon(icon, size: context.getRSize(11), color: subtext),
        SizedBox(width: context.getRSize(8)),
        Expanded(
          child: Text(
            text,
            style: TextStyle(
              color: subtext,
              fontSize: context.getRFontSize(12),
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}

class _EmptyState extends StatelessWidget {
  final IconData icon;
  final String label;
  const _EmptyState({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    final subtext =
        Theme.of(context).textTheme.bodySmall?.color ??
        Theme.of(context).iconTheme.color!;
    final border = Theme.of(context).dividerColor;
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: context.getRSize(48), color: border),
          SizedBox(height: context.getRSize(16)),
          Text(
            label,
            style: TextStyle(
              color: subtext,
              fontSize: context.getRFontSize(16),
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}
