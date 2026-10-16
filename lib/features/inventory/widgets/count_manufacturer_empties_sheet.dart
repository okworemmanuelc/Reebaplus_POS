import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reebaplus_pos/core/theme/app_icons.dart';

import 'package:reebaplus_pos/core/crates/crate_count_store.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/permissions/gate_registry.dart';
import 'package:reebaplus_pos/core/permissions/guarded.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:reebaplus_pos/shared/widgets/app_dropdown.dart';
import 'package:reebaplus_pos/features/inventory/widgets/inventory_parts.dart';
import 'package:reebaplus_pos/features/inventory/widgets/supplier_parts.dart';
import 'package:reebaplus_pos/shared/widgets/app_input.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/redesign.dart';

/// Test keys for [CountManufacturerEmptiesSheet] (#293).
const String kCountManufacturerEmptiesSheetKey =
    'count_manufacturer_empties_sheet';
const String kCountEmptiesInputFieldKey = 'count_empties_input_field';
const String kCountEmptiesExpectedTextKey = 'count_empties_expected_text';
const String kCountEmptiesDifferenceTextKey = 'count_empties_difference_text';
const String kCountEmptiesStorePickerKey = 'count_empties_store_picker';
const String kCountEmptiesSaveButtonKey = 'count_empties_save_button';
const String kCountEmptiesCancelButtonKey = 'count_empties_cancel_button';

/// Bottom sheet for counting a manufacturer's empties (#293, PRD #284 §6).
///
/// Features:
/// - Shows expected empties for the store (`expectedEmptiesAt`).
/// - Takes what was counted (never the difference).
/// - Shows difference and its naira warning value in a "This is what will be recorded" line.
/// - Requires picking a store in All Stores on multi-store businesses; asks no store
///   on single-store or locked-store businesses.
/// - Rejects negative or non-numeric input before saving.
/// - Cancel writes nothing.
/// - Records through [CratePoolDao.recordManualCountCorrection].
class CountManufacturerEmptiesSheet extends ConsumerStatefulWidget {
  final ManufacturerData manufacturer;

  const CountManufacturerEmptiesSheet({super.key, required this.manufacturer});

  /// Displays the count sheet modally.
  static Future<void> show(
    BuildContext context, {
    required ManufacturerData manufacturer,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => CountManufacturerEmptiesSheet(manufacturer: manufacturer),
    );
  }

  @override
  ConsumerState<CountManufacturerEmptiesSheet> createState() =>
      _CountManufacturerEmptiesSheetState();
}

