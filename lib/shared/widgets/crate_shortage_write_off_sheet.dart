import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:reebaplus_pos/core/crates/crate_shortage.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/permissions/permissions.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/theme/design_tokens.dart';
import 'package:reebaplus_pos/core/utils/notifications.dart';
import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:reebaplus_pos/shared/widgets/app_dropdown.dart';
import 'package:reebaplus_pos/shared/widgets/app_input.dart';
import 'package:reebaplus_pos/shared/widgets/crate_sheet_recorded_line.dart';

/// Test keys for [CrateShortageWriteOffSheet] (#296).
const String kCrateWriteOffSheetKey = 'crate_write_off_sheet';
const String kCrateWriteOffBrandPickerKey = 'crate_write_off_brand_picker';
const String kCrateWriteOffStorePickerKey = 'crate_write_off_store_picker';
const String kCrateWriteOffQuantityFieldKey = 'crate_write_off_quantity_field';
const String kCrateWriteOffNoteFieldKey = 'crate_write_off_note_field';
const String kCrateWriteOffRecordedLineKey = 'crate_write_off_recorded_line';
const String kCrateWriteOffSaveButtonKey = 'crate_write_off_save_button';
const String kCrateWriteOffCancelButtonKey = 'crate_write_off_cancel_button';

/// **Write off** crates found missing at a count (#296, PRD #284 decision 7).
///
/// The ONE write-off sheet: the manufacturer screen opens it for its brand
/// ([manufacturerId] set), Daily Reconciliation's "Crates missing" opens it
/// with a brand picker. Both read the live per-brand Crate Shortage in the
/// active store scope and save through `CratePoolDao.writeOffCrateShortage`,
/// which re-checks the open shortage inside its transaction — so the same
/// crates can't be written off twice from two screens.
///
/// Callers gate the entry point on `Gates.confirmCrateDeposit`; the save
/// re-checks it at fire time. Cancel writes nothing.
class CrateShortageWriteOffSheet extends ConsumerStatefulWidget {
  const CrateShortageWriteOffSheet({super.key, this.manufacturerId});

  /// The brand to write off, or null to let the user pick one.
  final String? manufacturerId;

  static Future<void> show(BuildContext context, {String? manufacturerId}) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => CrateShortageWriteOffSheet(manufacturerId: manufacturerId),
    );
  }

  @override
  ConsumerState<CrateShortageWriteOffSheet> createState() =>
      _CrateShortageWriteOffSheetState();
}

