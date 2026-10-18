import 'dart:async';
import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reebaplus_pos/core/theme/app_decorations.dart';
import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/data/countries.dart';
import 'package:reebaplus_pos/core/permissions/permissions.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/stores/van_store.dart';
import 'package:reebaplus_pos/core/widgets/app_fab.dart';
import 'package:reebaplus_pos/shared/widgets/shared_scaffold.dart';
import 'package:reebaplus_pos/shared/widgets/app_refresh_wrapper.dart';
import 'package:reebaplus_pos/shared/widgets/menu_button.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:reebaplus_pos/shared/widgets/app_input.dart';
import 'package:reebaplus_pos/shared/widgets/spotlight_target.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/redesign.dart';

import 'package:reebaplus_pos/core/theme/fixed_colors.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/utils/notifications.dart';
import 'package:reebaplus_pos/features/stores/screens/store_details_screen.dart';
import 'package:reebaplus_pos/features/stores/widgets/stores_parts.dart';

class StoresScreen extends ConsumerStatefulWidget {
  const StoresScreen({super.key});

  @override
  ConsumerState<StoresScreen> createState() => _StoresScreenState();
}

class _StoresScreenState extends ConsumerState<StoresScreen> {
  List<StoreData> _stores = [];
  StreamSubscription<List<StoreData>>? _storesSub;

  @override
  void initState() {
    super.initState();
    final db = ref.read(databaseProvider);
    // #140 — vans are locations, but they are not stores: they never appear in
    // this list, its transfer flows, or the store details screen. They are
    // registered and listed in Settings → Stores, and get their own hub in
    // #141 (van-sales spec §4.1).
    _storesSub = db.storesDao.watchActiveStores().listen((data) {
      if (mounted) setState(() => _stores = withoutVans(data));
    });
  }

  @override
  void dispose() {
    _storesSub?.cancel();
    super.dispose();
  }

  /// The name, address and country fields shared by the Add and Edit sheets.
  List<Widget> _formFields(
    BuildContext ctx, {
    required TextEditingController nameCtrl,
    required TextEditingController addressCtrl,
    required String nameHint,
    required String countryValue,
    required ValueChanged<String> onCountry,
  }) {
    return [
      AppInput(
        controller: nameCtrl,
        labelText: 'Store Name',
        hintText: nameHint,
        prefixIcon: const Icon(AppIcons.store, size: 20),
        validator: (v) =>
            v == null || v.trim().isEmpty ? 'Name is required' : null,
      ),
      SizedBox(height: ctx.getRSize(16)),
      AppInput(
        controller: addressCtrl,
        labelText: 'Street Address',
        hintText: 'e.g. 14 Market Road',
        prefixIcon: const Icon(AppIcons.map, size: 20),
        validator: (v) =>
            v == null || v.trim().isEmpty ? 'Street Address is required' : null,
      ),
      SizedBox(height: ctx.getRSize(16)),
      StoresAutocompleteField(
        label: 'Country',
        icon: AppIcons.public,
        initial: countryValue,
        options: kCountries,
        onChanged: onCountry,
        fieldBuilder: (c, controller, focusNode, onSubmitted) => AppInput(
          controller: controller,
          focusNode: focusNode,
          textCapitalization: TextCapitalization.words,
          onChanged: onCountry,
          onFieldSubmitted: (_) => onSubmitted(),
          prefixIcon: const Icon(AppIcons.public, size: 20),
        ),
      ),
      SizedBox(height: ctx.getRSize(24)),
    ];
  }

