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

/// Test keys for [ReverseCrateWriteOffSheet] (#296).
const String kReverseWriteOffSheetKey = 'reverse_write_off_sheet';
const String kReverseWriteOffStorePickerKey = 'reverse_write_off_store_picker';
const String kReverseWriteOffQuantityFieldKey =
    'reverse_write_off_quantity_field';
const String kReverseWriteOffRecordedLineKey = 'reverse_write_off_recorded_line';
const String kReverseWriteOffSaveButtonKey = 'reverse_write_off_save_button';
const String kReverseWriteOffCancelButtonKey = 'reverse_write_off_cancel_button';

/// **Reverse write-off** — written-off crates of one brand turned up at a
/// later count (#296, PRD #284 decision 7).
///
/// Capped at the crates a count found after they were written off. Saves
/// through `CratePoolDao.reverseCrateWriteOff`, which books a gain on today,
/// at the value those crates were written off at, and changes no earlier day.
///
/// Callers gate the entry point on `Gates.confirmCrateDeposit`; the save
/// re-checks it at fire time. Cancel writes nothing.
class ReverseCrateWriteOffSheet extends ConsumerStatefulWidget {
  const ReverseCrateWriteOffSheet({super.key, required this.manufacturerId});

  final String manufacturerId;

  static Future<void> show(BuildContext context, {required String manufacturerId}) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => ReverseCrateWriteOffSheet(manufacturerId: manufacturerId),
    );
  }

  @override
  ConsumerState<ReverseCrateWriteOffSheet> createState() =>
      _ReverseCrateWriteOffSheetState();
}

