import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/permissions/permissions.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/stores/van_store.dart';
import 'package:reebaplus_pos/core/theme/app_decorations.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/utils/name_case.dart';
import 'package:reebaplus_pos/core/utils/notifications.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/features/stores/widgets/add_location_flow.dart';
import 'package:reebaplus_pos/features/stores/widgets/stores_parts.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:reebaplus_pos/shared/widgets/app_input.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/redesign.dart';

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
    final name = toNameCase(_nameControllers[store.id]!.text);
    _nameControllers[store.id]!.text = name;
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
      AppNotification.showSuccess(
        context,
        isVan ? 'Van saved.' : 'Store saved.',
      );
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

  /// Register a new location — a store or a van — through the shared
  /// [addLocationFlow] (also used by the Van Sales hub, #779).
  Future<void> _addLocation({required bool isVan}) async {
    final created = await addLocationFlow(context, ref, isVan: isVan);
    if (created) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    // Screen-level gate (hard rule #6) + keeps the permission chain warm for
    // the save-site guard. stores.manage (via Gates.manageStores), not
    // settings.manage — verbatim.
    final canManage = Gates.manageStores.allows(ref);
    // The van section is its own axis: a Manager holding `van.manage` may set
    // up vans without holding `stores.manage`.
    final canManageVans = Gates.vanManage.allows(ref);

    return Container(
      decoration: AppDecorations.pageBackground(context),
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: StoresTopBar(
          key: StoresKeys.topBar,
          height: storesTopBarHeight(context),
          header: ScreenHeader(
            leading: StoresBackButton(
              onPressed: () => Navigator.maybePop(context),
            ),
            icon: AppIcons.store,
            title: 'Stores',
          ),
        ),
        body: !canManage && !canManageVans
            ? const StoresMessage(
                key: StoresKeys.noAccess,
                text: 'You don\'t have access to settings.',
              )
            : _loading
            ? const SizedBox.shrink()
            : _FadeIn(
                child: CustomScrollView(
                  key: StoresKeys.settingsList,
                  slivers: [
                    storesSliver(
                      SliverToBoxAdapter(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            if (canManage) ...[
                              for (final store in _stores) ...[
                                _LocationCard(
                                  nameLabel: 'Store name',
                                  nameIcon: AppIcons.store,
                                  nameController: _nameControllers[store.id]!,
                                  addressController:
                                      _addressControllers[store.id]!,
                                  saving: _saving.contains(store.id),
                                  onSave: () => _save(store),
                                ),
                                SizedBox(height: context.getRSize(12)),
                              ],
                              AppButton(
                                text: 'Add a store',
                                icon: AppIcons.add,
                                variant: AppButtonVariant.outline,
                                height: kMinInteractiveDimension,
                                onPressed: () => _addLocation(isVan: false),
                              ),
                            ],
                            if (canManageVans) ...[
                              SizedBox(height: context.getRSize(20)),
                              const SectionHeader(title: 'Vans'),
                              SizedBox(height: context.getRSize(6)),
                              Text(
                                'A van holds stock on the road. It is kept out of the '
                                'store picker and per-store reports, so only the drivers '
                                'you assign to it sell from it.',
                                style: context
                                    .regularStyle(13)
                                    .copyWith(color: muted),
                              ),
                              SizedBox(height: context.getRSize(12)),
                              for (final van in _vans) ...[
                                _LocationCard(
                                  nameLabel: 'Van name',
                                  nameIcon: AppIcons.supplier,
                                  nameController: _nameControllers[van.id]!,
                                  addressController:
                                      _addressControllers[van.id]!,
                                  saving: _saving.contains(van.id),
                                  onSave: () => _save(van),
                                ),
                                SizedBox(height: context.getRSize(12)),
                              ],
                              if (_vans.isEmpty)
                                Padding(
                                  padding: EdgeInsets.only(
                                    bottom: context.getRSize(16),
                                  ),
                                  child: Text(
                                    'No vans yet.',
                                    style: context
                                        .regularStyle(13)
                                        .copyWith(color: muted),
                                  ),
                                ),
                              AppButton(
                                text: 'Add a van',
                                icon: AppIcons.add,
                                variant: AppButtonVariant.outline,
                                height: kMinInteractiveDimension,
                                onPressed: () => _addLocation(isVan: true),
                              ),
                            ],
                          ],
                        ),
                      ),
                      top: context.getRSize(10),
                      bottom:
                          context.getRSize(24) + context.deviceBottomPadding,
                    ),
                  ],
                ),
              ),
      ),
    );
  }
}

/// Subtle fade-in wrapper for loaded content (§30.7 — no spinners). A local
/// copy of the frozen `SettingsFadeIn`.
class _FadeIn extends StatelessWidget {
  const _FadeIn({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 400),
      curve: Curves.easeIn,
      builder: (context, opacity, child) =>
          Opacity(opacity: opacity, child: child),
      child: child,
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
    return DecoratedBox(
      decoration: AppDecorations.card(context),
      child: Padding(
        padding: EdgeInsets.all(context.getRSize(12)),
        child: Column(
          children: [
            AppInput(
              controller: nameController,
              textCapitalization: TextCapitalization.words,
              labelText: nameLabel,
              prefixIcon: Icon(nameIcon, size: 20),
            ),
            SizedBox(height: context.getRSize(12)),
            AppInput(
              controller: addressController,
              labelText: 'Address',
              prefixIcon: const Icon(AppIcons.location, size: 20),
            ),
            SizedBox(height: context.getRSize(12)),
            AppButton(text: 'Save changes', onPressed: saving ? null : onSave),
          ],
        ),
      ),
    );
  }
}