  // ── Add Store ──────────────────────────────────────────────────────────
  void _showAddSheet(BuildContext context) {
    final nameCtrl = TextEditingController();
    final addressCtrl = TextEditingController();
    final formKey = GlobalKey<FormState>();
    bool saving = false;
    String countryValue = kDefaultCountry;

    showStoresSheet<void>(
      context,
      (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          return SpotlightTarget(
            id: SpotlightTargetId.createStoreForm,
            child: Form(
              key: formKey,
              child: StoreSheetFrame(
                icon: AppIcons.store,
                title: 'New Store',
                children: [
                  ..._formFields(
                    ctx,
                    nameCtrl: nameCtrl,
                    addressCtrl: addressCtrl,
                    nameHint: 'e.g. Main Store, Annex B',
                    countryValue: countryValue,
                    onCountry: (v) => setSheet(() => countryValue = v),
                  ),
                  AppButton(
                    text: 'Save Store',
                    onPressed: saving
                        ? null
                        : () async {
                            if (!formKey.currentState!.validate()) return;
                            // Re-check at the write boundary (hard rule #6).
                            if (!Gates.manageStores.allowsNow(ref)) {
                              showGateDenied(ctx, Gates.manageStores);
                              return;
                            }
                            setSheet(() => saving = true);
                            try {
                              final db = ref.read(databaseProvider);
                              final combinedLocation = [
                                addressCtrl.text.trim(),
                                countryValue.trim(),
                              ].where((p) => p.isNotEmpty).join(', ');

                              final currentUserId = ref
                                  .read(authProvider)
                                  .currentUser
                                  ?.id;
                              await db.storesDao.createStore(
                                name: nameCtrl.text.trim(),
                                location: combinedLocation,
                                userId: currentUserId,
                              );
                              try {
                                await ref
                                    .read(authProvider)
                                    .refreshCurrentUser();
                              } catch (_) {
                                // Refresh failure after commit must not trigger
                                // "Could not save store" or allow a duplicate retry.
                              }
                              if (ctx.mounted) Navigator.pop(ctx);
                            } catch (e) {
                              setSheet(() => saving = false);
                              if (ctx.mounted) {
                                AppNotification.showError(
                                  ctx,
                                  'Could not save store. Please try again.',
                                );
                              }
                            }
                          },
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  // ── Edit Store ─────────────────────────────────────────────────────────
  void _showEditSheet(BuildContext context, StoreData store) {
    final nameCtrl = TextEditingController(text: store.name);

    // Parse `stores.location`. The current format is "street, country" (2
    // parts); rows written before the state/LGA pickers were dropped are
    // "street, lga, state, country" (4) or "street, state, country" (3). All
    // three shapes put the street first and the country last, so read the ends
    // and ignore whatever is in between — those middle segments are no longer
    // collected and are dropped the next time the store is saved.
    final locParts = (store.location ?? '')
        .split(',')
        .map((p) => p.trim())
        .where((p) => p.isNotEmpty)
        .toList();
    final addressCtrl = TextEditingController(
      text: locParts.isNotEmpty ? locParts.first : '',
    );
    final initCountry = locParts.length >= 2 ? locParts.last : kDefaultCountry;

    final formKey = GlobalKey<FormState>();
    bool saving = false;
    String countryValue = initCountry;

    showStoresSheet<void>(
      context,
      (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          return Form(
            key: formKey,
            child: StoreSheetFrame(
              icon: AppIcons.edit,
              title: 'Edit Store',
              children: [
                ..._formFields(
                  ctx,
                  nameCtrl: nameCtrl,
                  addressCtrl: addressCtrl,
                  nameHint: 'e.g. Main Store',
                  countryValue: countryValue,
                  onCountry: (v) => setSheet(() => countryValue = v),
                ),
                AppButton(
                  text: 'Save Changes',
                  onPressed: saving
                      ? null
                      : () async {
                          if (!formKey.currentState!.validate()) return;
                          // Re-check at the write boundary (hard rule #6).
                          if (!Gates.manageStores.allowsNow(ref)) {
                            showGateDenied(ctx, Gates.manageStores);
                            return;
                          }
                          setSheet(() => saving = true);
                          final db = ref.read(databaseProvider);
                          final combinedLocation = [
                            addressCtrl.text.trim(),
                            countryValue.trim(),
                          ].where((p) => p.isNotEmpty).join(', ');

                          try {
                            await db.storesDao.updateStore(
                              id: store.id,
                              name: nameCtrl.text.trim(),
                              location: combinedLocation,
                            );
                            if (ctx.mounted) Navigator.pop(ctx);
                          } catch (e) {
                            setSheet(() => saving = false);
                            if (ctx.mounted) {
                              AppNotification.showError(
                                ctx,
                                'Could not save store. Please try again.',
                              );
                            }
                          }
                        },
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  // ── Delete Store ───────────────────────────────────────────────────────
  Future<void> _confirmDelete(BuildContext context, StoreData store) async {
    final db = ref.read(databaseProvider);
    final rows = await (db.select(
      db.inventory,
    )..where((t) => t.storeId.equals(store.id))).get();
    final stock = rows.fold<int>(0, (sum, r) => sum + r.quantity);
    if (!context.mounted) return;

    showDialog(
      context: context,
      builder: (ctx) {
        final t = Theme.of(ctx);
        final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
        return AlertDialog(
          scrollable: true,
          title: Text(
            'Delete Store',
            style: ctx.screenTitleStyle.copyWith(color: t.colorScheme.onSurface),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Are you sure you want to delete "${store.name}"?',
                style: ctx.regularStyle(14).copyWith(color: muted),
              ),
              if (stock > 0) ...[
                SizedBox(height: ctx.getRSize(12)),
                StoresNotice(
                  tone: IconTileTone.warning,
                  icon: AppIcons.warning,
                  text:
                      'This store has $stock units in stock. Deleting it will also remove its inventory records.',
                ),
              ],
            ],
          ),
          actions: [
            AppButton(
              text: 'Cancel',
              variant: AppButtonVariant.ghost,
              size: AppButtonSize.small,
              isFullWidth: false,
              onPressed: () => Navigator.pop(ctx),
            ),
            AppButton(
              text: 'Delete',
              variant: AppButtonVariant.danger,
              size: AppButtonSize.small,
              isFullWidth: false,
              onPressed: () async {
                Navigator.pop(ctx);
                // Re-check at the write boundary (hard rule #6) — deleting a
                // store needs `stores.manage`.
                if (!Gates.manageStores.allowsNow(ref)) {
                  showGateDenied(context, Gates.manageStores);
                  return;
                }
                // Soft-delete the store: hard-delete would orphan
                // inventory and ledger FKs. The cloud-side cascade in 0001
                // is ON DELETE CASCADE for inventory, but realtime DELETE
                // events confuse local listeners. Soft-delete + enqueue is
                // the consistent path with the rest of the codebase.
                final db = ref.read(databaseProvider);
                final whComp = StoresCompanion(
                  id: Value(store.id),
                  isDeleted: const Value(true),
                  lastUpdatedAt: Value(DateTime.now()),
                );
                try {
                  await (db.update(
                    db.stores,
                  )..where((t) => t.id.equals(store.id))).write(whComp);
                  // Full-row enqueue: a partial stores upsert omits the NOT NULL name.
                  await db.syncDao.enqueueUpsert(
                    'stores',
                    store
                        .toCompanion(true)
                        .copyWith(
                          isDeleted: const Value(true),
                          lastUpdatedAt: whComp.lastUpdatedAt,
                        ),
                  );
                } catch (e) {
                  if (context.mounted) {
                    AppNotification.showError(
                      context,
                      'Could not delete store. Please try again.',
                    );
                  }
                }
              },
            ),
          ],
        );
      },
    );
  }

  // ── Build ──────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    // Add/Edit/Delete a store is CEO-only — `stores.manage` (hard rule #6/#7).
    // Browsing the store list is open to any Manager who takes part in the
    // store-scoped transfer flow (§16.8.2) so they can open a store and request
    // stock from it; per-store full view + actions are gated inside the details
    // screen. Stock Transfer entry points have moved off this screen into the
    // store details. This tab is persistently mounted, so guard reactively: a
    // live grant change updates the FAB, the cards' Edit/Delete, and access.
    final canManage = Gates.manageStores.allows(ref);
    // Browse composite: a named gate can't own this one — the all-stores
    // viewer leg is a provider (store assignment), not a permission key — so
    // the composition stays here, citing the named gates for each key leg.
    final canSeeStores =
        canManage ||
        ref.watch(canViewAllStoresProvider) ||
        Gates.requestStoreTransfer.allows(ref) ||
        Gates.dispatchStoreTransfer.allows(ref) ||
        Gates.receiveStoreTransfer.allows(ref);
    return Container(
      decoration: AppDecorations.pageBackground(context),
      child: SharedScaffold(
        activeRoute: 'store',
        backgroundColor: Colors.transparent,
        appBar: StoresTopBar(
          key: StoresKeys.topBar,
          height: storesTopBarHeight(context),
          header: ScreenHeader(
            icon: AppIcons.store,
            title: 'Stores',
            subtitle: ref.watch(activeStoreLabelProvider),
            leading: context.isRailLayout
                ? null
                : const SizedBox.square(
                    dimension: kMinInteractiveDimension,
                    child: MenuButton(),
                  ),
            actions: const [StoresLiveBell()],
          ),
        ),
        floatingActionButton: canManage
            ? SpotlightTarget(
                id: SpotlightTargetId.createStoreFab,
                child: AppFAB(
                  onPressed: () => _showAddSheet(context),
                  icon: AppIcons.add,
                  label: 'Add Store',
                ),
              )
            : null,
        body: !canSeeStores
            ? const StoresMessage(
                key: StoresKeys.noAccess,
                text: 'You don’t have access to Stores.',
              )
            : Builder(
                builder: (context) {
                  final stores = _stores;
                  if (stores.isEmpty) {
                    return const AppRefreshWrapper(
                      child: CustomScrollView(
                        physics: AlwaysScrollableScrollPhysics(),
                        slivers: [
                          SliverFillRemaining(
                            hasScrollBody: false,
                            child: StoresMessage(
                              key: StoresKeys.empty,
                              icon: AppIcons.store,
                              title: 'No Stores Yet',
                              text:
                                  'Tap "Add Store" to create\nyour first storage location.',
                            ),
                          ),
                        ],
                      ),
                    );
                  }
                  return AppRefreshWrapper(
                    child: CustomScrollView(
                      key: StoresKeys.list,
                      physics: const AlwaysScrollableScrollPhysics(),
                      slivers: [
                        storesSliver(
                          SliverList.separated(
                            itemCount: stores.length,
                            separatorBuilder: (_, _) =>
                                SizedBox(height: context.getRSize(12)),
                            itemBuilder: (context, index) =>
                                _buildStoreCard(context, stores[index]),
                          ),
                          top: context.getRSize(16),
                          // Clears the Add Store FAB.
                          bottom:
                              context.getRSize(88) + context.deviceBottomPadding,
                        ),
                      ],
                    ),
                  );
                },
              ),
      ),
    );
  }

  // ── Store card ─────────────────────────────────────────────────────────
  Widget _buildStoreCard(BuildContext context, StoreData store) {
    return _StoreCard(
      // Key by store id so Flutter matches card state to the store, not the
      // list position. Stores are ordered by name, so inserting a new store
      // shifts positions; without this key the position-matched state keeps
      // streaming the previous store's inventory and shows its stock.
      key: ValueKey(store.id),
      store: store,
      onEdit: () => _showEditSheet(context, store),
      onDelete: () => _confirmDelete(context, store),
    );
  }
}

// ── Reactive store card ────────────────────────────────────────────────────

class _StoreCard extends ConsumerStatefulWidget {
  final StoreData store;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  const _StoreCard({
    super.key,
    required this.store,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  ConsumerState<_StoreCard> createState() => _StoreCardState();
}

class _StoreCardState extends ConsumerState<_StoreCard> {
  List<ProductDataWithStock> _inventory = [];
  StreamSubscription<List<ProductDataWithStock>>? _invSub;

  @override
  void initState() {
    super.initState();
    _subscribeInventory();
  }

  @override
  void didUpdateWidget(_StoreCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    // If this card's state is reused for a different store, re-target the
    // inventory stream and clear the stale figures so we never show another
    // store's stock.
    if (oldWidget.store.id != widget.store.id) {
      _inventory = [];
      _subscribeInventory();
    }
  }

  void _subscribeInventory() {
    _invSub?.cancel();
    final db = ref.read(databaseProvider);
    _invSub = db.inventoryDao
        .watchProductDatasWithStockByStore(widget.store.id)
        .listen((list) {
          if (mounted) setState(() => _inventory = list);
        });
  }

  @override
  void dispose() {
    _invSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    final f = t.extension<AppFixedColors>() ?? AppFixedColors.light;
    final totalStock = _inventory.fold<int>(0, (s, p) => s + p.totalStock);
    final productCount = _inventory.where((p) => p.totalStock > 0).length;
    final location = widget.store.location;
    final hasLocation = location != null && location.isNotEmpty;
    final canManage = Gates.manageStores.allows(ref);
    final hairline = Divider(height: 1, thickness: 1, color: t.dividerColor);

    return StoresCardShell(
      key: StoresKeys.card(widget.store.id),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Main row — the whole row opens Store Details.
          InkWell(
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => StoreDetailsScreen(store: widget.store),
                ),
              );
            },
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                minHeight: kMinInteractiveDimension,
              ),
              child: Padding(
                padding: EdgeInsets.all(context.getRSize(14)),
                child: Row(
                  children: [
                    const IconTile(icon: AppIcons.store, size: 44),
                    SizedBox(width: context.getRSize(12)),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            widget.store.name,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: context.boldStyle(15).copyWith(
                              color: t.colorScheme.onSurface,
                            ),
                          ),
                          if (hasLocation) ...[
                            SizedBox(height: context.getRSize(3)),
                            Row(
                              children: [
                                AppIcon(
                                  AppIcons.location,
                                  size: context.getRSize(14),
                                  color: muted,
                                ),
                                SizedBox(width: context.getRSize(4)),
                                Expanded(
                                  child: Text(
                                    location,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: context
                                        .regularStyle(12)
                                        .copyWith(color: muted),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ],
                      ),
                    ),
                    SizedBox(width: context.getRSize(8)),
                    AppIcon(
                      AppIcons.chevronRight,
                      size: context.getRSize(20),
                      color: muted,
                    ),
                  ],
                ),
              ),
            ),
          ),
          hairline,
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: StoreFigure(
                    icon: AppIcons.inventory,
                    tone: IconTileTone.info,
                    label: 'Total Units',
                    value: totalStock.toString(),
                  ),
                ),
                VerticalDivider(width: 1, thickness: 1, color: t.dividerColor),
                Expanded(
                  child: StoreFigure(
                    icon: AppIcons.tag,
                    tone: IconTileTone.green,
                    label: 'Products',
                    value: productCount.toString(),
                  ),
                ),
              ],
            ),
          ),
          // Actions row — Edit/Delete a store is CEO-only (`stores.manage`).
          // Hidden entirely for browse-only viewers (hide-don't-block).
          if (canManage) ...[
            hairline,
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: KeyedSubtree(
                      key: StoresKeys.edit(widget.store.id),
                      child: StoreCardAction(
                        icon: AppIcons.edit,
                        color: t.colorScheme.primary,
                        label: 'Edit',
                        onTap: widget.onEdit,
                      ),
                    ),
                  ),
                  VerticalDivider(
                    width: 1,
                    thickness: 1,
                    color: t.dividerColor,
                  ),
                  Expanded(
                    child: KeyedSubtree(
                      key: StoresKeys.delete(widget.store.id),
                      child: StoreCardAction(
                        icon: AppIcons.delete,
                        color: f.danger,
                        label: 'Delete',
                        onTap: widget.onDelete,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}
