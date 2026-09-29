import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:reebaplus_pos/core/crates/crate_count_store.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/permissions/gate_registry.dart';
import 'package:reebaplus_pos/core/permissions/guarded.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/services/crash_reporter.dart';
import 'package:reebaplus_pos/core/utils/notifications.dart';
import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:reebaplus_pos/shared/widgets/app_dropdown.dart';
import 'package:reebaplus_pos/shared/widgets/app_input.dart';

/// Test keys for [RecordDamagedCratesSheet] (#297).
const String kRecordDamagedCratesSheetKey = 'record_damaged_crates_sheet';
const String kRecordDamagedStorePickerKey = 'record_damaged_store_picker';
const String kRecordDamagedQuantityFieldKey = 'record_damaged_quantity_field';
const String kRecordDamagedReasonDropdownKey = 'record_damaged_reason_dropdown';
const String kRecordDamagedLossPreviewKey = 'record_damaged_loss_preview';
const String kRecordDamagedSaveButtonKey = 'record_damaged_save_button';
const String kRecordDamagedCancelButtonKey = 'record_damaged_cancel_button';

/// Bottom sheet to record damaged empties per brand from the manufacturer screen (#297).
///
/// Features:
/// - Store picker: asked only in All Stores on a multi-store business.
/// - Quantity input (digits only).
/// - Reason dropdown: `broken`, `burnt`, `rotten_wood`, `other`.
/// - Live naira loss preview before saving.
/// - Validated against the store's warehouse count; damage above warehouse count is rejected.
/// - Saves via [CratePoolDao.recordDamage], logs activity, and notifies managers and CEO.
class RecordDamagedCratesSheet extends ConsumerStatefulWidget {
  const RecordDamagedCratesSheet({
    super.key,
    required this.manufacturer,
  });

  final ManufacturerData manufacturer;

  /// Shows the sheet modally over [context].
  static Future<void> show(
    BuildContext context, {
    required ManufacturerData manufacturer,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => RecordDamagedCratesSheet(manufacturer: manufacturer),
    );
  }

  @override
  ConsumerState<RecordDamagedCratesSheet> createState() =>
      _RecordDamagedCratesSheetState();
}

