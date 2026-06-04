import 'package:drift/drift.dart' show Variable;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:intl/intl.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/utils/notifications.dart';
import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/features/profile/widgets/profile_ui.dart';
import 'package:reebaplus_pos/features/staff/screens/staff_permissions_screen.dart';
import 'package:reebaplus_pos/shared/utils/role_display.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';

/// Staff detail screen (master plan §9.5-9.6). Shows the member's avatar,
/// name, role, status, and assigned store, plus Change role / Suspend
/// (Reactivate) actions, each gated behind a confirm dialog. Reached from a
/// manageable card in Staff Management, or — with [readOnly] true — from the
/// viewer's own card, which opens view-only (no Change role / Suspend, since
/// you still can't manage yourself). Shares the modern profile card set
/// (profile_ui.dart) with the Profile screen.
class StaffDetailScreen extends ConsumerStatefulWidget {
  final String membershipId;
  final bool readOnly;
  const StaffDetailScreen({
    super.key,
    required this.membershipId,
    this.readOnly = false,
  });

  @override
  ConsumerState<StaffDetailScreen> createState() => _StaffDetailScreenState();
}

class _StaffDetailScreenState extends ConsumerState<StaffDetailScreen> {
  int? _totalSalesKobo;
  int _ordersCount = 0;

  @override
  void initState() {
    super.initState();
    _loadSales();
  }

  Future<void> _loadSales() async {
    // Total sales made + count (§9.5) — cheap aggregate over completed orders
    // the member rang up (orders.staff_id). A one-shot read, not a synced write.
    final db = ref.read(databaseProvider);
    final memberships = await db.userBusinessesDao.watchForCurrentBusiness().first;
    final m =
        memberships.where((r) => r.id == widget.membershipId).firstOrNull;
    if (m == null) return;
    final result = await db
        .customSelect(
          "SELECT COALESCE(SUM(net_amount_kobo), 0) AS total, COUNT(*) AS cnt "
          "FROM orders WHERE staff_id = ?1 AND status = 'completed'",
          variables: [Variable<String>(m.userId)],
        )
        .getSingleOrNull();
    if (!mounted) return;
    setState(() {
      _totalSalesKobo = result?.read<int>('total') ?? 0;
      _ordersCount = result?.read<int>('cnt') ?? 0;
    });
  }

  List<RoleData> _invitableRoles(List<RoleData> all, String? mySlug) {
    if (mySlug == 'manager') {
      return all
          .where((r) => r.slug == 'cashier' || r.slug == 'stock_keeper')
          .toList();
    }
    return all;
  }

