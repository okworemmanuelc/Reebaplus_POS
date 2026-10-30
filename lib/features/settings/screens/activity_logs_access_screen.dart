import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/permissions/permissions.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/features/settings/screens/settings_page_parts.dart';
import 'package:reebaplus_pos/core/settings/settings_widgets.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/utils/notifications.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/core/van_sales/van_sales_switch.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/redesign.dart';

const _kActivityLogsView = 'activity_logs.view';

/// CEO Settings > Activity Logs access (§10.1). Per-role toggle for the
/// `activity_logs.view` permission. CEO is locked on; others default off.
class ActivityLogsAccessScreen extends ConsumerWidget {
  const ActivityLogsAccessScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    // Screen-level gate (hard rule #6) — also keeps the permission chain warm
    // so the per-row toggle's guard reads a resolved value.
    final canManage = Gates.manageSettings.allows(ref);
    final roles = ref.watch(allRolesProvider);

    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    return SettingsPageScaffold(
      icon: AppIcons.auditCheck,
      title: 'Activity Logs access',
      body: !canManage
          ? const SettingsNoAccess()
          : roles.when(
              loading: () => const SizedBox.shrink(),
              error: (_, _) => Center(
                child: Text(
                  'Couldn\'t load roles.',
                  style: context.regularStyle(14).copyWith(color: muted),
                ),
              ),
              data: (list) => SettingsFadeIn(
                child: SettingsPageList(
                  listKey: const Key('activity-logs-access-list'),
                  children: [
                    Text(
                      'Choose which roles can open Activity Logs. The CEO always has access.',
                      style: context.regularStyle(13).copyWith(color: muted),
                    ),
                    SizedBox(height: context.getRSize(20)),
                    for (final role in rolesOnOffer(list)) ...[
                      _RoleToggle(role: role),
                      SizedBox(height: context.getRSize(12)),
                    ],
                  ],
                ),
              ),
            ),
    );
  }
}

class _RoleToggle extends ConsumerWidget {
  final RoleData role;
  const _RoleToggle({required this.role});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    final isCeo = role.slug == 'ceo';
    final grants =
        ref.watch(rolePermissionsProvider(role.id)).valueOrNull ?? [];
    final hasView = grants.any((g) => g.permissionKey == _kActivityLogsView);

    return SettingsCard(
      child: SettingsControlRow(
        icon: AppIcons.visibility,
        tone: IconTileTone.info,
        title: role.name,
        subtitle: isCeo ? 'Always on' : 'Can view activity logs',
        trailing: Switch(
          value: isCeo ? true : hasView,
          // CEO is locked on (§10.2 — CEO access can never be removed).
          onChanged: isCeo ? null : (v) => _toggle(context, ref, v),
          activeThumbColor: t.colorScheme.primary,
        ),
      ),
    );
  }

  Future<void> _toggle(BuildContext context, WidgetRef ref, bool enable) async {
    // Fire-time re-check (allowsNow, not allows) — callback, not a build.
    if (!Gates.manageSettings.allowsNow(ref)) {
      showGateDenied(context, Gates.manageSettings);
      return;
    }
    final db = ref.read(databaseProvider);
    try {
      if (enable) {
        await db.rolePermissionsDao.grant(role.id, _kActivityLogsView);
      } else {
        await db.rolePermissionsDao.revoke(role.id, _kActivityLogsView);
      }
      await db.activityLogDao.log(
        action: 'settings.activity_logs_access.toggle',
        description:
            '${enable ? 'Granted' : 'Revoked'} activity log access for ${role.name}',
        staffId: db.currentUserId,
      );
      if (context.mounted) {
        AppNotification.showSuccess(context, 'Access updated.');
      }
    } catch (_) {
      if (context.mounted) {
        AppNotification.showError(context, 'Couldn\'t update access.');
      }
    }
  }
}
