import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reebaplus_pos/core/theme/app_icons.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/permissions/permission_dependencies.dart';
import 'package:reebaplus_pos/core/permissions/permissions.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/settings/role_permissions_detail_screen.dart'
    show isPermissionKeyHidden;
import 'package:reebaplus_pos/features/staff/widgets/permission_parts.dart';
import 'package:reebaplus_pos/features/staff/widgets/staff_parts.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/theme/fixed_colors.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/redesign.dart';
import 'package:reebaplus_pos/core/utils/notifications.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';

/// Permission categories in master-plan order (mirrors the per-role screen).
/// `allPermissionsProvider` returns them alphabetically, so the order is
/// imposed here; unknown categories fall to the end.
const _categoryOrder = [
  'Stores',
  'Sales',
  'Products',
  'Stock',
  'Expenses',
  'Reports',
  'Customers',
  'Suppliers',
  'Staff',
  'System',
];

/// Per-staff permission overrides (master plan §10.2.1). Reached from a staff
/// member's profile (Staff Management → staff → Permission access → Customize).
/// Each toggle shows the **effective** value (the role default, unless this
/// person has an override); flipping it away from the role default stores an
/// override, flipping it back clears the override (inherit). The CEO is never
/// overridable (locked all-on, read-only).
class StaffPermissionsScreen extends ConsumerStatefulWidget {
  final UserData user;
  final RoleData role;
  const StaffPermissionsScreen({
    super.key,
    required this.user,
    required this.role,
  });

  @override
  ConsumerState<StaffPermissionsScreen> createState() =>
      _StaffPermissionsScreenState();
}