  Future<void> _changeRole(
    UserBusinessData membership,
    RoleData? currentRole,
    List<RoleData> options,
  ) async {
    // Defense-in-depth (hard rule #6): re-check the specific permission at the
    // start, not only at button render. Change-role has its own permission
    // (§9), separate from invite/suspend.
    if (!ref.read(currentUserPermissionsProvider).contains('staff.change_role')) {
      return;
    }
    final picked = await showDialog<RoleData>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Change role'),
        children: options
            .where((r) => r.id != membership.roleId)
            .map(
              (r) => SimpleDialogOption(
                onPressed: () => Navigator.pop(ctx, r),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Text(r.name),
                ),
              ),
            )
            .toList(),
      ),
    );
    if (picked == null) return;
    if (!mounted) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Confirm role change'),
        content: Text(
          'Change role from ${currentRole?.name ?? 'Unknown'} to '
          '${picked.name}?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Change role'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    final db = ref.read(databaseProvider);
    final currentUser = ref.read(authProvider).currentUser;
    final affectedName =
        ref.read(usersByBusinessProvider).valueOrNull?[membership.userId]?.name ??
            'A staff member';
    final actorName = currentUser?.name ?? 'A manager';
    final actorIsCeo = ref.read(currentUserRoleProvider)?.slug == 'ceo';
    await db.userBusinessesDao.setRole(membership.id, picked.id);
    await db.activityLogDao.log(
      action: 'staff.change_role',
      description:
          'Changed role from ${currentRole?.name ?? 'Unknown'} to ${picked.name}',
      staffId: currentUser?.id,
    );
    // §26.4 Staff — "Role changed (fires to CEO + affected staff)". The CEO is
    // notified only when a non-CEO (a Manager) made the change (actor never
    // self-notified); the affected staff member is always notified of their own
    // role change. fireNotification routes through enqueueUpsert (synced), so it
    // reaches the recipient's device live.
    final fromTo = 'from ${currentRole?.name ?? 'Unknown'} to ${picked.name}';
    if (!actorIsCeo) {
      final ceoIds = await db.userBusinessesDao.getUserIdsForRoleSlugs(['ceo']);
      for (final ceoId in ceoIds) {
        if (ceoId == currentUser?.id) continue;
        await db.notificationsDao.fireNotification(
          type: 'staff.role_changed',
          message: '$actorName changed $affectedName\'s role $fromTo',
          linkedRecordId: membership.userId,
          recipientUserId: ceoId,
        );
      }
    }
    if (membership.userId != currentUser?.id) {
      await db.notificationsDao.fireNotification(
        type: 'staff.role_changed',
        message: 'Your role was changed $fromTo by $actorName',
        linkedRecordId: membership.userId,
        recipientUserId: membership.userId,
      );
    }
    if (!mounted) return;
    AppNotification.showSuccess(context, 'Role updated.');
  }

  Future<void> _toggleSuspend(UserBusinessData membership) async {
    // Defense-in-depth (hard rule #6): re-check the specific permission before
    // running. Suspend/reactivate has its own permission (§9).
    if (!ref.read(currentUserPermissionsProvider).contains('staff.suspend')) {
      return;
    }
    final suspending = membership.status == 'active';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(suspending ? 'Suspend staff?' : 'Reactivate staff?'),
        content: Text(
          suspending
              ? 'A suspended member can no longer sign in or make sales. '
                  'They stay in the list, greyed out.'
              : 'This member will regain access to the app.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: suspending
                ? TextButton.styleFrom(
                    foregroundColor: Theme.of(ctx).colorScheme.error)
                : null,
            child: Text(suspending ? 'Suspend' : 'Reactivate'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    final db = ref.read(databaseProvider);
    final currentUser = ref.read(authProvider).currentUser;
    final affectedName =
        ref.read(usersByBusinessProvider).valueOrNull?[membership.userId]?.name ??
            'A staff member';
    final actorName = currentUser?.name ?? 'A manager';
    final actorIsCeo = ref.read(currentUserRoleProvider)?.slug == 'ceo';
    final newStatus = suspending ? 'suspended' : 'active';
    await db.userBusinessesDao.setStatus(membership.id, newStatus);
    await db.activityLogDao.log(
      action: 'staff.suspend',
      description: suspending ? 'Suspended staff member' : 'Reactivated staff member',
      staffId: currentUser?.id,
    );
    // §26.4 Staff — "Staff suspended/reactivated (fires to CEO)". Fires only when
    // a non-CEO (a Manager) made the change; the CEO is never self-notified.
    if (!actorIsCeo) {
      final ceoIds = await db.userBusinessesDao.getUserIdsForRoleSlugs(['ceo']);
      for (final ceoId in ceoIds) {
        if (ceoId == currentUser?.id) continue;
        await db.notificationsDao.fireNotification(
          type: suspending ? 'staff.suspended' : 'staff.reactivated',
          message: suspending
              ? '$actorName suspended $affectedName'
              : '$actorName reactivated $affectedName',
          severity: suspending ? 'warning' : 'info',
          linkedRecordId: membership.userId,
          recipientUserId: ceoId,
        );
      }
    }
    if (!mounted) return;
    AppNotification.showSuccess(
        context, suspending ? 'Staff suspended.' : 'Staff reactivated.');
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(currencySymbolProvider); // rebuild money displays when currency changes
    final t = Theme.of(context);
    final text = t.colorScheme.onSurface;
    final subtext = t.textTheme.bodySmall?.color ?? t.iconTheme.color!;

    final memberships =
        ref.watch(userBusinessesProvider).valueOrNull ?? const [];
    final membership =
        memberships.where((m) => m.id == widget.membershipId).firstOrNull;
    final users = ref.watch(usersByBusinessProvider).valueOrNull ?? const {};
    final roles = ref.watch(allRolesProvider).valueOrNull ?? const [];
    final rolesById = {for (final r in roles) r.id: r};
    final mySlug = ref.watch(currentUserRoleProvider)?.slug;

    if (membership == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Staff')),
        body: const Center(child: Text('Staff member not found.')),
      );
    }

    final user = users[membership.userId];
    final role = rolesById[membership.roleId];
    final store = ref.watch(storeByIdProvider(user?.storeId ?? '')).valueOrNull;
    final suspended = membership.status == 'suspended';
    final roleOptions = _invitableRoles(roles, mySlug);

    return Scaffold(
      backgroundColor: t.scaffoldBackgroundColor,
      appBar: AppBar(
        backgroundColor: t.colorScheme.surface,
        elevation: 0,
        iconTheme: IconThemeData(color: text),
        title: Text(
          'Staff',
          style: TextStyle(
            color: text,
            fontWeight: FontWeight.w800,
            fontSize: context.getRFontSize(18),
          ),
        ),
      ),
      body: user == null
          ? const Center(child: Text('Loading…'))
          : ListView(
              padding: EdgeInsets.all(context.getRSize(20)).copyWith(
                bottom: context.getRSize(20) + context.deviceBottomInset,
              ),
              children: [
                ProfileHeaderCard(
                  name: user.name,
                  avatarColorHex: user.avatarColor,
                  roleLabel: role?.name ?? 'Unknown',
                  roleColor: roleTagColor(role?.slug),
                  pills: [
                    ProfilePill(
                      icon: suspended
                          ? FontAwesomeIcons.userSlash
                          : FontAwesomeIcons.circleCheck,
                      label: suspended ? 'Suspended' : 'Active',
                      color: suspended ? subtext : t.colorScheme.primary,
                    ),
                    ProfilePill(
                      icon: FontAwesomeIcons.store,
                      label: store?.name ?? 'Unassigned',
                    ),
                  ],
                ),
                SizedBox(height: context.getRSize(24)),
                ProfileStatGrid(
                  stats: [
                    ProfileStat(
                      label: 'Orders',
                      value: _totalSalesKobo == null
                          ? '…'
                          : _ordersCount.toString(),
                      icon: FontAwesomeIcons.receipt,
                      color: t.colorScheme.primary,
                    ),
                    ProfileStat(
                      label: 'Total sales',
                      value: _totalSalesKobo == null
                          ? '…'
                          : formatCurrency(_totalSalesKobo! / 100.0),
                      icon: FontAwesomeIcons.sackDollar,
                      color: const Color(0xFFA855F7),
                    ),
                  ],
                ),
                SizedBox(height: context.getRSize(24)),
                ProfileInfoCard(
                  title: 'Account Details',
                  rows: _infoRows(membership, user, role, store, subtext),
                ),
                // Manage actions — hidden in view-only (own card). Each action
                // has its OWN permission (§9): Change role -> staff.change_role,
                // Suspend/Reactivate -> staff.suspend (both CEO + Manager by
                // default; the CEO can revoke either independently). Hidden, not
                // greyed (hard rule #7). The manageable→readOnly logic already
                // restricts which staff a viewer can act on.
                if (!widget.readOnly &&
                    (hasPermission(ref, 'staff.change_role') ||
                        hasPermission(ref, 'staff.suspend'))) ...[
                  SizedBox(height: context.getRSize(24)),
                  if (hasPermission(ref, 'staff.change_role')) ...[
                    AppButton(
                      text: 'Change role',
                      icon: FontAwesomeIcons.userGear,
                      variant: AppButtonVariant.secondary,
                      onPressed: () =>
                          _changeRole(membership, role, roleOptions),
                    ),
                    SizedBox(height: context.getRSize(12)),
                  ],
                  if (hasPermission(ref, 'staff.suspend'))
                    AppButton(
                      text: suspended ? 'Reactivate' : 'Suspend',
                      icon: suspended
                          ? FontAwesomeIcons.userCheck
                          : FontAwesomeIcons.userSlash,
                      variant: suspended
                          ? AppButtonVariant.success
                          : AppButtonVariant.danger,
                      onPressed: () => _toggleSuspend(membership),
                    ),
                ],
              ],
            ),
    );
  }

  /// Account-detail rows for the info card. The last row is the per-user
  /// Permission access (§10.2.1) — shown only to a permissions manager, never on
  /// the own (read-only) card, and not for the CEO target (always full access).
  List<ProfileInfoRow> _infoRows(
    UserBusinessData membership,
    UserData user,
    RoleData? role,
    StoreData? store,
    Color subtext,
  ) {
    final rows = <ProfileInfoRow>[
      ProfileInfoRow(
        icon: FontAwesomeIcons.store,
        label: 'Assigned store',
        value: store?.name ?? '—',
      ),
      ProfileInfoRow(
        icon: FontAwesomeIcons.envelope,
        label: 'Email',
        value: user.email ?? '—',
      ),
      ProfileInfoRow(
        icon: FontAwesomeIcons.clock,
        label: 'Last login',
        value: membership.lastLoginAt == null
            ? 'Never logged in'
            : DateFormat('MMM d, y • h:mm a').format(membership.lastLoginAt!),
      ),
    ];

    if (!widget.readOnly &&
        role != null &&
        hasPermission(ref, 'settings.manage')) {
      final isCeo = role.slug == 'ceo';
      final overrideCount = isCeo
          ? 0
          : (ref.watch(userPermissionOverridesProvider(user.id)).valueOrNull ??
                  const [])
              .length;
      final String state;
      final Color? stateColor;
      if (isCeo) {
        state = 'Full access';
        stateColor = subtext;
      } else if (overrideCount == 0) {
        state = 'Role default';
        stateColor = subtext;
      } else {
        state = '$overrideCount override${overrideCount == 1 ? '' : 's'}';
        stateColor = Theme.of(context).colorScheme.primary;
      }
      rows.add(
        ProfileInfoRow(
          icon: FontAwesomeIcons.userShield,
          label: 'Permission access',
          value: state,
          valueColor: stateColor,
          onTap: isCeo
              ? null
              : () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) =>
                          StaffPermissionsScreen(user: user, role: role),
                    ),
                  ),
        ),
      );
    }
    return rows;
  }
}
