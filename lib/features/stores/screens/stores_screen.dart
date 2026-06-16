import 'dart:async';
import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/widgets/app_fab.dart';
import 'package:reebaplus_pos/shared/widgets/shared_scaffold.dart';
import 'package:reebaplus_pos/shared/widgets/menu_button.dart';
import 'package:reebaplus_pos/shared/widgets/app_bar_header.dart';
import 'package:reebaplus_pos/shared/widgets/notification_bell.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:reebaplus_pos/shared/widgets/app_input.dart';

import 'package:reebaplus_pos/core/theme/design_tokens.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/core/utils/notifications.dart';
import 'package:reebaplus_pos/features/stores/screens/store_details_screen.dart';
import 'package:reebaplus_pos/features/stores/screens/stock_transfer_screen.dart';
import 'package:reebaplus_pos/features/stores/screens/incoming_transfers_screen.dart';

class StoresScreen extends ConsumerStatefulWidget {
  const StoresScreen({super.key});

  @override
  ConsumerState<StoresScreen> createState() => _StoresScreenState();
}

class _StoresScreenState extends ConsumerState<StoresScreen> {
  Color get _bg => Theme.of(context).scaffoldBackgroundColor;
  Color get _surface => Theme.of(context).colorScheme.surface;
  Color get _text => Theme.of(context).colorScheme.onSurface;
  Color get _subtext =>
      Theme.of(context).textTheme.bodySmall?.color ??
      Theme.of(context).iconTheme.color!;
  Color get _border => Theme.of(context).dividerColor;
  List<StoreData> _stores = [];
  StreamSubscription<List<StoreData>>? _storesSub;

  @override
  void initState() {
    super.initState();
    final db = ref.read(databaseProvider);
    _storesSub = db.storesDao.watchActiveStores().listen((data) {
      if (mounted) setState(() => _stores = data);
    });
  }

  @override
  void dispose() {
    _storesSub?.cancel();
    super.dispose();
  }