class _CrateShortageWriteOffSheetState
    extends ConsumerState<CrateShortageWriteOffSheet> {
  final _formKey = GlobalKey<FormState>();
  final _quantityCtrl = TextEditingController();
  final _noteCtrl = TextEditingController();
  late String? _manufacturerId = widget.manufacturerId;
  String? _storeId;
  bool _saving = false;

  @override
  void dispose() {
    _quantityCtrl.dispose();
    _noteCtrl.dispose();
    super.dispose();
  }

  int? get _quantity {
    final n = int.tryParse(_quantityCtrl.text.trim());
    return n != null && n > 0 ? n : null;
  }

  /// The store to write off at: the one the user picked, or the only store
  /// with an open shortage for the brand.
  String? _effectiveStoreId(CrateShortageBrand? brand) {
    if (brand == null) return null;
    final stores = brand.storesWithOpenShortage;
    if (_storeId != null && stores.contains(_storeId)) return _storeId;
    return stores.length == 1 ? stores.single : null;
  }

  Future<void> _save(CrateShortageBrand? brand) async {
    if (_saving) return;
    final storeId = _effectiveStoreId(brand);
    if (brand == null || storeId == null) {
      AppNotification.showError(context, 'Choose the brand and the store');
      return;
    }
    if (!_formKey.currentState!.validate()) return;
    // Re-check at fire time: access may have been revoked while the sheet was
    // open, and the button that opened it only reflects the moment of the tap.
    if (!Gates.confirmCrateDeposit.allowsNow(ref)) {
      showGateDenied(context, Gates.confirmCrateDeposit);
      return;
    }
    final userId = ref.read(authProvider).currentUser?.id;
    if (userId == null) {
      AppNotification.showError(context, 'Sign in again to write off crates.');
      return;
    }
    final note = _noteCtrl.text.trim();
    final quantity = _quantity!;

    setState(() => _saving = true);
    final String? id;
    try {
      id = await ref.read(databaseProvider).cratePoolDao.writeOffCrateShortage(
            manufacturerId: brand.manufacturerId,
            storeId: storeId,
            crateCount: quantity,
            performedBy: userId,
            note: note.isEmpty ? null : note,
          );
    } catch (_) {
      if (mounted) {
        setState(() => _saving = false);
        AppNotification.showError(
          context,
          'Could not write off the crates. Please try again.',
        );
      }
      return;
    }
    if (!mounted) return;
    if (id == null) {
      // Someone else wrote some off, or a count found them, since the sheet
      // opened: the live figure below is already up to date.
      setState(() => _saving = false);
      AppNotification.showError(
        context,
        'Fewer crates are missing now. Check the number and try again.',
      );
      return;
    }
    AppNotification.showSuccess(
      context,
      '$quantity ${brand.manufacturerName} '
      'crate${quantity == 1 ? '' : 's'} written off',
    );
    Navigator.pop(context);
  }

  String _recordedLine(CrateShortageBrand? brand, String? storeName) {
    final storeId = _effectiveStoreId(brand);
    if (brand == null) return 'Choose the brand to write off.';
    if (storeId == null) return 'Choose the store the crates went missing from.';
    final quantity = _quantity;
    if (quantity == null) return 'Enter how many crates are gone.';
    final each = formatCurrency(brand.ratePerCrateKobo / 100);
    final total = formatCurrency(quantity * brand.ratePerCrateKobo / 100);
    return '$quantity ${brand.manufacturerName} '
        'crate${quantity == 1 ? '' : 's'} missing at ${storeName ?? 'this store'} '
        'written off as lost: $total off today\'s profit ($quantity × $each, '
        'today\'s crate value). No earlier day changes.';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final lockedStoreId = ref.watch(lockedStoreProvider).value;
    final rollup =
        ref.watch(crateShortageRollupProvider(lockedStoreId)).valueOrNull ??
        CrateShortageRollup.empty;
    final stores = ref.watch(allStoresProvider).valueOrNull ?? const <StoreData>[];
    final openBrands = rollup.openBrands;
    final brand = _manufacturerId == null ? null : rollup.brand(_manufacturerId!);
    final storeIds = brand?.storesWithOpenShortage ?? const <String>[];
    final storeId = _effectiveStoreId(brand);
    final storeOpen = storeId == null ? 0 : brand!.byStore[storeId]!.openCrates;
    String? storeName(String? id) {
      for (final s in stores) {
        if (s.id == id) return s.name;
      }
      return null;
    }

    return Container(
      key: const ValueKey(kCrateWriteOffSheetKey),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(context.radiusL),
        ),
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
              Text('Write off missing crates', style: theme.textTheme.titleLarge),
              SizedBox(height: context.getRSize(4)),
              Text(
                'Only do this once you are sure the crates are gone. It comes '
                'out of today\'s profit.',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
                ),
              ),
              SizedBox(height: context.getRSize(20)),
              if (widget.manufacturerId == null) ...[
                AppDropdown<String>(
                  key: const ValueKey(kCrateWriteOffBrandPickerKey),
                  value: brand == null ? null : _manufacturerId,
                  labelText: 'Brand',
                  hintText: 'Choose a brand',
                  items: [
                    for (final b in openBrands)
                      DropdownMenuItem(
                        value: b.manufacturerId,
                        child: Text('${b.manufacturerName} — ${b.openCrates} missing'),
                      ),
                  ],
                  onChanged: (id) => setState(() {
                    _manufacturerId = id;
                    _storeId = null;
                  }),
                ),
                SizedBox(height: context.getRSize(12)),
              ],
              if (storeIds.length > 1) ...[
                AppDropdown<String>(
                  key: const ValueKey(kCrateWriteOffStorePickerKey),
                  value: storeId,
                  labelText: 'Store the crates went missing from',
                  hintText: 'Choose a store',
                  items: [
                    for (final id in storeIds)
                      DropdownMenuItem(
                        value: id,
                        child: Text(
                          '${storeName(id) ?? 'Store'} — '
                          '${brand!.byStore[id]!.openCrates} missing',
                        ),
                      ),
                  ],
                  onChanged: (id) => setState(() => _storeId = id),
                ),
                SizedBox(height: context.getRSize(12)),
              ],
              AppInput(
                key: const ValueKey(kCrateWriteOffQuantityFieldKey),
                controller: _quantityCtrl,
                labelText: 'Crates to write off',
                hintText: storeOpen > 0 ? 'Up to $storeOpen' : 'e.g. 2',
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                textInputAction: TextInputAction.next,
                validator: (_) {
                  final n = _quantity;
                  if (n == null) return 'Enter how many crates are gone';
                  // Capped at what is actually missing: more would book a loss
                  // for crates standing in the warehouse.
                  if (n > storeOpen) return 'Only $storeOpen missing';
                  return null;
                },
                onChanged: (_) => setState(() {}),
                fillColor: theme.cardColor,
              ),
              SizedBox(height: context.getRSize(12)),
              AppInput(
                key: const ValueKey(kCrateWriteOffNoteFieldKey),
                controller: _noteCtrl,
                labelText: 'Note (optional)',
                fillColor: theme.cardColor,
              ),
              SizedBox(height: context.getRSize(16)),
              CrateSheetRecordedLine(
                text: _recordedLine(brand, storeName(storeId)),
                textKey: const ValueKey(kCrateWriteOffRecordedLineKey),
              ),
              SizedBox(height: context.getRSize(24)),
              Row(
                children: [
                  Expanded(
                    child: AppButton(
                      key: const ValueKey(kCrateWriteOffCancelButtonKey),
                      text: 'Cancel',
                      variant: AppButtonVariant.outline,
                      onPressed: _saving ? null : () => Navigator.pop(context),
                    ),
                  ),
                  SizedBox(width: context.getRSize(12)),
                  Expanded(
                    child: AppButton(
                      key: const ValueKey(kCrateWriteOffSaveButtonKey),
                      text: 'Write off',
                      variant: AppButtonVariant.danger,
                      isLoading: _saving,
                      onPressed: () => _save(brand),
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