class _ReverseCrateWriteOffSheetState
    extends ConsumerState<ReverseCrateWriteOffSheet> {
  final _formKey = GlobalKey<FormState>();
  final _quantityCtrl = TextEditingController();
  String? _storeId;
  bool _saving = false;

  @override
  void dispose() {
    _quantityCtrl.dispose();
    super.dispose();
  }

  int? get _quantity {
    final n = int.tryParse(_quantityCtrl.text.trim());
    return n != null && n > 0 ? n : null;
  }

  String? _effectiveStoreId(CrateShortageBrand? brand) {
    if (brand == null) return null;
    final stores = brand.storesWithReversible;
    if (_storeId != null && stores.contains(_storeId)) return _storeId;
    return stores.length == 1 ? stores.single : null;
  }

  Future<void> _save(CrateShortageBrand? brand) async {
    if (_saving) return;
    final storeId = _effectiveStoreId(brand);
    if (brand == null || storeId == null) {
      AppNotification.showError(context, 'Choose the store the crates turned up at');
      return;
    }
    if (!_formKey.currentState!.validate()) return;
    if (!Gates.confirmCrateDeposit.allowsNow(ref)) {
      showGateDenied(context, Gates.confirmCrateDeposit);
      return;
    }
    final userId = ref.read(authProvider).currentUser?.id;
    if (userId == null) {
      AppNotification.showError(context, 'Sign in again to reverse a write-off.');
      return;
    }
    final quantity = _quantity!;

    setState(() => _saving = true);
    final List<String> ids;
    try {
      ids = await ref.read(databaseProvider).cratePoolDao.reverseCrateWriteOff(
            manufacturerId: brand.manufacturerId,
            storeId: storeId,
            crateCount: quantity,
            performedBy: userId,
          );
    } catch (_) {
      if (mounted) {
        setState(() => _saving = false);
        AppNotification.showError(
          context,
          'Could not reverse the write-off. Please try again.',
        );
      }
      return;
    }
    if (!mounted) return;
    if (ids.isEmpty) {
      setState(() => _saving = false);
      AppNotification.showError(
        context,
        'Fewer crates can be reversed now. Check the number and try again.',
      );
      return;
    }
    AppNotification.showSuccess(
      context,
      'Write-off of $quantity ${brand.manufacturerName} '
      'crate${quantity == 1 ? '' : 's'} reversed',
    );
    Navigator.pop(context);
  }

  String _recordedLine(
    CrateShortageBrand? brand,
    CrateShortageState? state,
    String? storeName,
  ) {
    if (brand == null || state == null) {
      return 'Choose the store the crates turned up at.';
    }
    final quantity = _quantity;
    if (quantity == null) return 'Enter how many crates turned up.';
    final plan = planCrateWriteOffReversal(state, quantity);
    if (plan.isEmpty) return 'Only ${state.reversibleCrates} can be reversed.';
    final gain = plan.fold(0, (sum, l) => sum + l.crates * l.ratePerCrateKobo);
    return '$quantity written-off ${brand.manufacturerName} '
        'crate${quantity == 1 ? '' : 's'} found at ${storeName ?? 'this store'}: '
        '${formatCurrency(gain / 100)} back into today\'s profit, at the value '
        'they were written off at. No earlier day changes.';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final lockedStoreId = ref.watch(lockedStoreProvider).value;
    final rollup =
        ref.watch(crateShortageRollupProvider(lockedStoreId)).valueOrNull ??
        CrateShortageRollup.empty;
    final stores = ref.watch(allStoresProvider).valueOrNull ?? const <StoreData>[];
    final brand = rollup.brand(widget.manufacturerId);
    final storeIds = brand?.storesWithReversible ?? const <String>[];
    final storeId = _effectiveStoreId(brand);
    final state = storeId == null ? null : brand!.byStore[storeId];
    final reversible = state?.reversibleCrates ?? 0;
    String? storeName(String? id) {
      for (final s in stores) {
        if (s.id == id) return s.name;
      }
      return null;
    }

    return Container(
      key: const ValueKey(kReverseWriteOffSheetKey),
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
              Text('Reverse write-off', style: theme.textTheme.titleLarge),
              SizedBox(height: context.getRSize(4)),
              Text(
                'For crates you wrote off that a later count found.',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
                ),
              ),
              SizedBox(height: context.getRSize(20)),
              if (storeIds.length > 1) ...[
                AppDropdown<String>(
                  key: const ValueKey(kReverseWriteOffStorePickerKey),
                  value: storeId,
                  labelText: 'Store the crates turned up at',
                  hintText: 'Choose a store',
                  items: [
                    for (final id in storeIds)
                      DropdownMenuItem(
                        value: id,
                        child: Text(
                          '${storeName(id) ?? 'Store'} — '
                          '${brand!.byStore[id]!.reversibleCrates} found',
                        ),
                      ),
                  ],
                  onChanged: (id) => setState(() => _storeId = id),
                ),
                SizedBox(height: context.getRSize(12)),
              ],
              AppInput(
                key: const ValueKey(kReverseWriteOffQuantityFieldKey),
                controller: _quantityCtrl,
                labelText: 'Crates found',
                hintText: reversible > 0 ? 'Up to $reversible' : 'e.g. 2',
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                validator: (_) {
                  final n = _quantity;
                  if (n == null) return 'Enter how many crates turned up';
                  if (n > reversible) return 'Only $reversible can be reversed';
                  return null;
                },
                onChanged: (_) => setState(() {}),
                fillColor: theme.cardColor,
              ),
              SizedBox(height: context.getRSize(16)),
              CrateSheetRecordedLine(
                text: _recordedLine(brand, state, storeName(storeId)),
                textKey: const ValueKey(kReverseWriteOffRecordedLineKey),
              ),
              SizedBox(height: context.getRSize(24)),
              Row(
                children: [
                  Expanded(
                    child: AppButton(
                      key: const ValueKey(kReverseWriteOffCancelButtonKey),
                      text: 'Cancel',
                      variant: AppButtonVariant.outline,
                      onPressed: _saving ? null : () => Navigator.pop(context),
                    ),
                  ),
                  SizedBox(width: context.getRSize(12)),
                  Expanded(
                    child: AppButton(
                      key: const ValueKey(kReverseWriteOffSaveButtonKey),
                      text: 'Reverse',
                      variant: AppButtonVariant.primary,
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
