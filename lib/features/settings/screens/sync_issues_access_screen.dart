import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:reebaplus_pos/core/theme/app_decorations.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/permissions/permissions.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/utils/notifications.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/core/van_sales/van_sales_switch.dart';
import 'package:reebaplus_pos/features/sync/widgets/sync_parts.dart';

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
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    // Screen-level gate (hard rule #6) — also keeps the permission chain warm
    // so the per-row toggle's guard reads a resolved value.
    final canManage = Gates.manageSettings.allows(ref);
    final roles = ref.watch(allRolesProvider);

    return Container(
      decoration: AppDecorations.pageBackground(context),
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: SyncTopBar.of(context, title: 'Sync Issues access'),
        body: SafeArea(
          top: false,
          bottom: false,
          child: !canManage
              ? Center(
                  key: SyncKeys.noAccess,
                  child: Padding(
                    padding: EdgeInsets.all(context.getRSize(16)),
                    child: Text(
                      'You don\'t have access to settings.',
                      textAlign: TextAlign.center,
                      style: context.regularStyle(14).copyWith(color: muted),
                    ),
                  ),
                )
              : roles.when(
                  loading: () => const SizedBox.shrink(),
                  error: (_, __) => Center(
                    child: Text(
                      'Couldn\'t load roles.',
                      style: context.regularStyle(14).copyWith(color: muted),
                    ),
                  ),
                  data: (list) => LayoutBuilder(
                    builder: (context, constraints) {
                      final gutter = syncGutter(context, constraints.maxWidth);
                      return ListView(
                        key: SyncKeys.accessList,
                        padding: EdgeInsets.fromLTRB(
                          gutter,
                          context.getRSize(16),
                          gutter,
                          context.getRSize(16) + context.deviceBottomPadding,
                        ),
                        children: [
                          Text(
                            key: SyncKeys.accessIntro,
                            'Choose which roles can open Sync Issues (the '
                            'sync troubleshooting screen). The CEO always has '
                            'access.',
                            style: context
                                .regularStyle(13)
                                .copyWith(color: muted, height: 1.4),
                          ),
                          SizedBox(height: context.getRSize(16)),
                          for (final role in rolesOnOffer(list)) ...[
                            _RoleToggle(role: role),
                            SizedBox(height: context.getRSize(12)),
                          ],
                        ],
                      );
                    },
                  ),
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
    final isCeo = role.slug == 'ceo';
    final grants =
        ref.watch(rolePermissionsProvider(role.id)).valueOrNull ?? [];
    final hasView = grants.any((g) => g.permissionKey == _kSyncView);

    return SyncRoleToggleRow(
      key: SyncKeys.roleRow(role.slug),
      switchKey: SyncKeys.roleSwitch(role.slug),
      title: role.name,
      subtitle: isCeo ? 'Always on' : 'Can open Sync Issues',
      value: isCeo ? true : hasView,
      // CEO is locked on — implicit owner of this infra screen.
      onChanged: isCeo ? null : (v) => _toggle(context, ref, v),
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
