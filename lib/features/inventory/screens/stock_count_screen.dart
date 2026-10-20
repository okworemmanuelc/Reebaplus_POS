import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reebaplus_pos/core/theme/app_icons.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/permissions/permissions.dart';
import 'package:reebaplus_pos/core/theme/app_decorations.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/theme/design_tokens.dart';
import 'package:reebaplus_pos/core/theme/fixed_colors.dart';
import 'package:reebaplus_pos/features/inventory/widgets/inventory_parts.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/redesign.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';

import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/core/widgets/app_fab.dart';
import 'package:reebaplus_pos/shared/widgets/app_input.dart';
import 'package:reebaplus_pos/shared/widgets/app_dropdown.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/services/crash_reporter.dart';
import 'package:reebaplus_pos/core/utils/notifications.dart';

/// Damage reasons (§17.2). Key (stored on the stock_adjustment reason as
/// `damage:<key>`) → human label shown in the form + History.
const Map<String, String> _kDamageReasons = {
  'broken': 'Broken',
  'expired': 'Expired',
  'spilled': 'Spilled',
  'theft': 'Theft',
  'other': 'Other',
};

class StockCountScreen extends ConsumerStatefulWidget {
  /// The store to count. A daily stock count is always per store (§17). When
  /// provided (the Inventory store-lock case) the screen is locked to it; when
  /// null (entered unscoped, e.g. a CEO with no store lock) a store picker lets
  /// the user choose which store to count — never a combined all-stores count.
  final String? storeId;

  const StockCountScreen({super.key, this.storeId});

  @override
  ConsumerState<StockCountScreen> createState() => _StockCountScreenState();
}

class _StockCountScreenState extends ConsumerState<StockCountScreen> {
  List<ProductStockWithStore> _items = [];
  final List<TextEditingController> _controllers = [];
  // §17.2 Record Damages quantity field. Owned by the State (not the modal
  // sheet) so it is disposed exactly once, when the screen tears down — never
  // inline after the sheet closes, which raced the dismissing AppInput and
  // threw "TextEditingController used after being disposed".
  final TextEditingController _damageQtyCtrl = TextEditingController();
  bool _loading = true;
  bool _saving = false;

  // §17: a count is per store. [_selectedStoreId] is the store being counted
  // (widget.storeId when locked, else the user's pick). [_stores] backs the
  // picker AND the store-name map shown in the Count History sheet.
  List<StoreData> _stores = [];
  String? _selectedStoreId;
  // §17.1: the header subtitle is the store NAME (never the raw id).
  String? _storeName;

  /// The store label for the header + notifications. A scoped count whose name
  /// hasn't resolved yet (store not yet synced to this device) reads "This
  /// store" rather than a raw id.
  String get _storeLabel => _storeName ?? 'This store';
  Color get _subtext =>
      Theme.of(context).textTheme.bodySmall?.color ??
      Theme.of(context).iconTheme.color!;

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void dispose() {
    for (final c in _controllers) {
      c.dispose();
    }
    _damageQtyCtrl.dispose();
    super.dispose();
  }

  /// Loads the store list (for the picker + the History store-name map) and
  /// settles on the store to count: the locked store when provided, else the
  /// first active store. Then loads that store's products.
  Future<void> _init() async {
    final stores = await ref.read(databaseProvider).storesDao.getActiveStores();
    if (!mounted) return;
    setState(() {
      _stores = stores;
      _selectedStoreId =
          widget.storeId ?? (stores.isNotEmpty ? stores.first.id : null);
    });
    await _loadProducts();
  }

  Future<void> _loadProducts() async {
    final db = ref.read(databaseProvider);
    final storeId = _selectedStoreId;
    final items = await db.inventoryDao.getProductsStockPerStore(
      storeId: storeId,
    );
    // §17.1: resolve the store NAME for the subtitle (no raw-UUID leak).
    final storeName = storeId == null
        ? null
        : (_storeNameFor(storeId) ??
              (await db.storesDao.getStore(storeId))?.name);
    if (!mounted) return;
    setState(() {
      _items = items;
      _storeName = storeName;
      for (final c in _controllers) {
        c.dispose();
      }
      _controllers.clear();
      for (final item in items) {
        _controllers.add(
          TextEditingController(text: item.totalStock.toString()),
        );
      }
      _loading = false;
    });
  }

  /// Store name from the loaded [_stores] list, or null if not present (e.g. a
  /// historical count's store was since soft-deleted).
  String? _storeNameFor(String storeId) {
    for (final s in _stores) {
      if (s.id == storeId) return s.name;
    }
    return null;
  }

  int _diff(int index) {
    // A blank ACTUAL field means "not counted yet", NOT "counted zero" — don't
    // coerce it to 0, or saving would drive that product's stock to 0 and record
    // a false shortage. Blank → no change (skipped on save). A typed "0" is a
    // real count of zero and still produces a diff.
    final raw = _controllers[index].text.trim();
    if (raw.isEmpty) return 0;
    final actual = int.tryParse(raw) ?? 0;
    return actual - _items[index].totalStock;
  }

