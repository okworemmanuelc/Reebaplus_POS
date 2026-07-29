import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/permissions/permissions.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/settings/settings_widgets.dart';
import 'package:reebaplus_pos/core/stores/van_store.dart';
import 'package:reebaplus_pos/core/theme/app_decorations.dart';
import 'package:reebaplus_pos/core/utils/notifications.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/shared/widgets/glassy_card.dart';
import 'package:reebaplus_pos/shared/widgets/glassy_scaffold.dart';

/// CEO Settings > Stores (§10.1). Registers and edits the business's stores —
/// name + single `location` address. Name/address persist to the `stores` row
/// via [StoresDao.updateStore] (synced); new stores go through
/// [StoresDao.createStore].
///
/// This is the **only** surface that creates a `stores` row after onboarding
/// (which mints the first one), so both the store and the van affordances live
/// here.
///
/// Also the registration desk for **vans** (#140, van-sales spec §4.1). A van
/// is a `stores` row with `kind = 'van'` — it holds real per-SKU inventory but
/// is hidden from every normal store surface, so this screen is the one place
/// it is visible and editable (the Van Sales hub operates vans; it does not
/// register them). Both affordances run through the single [_addLocation] path.
///
/// Note: the `stores` table holds only `name` + a single `location` string
/// (onboarding fuses street/state/country into it), so there are no separate
/// address/state/country fields to show here.
class StoresSettingsScreen extends ConsumerStatefulWidget {
  const StoresSettingsScreen({super.key});

  @override
  ConsumerState<StoresSettingsScreen> createState() =>
      _StoresSettingsScreenState();
}

class _StoresSettingsScreenState extends ConsumerState<StoresSettingsScreen> {
  List<StoreData> _stores = [];
  List<StoreData> _vans = [];
  final Map<String, TextEditingController> _nameControllers = {};
  final Map<String, TextEditingController> _addressControllers = {};
  final Set<String> _saving = {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final c in _nameControllers.values) {
      c.dispose();
    }
    for (final c in _addressControllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    final db = ref.read(databaseProvider);
    final locations = await db.storesDao.getActiveStores();

    if (!mounted) return;
    setState(() {
      _stores = withoutVans(locations);
      _vans = onlyVans(locations);
      for (final store in locations) {
        _nameControllers[store.id] ??= TextEditingController(text: store.name);
        _addressControllers[store.id] ??= TextEditingController(
          text: store.location?.trim() ?? '',
        );
      }
      _loading = false;
    });
  }

  /// The gate that owns a location: a van belongs to Van Sales (`van.manage`),
  /// a warehouse to Stores (`stores.manage`). Cited by both the render gate and
  /// the write boundary so the two can never diverge.
  NamedGate _gateFor(StoreData store) =>
      isVanStore(store) ? Gates.vanManage : Gates.manageStores;

  Future<void> _save(StoreData store) async {
    // Defense-in-depth (hard rule #6): the drawer hides the entry, but the
    // write site re-checks too. Fire-time form (allowsNow) — this is a
    // callback, not a build.
    final gate = _gateFor(store);
    if (!gate.allowsNow(ref)) {
      showGateDenied(context, gate);
      return;
    }
    final isVan = isVanStore(store);
    final name = _nameControllers[store.id]!.text.trim();
    final address = _addressControllers[store.id]!.text.trim();
    if (name.isEmpty) {
      AppNotification.showError(
        context,
        isVan ? 'Van name can\'t be empty.' : 'Store name can\'t be empty.',
      );
      return;
    }

    setState(() => _saving.add(store.id));
    final db = ref.read(databaseProvider);
    try {
      await db.storesDao.updateStore(
        id: store.id,
        name: name,
        location: address,
      );
      await db.activityLogDao.log(
        action: isVan ? 'settings.van.update' : 'settings.store.update',
        description: isVan ? 'Updated van info' : 'Updated store info',
        staffId: db.currentUserId,
      );
      if (!mounted) return;
      AppNotification.showSuccess(context, isVan ? 'Van saved.' : 'Store saved.');
    } catch (_) {
      if (!mounted) return;
      AppNotification.showError(
        context,
        isVan ? 'Couldn\'t save van.' : 'Couldn\'t save store.',
      );
    } finally {
      if (mounted) setState(() => _saving.remove(store.id));
    }
  }

  /// Register a new location — a store or a van. A van is the same `stores`
  /// insert a warehouse gets and only `kind` differs, which is what keeps it out
  /// of every store picker, store list and per-store report. One method for both
  /// so the gate, the insert and the activity-log action can never drift apart.
  Future<void> _addLocation({required bool isVan}) async {
    // Write boundary (hard rule #6) — re-checked at fire time, not just render.
    final gate = isVan ? Gates.vanManage : Gates.manageStores;
    if (!gate.allowsNow(ref)) {
      showGateDenied(context, gate);
      return;
    }
    // The sheet owns its controllers and hands the values back through `pop`,
    // so there is nothing here to dispose — see [_AddLocationSheet].
    final created = await showModalBottomSheet<_NewLocation>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _AddLocationSheet(isVan: isVan),
    );
    // A non-null result means the sheet's validator passed, so the name is
    // already known non-empty.
    if (created == null) return;