  // ── Add Store ──────────────────────────────────────────────────────────
  void _showAddSheet(BuildContext context) {
    final nameCtrl = TextEditingController();
    final addressCtrl = TextEditingController();
    final cityStateCtrl = TextEditingController();
    final countryCtrl = TextEditingController();
    final formKey = GlobalKey<FormState>();
    bool saving = false;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => Padding(
          padding: EdgeInsets.only(bottom: ctx.deviceBottomPadding),
          child: Container(
            decoration: BoxDecoration(
              color: _surface,
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(24),
              ),
            ),
            padding: EdgeInsets.fromLTRB(
              rSize(ctx, 24),
              rSize(ctx, 20),
              rSize(ctx, 24),
              rSize(ctx, 32),
            ),
            child: Form(
              key: formKey,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Handle
                    Center(
                      child: Container(
                        width: 40,
                        height: 4,
                        decoration: BoxDecoration(
                          color: _border,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                    SizedBox(height: rSize(ctx, 20)),

                    // Title
                    Row(
                      children: [
                        Container(
                          padding: EdgeInsets.all(rSize(ctx, 10)),
                          decoration: BoxDecoration(
                            color: Theme.of(
                              context,
                            ).colorScheme.primary.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Icon(
                            FontAwesomeIcons.store.data,
                            color: Theme.of(context).colorScheme.primary,
                            size: rSize(ctx, 18),
                          ),
                        ),
                        SizedBox(width: rSize(ctx, 12)),
                        Text(
                          'New Store',
                          style: TextStyle(
                            fontSize: rFontSize(ctx, 18),
                            fontWeight: FontWeight.bold,
                            color: _text,
                          ),
                        ),
                      ],
                    ),
                    SizedBox(height: rSize(ctx, 24)),

                    AppInput(
                      controller: nameCtrl,
                      labelText: 'Store Name',
                      hintText: 'e.g. Main Store, Annex B',
                      prefixIcon: const Icon(Icons.store_outlined, size: 20),
                      validator: (v) => v == null || v.trim().isEmpty
                          ? 'Name is required'
                          : null,
                    ),
                    SizedBox(height: rSize(ctx, 16)),

                    AppInput(
                      controller: addressCtrl,
                      labelText: 'Street Address',
                      hintText: 'e.g. 14 Market Road',
                      prefixIcon: const Icon(Icons.map_outlined, size: 20),
                      validator: (v) => v == null || v.trim().isEmpty
                          ? 'Street Address is required'
                          : null,
                    ),
                    SizedBox(height: rSize(ctx, 16)),

                    AppInput(
                      controller: cityStateCtrl,
                      labelText: 'City and State',
                      hintText: 'e.g. Lagos Island, Lagos',
                      prefixIcon: const Icon(
                        Icons.location_city_outlined,
                        size: 20,
                      ),
                      validator: (v) => v == null || v.trim().isEmpty
                          ? 'City and State are required'
                          : null,
                    ),
                    SizedBox(height: rSize(ctx, 16)),

                    AppInput(
                      controller: countryCtrl,
                      labelText: 'Country',
                      hintText: 'e.g. Nigeria',
                      prefixIcon: const Icon(Icons.public_outlined, size: 20),
                      validator: (v) => v == null || v.trim().isEmpty
                          ? 'Country is required'
                          : null,
                    ),
                    SizedBox(height: rSize(ctx, 28)),

                    // Save button
                    AppButton(
                      text: 'Save Store',
                      onPressed: saving
                          ? null
                          : () async {
                              if (!formKey.currentState!.validate()) return;
                              // Re-check at the write boundary (hard rule #6) in
                              // case `stores.manage` was revoked while the
                              // sheet was open.
                              if (!ref
                                  .read(currentUserPermissionsProvider)
                                  .contains('stores.manage')) {
                                return;
                              }
                              setSheet(() => saving = true);
                              try {
                                final db = ref.read(databaseProvider);
                                final combinedLocation =
                                    '${addressCtrl.text.trim()}, ${cityStateCtrl.text.trim()}, ${countryCtrl.text.trim()}';

                                final whBusinessId = ref
                                    .read(authProvider)
                                    .currentUser
                                    ?.businessId;
                                if (whBusinessId == null) return;
                                final whComp = StoresCompanion.insert(
                                  id: Value(UuidV7.generate()),
                                  name: nameCtrl.text.trim(),
                                  businessId: whBusinessId,
                                  location: Value(combinedLocation),
                                  lastUpdatedAt: Value(DateTime.now()),
                                );
                                await db.into(db.stores).insert(whComp);
                                await db.syncDao.enqueueUpsert(
                                  'stores',
                                  whComp,
                                );
                                if (ctx.mounted) Navigator.pop(ctx);
                              } catch (e) {
                                setSheet(() => saving = false);
                                if (ctx.mounted) {
                                  AppNotification.showError(ctx, 'Error: $e');
                                }
                              }
                            },
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ── Edit Store ─────────────────────────────────────────────────────────
  void _showEditSheet(BuildContext context, StoreData store) {
    final nameCtrl = TextEditingController(text: store.name);

    // Parse location: "Street, City/State, Country"
    final locParts = (store.location ?? '').split(', ');
    final addressCtrl = TextEditingController(
      text: locParts.isNotEmpty ? locParts[0] : '',
    );
    final cityStateCtrl = TextEditingController(
      text: locParts.length > 1 ? locParts[1] : '',
    );
    final countryCtrl = TextEditingController(
      text: locParts.length > 2 ? locParts[2] : '',
    );

    final formKey = GlobalKey<FormState>();
    bool saving = false;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => Padding(
          padding: EdgeInsets.only(bottom: ctx.deviceBottomPadding),
          child: Container(
            decoration: BoxDecoration(
              color: _surface,
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(24),
              ),
            ),
            padding: EdgeInsets.fromLTRB(
              rSize(ctx, 24),
              rSize(ctx, 20),
              rSize(ctx, 24),
              rSize(ctx, 32),
            ),
            child: Form(
              key: formKey,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Center(
                      child: Container(
                        width: 40,
                        height: 4,
                        decoration: BoxDecoration(
                          color: _border,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                    SizedBox(height: rSize(ctx, 20)),
                    Row(
                      children: [
                        Container(
                          padding: EdgeInsets.all(rSize(ctx, 10)),
                          decoration: BoxDecoration(
                            color: Theme.of(
                              context,
                            ).colorScheme.primary.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Icon(
                            FontAwesomeIcons.penToSquare.data,
                            color: Theme.of(context).colorScheme.primary,
                            size: rSize(ctx, 18),
                          ),
                        ),
                        SizedBox(width: rSize(ctx, 12)),
                        Text(
                          'Edit Store',
                          style: TextStyle(
                            fontSize: rFontSize(ctx, 18),
                            fontWeight: FontWeight.bold,
                            color: _text,
                          ),
                        ),
                      ],
                    ),
                    SizedBox(height: rSize(ctx, 24)),
                    AppInput(
                      controller: nameCtrl,
                      labelText: 'Store Name',
                      hintText: 'e.g. Main Store',
                      prefixIcon: const Icon(Icons.store_outlined, size: 20),
                      validator: (v) => v == null || v.trim().isEmpty
                          ? 'Name is required'
                          : null,
                    ),
                    SizedBox(height: rSize(ctx, 16)),
                    AppInput(
                      controller: addressCtrl,
                      labelText: 'Street Address',
                      hintText: 'e.g. 14 Market Road',
                      prefixIcon: const Icon(Icons.map_outlined, size: 20),
                      validator: (v) => v == null || v.trim().isEmpty
                          ? 'Street Address is required'
                          : null,
                    ),
                    SizedBox(height: rSize(ctx, 16)),
                    AppInput(
                      controller: cityStateCtrl,
                      labelText: 'City and State',
                      hintText: 'e.g. Lagos Island, Lagos',
                      prefixIcon: const Icon(
                        Icons.location_city_outlined,
                        size: 20,
                      ),
                      validator: (v) => v == null || v.trim().isEmpty
                          ? 'City and State are required'
                          : null,
                    ),
                    SizedBox(height: rSize(ctx, 16)),
                    AppInput(
                      controller: countryCtrl,
                      labelText: 'Country',
                      hintText: 'e.g. Nigeria',
                      prefixIcon: const Icon(Icons.public_outlined, size: 20),
                      validator: (v) => v == null || v.trim().isEmpty
                          ? 'Country is required'
                          : null,
                    ),
                    SizedBox(height: rSize(ctx, 28)),
                    AppButton(
                      text: 'Save Changes',
                      onPressed: saving
                          ? null
                          : () async {
                              if (!formKey.currentState!.validate()) return;
                              // Re-check at the write boundary (hard rule #6).
                              if (!ref
                                  .read(currentUserPermissionsProvider)
                                  .contains('stores.manage')) {
                                return;
                              }
                              setSheet(() => saving = true);
                              final db = ref.read(databaseProvider);
                              final combinedLocation =
                                  '${addressCtrl.text.trim()}, ${cityStateCtrl.text.trim()}, ${countryCtrl.text.trim()}';

                              final whComp = StoresCompanion(
                                id: Value(store.id),
                                name: Value(nameCtrl.text.trim()),
                                location: Value(combinedLocation),
                                lastUpdatedAt: Value(DateTime.now()),
                              );
                              try {
                                await (db.update(db.stores)
                                      ..where((t) => t.id.equals(store.id)))
                                    .write(whComp);
                                await db.syncDao.enqueueUpsert(
                                  'stores',
                                  whComp,
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
              ),
            ),
          ),
        ),
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
      builder: (ctx) => AlertDialog(
        backgroundColor: _surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(
          'Delete Store',
          style: TextStyle(
            color: _text,
            fontWeight: FontWeight.bold,
            fontSize: 18,
          ),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Are you sure you want to delete "${store.name}"?',
              style: TextStyle(color: _subtext),
            ),
            if (stock > 0) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: AppColors.warning.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: AppColors.warning.withValues(alpha: 0.3),
                  ),
                ),
                child: Row(
                  children: [
                    const Icon(
                      Icons.warning_amber_rounded,
                      color: AppColors.warning,
                      size: 18,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'This store has $stock units in stock. Deleting it will also remove its inventory records.',
                        style: const TextStyle(
                          color: AppColors.warning,
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
        actions: [
          AppButton(
            text: 'Cancel',
            variant: AppButtonVariant.ghost,
            size: AppButtonSize.small,
            onPressed: () => Navigator.pop(ctx),
          ),
          AppButton(
            text: 'Delete',
            variant: AppButtonVariant.danger,
            size: AppButtonSize.small,
            onPressed: () async {
              Navigator.pop(ctx);
              // Re-check at the write boundary (hard rule #6) — deleting a
              // store needs `stores.manage`.
              if (!ref
                  .read(currentUserPermissionsProvider)
                  .contains('stores.manage')) {
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
      ),
    );
  }

  // ── Build ──────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    // Stores management is CEO-only — `stores.manage` (hard rule #6/#7). The
    // drawer entry is gated, but this tab is persistently mounted, so guard the
    // screen reactively too: if the grant is revoked live, the Add / Stock
    // Transfer entry points, the store cards' Edit/Delete, and the list all
    // disappear at once.
    final canManage = hasPermission(ref, 'stores.manage');
    return SharedScaffold(
      activeRoute: 'store',
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: _surface,
        elevation: 0,
        leading: const MenuButton(),
        title: AppBarHeader(
          icon: FontAwesomeIcons.store.data,
          title: 'Stores',
          subtitle: 'Manage Storage Locations',
        ),
        actions: [
          if (canManage)
            IconButton(
              tooltip: 'Stock Transfer',
              icon: const Icon(Icons.swap_horiz_rounded),
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const StockTransferScreen()),
              ),
            ),
          if (canManage || hasPermission(ref, 'stores.receive_transfer'))
            IconButton(
              tooltip: 'Transfer Queue',
              icon: const Icon(Icons.move_to_inbox_rounded),
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => const IncomingTransfersScreen(),
                ),
              ),
            ),
          const NotificationBell(),
          SizedBox(width: rSize(context, 8)),
        ],
      ),
      floatingActionButton: canManage
          ? AppFAB(
              onPressed: () => _showAddSheet(context),
              icon: Icons.add_rounded,
              label: 'Add Store',
            )
          : null,
      body: !canManage
          ? Center(
              child: Padding(
                padding: EdgeInsets.all(rSize(context, 32)),
                child: Text(
                  'You don’t have access to Stores.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: _subtext,
                    fontSize: rFontSize(context, 14),
                  ),
                ),
              ),
            )
          : Builder(
              builder: (context) {
                final stores = _stores;

                if (stores.isEmpty) {
                  return _buildEmptyState(context);
                }

                return ListView.builder(
                  padding: EdgeInsets.fromLTRB(
                    rSize(context, 16),
                    rSize(context, 16),
                    rSize(context, 16),
                    rSize(context, 100) + context.deviceBottomPadding,
                  ),
                  itemCount: stores.length,
                  itemBuilder: (context, index) =>
                      _buildStoreCard(context, stores[index]),
                );
              },
            ),
    );
  }

  // ── Empty state ────────────────────────────────────────────────────────────
  Widget _buildEmptyState(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: EdgeInsets.all(rSize(context, 24)),
            decoration: BoxDecoration(
              color: Theme.of(
                context,
              ).colorScheme.primary.withValues(alpha: 0.08),
              shape: BoxShape.circle,
            ),
            child: Icon(
              FontAwesomeIcons.store.data,
              size: rSize(context, 40),
              color: Theme.of(
                context,
              ).colorScheme.primary.withValues(alpha: 0.5),
            ),
          ),
          SizedBox(height: rSize(context, 20)),
          Text(
            'No Stores Yet',
            style: TextStyle(
              fontSize: rFontSize(context, 18),
              fontWeight: FontWeight.bold,
              color: _text,
            ),
          ),
          SizedBox(height: rSize(context, 8)),
          Text(
            'Tap "Add Store" to create\nyour first storage location.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: rFontSize(context, 14),
              color: _subtext,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }

  // ── Store card ─────────────────────────────────────────────────────────
  Widget _buildStoreCard(BuildContext context, StoreData store) {
    return _StoreCard(
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
  Color get _surface => Theme.of(context).colorScheme.surface;
  Color get _text => Theme.of(context).colorScheme.onSurface;
  Color get _subtext =>
      Theme.of(context).textTheme.bodySmall?.color ??
      Theme.of(context).iconTheme.color!;
  // Stronger border for card edges and dividers — more visible in light mode
  Color get _strongBorder => Theme.of(context).dividerColor;
  // Subtle blue-tinted stripe for stats/actions section in light mode
  Color get _stripe => Theme.of(context).cardColor;

  @override
  void initState() {
    super.initState();
    final db = ref.read(databaseProvider);
    final id = widget.store.id;
    _invSub = db.inventoryDao.watchProductDatasWithStockByStore(id).listen((
      list,
    ) {
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
    final totalStock = _inventory.fold<int>(0, (s, p) => s + p.totalStock);
    final productCount = _inventory.where((p) => p.totalStock > 0).length;

    return Container(
      margin: EdgeInsets.only(bottom: rSize(context, 14)),
      decoration: BoxDecoration(
        color: _surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _strongBorder),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.07),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Column(
        children: [
          // Main row
          InkWell(
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => StoreDetailsScreen(store: widget.store),
                ),
              );
            },
            borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
            child: Padding(
              padding: EdgeInsets.all(rSize(context, 16)),
              child: Row(
                children: [
                  Container(
                    padding: EdgeInsets.all(rSize(context, 12)),
                    decoration: BoxDecoration(
                      color: Theme.of(
                        context,
                      ).colorScheme.primary.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(
                      FontAwesomeIcons.store.data,
                      color: Theme.of(context).colorScheme.primary,
                      size: rSize(context, 20),
                    ),
                  ),
                  SizedBox(width: rSize(context, 14)),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.store.name,
                          style: TextStyle(
                            fontSize: rFontSize(context, 16),
                            fontWeight: FontWeight.bold,
                            color: _text,
                          ),
                        ),
                        if (widget.store.location != null &&
                            widget.store.location!.isNotEmpty) ...[
                          SizedBox(height: rSize(context, 3)),
                          Row(
                            children: [
                              Icon(
                                Icons.location_on_outlined,
                                size: rSize(context, 12),
                                color: _subtext,
                              ),
                              SizedBox(width: rSize(context, 4)),
                              Expanded(
                                child: Text(
                                  widget.store.location!,
                                  style: TextStyle(
                                    fontSize: rFontSize(context, 12),
                                    color: _subtext,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ],
                    ),
                  ),
                  Icon(
                    FontAwesomeIcons.chevronRight.data,
                    size: rSize(context, 13),
                    color: _subtext,
                  ),
                ],
              ),
            ),
          ),

          // Stats row
          Container(
            decoration: BoxDecoration(
              color: _stripe,
              border: Border(top: BorderSide(color: _strongBorder)),
            ),
            child: Row(
              children: [
                Expanded(
                  child: _statCell(
                    icon: FontAwesomeIcons.boxesStacked.data,
                    label: 'Total Units',
                    value: totalStock.toString(),
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
                Container(width: 1, height: 36, color: _strongBorder),
                Expanded(
                  child: _statCell(
                    icon: FontAwesomeIcons.tag.data,
                    label: 'Products',
                    value: productCount.toString(),
                    color: AppColors.success,
                  ),
                ),
              ],
            ),
          ),

          // Actions row
          Container(
            decoration: BoxDecoration(
              color: _stripe,
              border: Border(top: BorderSide(color: _strongBorder)),
              borderRadius: const BorderRadius.vertical(
                bottom: Radius.circular(16),
              ),
            ),
            child: Row(
              children: [
                Expanded(
                  child: _actionButton(
                    icon: FontAwesomeIcons.penToSquare.data,
                    color: Theme.of(context).colorScheme.primary,
                    label: 'Edit',
                    onTap: widget.onEdit,
                  ),
                ),
                Container(width: 1, height: 36, color: _strongBorder),
                Expanded(
                  child: _actionButton(
                    icon: FontAwesomeIcons.trash.data,
                    color: Theme.of(context).colorScheme.error,
                    label: 'Delete',
                    onTap: widget.onDelete,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _statCell({
    required IconData icon,
    required String label,
    required String value,
    required Color color,
  }) {
    return Padding(
      padding: EdgeInsets.symmetric(
        vertical: rSize(context, 10),
        horizontal: rSize(context, 12),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: rSize(context, 12), color: color),
          SizedBox(width: rSize(context, 6)),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                value,
                style: TextStyle(
                  fontSize: rFontSize(context, 13),
                  fontWeight: FontWeight.bold,
                  color: _text,
                ),
              ),
              Text(
                label,
                style: TextStyle(
                  fontSize: rFontSize(context, 10),
                  color: _subtext,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _actionButton({
    required IconData icon,
    required Color color,
    required String label,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: const BorderRadius.vertical(bottom: Radius.circular(16)),
      child: Padding(
        padding: EdgeInsets.symmetric(vertical: rSize(context, 10)),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: rSize(context, 13), color: color),
            SizedBox(height: rSize(context, 3)),
            Text(
              label,
              style: TextStyle(
                fontSize: rFontSize(context, 10),
                color: color,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
