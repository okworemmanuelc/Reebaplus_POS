import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/theme/colors.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';

import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/core/widgets/app_fab.dart';
import 'package:reebaplus_pos/shared/widgets/app_input.dart';
import 'package:reebaplus_pos/shared/widgets/app_dropdown.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/services/crash_reporter.dart';
import 'package:reebaplus_pos/core/utils/notifications.dart';
import 'package:reebaplus_pos/features/dashboard/reconciliation/recon_data.dart'
    show kCrateLostSuffix;

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
  Color get _bg => Theme.of(context).scaffoldBackgroundColor;
  Color get _surface => Theme.of(context).colorScheme.surface;
  Color get _text => Theme.of(context).colorScheme.onSurface;
  Color get _subtext =>
      Theme.of(context).textTheme.bodySmall?.color ??
      Theme.of(context).iconTheme.color!;
  Color get _border => Theme.of(context).dividerColor;
  Color get _card => Theme.of(context).cardColor;

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
        builder: (sheetCtx, scrollCtrl) => Container(
          decoration: BoxDecoration(
            color: _surface,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          ),
          child: Column(
            children: [
              // Handle
              Padding(
                padding: EdgeInsets.symmetric(vertical: context.getRSize(12)),
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: _border,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              // Header
              Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: context.getRSize(20),
                ),
                child: Row(
                  children: [
                    Icon(
                      FontAwesomeIcons.clipboardList.data,
                      size: context.getRSize(16),
                      color: Theme.of(context).colorScheme.primary,
                    ),
                    SizedBox(width: context.getRSize(10)),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Review Count',
                            style: TextStyle(
                              color: _text,
                              fontSize: context.getRFontSize(18),
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          Text(
                            _storeLabel,
                            style: TextStyle(
                              color: _subtext,
                              fontSize: context.getRFontSize(12),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              SizedBox(height: context.getRSize(10)),
              // Summary chips
              Padding(
                padding: EdgeInsets.symmetric(horizontal: context.getRSize(20)),
                child: Wrap(
                  spacing: context.getRSize(8),
                  runSpacing: context.getRSize(6),
                  children: [
                    _reviewChip(
                      '${_items.length} counted',
                      _subtext,
                      _border.withValues(alpha: 0.5),
                    ),
                    if (changedIndexes.isNotEmpty)
                      _reviewChip(
                        '${changedIndexes.length} adjusted',
                        Theme.of(context).colorScheme.primary,
                        Theme.of(
                          context,
                        ).colorScheme.primary.withValues(alpha: 0.1),
                      ),
                    if (shortages > 0)
                      _reviewChip(
                        '$shortages short',
                        danger,
                        danger.withValues(alpha: 0.1),
                      ),
                    if (surpluses > 0)
                      _reviewChip(
                        '$surpluses over',
                        success,
                        success.withValues(alpha: 0.1),
                      ),
                  ],
                ),
              ),
              SizedBox(height: context.getRSize(10)),
              Divider(color: _border, height: 1),
              // Changed items list or "all matched" state
              Expanded(
                child: changedIndexes.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              FontAwesomeIcons.circleCheck.data,
                              size: context.getRSize(36),
                              color: success.withValues(alpha: 0.6),
                            ),
                            SizedBox(height: context.getRSize(12)),
                            Text(
                              'All products matched',
                              style: TextStyle(
                                color: _text,
                                fontSize: context.getRFontSize(15),
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            SizedBox(height: context.getRSize(4)),
                            Text(
                              'The count will be recorded with no stock changes.',
                              style: TextStyle(
                                color: _subtext,
                                fontSize: context.getRFontSize(13),
                              ),
                              textAlign: TextAlign.center,
                            ),
                          ],
                        ),
                      )
                    : ListView.separated(
                        controller: scrollCtrl,
                        padding: EdgeInsets.fromLTRB(
                          context.getRSize(16),
                          context.getRSize(10),
                          context.getRSize(16),
                          context.getRSize(10),
                        ),
                        itemCount: changedIndexes.length,
                        separatorBuilder: (_, __) =>
                            SizedBox(height: context.getRSize(6)),
                        itemBuilder: (_, idx) {
                          final i = changedIndexes[idx];
                          final item = _items[i];
                          final d = _diff(i);
                          final actual = item.totalStock + d;
                          final isShort = d < 0;
                          final diffColor = isShort ? danger : success;
                          final sign = d > 0 ? '+' : '';
                          return Container(
                            padding: EdgeInsets.symmetric(
                              horizontal: context.getRSize(12),
                              vertical: context.getRSize(10),
                            ),
                            decoration: BoxDecoration(
                              color: _card,
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(
                                color: diffColor.withValues(alpha: 0.3),
                              ),
                            ),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    item.product.name,
                                    style: TextStyle(
                                      color: _text,
                                      fontSize: context.getRFontSize(13),
                                      fontWeight: FontWeight.w600,
                                    ),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                SizedBox(width: context.getRSize(8)),
                                Text(
                                  '${item.totalStock} → $actual',
                                  style: TextStyle(
                                    color: _subtext,
                                    fontSize: context.getRFontSize(12),
                                  ),
                                ),
                                SizedBox(width: context.getRSize(10)),
                                Container(
                                  padding: EdgeInsets.symmetric(
                                    horizontal: context.getRSize(8),
                                    vertical: context.getRSize(3),
                                  ),
                                  decoration: BoxDecoration(
                                    color: diffColor.withValues(alpha: 0.12),
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: Text(
                                    '$sign$d',
                                    style: TextStyle(
                                      color: diffColor,
                                      fontSize: context.getRFontSize(12),
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
              ),
              // Action buttons
              Padding(
                padding: EdgeInsets.fromLTRB(
                  context.getRSize(16),
                  context.getRSize(8),
                  context.getRSize(16),
                  context.deviceBottomPadding + context.getRSize(16),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => Navigator.pop(sheetCtx, false),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: _text,
                          side: BorderSide(color: _border),
                          padding: EdgeInsets.symmetric(
                            vertical: context.getRSize(14),
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        child: Text(
                          'Back',
                          style: TextStyle(
                            fontSize: context.getRFontSize(14),
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                    SizedBox(width: context.getRSize(12)),
                    Expanded(
                      flex: 2,
                      child: FilledButton(
                        onPressed: () => Navigator.pop(sheetCtx, true),
                        style: FilledButton.styleFrom(
                          padding: EdgeInsets.symmetric(
                            vertical: context.getRSize(14),
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        child: Text(
                          'Confirm & Save Count',
                          style: TextStyle(
                            fontSize: context.getRFontSize(14),
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _reviewChip(String label, Color textColor, Color bgColor) {
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: context.getRSize(10),
        vertical: context.getRSize(4),
      ),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: textColor,
          fontSize: context.getRFontSize(12),
          fontWeight: FontWeight.w700,
        ),
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
    // §17.2 crate-aware damages. Only meaningful for a tracked bottle
    // (unit=='bottle' && trackEmpties): 'none' (crate intact), 'full' (the
    // full crate — item + its container — was lost) or 'empty' (a stored
    // returned empty was damaged).
    String crateFate = 'none';
    // Crate-fate surfaces are gated on the combined business opt-in, not just a
    // product's trackEmpties — when the business has crate tracking OFF, a
    // legacy product still flagged trackEmpties must never offer a crate fate
    // or write empty-crate ledger rows.
    final tracksCrates = businessTracksCrates(ref.read(currentBusinessProvider));
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
                AppNotification.showError(sheetCtx, 'Choose a product.');
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

              // §17.2 crate-aware: only a tracked bottle can carry a crate fate,
              // and only when the business opted into crate tracking.
              final isTrackedBottle =
                  tracksCrates &&
                  p.product.unit.toLowerCase() == 'bottle' &&
                  p.product.trackEmpties;
              final fate = isTrackedBottle ? crateFate : 'none';

              // §17.2 crate-aware — STORED empty damaged: a crate-only loss. No
              // drink is involved, so it touches NO bottle stock and books no
              // damage cost; it only debits the empty-crate pool (+ store balance
              // + a `damaged` crate_ledger row) and forfeits the deposit, which
              // the Statement reads from that ledger row. Quantity here means
              // empty crates, validated against the held-empties pool, not stock.
              if (fate == 'empty') {
                final mfrId = p.product.manufacturerId;
                if (mfrId == null) {
                  AppNotification.showError(
                    sheetCtx,
                    'This product has no manufacturer, so its empties '
                    'can\'t be tracked.',
                  );
                  return;
                }
                final pool =
                    ref.read(emptyCratesByManufacturerProvider).valueOrNull ??
                    const <String, int>{};
                final available = pool[mfrId] ?? 0;
                if (qty > available) {
                  AppNotification.showError(
                    sheetCtx,
                    'Only $available empty crate${available == 1 ? '' : 's'} '
                    'in stock.',
                  );
                  return;
                }
                setSheet(() => submitting = true);
                try {
                  await db.inventoryDao.recordEmptyCrateDamage(
                    mfrId,
                    qty,
                    storeId: p.storeId,
                  );
                } catch (e, st) {
                  CrashReporter.record(
                    e,
                    st,
                    context: 'inventory.damage.crate_empty_debit',
                  );
                  if (!sheetCtx.mounted) return;
                  setSheet(() => submitting = false);
                  AppNotification.showError(
                    sheetCtx,
                    'Could not record the damaged empties. Try again.',
                  );
                  return;
                }
                try {
                  await logService.logAction(
                    'stock_damage',
                    'Damaged empties recorded: $qty × ${p.product.name} '
                        '($reasonLabel)',
                    productId: p.product.id,
                    storeId: p.storeId,
                  );
                  await _notifyManagersAndCeo(
                    db,
                    type: 'stock_damage',
                    message:
                        'Damaged empties recorded: $qty × ${p.product.name} '
                        '($reasonLabel).',
                    severity: 'warning',
                  );
                  if (!sheetCtx.mounted) return;
                  Navigator.pop(sheetCtx);
                  await _loadProducts();
                  if (!context.mounted) return;
                  AppNotification.showSuccess(
                    context,
                    'Recorded $qty damaged empt${qty == 1 ? 'y' : 'ies'}.',
                  );
                } catch (_) {
                  if (!sheetCtx.mounted) return;
                  setSheet(() => submitting = false);
                  Navigator.pop(sheetCtx);
                  await _loadProducts();
                  if (!context.mounted) return;
                  AppNotification.showError(
                    context,
                    'Empties debited, but logging the activity failed.',
                  );
                }
                return;
              }

              // none / full: a damaged product (the drink is lost). 'full' also
              // forfeits the crate deposit — the held-empties pool is untouched
              // (that container was never a returned empty), so it rides purely
              // on the +cratelost reason suffix the Statement reads.
              if (qty > p.totalStock) {
                AppNotification.showError(
                  sheetCtx,
                  'Only ${p.totalStock} in stock.',
                );
                return;
              }
              setSheet(() => submitting = true);
              final reason =
                  'damage:$reasonKey${fate == 'full' ? kCrateLostSuffix : ''}';

              try {
                // §17.2: reduces system stock. Routes through adjustStock so the
                // stock_adjustments + stock_transactions ledger (and the cloud)
                // record it; reason `damage:<key>[+cratelost]` distinguishes it
                // from a count adjustment for the Ring 3 report and carries the
                // full-crate fate the Statement reads.
                await db.inventoryDao.adjustStock(
                  p.product.id,
                  p.storeId,
                  -qty,
                  reason,
                  staffId,
                );
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

            return Padding(
              padding: EdgeInsets.only(
                left: context.getRSize(20),
                right: context.getRSize(20),
                top: context.getRSize(20),
                bottom: context.deviceBottomPadding + context.getRSize(20),
              ),
              child: Container(
                padding: EdgeInsets.all(context.getRSize(20)),
                decoration: BoxDecoration(
                  color: _surface,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          FontAwesomeIcons.triangleExclamation.data,
                          size: context.getRSize(16),
                          color: danger,
                        ),
                        SizedBox(width: context.getRSize(10)),
                        Text(
                          'Record Damages',
                          style: TextStyle(
                            color: _text,
                            fontSize: context.getRFontSize(18),
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ],
                    ),
                    SizedBox(height: context.getRSize(16)),
                    AppDropdown<ProductStockWithStore>(
                      labelText: 'Product',
                      hintText: 'Choose a product',
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
                        // Crate fate only applies to a tracked bottle; reset it
                        // when switching to a product that can't carry one.
                        final tb =
                            tracksCrates &&
                            v != null &&
                            v.product.unit.toLowerCase() == 'bottle' &&
                            v.product.trackEmpties;
                        if (!tb) crateFate = 'none';
                      }),
                    ),
                    SizedBox(height: context.getRSize(14)),
                    AppInput(
                      controller: _damageQtyCtrl,
                      labelText: 'Quantity',
                      hintText: 'How many were damaged',
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    ),
                    SizedBox(height: context.getRSize(14)),
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
                    // §17.2 crate-aware: a tracked bottle can lose its crate
                    // deposit too. Ask whether the empty crate went with it.
                    if (tracksCrates &&
                        product != null &&
                        product!.product.unit.toLowerCase() == 'bottle' &&
                        product!.product.trackEmpties) ...[
                      SizedBox(height: context.getRSize(14)),
                      AppDropdown<String>(
                        labelText: 'Empty crate',
                        value: crateFate,
                        items: const [
                          DropdownMenuItem(
                            value: 'none',
                            child: Text('Crate intact — only the item lost'),
                          ),
                          DropdownMenuItem(
                            value: 'full',
                            child: Text('Crate lost with the item'),
                          ),
                          DropdownMenuItem(
                            value: 'empty',
                            child: Text('A stored empty crate was damaged'),
                          ),
                        ],
                        onChanged: (v) =>
                            setSheet(() => crateFate = v ?? crateFate),
                      ),
                    ],
                    SizedBox(height: context.getRSize(20)),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        onPressed: submitting ? null : submit,
                        style: FilledButton.styleFrom(
                          backgroundColor: danger,
                          padding: EdgeInsets.symmetric(
                            vertical: context.getRSize(14),
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                        ),
                        child: submitting
                            ? SizedBox(
                                width: context.getRSize(18),
                                height: context.getRSize(18),
                                child: const CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              )
                            : Text(
                                'Record Damage',
                                style: TextStyle(
                                  fontSize: context.getRFontSize(15),
                                  fontWeight: FontWeight.w700,
                                ),
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
        builder: (ctx, scrollCtrl) => Container(
          decoration: BoxDecoration(
            color: _surface,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          ),
          child: Column(
            children: [
              // Handle
              Padding(
                padding: EdgeInsets.symmetric(vertical: context.getRSize(12)),
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: _border,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              Padding(
                padding: EdgeInsets.symmetric(horizontal: context.getRSize(20)),
                child: Row(
                  children: [
                    Icon(
                      FontAwesomeIcons.clockRotateLeft.data,
                      size: context.getRSize(16),
                      color: Theme.of(context).colorScheme.primary,
                    ),
                    SizedBox(width: context.getRSize(10)),
                    Text(
                      'Count History',
                      style: TextStyle(
                        color: _text,
                        fontSize: context.getRFontSize(18),
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
              ),
              SizedBox(height: context.getRSize(8)),
              Divider(color: _border, height: 1),
              if (dates.isEmpty)
                Expanded(
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          FontAwesomeIcons.clockRotateLeft.data,
                          size: context.getRSize(36),
                          color: _border,
                        ),
                        SizedBox(height: context.getRSize(12)),
                        Text(
                          'No history yet',
                          style: TextStyle(
                            color: _subtext,
                            fontSize: context.getRFontSize(15),
                          ),
                        ),
                      ],
                    ),
                  ),
                )
              else
                Expanded(
                  child: ListView.separated(
                    controller: scrollCtrl,
                    padding: EdgeInsets.fromLTRB(
                      0,
                      context.getRSize(8),
                      0,
                      context.getRSize(8) + context.deviceBottomPadding,
                    ),
                    itemCount: dates.length,
                    separatorBuilder: (_, __) => Divider(
                      color: _border,
                      height: 1,
                      indent: context.getRSize(20),
                    ),
                    itemBuilder: (ctx, i) {
                      final dateKey = dates[i];
                      final dayCounts = grouped[dateKey]!;
                      final date = DateTime.parse(dateKey);
                      final label = _formatDate(date);
                      final shortages = dayCounts.fold<int>(
                        0,
                        (n, c) => n + c.shortageCount,
                      );

                      return ListTile(
                        contentPadding: EdgeInsets.symmetric(
                          horizontal: context.getRSize(20),
                          vertical: context.getRSize(4),
                        ),
                        leading: Container(
                          padding: EdgeInsets.all(context.getRSize(10)),
                          decoration: BoxDecoration(
                            color: Theme.of(
                              context,
                            ).colorScheme.primary.withValues(alpha: 0.08),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Icon(
                            FontAwesomeIcons.clipboardCheck.data,
                            size: context.getRSize(14),
                            color: Theme.of(context).colorScheme.primary,
                          ),
                        ),
                        title: Text(
                          label,
                          style: TextStyle(
                            color: _text,
                            fontWeight: FontWeight.w700,
                            fontSize: context.getRFontSize(14),
                          ),
                        ),
                        subtitle: Text(
                          '${dayCounts.length} count${dayCounts.length == 1 ? '' : 's'}'
                          '${shortages > 0 ? ' · $shortages short' : ''}',
                          style: TextStyle(
                            color: shortages > 0 ? danger : _subtext,
                            fontSize: context.getRFontSize(12),
                          ),
                        ),
                        trailing: Icon(
                          Icons.chevron_right,
                          color: _subtext,
                          size: context.getRSize(20),
                        ),
                        onTap: () {
                          Navigator.pop(ctx);
                          _showDayDetail(context, label, dayCounts);
                        },
                      );
                    },
                  ),
                ),
            ],
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
        builder: (ctx, scrollCtrl) => Container(
          decoration: BoxDecoration(
            color: _surface,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          ),
          child: Column(
            children: [
              // Handle
              Padding(
                padding: EdgeInsets.symmetric(vertical: context.getRSize(12)),
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: _border,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              Padding(
                padding: EdgeInsets.symmetric(horizontal: context.getRSize(20)),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            dateLabel,
                            style: TextStyle(
                              color: _text,
                              fontSize: context.getRFontSize(18),
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          Text(
                            'Saved counts',
                            style: TextStyle(
                              color: _subtext,
                              fontSize: context.getRFontSize(12),
                            ),
                          ),
                        ],
                      ),
                    ),
                    Container(
                      padding: EdgeInsets.symmetric(
                        horizontal: context.getRSize(10),
                        vertical: context.getRSize(4),
                      ),
                      decoration: BoxDecoration(
                        color: Theme.of(
                          context,
                        ).colorScheme.primary.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        '${counts.length} count${counts.length == 1 ? '' : 's'}',
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.primary,
                          fontSize: context.getRFontSize(12),
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              SizedBox(height: context.getRSize(8)),
              Divider(color: _border, height: 1),
              Expanded(
                child: ListView.separated(
                  controller: scrollCtrl,
                  padding: EdgeInsets.fromLTRB(
                    context.getRSize(16),
                    context.getRSize(12),
                    context.getRSize(16),
                    context.getRSize(12) + context.deviceBottomPadding,
                  ),
                  itemCount: counts.length,
                  separatorBuilder: (_, __) =>
                      SizedBox(height: context.getRSize(10)),
                  itemBuilder: (ctx, i) =>
                      _buildCountSessionCard(context, counts[i]),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// One saved count session: store + time, a counted/adjusted/short summary,
  /// and the itemised changed lines parsed from the session's lines_json.
  Widget _buildCountSessionCard(BuildContext context, StockCountData c) {
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
      padding: EdgeInsets.all(context.getRSize(12)),
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: (c.shortageCount > 0 ? danger : _border).withValues(
            alpha: c.shortageCount > 0 ? 0.3 : 1,
          ),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                FontAwesomeIcons.store.data,
                size: context.getRSize(11),
                color: Theme.of(context).colorScheme.primary,
              ),
              SizedBox(width: context.getRSize(6)),
              Expanded(
                child: Text(
                  storeName,
                  style: TextStyle(
                    color: _text,
                    fontSize: context.getRFontSize(13),
                    fontWeight: FontWeight.w700,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Text(
                _formatTime(c.createdAt),
                style: TextStyle(
                  color: _subtext,
                  fontSize: context.getRFontSize(11),
                ),
              ),
            ],
          ),
          SizedBox(height: context.getRSize(4)),
          Text(
            summaryParts.join(' · '),
            style: TextStyle(
              color: _subtext,
              fontSize: context.getRFontSize(12),
            ),
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
    final d = (l['d'] as num?)?.toInt() ?? 0;
    final color = d < 0 ? danger : (d > 0 ? success : _subtext);
    final name = l['n']?.toString() ?? 'Product';
    final sign = d > 0 ? '+' : '';
    return Padding(
      padding: EdgeInsets.symmetric(vertical: context.getRSize(3)),
      child: Row(
        children: [
          Expanded(
            child: Text(
              name,
              style: TextStyle(
                color: _text,
                fontSize: context.getRFontSize(12),
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Text(
            '${l['s']} → ${l['a']}',
            style: TextStyle(
              color: _subtext,
              fontSize: context.getRFontSize(11),
            ),
          ),
          SizedBox(width: context.getRSize(8)),
          SizedBox(
            width: context.getRSize(40),
            child: Text(
              '$sign$d',
              textAlign: TextAlign.right,
              style: TextStyle(
                color: color,
                fontSize: context.getRFontSize(12),
                fontWeight: FontWeight.w700,
              ),
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

  @override
  Widget build(BuildContext context) {
    // §17.4 access: Stock keeper, Manager, CEO. Cashier blocked. The Stock Take
    // entry icon is already hidden for Cashier (Inventory header), but guard the
    // screen too (CLAUDE.md coding rule #1). Fail CLOSED: never render the full
    // mutating UI (Save / Record Damages / table) until an allowed role is
    // confirmed — show a spinner while the role is still resolving (null), and
    // the no-access state once it resolves to a disallowed role.
    // §17.4 access is by role, but the count/damage actions decrement stock, so
    // gate on the `stock.adjust` permission too (hard rule #6) — it is
    // independently revocable from a Manager/Stock keeper. `perms` is empty
    // while the role's grants are still loading; treat that as "resolving" so we
    // show a spinner rather than flashing the no-access state for a legit role.
    final role = ref.watch(currentUserRoleProvider);
    final perms = ref.watch(currentUserPermissionsProvider);
    const allowed = {'ceo', 'manager', 'stock_keeper'};
    final blocked =
        role == null ||
        perms.isEmpty ||
        !allowed.contains(role.slug) ||
        !perms.contains('stock.adjust');
    if (blocked) {
      return Scaffold(
        backgroundColor: _bg,
        appBar: AppBar(
          backgroundColor: _surface,
          elevation: 0,
          leading: IconButton(
            icon: Icon(Icons.arrow_back_ios_new, color: _text, size: 20),
            onPressed: () => Navigator.pop(context),
          ),
          title: Text(
            'Daily Stock Count',
            style: TextStyle(
              color: _text,
              fontSize: context.getRFontSize(16),
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
        body: Center(
          child: (role == null || perms.isEmpty)
              ? const CircularProgressIndicator()
              : Text(
                  'You don’t have access to stock counts.',
                  style: TextStyle(
                    color: _subtext,
                    fontSize: context.getRFontSize(14),
                  ),
                ),
        ),
      );
    }
    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: _surface,
        elevation: 0,
        leading: IconButton(
          icon: Icon(Icons.arrow_back_ios_new, color: _text, size: 20),
          onPressed: () => Navigator.pop(context),
        ),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Daily Stock Count',
              style: TextStyle(
                color: _text,
                fontSize: context.getRFontSize(16),
                fontWeight: FontWeight.w800,
              ),
            ),
            // §17.1: subtitle = store NAME (store icon, never the raw id).
            Row(
              children: [
                Icon(
                  FontAwesomeIcons.store.data,
                  size: context.getRSize(10),
                  color: _subtext,
                ),
                SizedBox(width: context.getRSize(5)),
                Text(
                  _storeLabel,
                  style: TextStyle(
                    color: _subtext,
                    fontSize: context.getRFontSize(11),
                  ),
                ),
              ],
            ),
          ],
        ),
        actions: [
          if (!_loading && _items.isNotEmpty)
            IconButton(
              icon: Icon(
                FontAwesomeIcons.triangleExclamation.data,
                color: _text,
                size: context.getRSize(16),
              ),
              tooltip: 'Record Damages',
              onPressed: _saving ? null : () => _recordDamages(context),
            ),
          IconButton(
            icon: Icon(
              FontAwesomeIcons.clockRotateLeft.data,
              color: _text,
              size: context.getRSize(16),
            ),
            tooltip: 'View History',
            onPressed: () => _viewHistory(context),
          ),
          if (!_loading && _saving)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Center(
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
              ),
            ),
        ],
      ),
      body: Column(
        children: [
          // §17: the count is per store. When entered unscoped with more than
          // one store, a picker chooses which store to count (kept above the
          // list so it stays reachable even when a store has no products).
          if (widget.storeId == null && _stores.length > 1)
            _buildStorePicker(context),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _items.isEmpty
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          FontAwesomeIcons.boxOpen.data,
                          size: context.getRSize(48),
                          color: _subtext.withValues(alpha: 0.4),
                        ),
                        SizedBox(height: context.getRSize(16)),
                        Text(
                          'No products found',
                          style: TextStyle(
                            color: _subtext,
                            fontSize: context.getRFontSize(16),
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  )
                : _buildTable(context),
          ),
        ],
      ),
      floatingActionButton: _loading || _saving || _items.isEmpty
          ? null
          : AppFAB(
              heroTag: 'save_count_fab',
              onPressed: _confirmAndSave,
              icon: FontAwesomeIcons.floppyDisk.data,
              label: 'Save Count',
            ),
    );
  }

  /// Store picker (§17) — shown only when the screen was entered unscoped and
  /// the business has more than one store. Switching reloads that store's count.
  Widget _buildStorePicker(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        context.getRSize(16),
        context.getRSize(12),
        context.getRSize(16),
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

  Widget _buildTable(BuildContext context) {
    // Per store (§17): a flat product list — no store-section headers (the
    // header subtitle / picker already names the single store being counted).
    return Column(
      children: [
        _buildTableHeader(context),
        Expanded(
          child: ListView.builder(
            padding: EdgeInsets.only(
              bottom: context.getRSize(24) + context.deviceBottomPadding,
            ),
            itemCount: _items.length,
            itemBuilder: (_, i) => _buildRow(context, i),
          ),
        ),
      ],
    );
  }

  Widget _buildTableHeader(BuildContext context) {
    final style = TextStyle(
      color: _subtext,
      fontSize: context.getRFontSize(11),
      fontWeight: FontWeight.w700,
      letterSpacing: 0.5,
    );
    return Container(
      color: _surface,
      padding: EdgeInsets.symmetric(
        horizontal: context.getRSize(16),
        vertical: context.getRSize(10),
      ),
      child: Row(
        children: [
          Expanded(flex: 5, child: Text('PRODUCT', style: style)),
          SizedBox(
            width: context.getRSize(56),
            child: Text('SYSTEM', style: style, textAlign: TextAlign.center),
          ),
          SizedBox(
            width: context.getRSize(72),
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

    return StatefulBuilder(
      builder: (context, setRowState) {
        final diff = _diff(i);
        final diffColor = diff > 0
            ? success
            : diff < 0
            ? danger
            : _subtext;
        final diffLabel = diff == 0 ? '—' : (diff > 0 ? '+$diff' : '$diff');

        return Container(
          margin: EdgeInsets.symmetric(
            horizontal: context.getRSize(16),
            vertical: context.getRSize(4),
          ),
          padding: EdgeInsets.symmetric(
            horizontal: context.getRSize(12),
            vertical: context.getRSize(10),
          ),
          decoration: BoxDecoration(
            color: _card,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: diff != 0 ? diffColor.withValues(alpha: 0.4) : _border,
            ),
          ),
          child: Row(
            children: [
              Expanded(
                flex: 5,
                child: Text(
                  item.product.name,
                  style: TextStyle(
                    color: _text,
                    fontSize: context.getRFontSize(13),
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              SizedBox(
                width: context.getRSize(56),
                child: Text(
                  '$systemStock',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: _subtext,
                    fontSize: context.getRFontSize(13),
                  ),
                ),
              ),
              SizedBox(
                width: context.getRSize(72),
                child: AppInput(
                  controller: _controllers[i],
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  onChanged: (_) => setRowState(() {}),
                  textAlign: TextAlign.center,
                  contentPadding: EdgeInsets.symmetric(
                    horizontal: context.getRSize(6),
                    vertical: context.getRSize(8),
                  ),
                  fillColor: _surface,
                ),
              ),
              SizedBox(
                width: context.getRSize(56),
                child: Text(
                  diffLabel,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: diffColor,
                    fontSize: context.getRFontSize(13),
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
