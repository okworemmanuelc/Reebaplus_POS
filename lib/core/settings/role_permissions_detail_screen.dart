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

const _kMaxDiscount = 'max_discount_percent';
const _kMaxExpenseKobo = 'max_expense_approval_kobo';

/// Permission keys present in the catalogue but hidden from the Roles &
/// Permissions UI. `sales.discount.give` is governed entirely by the per-role
/// discount slider (`max_discount_percent`), so its on/off toggle is redundant.
/// The key stays in the catalogue (unenforced) — hiding is reversible.
const kHiddenPermissionKeys = {'sales.discount.give'};

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
    final cascaded = descendantsOf(key).where(granted.contains).toList()..sort();
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
  }

  Future<void> _commitDiscount(int value) async {
    if (_isCeo || value == _lastSavedDiscount) return;
    if (!_guard()) return;
    _lastSavedDiscount = value;
    await _db.roleSettingsDao.set(role.id, _kMaxDiscount, value.toString());
    await _db.activityLogDao.log(
      action: 'settings.role_setting.discount',
      description: 'Set max discount to $value% for ${role.name}',
      staffId: _db.currentUserId,
    );
  }

  /// Manager-only: unlock/lock the Home store picker for Managers (§11.2).
  Future<void> _commitViewAllStores(bool enable) async {
    if (!_guard()) return;
    setState(() => _viewAllStores = enable);
    await _db.roleSettingsDao
        .set(role.id, kManagerViewAllStoresKey, enable.toString());
    await _db.activityLogDao.log(
      action: 'settings.role_setting.view_all_stores',
      description:
          '${enable ? 'Allowed' : 'Disallowed'} viewing other stores for ${role.name}',
      staffId: _db.currentUserId,
    );
  }

  /// Commit the expense limit. Called from focus-loss, submit, and dispose, so
  /// it uses [_db] (not ref) and self-guards against no-op writes. The live
  /// call sites (focus/submit) gate on permission before invoking.
  Future<void> _commitExpense() async {
    if (_isCeo || !_seeded) return;
    final kobo = (parseCurrency(_expenseCtrl.text) * 100).toInt();
    if (kobo == _lastSavedExpenseKobo) return;
    _lastSavedExpenseKobo = kobo;
    await _db.roleSettingsDao.set(role.id, _kMaxExpenseKobo, kobo.toString());
    await _db.activityLogDao.log(
      action: 'settings.role_setting.expense_approval',
      description:
          'Set max expense approval to ${formatCurrency(kobo / 100)} for ${role.name}',
      staffId: _db.currentUserId,
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final canManage = hasPermission(ref, 'settings.manage');

    return Scaffold(
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
            24, 24, 24, 24 + context.deviceBottomInset),
        children: [
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
              keyboardType: TextInputType.number,
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
