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
import 'package:reebaplus_pos/shared/utils/role_display.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';

/// Staff detail screen (master plan §9.5-9.6). Shows the member's avatar,
/// name, role, status, and assigned store, plus Change role / Suspend
/// (Reactivate) actions, each gated behind a confirm dialog. Reached from a
/// manageable card in Staff Management, or — with [readOnly] true — from the
/// viewer's own card, which opens view-only (no Change role / Suspend, since
/// you still can't manage yourself).
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

  @override
  void initState() {
    super.initState();
    _loadSales();
  }

  Future<void> _loadSales() async {
    // Total sales made (§9.5) — cheap aggregate over completed orders the
    // member rang up (orders.staff_id). A one-shot read, not a synced write.
    final db = ref.read(databaseProvider);
    final memberships = await db.userBusinessesDao.watchForCurrentBusiness().first;
    final m =
        memberships.where((r) => r.id == widget.membershipId).firstOrNull;
    if (m == null) return;
    final result = await db
        .customSelect(
          "SELECT COALESCE(SUM(net_amount_kobo), 0) AS total "
          "FROM orders WHERE staff_id = ?1 AND status = 'completed'",
          variables: [Variable<String>(m.userId)],
        )
        .getSingleOrNull();
    if (!mounted) return;
    setState(() => _totalSalesKobo = result?.read<int>('total') ?? 0);
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
    await db.userBusinessesDao.setRole(membership.id, picked.id);
    await db.activityLogDao.log(
      action: 'staff.change_role',
      description:
          'Changed role from ${currentRole?.name ?? 'Unknown'} to ${picked.name}',
      staffId: currentUser?.id,
    );
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
    final newStatus = suspending ? 'suspended' : 'active';
    await db.userBusinessesDao.setStatus(membership.id, newStatus);
    await db.activityLogDao.log(
      action: 'staff.suspend',
      description: suspending ? 'Suspended staff member' : 'Reactivated staff member',
      staffId: currentUser?.id,
    );
    if (!mounted) return;
    AppNotification.showSuccess(
        context, suspending ? 'Staff suspended.' : 'Staff reactivated.');
  }

  Color _avatarColor(UserData user) {
    final hex = user.avatarColor.replaceFirst('#', '');
    final value = int.tryParse('FF$hex', radix: 16);
    return value != null ? Color(value) : const Color(0xFF3B82F6);
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
              padding: EdgeInsets.all(context.getRSize(16)).copyWith(
                bottom: context.getRSize(16) + context.deviceBottomInset,
              ),
              children: [
                Center(
                  child: Column(
                    children: [
                      CircleAvatar(
                        radius: context.getRSize(40),
                        backgroundColor: _avatarColor(user),
                        child: Text(
                          user.name.isNotEmpty
                              ? user.name[0].toUpperCase()
                              : '?',
                          style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: context.getRFontSize(28),
                          ),
                        ),
                      ),
                      SizedBox(height: context.getRSize(12)),
                      Text(
                        user.name,
                        style: TextStyle(
                          color: text,
                          fontSize: context.getRFontSize(20),
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      SizedBox(height: context.getRSize(8)),
                      Wrap(
                        spacing: 8,
                        children: [
                          _Tag(
                            label: role?.name ?? 'Unknown',
                            color: roleTagColor(role?.slug),
                          ),
                          _Tag(
                            label: suspended ? 'Suspended' : 'Active',
                            color: suspended
                                ? subtext
                                : t.colorScheme.primary,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                SizedBox(height: context.getRSize(24)),
                _InfoRow(
                  icon: FontAwesomeIcons.store,
                  label: 'Assigned store',
                  value: store?.name ?? '—',
                ),
                _InfoRow(
                  icon: FontAwesomeIcons.envelope,
                  label: 'Email',
                  value: user.email ?? '—',
                ),
                _InfoRow(
                  icon: FontAwesomeIcons.sackDollar,
                  label: 'Total sales made',
                  value: _totalSalesKobo == null
                      ? '…'
                      : formatCurrency(_totalSalesKobo! / 100.0),
                ),
                _InfoRow(
                  icon: FontAwesomeIcons.clock,
                  label: 'Last login',
                  value: membership.lastLoginAt == null
                      ? 'Never logged in'
                      : DateFormat('MMM d, y • h:mm a')
                          .format(membership.lastLoginAt!),
                ),
                // Permission access (§10.2.1) — only a permissions manager sees
                // it, and never on the own (read-only) card. User-scope
                // overrides are a Phase-1 placeholder; this person currently
                // uses their role's permissions.
                if (!widget.readOnly &&
                    hasPermission(ref, 'settings.manage')) ...[
                  SizedBox(height: context.getRSize(4)),
                  _PermissionAccessCard(roleName: role?.name ?? 'their'),
                ],
                // Manage actions — hidden in view-only (own card). Each action
                // has its OWN permission (§9): Change role -> staff.change_role,
                // Suspend/Reactivate -> staff.suspend (both CEO + Manager by
                // default; the CEO can revoke either independently). Hidden, not
                // greyed (hard rule #7). The manageable→readOnly logic already
                // restricts which staff a viewer can act on.
                if (!widget.readOnly &&
                    (hasPermission(ref, 'staff.change_role') ||
                        hasPermission(ref, 'staff.suspend'))) ...[
                  SizedBox(height: context.getRSize(28)),
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
}

class _Tag extends StatelessWidget {
  final String label;
  final Color color;
  const _Tag({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontWeight: FontWeight.bold,
          fontSize: 12,
        ),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  const _InfoRow({
    required this.icon,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final text = t.colorScheme.onSurface;
    final subtext = t.textTheme.bodySmall?.color ?? t.iconTheme.color!;
    return Container(
      margin: EdgeInsets.only(bottom: context.getRSize(10)),
      padding: EdgeInsets.all(context.getRSize(14)),
      decoration: BoxDecoration(
        color: t.cardColor,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: t.dividerColor),
      ),
      child: Row(
        children: [
          Icon(icon, size: context.getRSize(15), color: subtext),
          SizedBox(width: context.getRSize(12)),
          Text(
            label,
            style: TextStyle(
              color: subtext,
              fontSize: context.getRFontSize(13),
              fontWeight: FontWeight.w600,
            ),
          ),
          const Spacer(),
          Flexible(
            child: Text(
              value,
              textAlign: TextAlign.right,
              style: TextStyle(
                color: text,
                fontSize: context.getRFontSize(14),
                fontWeight: FontWeight.bold,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

/// Per-user permission scope (§10.2.1). This member uses their role's
/// permissions today; a per-person override is a Phase-1 placeholder, disabled
/// until multi-store ships. Nothing is stored or enforced here yet.
class _PermissionAccessCard extends StatelessWidget {
  final String roleName;
  const _PermissionAccessCard({required this.roleName});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final text = t.colorScheme.onSurface;
    final subtext = t.textTheme.bodySmall?.color ?? t.iconTheme.color!;
    return Container(
      margin: EdgeInsets.only(bottom: context.getRSize(10)),
      padding: EdgeInsets.all(context.getRSize(14)),
      decoration: BoxDecoration(
        color: t.cardColor,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: t.dividerColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(FontAwesomeIcons.userShield,
                  size: context.getRSize(15), color: subtext),
              SizedBox(width: context.getRSize(12)),
              Text(
                'Permission access',
                style: TextStyle(
                  color: subtext,
                  fontSize: context.getRFontSize(13),
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          SizedBox(height: context.getRSize(10)),
          Text(
            'Uses the $roleName role’s permissions, set in Roles & Permissions.',
            style: TextStyle(
              color: text,
              fontSize: context.getRFontSize(13),
              height: 1.4,
            ),
          ),
          SizedBox(height: context.getRSize(12)),
          // Per-user override — disabled placeholder (§10.2.1).
          Opacity(
            opacity: 0.5,
            child: Row(
              children: [
                Icon(FontAwesomeIcons.sliders,
                    size: context.getRSize(14), color: subtext),
                SizedBox(width: context.getRSize(10)),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Customize this staff’s permissions',
                        style: TextStyle(
                          color: text,
                          fontSize: context.getRFontSize(13),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      SizedBox(height: context.getRSize(2)),
                      Text(
                        'Coming with multi-store',
                        style: TextStyle(
                          color: subtext,
                          fontSize: context.getRFontSize(11),
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(Icons.lock_outline,
                    size: context.getRSize(15), color: subtext),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
