import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/permissions/permission_dependencies.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/settings/role_permissions_detail_screen.dart'
    show kHiddenPermissionKeys;
import 'package:reebaplus_pos/core/settings/settings_widgets.dart';
import 'package:reebaplus_pos/core/theme/app_decorations.dart';
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
  'Funds',
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
    if (!ref.read(currentUserPermissionsProvider).contains('settings.manage')) {
      AppNotification.showError(
          context, 'You don\'t have permission to do that.');
      return false;
    }
    return true;
  }

  /// Force [key] to [target] for this user. Stores an override only when
  /// [target] differs from the role default; when they match, the override is
  /// cleared so the permission inherits the role again.
  Future<void> _setEffective(String key, bool target, bool roleDefault) async {
    await _db.userPermissionOverridesDao
        .setOverride(user.id, key, target == roleDefault ? null : target);
  }

  Future<void> _toggle(
    String key,
    bool enable,
    Set<String> roleDefaults,
    Set<String> effective,
  ) async {
    if (!_guard()) return;
    bool roleDefaultOf(String k) => roleDefaults.contains(k);

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
    final cascaded =
        descendantsOf(key).where(effective.contains).toList()..sort();
    await _setEffective(key, false, roleDefaultOf(key));
    for (final dep in cascaded) {
      await _setEffective(dep, false, roleDefaultOf(dep));
    }
    final suffix =
        cascaded.isEmpty ? '' : ' (also revoked: ${cascaded.join(', ')})';
    await _db.activityLogDao.log(
      action: 'settings.user_permission.override',
      description: 'Revoked "$key" for ${user.name} (override)$suffix',
      staffId: _db.currentUserId,
    );
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
        backgroundColor: t.colorScheme.surface,
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
            style: TextButton.styleFrom(foregroundColor: t.colorScheme.error),
            child: const Text('Restore'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    if (!_guard()) return; // re-check after the await (permission may have changed)

    final cleared =
        await _db.userPermissionOverridesDao.clearAllForUser(user.id);
    await _db.activityLogDao.log(
      action: 'settings.user_permission.restore_defaults',
      description: 'Restored ${role.name} defaults for ${user.name} '
          '(cleared $cleared override${cleared == 1 ? '' : 's'})',
      staffId: _db.currentUserId,
    );
    if (mounted) {
      AppNotification.showSuccess(
          context, 'Restored ${role.name} defaults for ${user.name}.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final canManage = hasPermission(ref, 'settings.manage');

    return Scaffold(
      backgroundColor: t.scaffoldBackgroundColor,
      appBar: AppBar(
        title: Text(
          user.name,
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: true,
      ),
      body: !canManage
          ? const SettingsNoAccess()
          : ref.watch(allPermissionsProvider).when(
                loading: () => const SizedBox.shrink(),
                error: (_, __) => Center(
                  child: Text(
                    'Couldn\'t load permissions.',
                    style: TextStyle(
                      color: t.colorScheme.onSurface.withValues(alpha: 0.6),
                    ),
                  ),
                ),
                data: (perms) => _buildBody(t, perms),
              ),
    );
  }

  Widget _buildBody(ThemeData t, List<PermissionData> permsRaw) {
    final perms = permsRaw
        .where((p) => !kHiddenPermissionKeys.contains(p.key))
        .toList();

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

    return SettingsFadeIn(
      child: ListView(
        padding:
            EdgeInsets.fromLTRB(24, 24, 24, 24 + context.deviceBottomInset),
        children: [
          Text(
            _isCeo
                ? 'The CEO always has full access — these can\'t be changed.'
                : 'Overrides the ${role.name} role defaults for ${user.name}. '
                    'Flip a toggle to override; flip it back to the role default '
                    'to inherit again.',
            style: TextStyle(
              fontSize: 13,
              height: 1.4,
              color: t.colorScheme.onSurface.withValues(alpha: 0.6),
            ),
          ),
          const SizedBox(height: 20),
          for (final entry in groups.entries) ...[
            SettingsSectionTitle(entry.key),
            const SizedBox(height: 8),
            _permissionGroupCard(
                t, entry.value, roleDefaults, effective, overrideByKey, byKey),
            const SizedBox(height: 20),
          ],
          if (!_isCeo) ...[
            const SizedBox(height: 4),
            AppButton(
              text: 'Restore defaults',
              icon: FontAwesomeIcons.arrowRotateLeft,
              variant: AppButtonVariant.outline,
              onPressed: overrides.isEmpty
                  ? null
                  : () => _restoreDefaults(overrides.length),
            ),
            const SizedBox(height: 8),
            Text(
              overrides.isEmpty
                  ? '${user.name} is already on the ${role.name} defaults.'
                  : 'Clears all ${overrides.length} '
                      'override${overrides.length == 1 ? '' : 's'} and returns '
                      '${user.name} to the ${role.name} defaults.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12,
                color: t.colorScheme.onSurface.withValues(alpha: 0.5),
              ),
            ),
          ],
        ],
      ),
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
    return Container(
      decoration: AppDecorations.glassCard(context, radius: 16),
      child: Column(
        children: [
          for (final perm in perms)
            () {
              final parent = parentOf(perm.key);
              final parentOff = !_isCeo &&
                  parent != null &&
                  !effective.contains(parent);
              final isOverridden = overrideByKey.containsKey(perm.key);
              final roleDefault = roleDefaults.contains(perm.key);

              String? subtitle;
              if (parentOff) {
                subtitle =
                    'Requires "${byKey[parent]?.description ?? parent}"';
              } else if (!_isCeo && isOverridden) {
                subtitle =
                    'Overridden — role default is ${roleDefault ? 'on' : 'off'}';
              }

              return SwitchListTile(
                title: Text(
                  perm.description,
                  style: TextStyle(
                    fontSize: 14,
                    color: t.colorScheme.onSurface,
                  ),
                ),
                subtitle: subtitle == null
                    ? null
                    : Text(
                        subtitle,
                        style: TextStyle(
                          fontSize: 12,
                          color: t.colorScheme.onSurface.withValues(
                            alpha: parentOff ? 0.5 : 0.7,
                          ),
                          fontWeight: (!parentOff && !_isCeo && isOverridden)
                              ? FontWeight.w600
                              : FontWeight.normal,
                        ),
                      ),
                value: _isCeo
                    ? true
                    : !parentOff && effective.contains(perm.key),
                onChanged: (_isCeo || parentOff)
                    ? null
                    : (v) => _toggle(perm.key, v, roleDefaults, effective),
                activeThumbColor: t.colorScheme.primary,
                contentPadding: const EdgeInsets.symmetric(horizontal: 16),
              );
            }(),
        ],
      ),
    );
  }
}
