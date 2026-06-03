import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/settings/settings_widgets.dart';
import 'package:reebaplus_pos/core/utils/notifications.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';

const _kSyncView = 'sync.view';

/// CEO Settings > Sync Issues access. Per-role toggle for the `sync.view`
/// permission, which gates the Sync Issues troubleshooting screen (and its
/// sidebar item / sync badge / banner). CEO is locked on (implicit owner);
/// other roles default off. Mirrors the Activity Logs access screen.
class SyncIssuesAccessScreen extends ConsumerWidget {
  const SyncIssuesAccessScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    // Screen-level gate (hard rule #6) — also keeps the permission chain warm
    // so the per-row toggle's guard reads a resolved value.
    final canManage = hasPermission(ref, 'settings.manage');
    final roles = ref.watch(allRolesProvider);

    return Scaffold(
      backgroundColor: t.scaffoldBackgroundColor,
      appBar: AppBar(
        title: const Text(
          'Sync Issues access',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: true,
      ),
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
                      24, 24, 24, 24 + context.deviceBottomInset),
                  children: [
                    Text(
                      'Choose which roles can open Sync Issues (the sync '
                      'troubleshooting screen). The CEO always has access.',
                      style: TextStyle(
                        fontSize: 13,
                        height: 1.4,
                        color: t.colorScheme.onSurface.withValues(alpha: 0.6),
                      ),
                    ),
                    const SizedBox(height: 20),
                    for (final role in list) ...[
                      _RoleToggle(role: role),
                      const SizedBox(height: 16),
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
    final grants = ref.watch(rolePermissionsProvider(role.id)).valueOrNull ?? [];
    final hasView = grants.any((g) => g.permissionKey == _kSyncView);

    return SettingsTile(
      icon: Icons.cloud_sync_rounded,
      title: role.name,
      subtitle: isCeo ? 'Always on' : 'Can open Sync Issues',
      trailing: Switch(
        value: isCeo ? true : hasView,
        // CEO is locked on — implicit owner of this infra screen.
        onChanged: isCeo ? null : (v) => _toggle(context, ref, v),
        activeThumbColor: t.colorScheme.primary,
      ),
    );
  }

  Future<void> _toggle(BuildContext context, WidgetRef ref, bool enable) async {
    // ref.read (not hasPermission/watch) — callback, matches the other settings
    // sub-pages.
    if (!ref.read(currentUserPermissionsProvider).contains('settings.manage')) {
      AppNotification.showError(context, 'You don\'t have permission to do that.');
      return;
    }
    final db = ref.read(databaseProvider);
    try {
      if (enable) {
        await db.rolePermissionsDao.grant(role.id, _kSyncView);
      } else {
        await db.rolePermissionsDao.revoke(role.id, _kSyncView);
      }
      await db.activityLogDao.log(
        action: 'settings.sync_issues_access.toggle',
        description:
            '${enable ? 'Granted' : 'Revoked'} Sync Issues access for ${role.name}',
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
