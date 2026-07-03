import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/permissions/permissions.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/settings/settings_widgets.dart';
import 'package:reebaplus_pos/core/theme/app_decorations.dart';
import 'package:reebaplus_pos/core/utils/notifications.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/shared/widgets/glassy_card.dart';
import 'package:reebaplus_pos/shared/widgets/glassy_scaffold.dart';

/// CEO Settings > Stores (§10.1). Edits the business's store(s) — name +
/// single `location` address. Name/address persist to the `stores` row via
/// [StoresDao.updateStore] (synced). Adding more stores is Phase 2.
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
    final stores = await db.storesDao.getActiveStores();

    if (!mounted) return;
    setState(() {
      _stores = stores;
      for (final store in stores) {
        _nameControllers[store.id] = TextEditingController(text: store.name);
        _addressControllers[store.id] = TextEditingController(
          text: store.location?.trim() ?? '',
        );
      }
      _loading = false;
    });
  }

  Future<void> _save(StoreData store) async {
    // Defense-in-depth (hard rule #6): the drawer hides the entry, but the
    // write site re-checks too. Fire-time form (allowsNow) — this is a
    // callback, not a build.
    if (!Gates.manageStores.allowsNow(ref)) {
      showGateDenied(context, Gates.manageStores);
      return;
    }
    final name = _nameControllers[store.id]!.text.trim();
    final address = _addressControllers[store.id]!.text.trim();
    if (name.isEmpty) {
      AppNotification.showError(context, 'Store name can\'t be empty.');
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
        action: 'settings.store.update',
        description: 'Updated store info',
        staffId: db.currentUserId,
      );
      if (!mounted) return;
      AppNotification.showSuccess(context, 'Store saved.');
    } catch (_) {
      if (!mounted) return;
      AppNotification.showError(context, 'Couldn\'t save store.');
    } finally {
      if (mounted) setState(() => _saving.remove(store.id));
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    // Screen-level gate (hard rule #6) + keeps the permission chain warm for
    // the save-site guard. stores.manage (via Gates.manageStores), not
    // settings.manage — verbatim.
    final canManage = Gates.manageStores.allows(ref);

    // Scaffold wrapper handles body resizing under MainLayout correctly.
    return GlassyScaffold(
      title: 'Stores',
      body: !canManage
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
                  for (final store in _stores) ...[
                    GlassyCard(
                      padding: const EdgeInsets.all(16),
                      radius: 16,
                      child: Column(
                        children: [
                          TextField(
                            controller: _nameControllers[store.id],
                            textCapitalization: TextCapitalization.words,
                            decoration: AppDecorations.authInputDecoration(
                              context,
                              label: 'Store name',
                              prefixIcon: Icons.store_rounded,
                            ),
                          ),
                          const SizedBox(height: 16),
                          TextField(
                            controller: _addressControllers[store.id],
                            decoration: AppDecorations.authInputDecoration(
                              context,
                              label: 'Address',
                              prefixIcon: Icons.location_on_rounded,
                            ),
                          ),
                          const SizedBox(height: 16),
                          _SaveButton(
                            saving: _saving.contains(store.id),
                            onPressed: () => _save(store),
                          ),
                        ],
                      ),
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
              ),
            ),
    );
  }
}

class _SaveButton extends StatelessWidget {
  final bool saving;
  final VoidCallback onPressed;
  const _SaveButton({required this.saving, required this.onPressed});

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
          child: const Text(
            'Save changes',
            style: TextStyle(
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
