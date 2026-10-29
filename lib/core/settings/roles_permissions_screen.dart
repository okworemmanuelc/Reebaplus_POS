import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/permissions/permissions.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/settings/role_permissions_detail_screen.dart';
import 'package:reebaplus_pos/features/staff/widgets/permission_parts.dart';
import 'package:reebaplus_pos/features/staff/widgets/staff_parts.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/redesign.dart';

import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/core/storefront/online_ordering_switch.dart';
import 'package:reebaplus_pos/core/van_sales/van_sales_switch.dart';

/// CEO Settings > Roles & Permissions (§10.1/§10.2). Lists the four system
/// roles; tap one to edit its permissions and limits.
class RolesPermissionsScreen extends ConsumerWidget {
  const RolesPermissionsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final canManage = Gates.manageSettings.allows(ref);
    final roles = ref.watch(allRolesProvider);

    return PermissionPage(
      title: 'Roles & Permissions',
      icon: AppIcons.staff,
      body: !canManage
          ? const PermissionMessage('You don\'t have access to settings.')
          : roles.when(
              loading: () => const SizedBox.shrink(),
              error: (_, __) =>
                  const PermissionMessage('Couldn\'t load roles.'),
              data: (list) => StaffColumn(
                scrollKey: PermissionKeys.rolesList,
                top: context.getRSize(20),
                children: [
                  const PermissionIntro('Tap a role to set what it can do.'),
                  SizedBox(height: context.getRSize(16)),
                  for (final role in rolesOnOffer(list)) ...[
                    _RoleCard(
                      key: PermissionKeys.roleRow(role.slug),
                      role: role,
                    ),
                    SizedBox(height: context.getRSize(12)),
                  ],
                ],
              ),
            ),
    );
  }
}

class _RoleCard extends ConsumerWidget {
  final RoleData role;
  const _RoleCard({super.key, required this.role});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isCeo = role.slug == 'ceo';
    // Exclude hidden keys (e.g. give-discount) from both tallies so the count
    // matches the toggles actually shown on the detail screen.
    final count =
        (ref.watch(rolePermissionsProvider(role.id)).valueOrNull ??
                const <RolePermissionData>[])
            .where((g) => !isPermissionKeyHidden(g.permissionKey))
            .length;
    // Derive the denominator from the global catalogue so it never goes stale
    // if permission keys are added. Falls back to the seed count (42 minus the
    // hidden keys, and the van keys while Van Sales is off) for the one frame
    // before the catalogue stream resolves.
    final allPerms = ref.watch(allPermissionsProvider).valueOrNull;
    final total = allPerms == null
        ? 42 -
              kHiddenPermissionKeys.length -
              (isVanSalesEnabled() ? 0 : kVanSalesPermissionKeys.length) -
              (isOnlineOrderingEnabled() ? 0 : kOnlineOrderingPermissionKeys.length)
        : allPerms.where((p) => !isPermissionKeyHidden(p.key)).length;
    // CEO is locked all-on; show the full count regardless of sync state.
    final subtitle = isCeo
        ? 'All $total permissions'
        : '$count of $total permissions';

    return SettingsRow(
      icon: AppIcons.staff,
      tone: staffRoleIconTone(role.slug),
      title: role.name,
      subtitle: subtitle,
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => RolePermissionsDetailScreen(role: role),
        ),
      ),
    );
  }
}
