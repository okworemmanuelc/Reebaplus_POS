import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/permissions/permission_dependencies.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/settings/settings_widgets.dart';
import 'package:reebaplus_pos/core/theme/app_decorations.dart';
import 'package:reebaplus_pos/core/utils/currency_input_formatter.dart';
import 'package:reebaplus_pos/core/utils/notifications.dart';
import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

const _kMaxDiscount = 'max_discount_percent';
const _kMaxExpenseKobo = 'max_expense_approval_kobo';

/// Permission keys present in the catalogue but hidden from the Roles &
/// Permissions UI (and, via the same set, the per-staff override editor).
/// The keys stay in the catalogue — hiding is reversible; re-show one the
/// moment its feature ships.
/// - `sales.discount.give` is governed entirely by the per-role discount slider
///   (`max_discount_percent`), so its on/off toggle is redundant.
/// - `shipments.manage` ("Manage incoming shipments") has no Track-Shipments
///   screen yet (§22) — un-hide when that screen ships.
const kHiddenPermissionKeys = {
  'sales.discount.give',
  'shipments.manage',
};

/// Permission categories in master-plan order. `allPermissionsProvider` returns
/// them alphabetically, so the order is imposed here. Unknown categories (none
/// today) fall through to the end.
const _categoryOrder = [
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

/// CEO Settings > Roles & Permissions > a single role (§10.2). All permissions
/// as toggles grouped by category, then the two role limits. CEO is locked
/// all-on with read-only limits (its access can never be removed).
class RolePermissionsDetailScreen extends ConsumerStatefulWidget {
  final RoleData role;
  const RolePermissionsDetailScreen({super.key, required this.role});

  @override
  ConsumerState<RolePermissionsDetailScreen> createState() =>
      _RolePermissionsDetailScreenState();
}

class _RolePermissionsDetailScreenState
    extends ConsumerState<RolePermissionsDetailScreen> {
  late final AppDatabase _db = ref.read(databaseProvider);
  final _expenseCtrl = TextEditingController();
  final _expenseFocus = FocusNode();

  // Limit inputs are seeded once from the first resolved settings snapshot,
  // then the user owns them until commit (so the stream doesn't fight typing).
  bool _seeded = false;
  int _discount = 0;
  int _lastSavedDiscount = 0;
  int? _lastSavedExpenseKobo;
  // Manager-only: CEO toggle that unlocks the Home store picker (§11.2).
  bool _viewAllStores = false;
  // Permission scope (§10.2.1). Business is the default scope (applies to every
  // store); Store overrides this role's permissions for one chosen store.
  // User-scope overrides live on the staff member's profile, not here.
  bool _storeScope = false;
  // Store scope: which store's overrides are being edited. null → default to the
  // first store (resolved at build time, never via setState during build).
  String? _selectedStoreId;

  RoleData get role => widget.role;
  bool get _isCeo => role.slug == 'ceo';
  bool get _isManager => role.slug == 'manager';

  @override
  void initState() {
    super.initState();
    // Commit the expense field when it loses focus (§ debounce — don't enqueue
    // a sync row on every keystroke).
    _expenseFocus.addListener(() {
      if (!_expenseFocus.hasFocus) _commitExpense();
    });
  }

  @override
  void dispose() {
    // Flush a pending edit if the user leaves without blurring/submitting.
    if (_seeded && !_isCeo) _commitExpense();
    _expenseCtrl.dispose();
    _expenseFocus.dispose();
    super.dispose();
  }

  void _seed(List<RoleSettingData> settings) {
    String? valueOf(String key) => settings
        .where((s) => s.settingKey == key)
        .map((s) => s.settingValue)
        .firstOrNull;

    _discount = int.tryParse(valueOf(_kMaxDiscount) ?? '') ?? _defaultDiscount();
    _lastSavedDiscount = _discount;
    if (!_isCeo) {
      final kobo = int.tryParse(valueOf(_kMaxExpenseKobo) ?? '') ?? 0;
      _lastSavedExpenseKobo = kobo;
      _expenseCtrl.text = fmtNumber(kobo ~/ 100);
    }
    if (_isManager) {
      _viewAllStores = valueOf(kManagerViewAllStoresKey) == 'true';
    }
    _seeded = true;
  }

  int _defaultDiscount() {
    switch (role.slug) {
      case 'ceo':
        return 100;
      case 'manager':
        return 10;
      default:
        return 0;
    }
  }

  /// True if the current viewer may still manage settings. ref.read (callback,
  /// not build) — matches the convention in the other settings sub-pages.
  bool _guard() {
    if (!ref.read(currentUserPermissionsProvider).contains('settings.manage')) {
      AppNotification.showError(
          context, 'You don\'t have permission to do that.');
      return false;
    }
    return true;
  }

  Future<void> _togglePermission(String key, bool enable) async {
    if (!_guard()) return;
    try {
      if (enable) {
        await _db.rolePermissionsDao.grant(role.id, key);
        await _db.activityLogDao.log(
          action: 'settings.role_permission.toggle',
          description: 'Granted "$key" for ${role.name}',
          staffId: _db.currentUserId,
        );
        return;
      }
      // Revoking a parent cascades to any granted permission that depends on it
      // (§10.2 dependency gating) — a child can't stay on once its parent is off.
      // revoke() is idempotent, but we intersect with the granted set so the
      // activity log records only what actually changed.
      final granted = (ref.read(rolePermissionsProvider(role.id)).valueOrNull ??
              const <RolePermissionData>[])
          .map((g) => g.permissionKey)
          .toSet();
      final cascaded =
          descendantsOf(key).where(granted.contains).toList()..sort();
      await _db.rolePermissionsDao.revoke(role.id, key);
      for (final dep in cascaded) {
        await _db.rolePermissionsDao.revoke(role.id, dep);
      }
      final suffix =
          cascaded.isEmpty ? '' : ' (also revoked: ${cascaded.join(', ')})';
      await _db.activityLogDao.log(
        action: 'settings.role_permission.toggle',
        description: 'Revoked "$key" for ${role.name}$suffix',
        staffId: _db.currentUserId,
      );
    } catch (_) {
      if (mounted) AppNotification.showError(context, "Couldn't update permission.");
    }
  }

  Future<void> _commitDiscount(int value) async {
    if (_isCeo || value == _lastSavedDiscount) return;
    if (!_guard()) return;
    final prev = _lastSavedDiscount;
    _lastSavedDiscount = value;
    try {
      await _db.roleSettingsDao.set(role.id, _kMaxDiscount, value.toString());
      await _db.activityLogDao.log(
        action: 'settings.role_setting.discount',
        description: 'Set max discount to $value% for ${role.name}',
        staffId: _db.currentUserId,
      );
    } catch (_) {
      _lastSavedDiscount = prev;
      if (mounted) {
        AppNotification.showError(context, "Couldn't save discount limit.");
      }
    }
  }

  /// Manager-only: unlock/lock the Home store picker for Managers (§11.2).
  Future<void> _commitViewAllStores(bool enable) async {
    if (!_guard()) return;
    setState(() => _viewAllStores = enable);
    try {
      await _db.roleSettingsDao
          .set(role.id, kManagerViewAllStoresKey, enable.toString());
      await _db.activityLogDao.log(
        action: 'settings.role_setting.view_all_stores',
        description:
            '${enable ? 'Allowed' : 'Disallowed'} viewing other stores for ${role.name}',
        staffId: _db.currentUserId,
      );
    } catch (_) {
      if (mounted) {
        setState(() => _viewAllStores = !enable);
        AppNotification.showError(
            context, "Couldn't update store visibility.");
      }
    }
  }

  /// Commit the expense limit. Called from focus-loss, submit, and dispose, so
  /// it uses [_db] (not ref) and self-guards against no-op writes. The live
  /// call sites (focus/submit) gate on permission before invoking.
  Future<void> _commitExpense() async {
    if (_isCeo || !_seeded) return;
    final kobo = (parseCurrency(_expenseCtrl.text) * 100).toInt();
    if (kobo == _lastSavedExpenseKobo) return;
    _lastSavedExpenseKobo = kobo;
    try {
      await _db.roleSettingsDao.set(role.id, _kMaxExpenseKobo, kobo.toString());
      await _db.activityLogDao.log(
        action: 'settings.role_setting.expense_approval',
        description:
            'Set max expense approval to ${formatCurrency(kobo / 100)} for ${role.name}',
        staffId: _db.currentUserId,
      );
    } catch (_) {
      if (mounted) {
        AppNotification.showError(
            context, "Couldn't save expense approval limit.");
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final canManage = hasPermission(ref, 'settings.manage');

    return Scaffold(
      // Body padding is nav-only (deviceBottomPadding): this screen is under
      // MainLayout, whose Scaffold already resizes the body for the keyboard, so
      // the inset must not re-add it. resizeToAvoidBottomInset:false is a harmless
      // no-op here (the screen sees viewInsets 0 under MainLayout).
      resizeToAvoidBottomInset: false,
      backgroundColor: t.scaffoldBackgroundColor,
      appBar: AppBar(
        title: Text(
          role.name,
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
    // Drop hidden keys (e.g. give-discount, governed by the slider) so they
    // never render as toggles.
    final perms = permsRaw
        .where((p) => !kHiddenPermissionKeys.contains(p.key))
        .toList();
    final granted = (ref.watch(rolePermissionsProvider(role.id)).valueOrNull ??
            const <RolePermissionData>[])
        .map((g) => g.permissionKey)
        .toSet();
    // For the "Requires …" hint on a gated child toggle (§10.2).
    final byKey = {for (final p in perms) p.key: p};

    final settingsAsync = ref.watch(roleSettingsProvider(role.id));
    if (settingsAsync.hasValue && !_seeded) _seed(settingsAsync.value!);

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
    // The Stores section is rendered first, on its own (with the Manager-only
    // "Allow viewing other stores" toggle), so pull its permission group out of
    // the generic category loop. null when no Stores permission exists.
    final storesPerms = groups.remove('Stores');

    return SettingsFadeIn(
      child: ListView(
        padding: EdgeInsets.fromLTRB(
            24, 24, 24, 24 + context.deviceBottomPadding),
        children: [
          // Permission scope selector (§10.2.1): Business (real, default) vs
          // Store (Phase-1 placeholder). User-scope overrides live on the staff
          // member's profile (Staff Management → staff → Permission access).
          _scopeSelector(t),
          const SizedBox(height: 10),
          Text(
            'Business applies to every store. Store overrides this role\'s '
            'permissions for one store (the default for everyone working there). '
            'A single staff member\'s overrides live on their profile '
            '(Staff Management).',
            style: TextStyle(
              fontSize: 12,
              height: 1.4,
              color: t.colorScheme.onSurface.withValues(alpha: 0.55),
            ),
          ),
          const SizedBox(height: 20),
          if (_storeScope)
            ..._buildStoreScope(t, perms, granted, byKey)
          else ...[
          if (_isCeo)
            Padding(
              padding: const EdgeInsets.only(bottom: 20),
              child: Text(
                'The CEO always has full access — these can\'t be changed.',
                style: TextStyle(
                  fontSize: 13,
                  height: 1.4,
                  color: t.colorScheme.onSurface.withValues(alpha: 0.6),
                ),
              ),
            ),
          // Stores section sits first: the Manager-only "Allow viewing other
          // stores" toggle (§11.2) and, directly below it, the store
          // permission toggle(s) — e.g. "Add, edit, and remove stores" (§10.1).
          if (_isManager || storesPerms != null) ...[
            const SettingsSectionTitle('Stores'),
            const SizedBox(height: 8),
            if (_isManager) _viewAllStoresCard(t),
            if (_isManager && storesPerms != null) const SizedBox(height: 8),
            if (storesPerms != null)
              _permissionGroupCard(t, storesPerms, granted, byKey),
            const SizedBox(height: 20),
          ],
          for (final entry in groups.entries) ...[
            SettingsSectionTitle(entry.key),
            const SizedBox(height: 8),
            _permissionGroupCard(t, entry.value, granted, byKey),
            // The per-role discount limit lives under Sales (§10.2) — it's the
            // sole discount control now that the give-discount toggle is gone.
            if (entry.key == 'Sales') ...[
              const SizedBox(height: 8),
              _discountCard(t),
            ],
            // The per-role expense-approval limit lives under Expenses (§10.2).
            if (entry.key == 'Expenses') ...[
              const SizedBox(height: 8),
              _expenseCard(t),
            ],
            const SizedBox(height: 20),
          ],
          ],
        ],
      ),
    );
  }

  /// Permission scope selector (§10.2.1). Business is the real, default scope
  /// (the toggles below apply to every store); Store is a Phase-1 placeholder.
  Widget _scopeSelector(ThemeData t) {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: AppDecorations.glassCard(context, radius: 14),
      child: Row(
        children: [
          _scopeSegment(t, 'Business', !_storeScope,
              () => setState(() => _storeScope = false)),
          _scopeSegment(
              t, 'Store', _storeScope, () => setState(() => _storeScope = true)),
        ],
      ),
    );
  }

  Widget _scopeSegment(
    ThemeData t,
    String label,
    bool selected,
    VoidCallback onTap,
  ) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.symmetric(vertical: 10),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: selected ? t.colorScheme.primary : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: selected
                  ? t.colorScheme.onPrimary
                  : t.colorScheme.onSurface.withValues(alpha: 0.7),
            ),
          ),
        ),
      ),
    );
  }

  /// Store-scope body (§10.2.1 Store scope). Pick a store, then override this
  /// role's permission toggles for that store: each toggle shows the effective
  /// value (the business default, unless the store overrides it). Flipping it
  /// away from the business default stores an override; flipping it back clears
  /// it (inherit). Boolean toggles only — the per-role limits stay role-level.
  List<Widget> _buildStoreScope(
    ThemeData t,
    List<PermissionData> perms,
    Set<String> businessDefaults,
    Map<String, PermissionData> byKey,
  ) {
    // The CEO is never overridable (always all-on) — store overrides don't apply.
    if (_isCeo) {
      return [
        _storeScopeNote(
          t,
          'The CEO always has full access — per-store overrides don\'t apply.',
        ),
      ];
    }

    final stores =
        ref.watch(allStoresProvider).valueOrNull ?? const <StoreData>[];
    if (stores.isEmpty) {
      return [
        _storeScopeNote(
          t,
          'Add a store first (Stores) to set per-store permissions.',
        ),
      ];
    }

    // Resolve the selected store without setState-during-build: fall back to the
    // first store when nothing is picked or the pick is stale.
    final selectedId = (_selectedStoreId != null &&
            stores.any((s) => s.id == _selectedStoreId))
        ? _selectedStoreId!
        : stores.first.id;

    // This store's overrides for this role, keyed for lookup.
    final overrides = ref
            .watch(storeRolePermissionsProvider(
                (storeId: selectedId, roleId: role.id)))
            .valueOrNull ??
        const <StoreRolePermissionData>[];
    final overrideByKey = {for (final o in overrides) o.permissionKey: o};

    // Effective set for this store = business defaults ± store overrides (same
    // as the runtime resolver's store layer).
    final effective = businessDefaults.toSet();
    for (final o in overrides) {
      if (o.isGranted) {
        effective.add(o.permissionKey);
      } else {
        effective.remove(o.permissionKey);
      }
    }

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

    return [
      _storePicker(t, stores, selectedId),
      const SizedBox(height: 16),
      for (final entry in groups.entries) ...[
        SettingsSectionTitle(entry.key),
        const SizedBox(height: 8),
        _storePermissionGroupCard(t, selectedId, entry.value, businessDefaults,
            effective, overrideByKey, byKey),
        const SizedBox(height: 20),
      ],
      const SizedBox(height: 4),
      AppButton(
        text: 'Restore store defaults',
        icon: FontAwesomeIcons.arrowRotateLeft,
        variant: AppButtonVariant.outline,
        onPressed: overrides.isEmpty
            ? null
            : () => _restoreStoreDefaults(selectedId, overrides.length),
      ),
      const SizedBox(height: 8),
      Text(
        overrides.isEmpty
            ? 'This store uses the ${role.name} business defaults.'
            : 'Clears all ${overrides.length} '
                'override${overrides.length == 1 ? '' : 's'} for this store and '
                'returns it to the ${role.name} business defaults.',
        textAlign: TextAlign.center,
        style: TextStyle(
          fontSize: 12,
          color: t.colorScheme.onSurface.withValues(alpha: 0.5),
        ),
      ),
    ];
  }

  /// A simple glass note for the Store scope when there's nothing to edit
  /// (CEO role, or no stores yet).
  Widget _storeScopeNote(ThemeData t, String message) {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: AppDecorations.glassCard(context, radius: 16),
      child: Column(
        children: [
          Icon(
            Icons.storefront_outlined,
            size: 36,
            color: t.colorScheme.onSurface.withValues(alpha: 0.4),
          ),
          const SizedBox(height: 12),
          Text(
            message,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 13,
              height: 1.4,
              color: t.colorScheme.onSurface.withValues(alpha: 0.6),
            ),
          ),
        ],
      ),
    );
  }

  /// Store picker for the Store scope — choose which store's overrides to edit.
  Widget _storePicker(ThemeData t, List<StoreData> stores, String selectedId) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      decoration: AppDecorations.glassCard(context, radius: 14),
      child: Row(
        children: [
          Icon(
            Icons.storefront_outlined,
            size: 20,
            color: t.colorScheme.onSurface.withValues(alpha: 0.6),
          ),
          const SizedBox(width: 12),
          Text(
            'Store',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: t.colorScheme.onSurface.withValues(alpha: 0.8),
            ),
          ),
          const Spacer(),
          Flexible(
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                value: selectedId,
                isExpanded: true,
                alignment: Alignment.centerRight,
                borderRadius: BorderRadius.circular(12),
                items: [
                  for (final s in stores)
                    DropdownMenuItem(
                      value: s.id,
                      child: Text(
                        s.name,
                        textAlign: TextAlign.right,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: (v) {
                  if (v != null) setState(() => _selectedStoreId = v);
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Force [key] to [target] for [storeId]+this role. Stores an override only
  /// when [target] differs from the business default; when they match, the
  /// override is cleared so the permission inherits the business default again.
  Future<void> _setStoreEffective(
    String storeId,
    String key,
    bool target,
    bool businessDefault,
  ) async {
    await _db.storeRolePermissionsDao.setOverride(
        storeId, role.id, key, target == businessDefault ? null : target);
  }

  Future<void> _toggleStore(
    String storeId,
    String key,
    bool enable,
    Set<String> businessDefaults,
    Set<String> effective,
  ) async {
    if (!_guard()) return;
    bool defaultOf(String k) => businessDefaults.contains(k);

    try {
      if (enable) {
        await _setStoreEffective(storeId, key, true, defaultOf(key));
        await _db.activityLogDao.log(
          action: 'settings.store_permission.override',
          description:
              'Granted "$key" for ${role.name} at this store (override)',
          staffId: _db.currentUserId,
        );
        return;
      }

      // Turning a permission off also forces off any effectively-granted
      // permission that depends on it (§10.2 dependency gating) — a child can't
      // stay on once its parent is off. Mirrors the per-role / per-user cascade.
      final cascaded =
          descendantsOf(key).where(effective.contains).toList()..sort();
      await _setStoreEffective(storeId, key, false, defaultOf(key));
      for (final dep in cascaded) {
        await _setStoreEffective(storeId, dep, false, defaultOf(dep));
      }
      final suffix =
          cascaded.isEmpty ? '' : ' (also revoked: ${cascaded.join(', ')})';
      await _db.activityLogDao.log(
        action: 'settings.store_permission.override',
        description:
            'Revoked "$key" for ${role.name} at this store (override)$suffix',
        staffId: _db.currentUserId,
      );
    } catch (_) {
      if (mounted) {
        AppNotification.showError(
            context, "Couldn't update this store's permission.");
      }
    }
  }

  /// Restore store defaults — clear every override for [storeId]+this role so
  /// the store reverts to the business defaults. Confirmed first (two-step gate),
  /// then re-guarded after the await.
  Future<void> _restoreStoreDefaults(String storeId, int overrideCount) async {
    if (!_guard()) return;
    final t = Theme.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: t.colorScheme.surface,
        title: const Text('Restore store defaults?'),
        content: Text(
          'This removes all $overrideCount custom permission '
          'override${overrideCount == 1 ? '' : 's'} for the ${role.name} role '
          'at this store and returns it to the business defaults.',
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

    try {
      final cleared = await _db.storeRolePermissionsDao
          .clearAllForStoreRole(storeId, role.id);
      await _db.activityLogDao.log(
        action: 'settings.store_permission.restore_defaults',
        description: 'Restored ${role.name} business defaults at a store '
            '(cleared $cleared override${cleared == 1 ? '' : 's'})',
        staffId: _db.currentUserId,
      );
      if (mounted) {
        AppNotification.showSuccess(
            context, 'Restored ${role.name} defaults for this store.');
      }
    } catch (_) {
      if (mounted) {
        AppNotification.showError(
            context, "Couldn't restore store defaults.");
      }
    }
  }

  /// A glass card of per-store permission toggles for one category. Each toggle
  /// shows the effective value for the store (business default ± override); a
  /// child is locked off while its parent is effectively off.
  Widget _storePermissionGroupCard(
    ThemeData t,
    String storeId,
    List<PermissionData> perms,
    Set<String> businessDefaults,
    Set<String> effective,
    Map<String, StoreRolePermissionData> overrideByKey,
    Map<String, PermissionData> byKey,
  ) {
    return Container(
      decoration: AppDecorations.glassCard(context, radius: 16),
      child: Column(
        children: [
          for (final perm in perms)
            () {
              final parent = parentOf(perm.key);
              final parentOff = parent != null && !effective.contains(parent);
              final isOverridden = overrideByKey.containsKey(perm.key);
              final businessDefault = businessDefaults.contains(perm.key);

              String? subtitle;
              if (parentOff) {
                subtitle = 'Requires "${byKey[parent]?.description ?? parent}"';
              } else if (isOverridden) {
                subtitle =
                    'Overridden — business default is ${businessDefault ? 'on' : 'off'}';
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
                          fontWeight: (!parentOff && isOverridden)
                              ? FontWeight.w600
                              : FontWeight.normal,
                        ),
                      ),
                value: !parentOff && effective.contains(perm.key),
                onChanged: parentOff
                    ? null
                    : (v) => _toggleStore(
                        storeId, perm.key, v, businessDefaults, effective),
                activeThumbColor: t.colorScheme.primary,
                contentPadding: const EdgeInsets.symmetric(horizontal: 16),
              );
            }(),
        ],
      ),
    );
  }

  /// A glass card of permission toggles for one category (§10.2). A child is
  /// locked off while its parent permission is off — it can't be granted alone,
  /// and is cascade-revoked when the parent goes off. CEO is always all-on.
  Widget _permissionGroupCard(
    ThemeData t,
    List<PermissionData> perms,
    Set<String> granted,
    Map<String, PermissionData> byKey,
  ) {
    return Container(
      decoration: AppDecorations.glassCard(context, radius: 16),
      child: Column(
        children: [
          for (final perm in perms)
            () {
              final parent = parentOf(perm.key);
              final parentOff =
                  !_isCeo && parent != null && !granted.contains(parent);
              return SwitchListTile(
                title: Text(
                  perm.description,
                  style: TextStyle(
                    fontSize: 14,
                    color: t.colorScheme.onSurface,
                  ),
                ),
                subtitle: parentOff
                    ? Text(
                        'Requires "${byKey[parent]?.description ?? parent}"',
                        style: TextStyle(
                          fontSize: 12,
                          color: t.colorScheme.onSurface.withValues(alpha: 0.5),
                        ),
                      )
                    : null,
                value: _isCeo ? true : !parentOff && granted.contains(perm.key),
                onChanged: (_isCeo || parentOff)
                    ? null
                    : (v) => _togglePermission(perm.key, v),
                activeThumbColor: t.colorScheme.primary,
                contentPadding: const EdgeInsets.symmetric(horizontal: 16),
              );
            }(),
        ],
      ),
    );
  }

  /// Manager-only toggle: unlock the Home store picker so a Manager can view
  /// other stores and request restock when running low (§11.2 / §10.2).
  Widget _viewAllStoresCard(ThemeData t) {
    return Container(
      decoration: AppDecorations.glassCard(context, radius: 16),
      child: SwitchListTile(
        title: Text(
          'Allow viewing other stores',
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w600,
            color: t.colorScheme.onSurface,
          ),
        ),
        subtitle: Text(
          'Lets this role switch stores on Home to check stock and request restock. Off by default.',
          style: TextStyle(
            fontSize: 13,
            height: 1.3,
            color: t.colorScheme.onSurface.withValues(alpha: 0.6),
          ),
        ),
        value: _viewAllStores,
        onChanged: (v) => _commitViewAllStores(v),
        activeThumbColor: t.colorScheme.primary,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16),
      ),
    );
  }

  /// Per-role discount limit (§10.2). Shown under the Sales section — it's the
  /// sole discount control now that the give-discount toggle is removed.
  Widget _discountCard(ThemeData t) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: AppDecorations.glassCard(context, radius: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Max discount %
          Row(
            children: [
              Expanded(
                child: Text(
                  'Maximum discount',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: t.colorScheme.onSurface,
                  ),
                ),
              ),
              Text(
                _isCeo ? '100% (unlimited)' : '$_discount%',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.bold,
                  color: t.colorScheme.primary,
                ),
              ),
            ],
          ),
          if (!_isCeo)
            Slider(
              value: _discount.toDouble(),
              min: 0,
              max: 100,
              divisions: 100,
              label: '$_discount%',
              onChanged: (v) => setState(() => _discount = v.round()),
              onChangeEnd: (v) => _commitDiscount(v.round()),
            ),
        ],
      ),
    );
  }

  /// Per-role expense-approval limit (§10.2). Shown under the Expenses section.
  Widget _expenseCard(ThemeData t) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: AppDecorations.glassCard(context, radius: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Max expense approval
          Text(
            'Max expense approval',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: t.colorScheme.onSurface,
            ),
          ),
          const SizedBox(height: 8),
          if (_isCeo)
            Text(
              'Unlimited',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.bold,
                color: t.colorScheme.primary,
              ),
            )
          else
            TextField(
              controller: _expenseCtrl,
              focusNode: _expenseFocus,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              inputFormatters: [CurrencyInputFormatter()],
              onSubmitted: (_) {
                if (_guard()) _commitExpense();
              },
              decoration: InputDecoration(
                prefixText: '$activeCurrencySymbol ',
                hintText: '0',
                isDense: true,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