    final db = ref.read(databaseProvider);
    try {
      await db.storesDao.createStore(
        name: created.name,
        location: created.note,
        kind: isVan ? kStoreKindVan : kStoreKindStore,
      );
      await db.activityLogDao.log(
        action: isVan ? 'settings.van.create' : 'settings.store.create',
        description: isVan
            ? 'Registered van "${created.name}"'
            : 'Added store "${created.name}"',
        staffId: db.currentUserId,
      );
      await _load();
      if (!mounted) return;
      AppNotification.showSuccess(
        context,
        isVan ? 'Van added.' : 'Store added.',
      );
    } catch (_) {
      if (!mounted) return;
      AppNotification.showError(
        context,
        isVan ? 'Couldn\'t add the van.' : 'Couldn\'t add the store.',
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    // Screen-level gate (hard rule #6) + keeps the permission chain warm for
    // the save-site guard. stores.manage (via Gates.manageStores), not
    // settings.manage — verbatim.
    final canManage = Gates.manageStores.allows(ref);
    // The van section is its own axis: a Manager holding `van.manage` may set
    // up vans without holding `stores.manage`.
    final canManageVans = Gates.vanManage.allows(ref);

    // Scaffold wrapper handles body resizing under MainLayout correctly.
    return GlassyScaffold(
      title: 'Stores',
      body: !canManage && !canManageVans
          ? const SettingsNoAccess()
          : _loading
          ? const SizedBox.shrink()
          : SettingsFadeIn(
              child: ListView(
                padding: EdgeInsets.fromLTRB(
                  24,
                  24,
                  24,
                  24 + context.deviceBottomPadding,
                ),
                children: [
                  if (canManage) ...[
                    for (final store in _stores) ...[
                      _LocationCard(
                        nameLabel: 'Store name',
                        nameIcon: Icons.store_rounded,
                        nameController: _nameControllers[store.id]!,
                        addressController: _addressControllers[store.id]!,
                        saving: _saving.contains(store.id),
                        onSave: () => _save(store),
                      ),
                      const SizedBox(height: 16),
                    ],
                    OutlinedButton.icon(
                      onPressed: () => _addLocation(isVan: false),
                      icon: const Icon(Icons.add_rounded),
                      label: const Text('Add a store'),
                    ),
                  ],
                  if (canManageVans) ...[
                    SizedBox(height: context.getRSize(28)),
                    Text(
                      'Vans',
                      style: t.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    SizedBox(height: context.getRSize(6)),
                    Text(
                      'A van holds stock on the road. It is kept out of the '
                      'store picker and per-store reports, so only the drivers '
                      'you assign to it sell from it.',
                      style: t.textTheme.bodySmall?.copyWith(
                        color: t.colorScheme.onSurface.withValues(alpha: 0.6),
                      ),
                    ),
                    SizedBox(height: context.getRSize(16)),
                    for (final van in _vans) ...[
                      _LocationCard(
                        nameLabel: 'Van name',
                        nameIcon: Icons.local_shipping_rounded,
                        nameController: _nameControllers[van.id]!,
                        addressController: _addressControllers[van.id]!,
                        saving: _saving.contains(van.id),
                        onSave: () => _save(van),
                      ),
                      const SizedBox(height: 16),
                    ],
                    if (_vans.isEmpty)
                      Padding(
                        padding: EdgeInsets.only(bottom: context.getRSize(16)),
                        child: Text(
                          'No vans yet.',
                          style: t.textTheme.bodySmall?.copyWith(
                            color:
                                t.colorScheme.onSurface.withValues(alpha: 0.5),
                          ),
                        ),
                      ),
                    OutlinedButton.icon(
                      onPressed: () => _addLocation(isVan: true),
                      icon: const Icon(Icons.add_rounded),
                      label: const Text('Add a van'),
                    ),
                  ],
                ],
              ),
            ),
    );
  }
}

/// One editable location card — a store or a van. The two differ only in the
/// name field's label and icon; everything else (address, save) is identical
/// because a van *is* a `stores` row.
class _LocationCard extends StatelessWidget {
  const _LocationCard({
    required this.nameLabel,
    required this.nameIcon,
    required this.nameController,
    required this.addressController,
    required this.saving,
    required this.onSave,
  });

  final String nameLabel;
  final IconData nameIcon;
  final TextEditingController nameController;
  final TextEditingController addressController;
  final bool saving;
  final VoidCallback onSave;

  @override
  Widget build(BuildContext context) {
    return GlassyCard(
      padding: const EdgeInsets.all(16),
      radius: 16,
      child: Column(
        children: [
          TextField(
            controller: nameController,
            textCapitalization: TextCapitalization.words,
            decoration: AppDecorations.authInputDecoration(
              context,
              label: nameLabel,
              prefixIcon: nameIcon,
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: addressController,
            decoration: AppDecorations.authInputDecoration(
              context,
              label: 'Address',
              prefixIcon: Icons.location_on_rounded,
            ),
          ),
          const SizedBox(height: 16),
          _SaveButton(saving: saving, onPressed: onSave),
        ],
      ),
    );
  }
}

/// What an add-location sheet hands back: a name plus the optional second line
/// that lands in the `location` column. Returned through `Navigator.pop` rather
/// than read off caller-owned controllers — that indirection is what lets the
/// sheet own its own fields (see [_AddLocationSheet]).
class _NewLocation {
  const _NewLocation({required this.name, required this.note});

  /// Non-empty — the sheet only pops once its validator has passed.
  final String name;

  /// A store's address or a van's plate/route. May be empty; `createStore`
  /// stores empty as NULL.
  final String note;
}

/// The "Add a store" / "Add a van" bottom sheet — a name (required) plus an
/// optional second line stored in the same `location` column (a store's
/// address; a van's plate number or route). The two differ only in wording and
/// icon, because a van *is* a `stores` row.
///
/// **Owns its controllers.** They are created and disposed inside this State so
/// they can never be disposed out from under the fields reading them. The
/// earlier version took them from the caller, which disposed them the moment
/// `showModalBottomSheet` returned — but that future completes when `pop` is
/// called, while the sheet is still animating out and its `TextFormField`s are
/// still mounted, so they touched a disposed `TextEditingController` and threw
/// "A TextEditingController was used after being disposed." Keeping ownership
/// and lifetime in one place is the fix; hence [_NewLocation] as the result.
class _AddLocationSheet extends StatefulWidget {
  const _AddLocationSheet({required this.isVan});

  final bool isVan;

  @override
  State<_AddLocationSheet> createState() => _AddLocationSheetState();
}

class _AddLocationSheetState extends State<_AddLocationSheet> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _noteController = TextEditingController();

  @override
  void dispose() {
    _nameController.dispose();
    _noteController.dispose();
    super.dispose();
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) return;
    Navigator.pop(
      context,
      _NewLocation(
        name: _nameController.text.trim(),
        note: _noteController.text.trim(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final isVan = widget.isVan;
    return Padding(
      // deviceBottomPadding (nav only), never deviceBottomInset: the sheet sits
      // under MainLayout's Scaffold, which already resizes for the keyboard.
      padding: EdgeInsets.fromLTRB(
        context.getRSize(24),
        context.getRSize(20),
        context.getRSize(24),
        context.getRSize(24) + context.deviceBottomPadding,
      ),
      child: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              isVan ? 'Add a van' : 'Add a store',
              style: t.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            SizedBox(height: context.getRSize(6)),
            Text(
              isVan
                  ? 'Give it a name your drivers will recognise.'
                  : 'Give it a name your staff will recognise.',
              style: t.textTheme.bodySmall?.copyWith(
                color: t.colorScheme.onSurface.withValues(alpha: 0.6),
              ),
            ),
            SizedBox(height: context.getRSize(20)),
            TextFormField(
              controller: _nameController,
              autofocus: true,
              textCapitalization: TextCapitalization.words,
              decoration: AppDecorations.authInputDecoration(
                context,
                label: isVan ? 'Van name' : 'Store name',
                prefixIcon: isVan
                    ? Icons.local_shipping_rounded
                    : Icons.store_rounded,
              ),
              validator: (v) => (v == null || v.trim().isEmpty)
                  ? (isVan ? 'Give the van a name' : 'Give the store a name')
                  : null,
            ),
            SizedBox(height: context.getRSize(16)),
            TextFormField(
              controller: _noteController,
              textCapitalization: TextCapitalization.words,
              textInputAction: TextInputAction.done,
              onFieldSubmitted: (_) => _submit(),
              decoration: AppDecorations.authInputDecoration(
                context,
                label: isVan
                    ? 'Plate number or route (optional)'
                    : 'Address (optional)',
                prefixIcon: Icons.location_on_rounded,
              ),
            ),
            SizedBox(height: context.getRSize(24)),
            _SaveButton(
              saving: false,
              label: isVan ? 'Add van' : 'Add store',
              onPressed: _submit,
            ),
          ],
        ),
      ),
    );
  }
}

class _SaveButton extends StatelessWidget {
  final bool saving;
  final String label;
  final VoidCallback onPressed;
  const _SaveButton({
    required this.saving,
    required this.onPressed,
    this.label = 'Save changes',
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: saving ? null : onPressed,
      child: Opacity(
        opacity: saving ? 0.6 : 1,
        child: Container(
          height: 54,
          alignment: Alignment.center,
          decoration: AppDecorations.primaryGradient(context, radius: 14),
          child: Text(
            label,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 16,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      ),
    );
  }
}