  /// Pre-save review sheet: shows every product with a diff (or "all matched")
  /// so the user can verify figures before committing. Save Count only proceeds
  /// on explicit confirmation.
  Future<void> _confirmAndSave() async {
    // Snapshot diffs now; the text-field controllers may change while the sheet
    // is open if the user scrolls, so we capture once before showing.
    final changedIndexes = <int>[];
    for (int i = 0; i < _items.length; i++) {
      if (_diff(i) != 0) changedIndexes.add(i);
    }
    final shortages = changedIndexes.where((i) => _diff(i) < 0).length;
    final surpluses = changedIndexes.where((i) => _diff(i) > 0).length;

    final confirmed = await _showReviewSheet(
      changedIndexes: changedIndexes,
      shortages: shortages,
      surpluses: surpluses,
    );

    if (confirmed == true && mounted) {
      await _saveCount();
    }
  }

  /// Bottom sheet listing every product that will change (or "all matched").
  /// Returns true on "Confirm & Save", null/false on dismiss or "Back".
  Future<bool?> _showReviewSheet({
    required List<int> changedIndexes,
    required int shortages,
    required int surpluses,
  }) {
    return showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetCtx) => DraggableScrollableSheet(
        initialChildSize: changedIndexes.isEmpty ? 0.45 : 0.75,
        maxChildSize: 0.95,
        minChildSize: 0.35,
        builder: (sheetCtx, scrollCtrl) {
          final t = Theme.of(sheetCtx);
          final f = t.extension<AppFixedColors>() ?? AppFixedColors.light;
          final gutter = sheetCtx.getRSize(20);
          return _sheetSurface(
            sheetCtx,
            child: Column(
              children: [
                // Header, chips and the changed lines scroll together; only
                // the buttons stay pinned, so a short sideways sheet never
                // overflows.
                Expanded(
                  child: ListView(
                    controller: scrollCtrl,
                    padding: EdgeInsets.fromLTRB(
                      gutter,
                      sheetCtx.getRSize(12),
                      gutter,
                      sheetCtx.getRSize(10),
                    ),
                    children: [
                      InventorySheetHeader(
                        title: 'Review Count',
                        subtitle: _storeLabel,
                      ),
                      SizedBox(height: sheetCtx.getRSize(12)),
                      Wrap(
                        spacing: sheetCtx.getRSize(8),
                        runSpacing: sheetCtx.getRSize(6),
                        children: [
                          TagPill(
                            label: '${_items.length} counted',
                            tone: TagPillTone.neutral,
                          ),
                          if (changedIndexes.isNotEmpty)
                            TagPill(
                              label: '${changedIndexes.length} adjusted',
                              tone: TagPillTone.info,
                            ),
                          if (shortages > 0)
                            TagPill(
                              label: '$shortages short',
                              tone: TagPillTone.danger,
                            ),
                          if (surpluses > 0)
                            TagPill(
                              label: '$surpluses over',
                              tone: TagPillTone.green,
                            ),
                        ],
                      ),
                      SizedBox(height: sheetCtx.getRSize(14)),
                      if (changedIndexes.isEmpty)
                        _reviewMatched(sheetCtx)
                      else
                        for (final i in changedIndexes) ...[
                          _reviewLine(sheetCtx, f, i),
                          SizedBox(height: sheetCtx.getRSize(8)),
                        ],
                    ],
                  ),
                ),
                // Action buttons
                Padding(
                  padding: EdgeInsets.fromLTRB(
                    sheetCtx.getRSize(16),
                    sheetCtx.getRSize(8),
                    sheetCtx.getRSize(16),
                    sheetCtx.deviceBottomPadding + sheetCtx.getRSize(16),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: AppButton(
                          text: 'Back',
                          variant: AppButtonVariant.outline,
                          onPressed: () => Navigator.pop(sheetCtx, false),
                        ),
                      ),
                      SizedBox(width: sheetCtx.getRSize(12)),
                      Expanded(
                        flex: 2,
                        child: AppButton(
                          text: 'Confirm & Save Count',
                          onPressed: () => Navigator.pop(sheetCtx, true),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  /// A sheet's own Surface with the theme's top corners (both stock-count
  /// sheets open on a transparent background so a draggable sheet can fill it).
  Widget _sheetSurface(BuildContext ctx, {required Widget child}) {
    final t = Theme.of(ctx);
    final shape =
        t.bottomSheetTheme.shape ??
        const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(AppSpacing.borderRadiusXL),
          ),
        );
    return DecoratedBox(
      decoration: ShapeDecoration(color: t.colorScheme.surface, shape: shape),
      child: child,
    );
  }

  Widget _reviewMatched(BuildContext ctx) {
    final t = Theme.of(ctx);
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    return Padding(
      padding: EdgeInsets.symmetric(vertical: ctx.getRSize(24)),
      child: Column(
        children: [
          const IconTile(
            icon: AppIcons.checkCircle,
            tone: IconTileTone.green,
            size: 48,
          ),
          SizedBox(height: ctx.getRSize(12)),
          Text(
            'All products matched',
            textAlign: TextAlign.center,
            style: ctx.boldStyle(15).copyWith(color: t.colorScheme.onSurface),
          ),
          SizedBox(height: ctx.getRSize(4)),
          Text(
            'The count will be recorded with no stock changes.',
            textAlign: TextAlign.center,
            style: ctx.regularStyle(13).copyWith(color: muted),
          ),
        ],
      ),
    );
  }

  Widget _reviewLine(BuildContext ctx, AppFixedColors f, int i) {
    final t = Theme.of(ctx);
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    final item = _items[i];
    final d = _diff(i);
    final actual = item.totalStock + d;
    final sign = d > 0 ? '+' : '';
    return Container(
      constraints: const BoxConstraints(minHeight: kMinInteractiveDimension),
      padding: EdgeInsets.symmetric(
        horizontal: ctx.getRSize(14),
        vertical: ctx.getRSize(10),
      ),
      decoration: AppDecorations.card(ctx),
      child: Row(
        children: [
          Expanded(
            child: Text(
              item.product.name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: ctx
                  .semiBoldStyle(13)
                  .copyWith(color: t.colorScheme.onSurface),
            ),
          ),
          SizedBox(width: ctx.getRSize(8)),
          Text(
            '${item.totalStock} → $actual',
            style: ctx.regularStyle(12).copyWith(color: muted),
          ),
          SizedBox(width: ctx.getRSize(10)),
          TagPill(
            label: '$sign$d',
            tone: d < 0 ? TagPillTone.danger : TagPillTone.green,
          ),
        ],
      ),
    );
  }

  Future<void> _saveCount() async {
    setState(() => _saving = true);

    final db = ref.read(databaseProvider);
    final logService = ref.read(activityLogProvider);
    final staffId = ref.read(authProvider).currentUser?.id;

    try {
      // §17.3: adjust stock to the actual count, log each change, and collect the
      // changed lines for the stock_counts session snapshot the Daily
      // Reconciliation Report (§25.9) reads. Matched/blank lines are omitted from
      // the payload but still counted in productsCounted.
      final changedLines = <Map<String, dynamic>>[];
      for (int i = 0; i < _items.length; i++) {
        final diff = _diff(i);
        if (diff == 0) continue;

        final item = _items[i];
        await db.inventoryDao.adjustStock(
          item.product.id,
          item.storeId,
          diff,
          'Daily stock count adjustment',
          staffId,
        );

        final sign = diff > 0 ? '+' : '';
        await logService.logAction(
          'stock_count',
          'Stock count: ${item.product.name} adjusted by $sign$diff '
              '(system: ${item.totalStock}, actual: ${item.totalStock + diff})',
          productId: item.product.id,
          storeId: item.storeId,
        );

        changedLines.add({
          'p': item.product.id,
          'n': item.product.name,
          's': item.totalStock,
          'a': item.totalStock + diff,
          'd': diff,
        });
      }

      // Persist one session snapshot per Save Count — even when nothing changed
      // (§17.3: multiple counts/day, each timestamped). This is the stock-audit
      // half the Daily Reconciliation Report consumes.
      final businessDate = await ref.read(todaysBusinessDateProvider.future);
      await db.stockCountsDao.recordCount(
        storeId: _selectedStoreId,
        businessDate: businessDate,
        productsCounted: _items.length,
        changedLines: changedLines,
        countedBy: staffId,
      );

      final shortages = changedLines.where((l) => (l['d'] as int) < 0).length;
      // §26.4: stock count saved → reconciliation report ready (Manager, CEO).
      await _notifyManagersAndCeo(
        db,
        type: 'stock_count_saved',
        message: shortages > 0
            ? 'Stock count saved for $_storeLabel — '
                  '$shortages shortage${shortages == 1 ? '' : 's'} flagged. '
                  'Reconciliation report ready.'
            : 'Stock count saved for $_storeLabel — '
                  'reconciliation report ready.',
        severity: shortages > 0 ? 'warning' : 'info',
      );

      if (!mounted) return;
      setState(() => _saving = false);

      final adjusted = changedLines.length;
      AppNotification.showSuccess(
        context,
        adjusted == 0
            ? 'Count saved — all matched.'
            : 'Count saved — $adjusted product${adjusted == 1 ? '' : 's'} adjusted.',
      );

      Navigator.pop(context);
    } catch (e, st) {
      CrashReporter.record(e, st, context: 'inventory.stock_count.submit');
      // A concurrent sale on another shared-till device can drive system stock
      // below a negative diff, so adjustStock throws InsufficientStockException
      // mid-loop. Earlier lines may already be committed; refresh the displayed
      // figures and let the user review + retry, rather than leaving _saving
      // stuck true (which would permanently hide the Save FAB).
      if (!mounted) return;
      setState(() => _saving = false);
      AppNotification.showError(
        context,
        'Stock changed during the count — figures refreshed. Review and save again.',
      );
      await _loadProducts();
    }
  }

  /// Fires a §26.4 stock notification to every CEO + Manager (the roles that
  /// see the reconciliation report). Falls back to the actor if no role
  /// resolves locally (offline), so the event is never silently dropped —
  /// mirrors the Close Day pattern (daos.dart).
  Future<void> _notifyManagersAndCeo(
    AppDatabase db, {
    required String type,
    required String message,
    required String severity,
  }) async {
    final actorId = ref.read(authProvider).currentUser?.id;
    final recipients = await db.userBusinessesDao.getUserIdsForRoleSlugs([
      'ceo',
      'manager',
    ]);
    final targets = recipients.isEmpty
        ? (actorId == null ? const <String>[] : [actorId])
        : recipients;
    for (final uid in targets) {
      await db.notificationsDao.fireNotification(
        type: type,
        message: message,
        severity: severity,
        recipientUserId: uid,
      );
    }
  }

  // ── Record Damages (§17.2) ───────────────────────────────────────────────

  Future<void> _recordDamages(BuildContext context) async {
    if (_items.isEmpty) return;
    ProductStockWithStore? product;
    String reasonKey = 'broken';
    final tracksCrates = businessTracksCrates(
      ref.read(currentBusinessProvider),
    );
    // Reuse the State-owned controller; clear any value left from a prior open.
    _damageQtyCtrl.clear();
    bool submitting = false;

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetCtx) {
        return StatefulBuilder(
          builder: (sheetCtx, setSheet) {
            Future<void> submit() async {
              final qty = int.tryParse(_damageQtyCtrl.text.trim()) ?? 0;
              if (product == null) {
                AppNotification.showError(
                  sheetCtx,
                  'Choose a ${ref.read(industryLexiconProvider).itemLower}.',
                );
                return;
              }
              if (qty <= 0) {
                AppNotification.showError(sheetCtx, 'Enter a quantity.');
                return;
              }

              final db = ref.read(databaseProvider);
              final logService = ref.read(activityLogProvider);
              final staffId = ref.read(authProvider).currentUser?.id;
              final reasonLabel = _kDamageReasons[reasonKey]!;
              final p = product!;

              // #299: damaging a full crate of drinks (a tracked-bottle product)
              // always damages its crate too, with the crate's loss counted once.
              final isTrackedBottle =
                  tracksCrates &&
                  p.product.unit?.toLowerCase() == 'bottle' &&
                  p.product.trackEmpties;

              if (qty > p.totalStock) {
                AppNotification.showError(
                  sheetCtx,
                  'Only ${p.totalStock} in stock.',
                );
                return;
              }
              setSheet(() => submitting = true);
              final reason = 'damage:$reasonKey';

              try {
                // §17.2/#299: drink stock and (when applicable) the crate shell
                // loss are committed or rolled back together — a partial write
                // would leave stock reduced without the matching crate leg.
                await db.transaction(() async {
                  // §17.2: reduces system stock. Routes through adjustStock so the
                  // stock_adjustments + stock_transactions ledger (and the cloud)
                  // record it; reason `damage:<key>` distinguishes it from a count
                  // adjustment for the Ring 3 report.
                  await db.inventoryDao.adjustStock(
                    p.product.id,
                    p.storeId,
                    -qty,
                    reason,
                    staffId,
                  );
                  // #299: damaging a full crate of drinks (tracked bottle) always
                  // damages its crate too, writing a full_crate_damage leg with
                  // snapshotted per-crate rate.
                  if (isTrackedBottle && p.product.manufacturerId != null) {
                    await db.cratePoolDao.recordFullCrateDamage(
                      manufacturerId: p.product.manufacturerId!,
                      storeId: p.storeId,
                      crates: qty,
                      performedBy: staffId,
                      reason: reasonKey,
                    );
                  }
                });
              } catch (_) {
                if (!sheetCtx.mounted) return;
                setSheet(() => submitting = false);
                AppNotification.showError(
                  sheetCtx,
                  'Could not record damage — stock changed. Try again.',
                );
                return;
              }

              try {
                // §17.2: logs to History.
                await logService.logAction(
                  'stock_damage',
                  'Damage recorded: $qty × ${p.product.name} ($reasonLabel)',
                  productId: p.product.id,
                  storeId: p.storeId,
                );
                // §26.4: damage recorded → Manager, CEO.
                await _notifyManagersAndCeo(
                  db,
                  type: 'stock_damage',
                  message:
                      'Damage recorded: $qty × ${p.product.name} ($reasonLabel).',
                  severity: 'warning',
                );

                if (!sheetCtx.mounted) return;
                Navigator.pop(sheetCtx);
                await _loadProducts(); // refresh system stock + diffs
                if (!context.mounted) return;
                AppNotification.showSuccess(
                  context,
                  'Damage recorded — stock reduced by $qty.',
                );
              } catch (_) {
                if (!sheetCtx.mounted) return;
                setSheet(() => submitting = false);
                Navigator.pop(sheetCtx);
                await _loadProducts();
                if (!context.mounted) return;
                AppNotification.showError(
                  context,
                  'Stock reduced by $qty, but logging the activity failed.',
                );
              }
            }

            final t = Theme.of(sheetCtx);
            // The sheet's own Surface; the form scrolls so it never overflows
            // over a keyboard or a short sideways screen (#392).
            return Container(
              constraints: BoxConstraints(
                maxHeight: sheetCtx.sheetMaxHeight(0.92),
              ),
              decoration: ShapeDecoration(
                color: t.colorScheme.surface,
                shape:
                    t.bottomSheetTheme.shape ??
                    const RoundedRectangleBorder(
                      borderRadius: BorderRadius.vertical(
                        top: Radius.circular(AppSpacing.borderRadiusXL),
                      ),
                    ),
              ),
              child: SingleChildScrollView(
                padding: EdgeInsets.fromLTRB(
                  sheetCtx.getRSize(20),
                  sheetCtx.getRSize(12),
                  sheetCtx.getRSize(20),
                  sheetCtx.deviceBottomPadding + sheetCtx.getRSize(20),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const InventorySheetHeader(title: 'Record Damages'),
                    SizedBox(height: sheetCtx.getRSize(16)),
                    AppDropdown<ProductStockWithStore>(
                      labelText: ref.read(industryLexiconProvider).item,
                      hintText:
                          'Choose a ${ref.read(industryLexiconProvider).itemLower}',
                      value: product,
                      items: _items.map((it) {
                        return DropdownMenuItem(
                          value: it,
                          child: Text(
                            '${it.product.name} (${it.totalStock})',
                            overflow: TextOverflow.ellipsis,
                          ),
                        );
                      }).toList(),
                      onChanged: (v) => setSheet(() {
                        product = v;
                      }),
                    ),
                    SizedBox(height: sheetCtx.getRSize(14)),
                    AppInput(
                      controller: _damageQtyCtrl,
                      labelText: 'Quantity',
                      hintText: 'How many were damaged',
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    ),
                    SizedBox(height: sheetCtx.getRSize(14)),
                    AppDropdown<String>(
                      labelText: 'Reason',
                      value: reasonKey,
                      items: _kDamageReasons.entries
                          .map(
                            (e) => DropdownMenuItem(
                              value: e.key,
                              child: Text(e.value),
                            ),
                          )
                          .toList(),
                      onChanged: (v) =>
                          setSheet(() => reasonKey = v ?? reasonKey),
                    ),
                    SizedBox(height: sheetCtx.getRSize(20)),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        onPressed: submitting ? null : submit,
                        style: FilledButton.styleFrom(
                          backgroundColor:
                              (t.extension<AppFixedColors>() ??
                                      AppFixedColors.light)
                                  .danger,
                          foregroundColor: Colors.white,
                          minimumSize: const Size.fromHeight(
                            kMinInteractiveDimension,
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(
                              AppSpacing.borderRadiusL,
                            ),
                          ),
                        ),
                        child: submitting
                            ? SizedBox(
                                width: sheetCtx.getRSize(18),
                                height: sheetCtx.getRSize(18),
                                child: const CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              )
                            : Text(
                                'Record Damage',
                                style: sheetCtx.boldStyle(15),
                              ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  // ── History ────────────────────────────────────────────────────────────────

  Future<void> _viewHistory(BuildContext context) async {
    // §17.3: read saved count sessions from the authoritative stock_counts
    // table — every Save Count writes one row (incl. a no-change count), so a
    // count always shows here. (The old activity-log source missed no-change
    // counts and only carried per-line adjustments.)
    final counts = await ref
        .read(databaseProvider)
        .stockCountsDao
        .watchAllForBusiness()
        .first;

    // Group by the count's business date (already stored as YYYY-MM-DD).
    final Map<String, List<StockCountData>> grouped = {};
    for (final c in counts) {
      grouped.putIfAbsent(c.businessDate, () => []).add(c);
    }
    final dates = grouped.keys.toList()..sort((a, b) => b.compareTo(a));

    if (!context.mounted) return;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => DraggableScrollableSheet(
        initialChildSize: 0.7,
        maxChildSize: 0.95,
        minChildSize: 0.4,
        builder: (ctx, scrollCtrl) {
          final gutter = ctx.getRSize(20);
          return _sheetSurface(
            ctx,
            child: ListView(
              controller: scrollCtrl,
              padding: EdgeInsets.fromLTRB(
                gutter,
                ctx.getRSize(12),
                gutter,
                ctx.getRSize(16) + ctx.deviceBottomPadding,
              ),
              children: [
                const InventorySheetHeader(title: 'Count History'),
                SizedBox(height: ctx.getRSize(14)),
                if (dates.isEmpty)
                  const InventoryEmptyCard(
                    icon: AppIcons.history,
                    title: 'No history yet',
                  )
                else
                  for (final dateKey in dates) ...[
                    _historyRow(ctx, dateKey, grouped[dateKey]!),
                    SizedBox(height: ctx.getRSize(8)),
                  ],
              ],
            ),
          );
        },
      ),
    );
  }

  /// One day in the Count History: a flat card (48dp+ tap target) that opens
  /// that day's saved counts.
  Widget _historyRow(
    BuildContext ctx,
    String dateKey,
    List<StockCountData> dayCounts,
  ) {
    final t = Theme.of(ctx);
    final f = t.extension<AppFixedColors>() ?? AppFixedColors.light;
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    final label = _formatDate(DateTime.parse(dateKey));
    final shortages = dayCounts.fold<int>(0, (n, c) => n + c.shortageCount);
    final radius = BorderRadius.circular(AppSpacing.borderRadiusXL);
    return DecoratedBox(
      decoration: AppDecorations.card(ctx),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: radius,
          onTap: () {
            Navigator.pop(ctx);
            _showDayDetail(context, label, dayCounts);
          },
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              minHeight: kMinInteractiveDimension,
            ),
            child: Padding(
              padding: EdgeInsets.all(ctx.getRSize(14)),
              child: Row(
                children: [
                  const IconTile(
                    icon: AppIcons.auditCheck,
                    tone: IconTileTone.info,
                    size: 44,
                  ),
                  SizedBox(width: ctx.getRSize(14)),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          label,
                          style: ctx
                              .boldStyle(14)
                              .copyWith(color: t.colorScheme.onSurface),
                        ),
                        Text(
                          '${dayCounts.length} count${dayCounts.length == 1 ? '' : 's'}'
                          '${shortages > 0 ? ' · $shortages short' : ''}',
                          style: ctx
                              .regularStyle(12)
                              .copyWith(
                                color: shortages > 0 ? f.danger : muted,
                              ),
                        ),
                      ],
                    ),
                  ),
                  AppIcon(
                    AppIcons.chevronRight,
                    size: ctx.getRSize(20),
                    color: muted,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _showDayDetail(
    BuildContext context,
    String dateLabel,
    List<StockCountData> counts,
  ) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => DraggableScrollableSheet(
        initialChildSize: 0.75,
        maxChildSize: 0.95,
        minChildSize: 0.4,
        builder: (ctx, scrollCtrl) {
          final gutter = ctx.getRSize(20);
          return _sheetSurface(
            ctx,
            child: ListView(
              controller: scrollCtrl,
              padding: EdgeInsets.fromLTRB(
                gutter,
                ctx.getRSize(12),
                gutter,
                ctx.getRSize(16) + ctx.deviceBottomPadding,
              ),
              children: [
                InventorySheetHeader(
                  title: dateLabel,
                  subtitle: 'Saved counts',
                ),
                SizedBox(height: ctx.getRSize(10)),
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: TagPill(
                    label:
                        '${counts.length} count${counts.length == 1 ? '' : 's'}',
                    tone: TagPillTone.info,
                  ),
                ),
                SizedBox(height: ctx.getRSize(14)),
                for (final c in counts) ...[
                  _buildCountSessionCard(ctx, c),
                  SizedBox(height: ctx.getRSize(10)),
                ],
              ],
            ),
          );
        },
      ),
    );
  }

  /// One saved count session: store + time, a counted/adjusted/short summary,
  /// and the itemised changed lines parsed from the session's lines_json.
  Widget _buildCountSessionCard(BuildContext context, StockCountData c) {
    final t = Theme.of(context);
    final f = t.extension<AppFixedColors>() ?? AppFixedColors.light;
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    final storeName = c.storeId == null
        ? 'All stores'
        : (_storeNameFor(c.storeId!) ?? 'Store');
    List<Map<String, dynamic>> lines;
    try {
      lines = (jsonDecode(c.linesJson) as List).cast<Map<String, dynamic>>();
    } catch (_) {
      lines = const [];
    }

    final summaryParts = <String>['${c.productsCounted} counted'];
    if (lines.isNotEmpty) summaryParts.add('${lines.length} adjusted');
    if (c.shortageCount > 0) summaryParts.add('${c.shortageCount} short');
    if (c.surplusCount > 0) summaryParts.add('${c.surplusCount} over');

    return Container(
      padding: EdgeInsets.all(context.getRSize(14)),
      decoration: AppDecorations.card(context).copyWith(
        border: Border.all(
          color: c.shortageCount > 0 ? f.dangerOutline : t.dividerColor,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              AppIcon(
                AppIcons.store,
                size: context.getRSize(14),
                color: t.colorScheme.primary,
              ),
              SizedBox(width: context.getRSize(6)),
              Expanded(
                child: Text(
                  storeName,
                  overflow: TextOverflow.ellipsis,
                  style: context
                      .boldStyle(13)
                      .copyWith(color: t.colorScheme.onSurface),
                ),
              ),
              Text(
                _formatTime(c.createdAt),
                style: context.regularStyle(11).copyWith(color: muted),
              ),
            ],
          ),
          SizedBox(height: context.getRSize(4)),
          Text(
            summaryParts.join(' · '),
            style: context.regularStyle(12).copyWith(color: muted),
          ),
          if (lines.isNotEmpty) ...[
            SizedBox(height: context.getRSize(8)),
            for (final l in lines) _buildCountLineRow(context, l),
          ],
        ],
      ),
    );
  }

  Widget _buildCountLineRow(BuildContext context, Map<String, dynamic> l) {
    final t = Theme.of(context);
    final f = t.extension<AppFixedColors>() ?? AppFixedColors.light;
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    final d = (l['d'] as num?)?.toInt() ?? 0;
    final color = d < 0 ? f.danger : (d > 0 ? f.green : muted);
    final name = l['n']?.toString() ?? 'Product';
    final sign = d > 0 ? '+' : '';
    return Padding(
      padding: EdgeInsets.symmetric(vertical: context.getRSize(3)),
      child: Row(
        children: [
          Expanded(
            child: Text(
              name,
              overflow: TextOverflow.ellipsis,
              style: context
                  .regularStyle(12)
                  .copyWith(color: t.colorScheme.onSurface),
            ),
          ),
          Text(
            '${l['s']} → ${l['a']}',
            style: context.regularStyle(11).copyWith(color: muted),
          ),
          SizedBox(width: context.getRSize(8)),
          SizedBox(
            width: context.getRSize(40),
            child: Text(
              '$sign$d',
              textAlign: TextAlign.right,
              style: context.boldStyle(12).copyWith(color: color),
            ),
          ),
        ],
      ),
    );
  }

  String _formatDate(DateTime date) {
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    return '${months[date.month - 1]} ${date.day}, ${date.year}';
  }

  String _formatTime(DateTime dt) {
    final h = dt.hour > 12 ? dt.hour - 12 : (dt.hour == 0 ? 12 : dt.hour);
    final m = dt.minute.toString().padLeft(2, '0');
    final ampm = dt.hour >= 12 ? 'PM' : 'AM';
    return '$h:$m $ampm';
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  /// The solid Inventory top bar (#392): back, the clipboard tile, "Daily Stock
  /// Count" with the store name, and the Record Damages / History actions.
  PreferredSizeWidget _topBar(BuildContext context, {bool withActions = true}) {
    final t = Theme.of(context);
    return InventoryTopBar(
      icon: AppIcons.clipboardList,
      title: 'Daily Stock Count',
      // §17.1: subtitle = store NAME (never the raw id).
      subtitle: withActions ? _storeLabel : null,
      height: inventoryTopBarHeight(context),
      leading: IconButton(
        tooltip: MaterialLocalizations.of(context).backButtonTooltip,
        constraints: const BoxConstraints(
          minWidth: kMinInteractiveDimension,
          minHeight: kMinInteractiveDimension,
        ),
        onPressed: () => Navigator.pop(context),
        icon: AppIcon(
          AppIcons.arrowBack,
          size: context.getRSize(24),
          color: t.colorScheme.onSurface,
        ),
      ),
      actions: [
        if (withActions && !_loading && _items.isNotEmpty)
          InventoryBarAction(
            key: const Key('stock_count_record_damages_button'),
            icon: AppIcons.warning,
            tooltip: 'Record Damages',
            onPressed: _saving ? null : () => _recordDamages(context),
          ),
        if (withActions)
          InventoryBarAction(
            icon: AppIcons.history,
            tooltip: 'View History',
            onPressed: () => _viewHistory(context),
          ),
        if (withActions && !_loading && _saving)
          Padding(
            padding: EdgeInsets.symmetric(horizontal: context.getRSize(14)),
            child: Center(
              child: SizedBox(
                width: context.getRSize(20),
                height: context.getRSize(20),
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: t.colorScheme.primary,
                ),
              ),
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    // §17.4 access: Stock keeper, Manager, CEO. Cashier blocked. The Stock Take
    // entry icon is already hidden for Cashier (Inventory header), but guard the
    // screen too (CLAUDE.md coding rule #1). Fail CLOSED: never render the full
    // mutating UI (Save / Record Damages / table) until an allowed role is
    // confirmed — show a spinner while the role is still resolving (null), and
    // the no-access state once it resolves to a disallowed role.
    // §17.4 access is gated on Gates.dailyStockCount (tier in CEO/Manager/Stock keeper AND stock.adjust).
    // Fail closed while grants load → spinner, not a flash of no-access.
    final canCount = Gates.dailyStockCount.allows(ref);
    final isReady = ref.watch(gateContextProvider).isReady;
    if (!canCount) {
      return Container(
        decoration: AppDecorations.pageBackground(context),
        child: Scaffold(
          backgroundColor: Colors.transparent,
          appBar: _topBar(context, withActions: false),
          body: Center(
            child: !isReady
                ? const CircularProgressIndicator()
                : Padding(
                    padding: EdgeInsets.all(context.getRSize(16)),
                    child: Text(
                      'You don’t have access to stock counts.',
                      textAlign: TextAlign.center,
                      style: context.regularStyle(14).copyWith(color: _subtext),
                    ),
                  ),
          ),
        ),
      );
    }
    return Container(
      decoration: AppDecorations.pageBackground(context),
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: _topBar(context),
        body: SafeArea(
          top: false,
          bottom: false,
          // A list/form screen: content caps at the fixed 720 and centres
          // (#392), measured.
          child: LayoutBuilder(
            builder: (context, constraints) {
              final gutter = inventoryGutter(context, constraints.maxWidth);
              return Column(
                children: [
                  // §17: the count is per store. When entered unscoped with
                  // more than one store, a picker chooses which store to count
                  // (kept above the list so it stays reachable even when a
                  // store has no products).
                  if (widget.storeId == null && _stores.length > 1)
                    _buildStorePicker(context, gutter),
                  Expanded(
                    child: _loading
                        ? const Center(child: CircularProgressIndicator())
                        : _items.isEmpty
                        ? Padding(
                            padding: EdgeInsets.symmetric(
                              horizontal: gutter,
                              vertical: context.getRSize(16),
                            ),
                            child: Align(
                              alignment: Alignment.topCenter,
                              child: InventoryEmptyCard(
                                icon: AppIcons.box,
                                title:
                                    'No ${ref.watch(industryLexiconProvider).itemPluralLower} found',
                              ),
                            ),
                          )
                        : _buildTable(context, gutter),
                  ),
                ],
              );
            },
          ),
        ),
        floatingActionButton: _loading || _saving || _items.isEmpty
            ? null
            : AppFAB(
                heroTag: 'save_count_fab',
                onPressed: _confirmAndSave,
                icon: AppIcons.save,
                label: 'Save Count',
              ),
      ),
    );
  }

  /// Store picker (§17) — shown only when the screen was entered unscoped and
  /// the business has more than one store. Switching reloads that store's count.
  Widget _buildStorePicker(BuildContext context, double gutter) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        gutter,
        context.getRSize(12),
        gutter,
        context.getRSize(4),
      ),
      child: AppDropdown<String>(
        labelText: 'Store',
        value: _selectedStoreId,
        items: _stores
            .map((s) => DropdownMenuItem(value: s.id, child: Text(s.name)))
            .toList(),
        onChanged: (v) {
          if (v == null || v == _selectedStoreId) return;
          setState(() {
            _selectedStoreId = v;
            _loading = true;
          });
          _loadProducts();
        },
      ),
    );
  }

  Widget _buildTable(BuildContext context, double gutter) {
    // Per store (§17): a flat product list — no store-section headers (the
    // header subtitle / picker already names the single store being counted).
    return Column(
      children: [
        _buildTableHeader(context, gutter),
        Expanded(
          child: ListView.builder(
            // Clears the Save Count button so the last row can scroll above it.
            padding: EdgeInsets.fromLTRB(
              gutter,
              0,
              gutter,
              context.getRSize(80) + context.deviceBottomPadding,
            ),
            itemCount: _items.length,
            itemBuilder: (_, i) => _buildRow(context, i),
          ),
        ),
      ],
    );
  }

  Widget _buildTableHeader(BuildContext context, double gutter) {
    final style = context
        .semiBoldStyle(11)
        .copyWith(color: _subtext, letterSpacing: 0.5);
    return Padding(
      padding: EdgeInsets.fromLTRB(
        // Lines the labels up with the row cards' content (card inset 14).
        gutter + context.getRSize(14),
        context.getRSize(14),
        gutter + context.getRSize(14),
        context.getRSize(6),
      ),
      child: Row(
        children: [
          Expanded(flex: 5, child: Text('PRODUCT', style: style)),
          SizedBox(
            width: context.getRSize(56),
            child: Text('SYSTEM', style: style, textAlign: TextAlign.center),
          ),
          SizedBox(
            width: context.getRSize(84),
            child: Text('ACTUAL', style: style, textAlign: TextAlign.center),
          ),
          SizedBox(
            width: context.getRSize(56),
            child: Text('DIFF', style: style, textAlign: TextAlign.center),
          ),
        ],
      ),
    );
  }

  Widget _buildRow(BuildContext context, int i) {
    final item = _items[i];
    final systemStock = item.totalStock;
    final t = Theme.of(context);
    final f = t.extension<AppFixedColors>() ?? AppFixedColors.light;

    return StatefulBuilder(
      builder: (context, setRowState) {
        final diff = _diff(i);
        final diffColor = diff > 0
            ? f.green
            : diff < 0
            ? f.danger
            : _subtext;
        final diffLabel = diff == 0 ? '—' : (diff > 0 ? '+$diff' : '$diff');

        return Container(
          margin: EdgeInsets.only(bottom: context.getRSize(8)),
          padding: EdgeInsets.symmetric(
            horizontal: context.getRSize(14),
            vertical: context.getRSize(10),
          ),
          decoration: AppDecorations.card(context).copyWith(
            border: Border.all(
              color: diff < 0
                  ? f.dangerOutline
                  : diff > 0
                  ? f.green.withValues(alpha: 0.5)
                  : t.dividerColor,
            ),
          ),
          child: Row(
            children: [
              Expanded(
                flex: 5,
                child: Text(
                  item.product.name,
                  style: context
                      .boldStyle(14)
                      .copyWith(color: t.colorScheme.onSurface),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              SizedBox(
                width: context.getRSize(56),
                child: Text(
                  '$systemStock',
                  textAlign: TextAlign.center,
                  style: context.semiBoldStyle(13).copyWith(color: _subtext),
                ),
              ),
              SizedBox(
                width: context.getRSize(84),
                child: AppInput(
                  controller: _controllers[i],
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  onChanged: (_) => setRowState(() {}),
                  textAlign: TextAlign.center,
                  // 48dp tall: the box is its text line plus this padding.
                  contentPadding: EdgeInsets.symmetric(
                    horizontal: context.getRSize(6),
                    vertical: math.max(context.getRSize(14), 16),
                  ),
                  fillColor: t.scaffoldBackgroundColor,
                ),
              ),
              SizedBox(
                width: context.getRSize(56),
                child: Text(
                  diffLabel,
                  textAlign: TextAlign.center,
                  style: context.boldStyle(13).copyWith(color: diffColor),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