class _StaffPermissionsScreenState
    extends ConsumerState<StaffPermissionsScreen> {
  late final AppDatabase _db = ref.read(databaseProvider);

  UserData get user => widget.user;
  RoleData get role => widget.role;
  bool get _isCeo => role.slug == 'ceo';

  /// Re-check the manage permission at write time (mirrors the per-role screen).
  bool _guard() {
    if (!Gates.manageSettings.allowsNow(ref)) {
      showGateDenied(context, Gates.manageSettings);
      return false;
    }
    return true;
  }

  /// Force [key] to [target] for this user. Stores an override only when
  /// [target] differs from the role default; when they match, the override is
  /// cleared so the permission inherits the role again.
  Future<void> _setEffective(String key, bool target, bool roleDefault) async {
    await _db.userPermissionOverridesDao.setOverride(
      user.id,
      key,
      target == roleDefault ? null : target,
    );
  }

  Future<void> _toggle(
    String key,
    bool enable,
    Set<String> roleDefaults,
    Set<String> effective,
  ) async {
    if (!_guard()) return;
    bool roleDefaultOf(String k) => roleDefaults.contains(k);

    try {
      if (enable) {
        await _setEffective(key, true, roleDefaultOf(key));
        await _db.activityLogDao.log(
          action: 'settings.user_permission.override',
          description: 'Granted "$key" for ${user.name} (override)',
          staffId: _db.currentUserId,
        );
        return;
      }

      // Turning a permission off also forces off any effectively-granted
      // permission that depends on it (§10.2.1 dependency gating) — a child can't
      // stay on once its parent is off. Mirrors the per-role cascade.
      final cascaded = descendantsOf(key).where(effective.contains).toList()
        ..sort();
      await _setEffective(key, false, roleDefaultOf(key));
      for (final dep in cascaded) {
        await _setEffective(dep, false, roleDefaultOf(dep));
      }
      final suffix = cascaded.isEmpty
          ? ''
          : ' (also revoked: ${cascaded.join(', ')})';
      await _db.activityLogDao.log(
        action: 'settings.user_permission.override',
        description: 'Revoked "$key" for ${user.name} (override)$suffix',
        staffId: _db.currentUserId,
      );
    } catch (e) {
      if (mounted) {
        AppNotification.showError(
          context,
          'Could not update permission. Please try again.',
        );
      }
    }
  }

  /// Restore defaults — clear every override for this staff member so all
  /// permissions revert to their role's defaults. Confirmed first (a two-step
  /// gate so a stray tap can't wipe overrides), then re-guarded after the await.
  Future<void> _restoreDefaults(int overrideCount) async {
    if (!_guard()) return;
    final t = Theme.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Restore defaults?'),
        content: Text(
          'This removes all $overrideCount custom permission '
          'override${overrideCount == 1 ? '' : 's'} for ${user.name} and '
          'returns them to the ${role.name} role defaults.',
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
                  (t.extension<AppFixedColors>() ?? AppFixedColors.light)
                      .danger,
            ),
            child: const Text('Restore'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    if (!_guard()) {
      return; // re-check after the await (permission may have changed)
    }

    try {
      final cleared = await _db.userPermissionOverridesDao.clearAllForUser(
        user.id,
      );
      await _db.activityLogDao.log(
        action: 'settings.user_permission.restore_defaults',
        description:
            'Restored ${role.name} defaults for ${user.name} '
            '(cleared $cleared override${cleared == 1 ? '' : 's'})',
        staffId: _db.currentUserId,
      );
      if (mounted) {
        AppNotification.showSuccess(
          context,
          'Restored ${role.name} defaults for ${user.name}.',
        );
      }
    } catch (e) {
      if (mounted) {
        AppNotification.showError(
          context,
          'Could not restore defaults. Please try again.',
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final canManage = Gates.manageSettings.allows(ref);

    return PermissionPage(
      title: user.name,
      subtitle: role.name,
      body: !canManage
          ? const PermissionMessage('You don\'t have access to settings.')
          : ref
                .watch(allPermissionsProvider)
                .when(
                  loading: () => const SizedBox.shrink(),
                  error: (_, __) =>
                      const PermissionMessage('Couldn\'t load permissions.'),
                  data: (perms) => _buildBody(Theme.of(context), perms),
                ),
    );
  }

  Widget _buildBody(ThemeData t, List<PermissionData> permsRaw) {
    final perms = permsRaw.where((p) => !isPermissionKeyHidden(p.key)).toList();

    // Role default grants for this person's role.
    final roleDefaults =
        (ref.watch(rolePermissionsProvider(role.id)).valueOrNull ??
                const <RolePermissionData>[])
            .map((g) => g.permissionKey)
            .toSet();

    // This person's overrides, keyed for lookup.
    final overrides =
        ref.watch(userPermissionOverridesProvider(user.id)).valueOrNull ??
        const <UserPermissionOverrideData>[];
    final overrideByKey = {for (final o in overrides) o.permissionKey: o};

    // Effective set = role defaults ± overrides (same as the runtime resolver).
    final effective = roleDefaults.toSet();
    for (final o in overrides) {
      if (o.isGranted) {
        effective.add(o.permissionKey);
      } else {
        effective.remove(o.permissionKey);
      }
    }

    final byKey = {for (final p in perms) p.key: p};

    // Group by category in master-plan order; append any unknown categories.
    final groups = <String, List<PermissionData>>{};
    for (final cat in _categoryOrder) {
      final items = perms.where((p) => p.category == cat).toList();
      if (items.isNotEmpty) groups[cat] = items;
    }
    for (final p in perms) {
      if (!_categoryOrder.contains(p.category)) {
        groups.putIfAbsent(p.category, () => []).add(p);
      }
    }

    return StaffColumn(
      scrollKey: PermissionKeys.list,
      top: context.getRSize(20),
      children: [
        PermissionIntro(
          _isCeo
              ? 'The CEO always has full access — these can\'t be changed.'
              : 'Overrides the ${role.name} role defaults for ${user.name}. '
                    'Flip a toggle to override; flip it back to the role default '
                    'to inherit again.',
        ),
        SizedBox(height: context.getRSize(20)),
        for (final entry in groups.entries) ...[
          SectionHeader(title: entry.key, variant: SectionHeaderVariant.group),
          SizedBox(height: context.getRSize(8)),
          _permissionGroupCard(
            t,
            entry.value,
            roleDefaults,
            effective,
            overrideByKey,
            byKey,
          ),
          SizedBox(height: context.getRSize(20)),
        ],
        if (!_isCeo) ...[
          SizedBox(height: context.getRSize(4)),
          AppButton(
            text: 'Restore defaults',
            icon: AppIcons.undo,
            variant: AppButtonVariant.outline,
            onPressed: overrides.isEmpty
                ? null
                : () => _restoreDefaults(overrides.length),
          ),
          SizedBox(height: context.getRSize(8)),
          Text(
            overrides.isEmpty
                ? '${user.name} is already on the ${role.name} defaults.'
                : 'Clears all ${overrides.length} '
                      'override${overrides.length == 1 ? '' : 's'} and returns '
                      '${user.name} to the ${role.name} defaults.',
            textAlign: TextAlign.center,
            style: context
                .regularStyle(12)
                .copyWith(
                  color:
                      t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface,
                ),
          ),
        ],
      ],
    );
  }

  Widget _permissionGroupCard(
    ThemeData t,
    List<PermissionData> perms,
    Set<String> roleDefaults,
    Set<String> effective,
    Map<String, UserPermissionOverrideData> overrideByKey,
    Map<String, PermissionData> byKey,
  ) {
    return PermissionToggleCard(
      toggles: [
        for (final perm in perms)
          () {
            final parent = parentOf(perm.key);
            final parentOff =
                !_isCeo && parent != null && !effective.contains(parent);
            final isOverridden = overrideByKey.containsKey(perm.key);
            final roleDefault = roleDefaults.contains(perm.key);

            String? subtitle;
            if (parentOff) {
              subtitle = 'Requires "${byKey[parent]?.description ?? parent}"';
            } else if (!_isCeo && isOverridden) {
              subtitle =
                  'Overridden — role default is ${roleDefault ? 'on' : 'off'}';
            }

            return PermissionToggle(
              title: perm.description,
              subtitle: subtitle,
              emphasis: !parentOff && !_isCeo && isOverridden,
              dimSubtitle: parentOff,
              value: _isCeo ? true : !parentOff && effective.contains(perm.key),
              onChanged: (_isCeo || parentOff)
                  ? null
                  : (v) => _toggle(perm.key, v, roleDefaults, effective),
            );
          }(),
      ],
    );
  }
}