class _RecordDamagedCratesSheetState
    extends ConsumerState<RecordDamagedCratesSheet> {
  final _formKey = GlobalKey<FormState>();
  final _quantityCtrl = TextEditingController();
  late final List<StoreData> _stores;
  late final bool _mustPickStore;
  String? _storeId;
  int? _warehouseCount;
  bool _isLoadingWarehouse = false;
  String _reason = 'broken';
  bool _saving = false;

  static const _reasons = [
    (code: 'broken', label: 'Broken'),
    (code: 'burnt', label: 'Burnt'),
    (code: 'rotten_wood', label: 'Rotten wood'),
    (code: 'other', label: 'Other'),
  ];

  @override
  void initState() {
    super.initState();
    _stores = ref.read(selectableStoresProvider);
    _storeId = crateCountStoreWithoutAsking(
      lockedStoreId: ref.read(lockedStoreProvider).value,
      selectableStoreIds: [for (final s in _stores) s.id],
    );
    _mustPickStore = _storeId == null;
    if (_storeId != null) {
      _loadWarehouseCount(_storeId!);
    }
  }

  @override
  void dispose() {
    _quantityCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadWarehouseCount(String storeId) async {
    setState(() => _isLoadingWarehouse = true);
    try {
      final db = ref.read(databaseProvider);
      final count = await db.cratePoolDao.expectedEmptiesAt(
        manufacturerId: widget.manufacturer.id,
        storeId: storeId,
      );
      if (mounted && storeId == _storeId) {
        setState(() {
          _warehouseCount = count;
          _isLoadingWarehouse = false;
        });
      }
    } catch (_) {
      if (mounted && storeId == _storeId) {
        setState(() => _isLoadingWarehouse = false);
      }
    }
  }

  int? get _quantity {
    final n = int.tryParse(_quantityCtrl.text.trim());
    return n != null && n > 0 ? n : null;
  }

  String? get _storeName {
    if (_storeId == null) return null;
    for (final s in _stores) {
      if (s.id == _storeId) return s.name;
    }
    return 'Store';
  }

  String get _reasonLabel {
    for (final r in _reasons) {
      if (r.code == _reason) return r.label;
    }
    return 'Damaged';
  }

  String? _validateQuantity(String? value) {
    final raw = value?.trim() ?? '';
    if (raw.isEmpty) return 'Enter the number of damaged empties';
    final n = int.tryParse(raw);
    if (n == null || n <= 0) return 'Enter a number greater than 0';
    if (_warehouseCount != null && n > _warehouseCount!) {
      return 'Only $_warehouseCount empty crate${_warehouseCount == 1 ? '' : 's'} in warehouse';
    }
    return null;
  }

  String _lossPreviewLine() {
    final quantity = _quantity;
    final store = _storeName;
    if (store == null) return 'Choose the store holding the damaged empties.';
    if (quantity == null || quantity <= 0) {
      return 'Enter how many damaged empties to calculate loss.';
    }
    final rate = widget.manufacturer.depositAmountKobo;
    final total = formatCurrency(quantity * rate / 100);
    final each = formatCurrency(rate / 100);
    final reasonLabel = _reasonLabel;
    return '-$quantity crates from $store\'s warehouse. '
        'Loss: $total ($quantity × $each) • $reasonLabel.';
  }

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

  Future<void> _save() async {
    if (_saving) return;
    if (!_formKey.currentState!.validate()) return;
    if (_storeId == null) {
      AppNotification.showError(context, 'Please choose a store');
      return;
    }
    if (!Gates.countCrates.allowsNow(ref)) {
      showGateDenied(context, Gates.countCrates);
      return;
    }
    final performedBy = ref.read(authProvider).currentUser?.id;
    if (performedBy == null) {
      AppNotification.showError(
        context,
        'Could not tell who is recording damage. Sign in again.',
      );
      return;
    }
    final quantity = _quantity;
    if (quantity == null || quantity <= 0) return;

    final db = ref.read(databaseProvider);
    final currentWarehouse = await db.cratePoolDao.expectedEmptiesAt(
      manufacturerId: widget.manufacturer.id,
      storeId: _storeId!,
    );
    if (quantity > currentWarehouse) {
      if (mounted) {
        AppNotification.showError(
          context,
          'Only $currentWarehouse empty crate${currentWarehouse == 1 ? '' : 's'} in warehouse',
        );
      }
      return;
    }

    setState(() => _saving = true);
    try {
      await db.cratePoolDao.recordDamage(
        widget.manufacturer.id,
        quantity,
        storeId: _storeId,
        performedBy: performedBy,
        ratePerCrateKobo: widget.manufacturer.depositAmountKobo,
      );
    } catch (e, st) {
      CrashReporter.record(
        e,
        st,
        context: 'inventory.damage.empty_crate_record',
      );
      if (mounted) {
        setState(() => _saving = false);
        AppNotification.showError(
          context,
          'Could not record the damaged empties. Try again.',
        );
      }
      return;
    }

    try {
      final reasonLabel = _reasonLabel;
      await ref.read(activityLogProvider).logAction(
        'stock_damage',
        'Damaged empties recorded: $quantity × ${widget.manufacturer.name} ($reasonLabel)',
        storeId: _storeId,
      );
      await _notifyManagersAndCeo(
        db,
        type: 'stock_damage',
        message:
            'Damaged empties recorded: $quantity × ${widget.manufacturer.name} ($reasonLabel).',
        severity: 'warning',
      );
    } catch (_) {
      // Activity log or notification failure does not roll back the damage write.
    }

    if (!mounted) return;
    Navigator.pop(context);
    AppNotification.showSuccess(
      context,
      'Recorded $quantity damaged empt${quantity == 1 ? 'y' : 'ies'}.',
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      key: const ValueKey(kRecordDamagedCratesSheetKey),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
      ),
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
          context.getRSize(24),
          context.getRSize(24),
          context.getRSize(24),
          context.getRSize(24) + context.deviceBottomPadding,
        ),
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Record damaged empties',
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w900,
                ),
              ),
              SizedBox(height: context.getRSize(4)),
              Text(
                widget.manufacturer.name,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
                ),
              ),
              SizedBox(height: context.getRSize(20)),
              if (_mustPickStore) ...[
                AppDropdown<String>(
                  key: const ValueKey(kRecordDamagedStorePickerKey),
                  value: _storeId,
                  labelText: 'Store holding the empties',
                  hintText: 'Choose a store',
                  items: [
                    for (final store in _stores)
                      DropdownMenuItem(
                        value: store.id,
                        child: Text(store.name),
                      ),
                  ],
                  onChanged: (id) {
                    setState(() {
                      _storeId = id;
                      _warehouseCount = null;
                    });
                    if (id != null) {
                      _loadWarehouseCount(id);
                    }
                  },
                ),
                SizedBox(height: context.getRSize(12)),
              ],
              AppInput(
                key: const ValueKey(kRecordDamagedQuantityFieldKey),
                controller: _quantityCtrl,
                labelText: _warehouseCount != null
                    ? 'Number of damaged empties ($_warehouseCount in warehouse)'
                    : 'Number of damaged empties',
                hintText: 'e.g. 5',
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                textInputAction: TextInputAction.next,
                validator: _validateQuantity,
                onChanged: (_) => setState(() {}),
                fillColor: theme.cardColor,
              ),
              SizedBox(height: context.getRSize(12)),
              AppDropdown<String>(
                key: const ValueKey(kRecordDamagedReasonDropdownKey),
                value: _reason,
                labelText: 'Reason',
                items: [
                  for (final r in _reasons)
                    DropdownMenuItem(
                      value: r.code,
                      child: Text(r.label),
                    ),
                ],
                onChanged: (v) => setState(() => _reason = v ?? _reason),
              ),
              SizedBox(height: context.getRSize(16)),
              Container(
                width: double.infinity,
                padding: EdgeInsets.all(context.getRSize(12)),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary.withValues(alpha: 0.05),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: theme.colorScheme.primary.withValues(alpha: 0.15),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'This is what will be recorded',
                      style: theme.textTheme.labelMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: theme.colorScheme.primary,
                      ),
                    ),
                    SizedBox(height: context.getRSize(4)),
                    Text(
                      _lossPreviewLine(),
                      key: const ValueKey(kRecordDamagedLossPreviewKey),
                      style: theme.textTheme.bodyMedium,
                    ),
                  ],
                ),
              ),
              SizedBox(height: context.getRSize(24)),
              Row(
                children: [
                  Expanded(
                    child: AppButton(
                      key: const ValueKey(kRecordDamagedCancelButtonKey),
                      text: 'Cancel',
                      variant: AppButtonVariant.outline,
                      onPressed: _saving ? null : () => Navigator.pop(context),
                    ),
                  ),
                  SizedBox(width: context.getRSize(12)),
                  Expanded(
                    child: AppButton(
                      key: const ValueKey(kRecordDamagedSaveButtonKey),
                      text: 'Record damage',
                      variant: AppButtonVariant.primary,
                      isLoading: _saving,
                      onPressed: _isLoadingWarehouse ? null : _save,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