class _CountManufacturerEmptiesSheetState
    extends ConsumerState<CountManufacturerEmptiesSheet> {
  final TextEditingController _countCtrl = TextEditingController();
  String? _selectedStoreId;
  int? _expectedEmpties;
  bool _isLoadingExpected = false;
  String? _errorMessage;
  bool _mustPickStore = false;
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    _initStoreAndExpected();
  }

  @override
  void dispose() {
    _countCtrl.dispose();
    super.dispose();
  }

  void _initStoreAndExpected() {
    final selectableStores = ref.read(selectableStoresProvider);
    final lockedStoreId = ref.read(lockedStoreProvider).value;

    final autoStoreId = crateCountStoreWithoutAsking(
      lockedStoreId: lockedStoreId,
      selectableStoreIds: [for (final s in selectableStores) s.id],
    );

    if (autoStoreId != null) {
      _selectedStoreId = autoStoreId;
      _mustPickStore = false;
      _loadExpectedEmpties(autoStoreId);
    } else {
      _mustPickStore = true;
      _selectedStoreId = null;
    }
  }

  Future<void> _loadExpectedEmpties(String storeId) async {
    setState(() {
      _isLoadingExpected = true;
      _errorMessage = null;
    });

    try {
      final db = ref.read(databaseProvider);
      final expected = await db.cratePoolDao.expectedEmptiesAt(
        manufacturerId: widget.manufacturer.id,
        storeId: storeId,
      );
      // A slower lookup for a store the user has since switched away from
      // must not overwrite the current store's figure.
      if (mounted && storeId == _selectedStoreId) {
        setState(() {
          _expectedEmpties = expected;
          _isLoadingExpected = false;
        });
      }
    } catch (e) {
      if (mounted && storeId == _selectedStoreId) {
        setState(() {
          _isLoadingExpected = false;
          _errorMessage = 'Could not load expected empties: $e';
        });
      }
    }
  }

  Future<void> _handleSave() async {
    if (_isSaving) return;
    final storeId = _selectedStoreId;
    if (storeId == null) {
      setState(() => _errorMessage = 'Please select a store.');
      return;
    }

    final rawText = _countCtrl.text.trim();
    if (rawText.isEmpty) {
      setState(() => _errorMessage = 'Please enter counted empties.');
      return;
    }

    final counted = int.tryParse(rawText);
    if (counted == null || counted < 0) {
      setState(
        () => _errorMessage = 'Please enter a valid non-negative number.',
      );
      return;
    }

    if (!Gates.countCrates.allowsNow(ref)) {
      setState(() => _errorMessage = 'Permission denied to count crates.');
      return;
    }

    final performedBy = ref.read(authProvider).currentUser?.id;
    if (performedBy == null || performedBy.isEmpty) {
      setState(
        () => _errorMessage = 'Could not tell who is counting. Sign in again.',
      );
      return;
    }

    setState(() => _isSaving = true);
    try {
      final db = ref.read(databaseProvider);
      await db.cratePoolDao.recordManualCountCorrection(
        manufacturerId: widget.manufacturer.id,
        storeId: storeId,
        performedBy: performedBy,
        countedEmpties: counted,
      );

      if (mounted) {
        Navigator.of(context).pop();
      }
    } catch (e) {
      if (mounted) {
        setState(() => _errorMessage = 'Failed to record count: $e');
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final selectableStores = ref.watch(selectableStoresProvider);
    final rawText = _countCtrl.text.trim();
    final counted = int.tryParse(rawText);
    final isCountInvalid =
        rawText.isNotEmpty && (counted == null || counted < 0);

    final crateValueNaira = widget.manufacturer.depositAmountKobo / 100;

    String? differenceLine;
    if (_expectedEmpties != null && counted != null && counted >= 0) {
      final diff = counted - _expectedEmpties!;
      if (diff < 0) {
        final gap = -diff;
        final warningValueNaira = gap * crateValueNaira;
        differenceLine =
            'This is what will be recorded: $gap crates short (${formatCurrency(warningValueNaira)} warning value)';
      } else if (diff > 0) {
        differenceLine = 'This is what will be recorded: $diff crates surplus';
      } else {
        differenceLine = 'This is what will be recorded: No difference';
      }
    }

    final isShort =
        counted != null &&
        _expectedEmpties != null &&
        counted < _expectedEmpties!;
    return CrateSheetFrame(
      frameKey: const ValueKey(kCountManufacturerEmptiesSheetKey),
      title: 'Count ${widget.manufacturer.name} Empties',
      subtitle: 'Crate value: ${formatCurrency(crateValueNaira)}',
      children: [
        // Store picker (shown only in All Stores on multi-store business)
        if (_mustPickStore) ...[
          AppDropdown<String>(
            key: const ValueKey(kCountEmptiesStorePickerKey),
            labelText: 'Store counted',
            value: _selectedStoreId,
            items: [
              for (final store in selectableStores)
                DropdownMenuItem(value: store.id, child: Text(store.name)),
            ],
            onChanged: (storeId) {
              if (storeId != null) {
                setState(() => _selectedStoreId = storeId);
                _loadExpectedEmpties(storeId);
              }
            },
          ),
          SizedBox(height: context.getRSize(16)),
        ],

        // Expected Empties display
        CrateFactRow(
          label: 'Expected empties in warehouse',
          value: _isLoadingExpected
              ? '...'
              : (_expectedEmpties != null
                    ? '$_expectedEmpties crates'
                    : 'Select store'),
          valueKey: const ValueKey(kCountEmptiesExpectedTextKey),
        ),
        SizedBox(height: context.getRSize(16)),

        // Counted input field
        AppInput(
          key: const ValueKey(kCountEmptiesInputFieldKey),
          controller: _countCtrl,
          labelText: 'Counted empties',
          hintText: 'Enter physical count',
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          onChanged: (_) => setState(() => _errorMessage = null),
        ),

        if (isCountInvalid)
          InventoryFieldHelper(
            'Count cannot be negative or invalid',
            color: theme.colorScheme.error,
          ),

        SizedBox(height: context.getRSize(12)),

        // Difference and what will be recorded
        if (differenceLine != null)
          CrateRecordBox(
            key: const ValueKey(kCountEmptiesDifferenceTextKey),
            caption: null,
            message: differenceLine,
            tone: isShort ? IconTileTone.warning : null,
            icon: isShort ? AppIcons.warning : AppIcons.infoCircle,
          ),

        if (_errorMessage != null)
          Padding(
            padding: EdgeInsets.only(top: context.getRSize(10)),
            child: Text(
              _errorMessage!,
              style: context
                  .semiBoldStyle(12)
                  .copyWith(color: theme.colorScheme.error),
            ),
          ),

        SizedBox(height: context.getRSize(24)),

        // Actions row
        CrateSheetActions(
          cancelKey: const ValueKey(kCountEmptiesCancelButtonKey),
          confirmKey: const ValueKey(kCountEmptiesSaveButtonKey),
          confirmText: 'Save Count',
          cancelVariant: AppButtonVariant.ghost,
          confirming: _isSaving,
          onCancel: () => Navigator.of(context).pop(),
          onConfirm: _isSaving ? null : _handleSave,
        ),
      ],
    );
  }
}
