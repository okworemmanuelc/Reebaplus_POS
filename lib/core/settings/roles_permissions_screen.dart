import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/permissions/permissions.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/settings/role_permissions_detail_screen.dart';
import 'package:reebaplus_pos/core/settings/settings_widgets.dart';

import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/shared/utils/role_display.dart';
import 'package:reebaplus_pos/shared/widgets/glassy_card.dart';
import 'package:reebaplus_pos/shared/widgets/glassy_scaffold.dart';

/// CEO Settings > Roles & Permissions (§10.1/§10.2). Lists the four system
/// roles; tap one to edit its permissions and limits.
class RolesPermissionsScreen extends ConsumerWidget {
  const RolesPermissionsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    final canManage = Gates.manageSettings.allows(ref);
    final roles = ref.watch(allRolesProvider);

    return GlassyScaffold(
      title: 'Roles & Permissions',
      body: !canManage
          ? const SettingsNoAccess()
          : roles.when(
              loading: () => const SizedBox.shrink(),
              error: (_, __) => Center(
                child: Text(
                  'Couldn\'t load roles.',
                  style: TextStyle(
                    color: t.colorScheme.onSurface.withValues(alpha: 0.6),
                  ),
                ),
              ),
              data: (list) => SettingsFadeIn(
                child: ListView(
                  padding: EdgeInsets.fromLTRB(
                    24,
                    24,
                    24,
                    24 + context.deviceBottomPadding,
                  ),
                  children: [
                    Text(
                      'Tap a role to set what it can do.',
                      style: TextStyle(
                        fontSize: 13,
                        height: 1.4,
                        color: t.colorScheme.onSurface.withValues(alpha: 0.6),
                      ),
                    ),
                    const SizedBox(height: 20),
                    for (final role in list) ...[
                      _RoleCard(role: role),
                      const SizedBox(height: 16),
                    ],
                  ],
                ),
              ),
            ),
    );
  }
}

class _RoleCard extends ConsumerWidget {
  final RoleData role;
  const _RoleCard({required this.role});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    final color = roleTagColor(role.slug);
    final isCeo = role.slug == 'ceo';
    // Exclude hidden keys (e.g. give-discount) from both tallies so the count
    // matches the toggles actually shown on the detail screen.
    final count =
        (ref.watch(rolePermissionsProvider(role.id)).valueOrNull ??
                const <RolePermissionData>[])
            .where((g) => !kHiddenPermissionKeys.contains(g.permissionKey))
            .length;
    // Derive the denominator from the global catalogue so it never goes stale
    // if permission keys are added. Falls back to the seed count (39 minus the
    // hidden keys) for the one frame before the catalogue stream resolves.
    final allPerms = ref.watch(allPermissionsProvider).valueOrNull;
    final total = allPerms == null
        ? 39 - kHiddenPermissionKeys.length
        : allPerms.where((p) => !kHiddenPermissionKeys.contains(p.key)).length;
    // CEO is locked all-on; show the full count regardless of sync state.
    final subtitle = isCeo
        ? 'All $total permissions'
        : '$count of $total permissions';

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => RolePermissionsDetailScreen(role: role),
          ),
        ),
        child: GlassyCard(
          padding: const EdgeInsets.all(16),
          radius: 16,
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(Icons.badge_rounded, color: color, size: 20),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      role.name,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: t.colorScheme.onSurface,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      style: TextStyle(
                        fontSize: 13,
                        color: t.colorScheme.onSurface.withValues(alpha: 0.6),
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.chevron_right,
                color: t.colorScheme.onSurface.withValues(alpha: 0.4),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
