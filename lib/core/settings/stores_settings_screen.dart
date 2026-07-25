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

/// CEO Settings > Stores (§10.1). Edits the business's store(s) — name +
/// single `location` address. Name/address persist to the `stores` row via
/// [StoresDao.updateStore] (synced). Adding more stores is Phase 2.
///
/// Also the registration desk for **vans** (#140, van-sales spec §4.1). A van
/// is a `stores` row with `kind = 'van'` — it holds real per-SKU inventory but
/// is hidden from every normal store surface, so this screen is the one place
/// it is visible and editable until the Van Sales hub lands in #141.
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

  /// Register a new van. A van is a location, so this is the same `stores`
  /// insert a warehouse gets — only `kind` differs, and that one field is what
  /// keeps it out of every store picker, store list and per-store report.
  Future<void> _addVan() async {
    // Write boundary (hard rule #6) — re-checked at fire time, not just render.
    if (!Gates.vanManage.allowsNow(ref)) {
      showGateDenied(context, Gates.vanManage);
      return;
    }
    final nameCtrl = TextEditingController();
    final noteCtrl = TextEditingController();
    final created = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetCtx) => _AddVanSheet(
        nameController: nameCtrl,
        noteController: noteCtrl,
      ),
    );
    final name = nameCtrl.text.trim();
    final note = noteCtrl.text.trim();
    nameCtrl.dispose();
    noteCtrl.dispose();
    if (created != true || name.isEmpty) return;

    final db = ref.read(databaseProvider);
    try {
      await db.storesDao.createStore(
        name: name,
        location: note,
        kind: kStoreKindVan,
      );
      await db.activityLogDao.log(
        action: 'settings.van.create',
        description: 'Registered van "$name"',
        staffId: db.currentUserId,
      );
      await _load();
      if (!mounted) return;
      AppNotification.showSuccess(context, 'Van added.');
    } catch (_) {
      if (!mounted) return;
      AppNotification.showError(context, 'Couldn\'t add the van.');
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
                    const SizedBox(height: 8),
                    Text(
                      'Adding more stores is coming in a future update.',
                      style: TextStyle(
                        fontSize: 13,
                        color: t.colorScheme.onSurface.withValues(alpha: 0.5),
                      ),
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
                      onPressed: _addVan,
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

/// The "Add a van" bottom sheet — name (required) + an optional note that is
/// stored in the same `location` column a store's address uses (plate number,
/// route, whatever the owner calls it).
class _AddVanSheet extends StatefulWidget {
  const _AddVanSheet({
    required this.nameController,
    required this.noteController,
  });

  final TextEditingController nameController;
  final TextEditingController noteController;

  @override
  State<_AddVanSheet> createState() => _AddVanSheetState();
}

class _AddVanSheetState extends State<_AddVanSheet> {
  final _formKey = GlobalKey<FormState>();

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(
        context.getRSize(24),
        context.getRSize(20),
        context.getRSize(24),
        context.getRSize(24) + context.deviceBottomInset,
      ),
      child: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Add a van',
              style: t.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            SizedBox(height: context.getRSize(6)),
            Text(
              'Give it a name your drivers will recognise.',
              style: t.textTheme.bodySmall?.copyWith(
                color: t.colorScheme.onSurface.withValues(alpha: 0.6),
              ),
            ),
            SizedBox(height: context.getRSize(20)),
            TextFormField(
              controller: widget.nameController,
              autofocus: true,
              textCapitalization: TextCapitalization.words,
              decoration: AppDecorations.authInputDecoration(
                context,
                label: 'Van name',
                prefixIcon: Icons.local_shipping_rounded,
              ),
              validator: (v) =>
                  (v == null || v.trim().isEmpty) ? 'Give the van a name' : null,
            ),
            SizedBox(height: context.getRSize(16)),
            TextFormField(
              controller: widget.noteController,
              decoration: AppDecorations.authInputDecoration(
                context,
                label: 'Plate number or route (optional)',
                prefixIcon: Icons.location_on_rounded,
              ),
            ),
            SizedBox(height: context.getRSize(24)),
            _SaveButton(
              saving: false,
              label: 'Add van',
              onPressed: () {
                if (!_formKey.currentState!.validate()) return;
                Navigator.pop(context, true);
              },
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
