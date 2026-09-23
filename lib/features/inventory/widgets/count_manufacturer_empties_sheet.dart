import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import 'package:reebaplus_pos/core/crates/crate_count_store.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/permissions/gate_registry.dart';
import 'package:reebaplus_pos/core/permissions/guarded.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/theme/design_tokens.dart';
import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:reebaplus_pos/shared/widgets/app_dropdown.dart';
import 'package:reebaplus_pos/shared/widgets/app_input.dart';

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

  const CountManufacturerEmptiesSheet({
    super.key,
    required this.manufacturer,
  });

  /// Displays the count sheet modally.
  static Future<void> show(
    BuildContext context, {
    required ManufacturerData manufacturer,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => CountManufacturerEmptiesSheet(
        manufacturer: manufacturer,
      ),
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
      if (mounted) {
        setState(() {
          _expectedEmpties = expected;
          _isLoadingExpected = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoadingExpected = false;
          _errorMessage = 'Could not load expected empties: $e';
        });
      }
    }
  }

  Future<void> _handleSave() async {
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
      setState(() => _errorMessage = 'Please enter a valid non-negative number.');
      return;
    }

    if (!Gates.countCrates.allowsNow(ref)) {
      setState(() => _errorMessage = 'Permission denied to count crates.');
      return;
    }

    final user = ref.read(authProvider).currentUser;
    final performedBy = user?.id ?? '';

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
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final selectableStores = ref.watch(selectableStoresProvider);
    final rawText = _countCtrl.text.trim();
    final counted = int.tryParse(rawText);
    final isCountInvalid = rawText.isNotEmpty && (counted == null || counted < 0);

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

    return Container(
      key: const ValueKey(kCountManufacturerEmptiesSheetKey),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(AppSpacing.borderRadiusL)),
      ),
      padding: EdgeInsets.fromLTRB(
        context.getRSize(20),
        context.getRSize(16),
        context.getRSize(20),
        context.getRSize(20) + context.deviceBottomPadding,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Handle bar
            Center(
              child: Container(
                width: context.getRSize(40),
                height: context.getRSize(4),
                decoration: BoxDecoration(
                  color: theme.dividerColor.withValues(alpha: 0.3),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            SizedBox(height: context.getRSize(16)),

            // Title
            Row(
              children: [
                Container(
                  width: context.getRSize(36),
                  height: context.getRSize(36),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primary.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(AppSpacing.borderRadiusM),
                  ),
                  child: Icon(
                    FontAwesomeIcons.clipboardCheck.data,
                    size: context.getRSize(16),
                    color: theme.colorScheme.primary,
                  ),
                ),
                SizedBox(width: context.getRSize(12)),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Count ${widget.manufacturer.name} Empties',
                        style: TextStyle(
                          fontSize: context.getRFontSize(17),
                          fontWeight: FontWeight.w800,
                          letterSpacing: -0.4,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        'Crate value: ${formatCurrency(crateValueNaira)}',
                        style: TextStyle(
                          fontSize: context.getRFontSize(12),
                          color: theme.colorScheme.onSurfaceVariant,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            SizedBox(height: context.getRSize(20)),

            // Store picker (shown only in All Stores on multi-store business)
            if (_mustPickStore) ...[
              AppDropdown<String>(
                key: const ValueKey(kCountEmptiesStorePickerKey),
                labelText: 'Store counted',
                value: _selectedStoreId,
                items: [
                  for (final store in selectableStores)
                    DropdownMenuItem(
                      value: store.id,
                      child: Text(store.name),
                    ),
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
            Container(
              padding: EdgeInsets.symmetric(
                 horizontal: context.getRSize(14),
                 vertical: context.getRSize(12),
              ),
              decoration: BoxDecoration(
                color: theme.scaffoldBackgroundColor,
                borderRadius: BorderRadius.circular(AppSpacing.borderRadiusM),
                border: Border.all(
                  color: theme.dividerColor.withValues(alpha: 0.1),
                ),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Text(
                      'Expected empties in warehouse',
                      style: TextStyle(
                        fontSize: context.getRFontSize(13),
                        color: theme.colorScheme.onSurfaceVariant,
                        fontWeight: FontWeight.w600,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  SizedBox(width: context.getRSize(8)),
                  Text(
                    _isLoadingExpected
                        ? '...'
                        : (_expectedEmpties != null ? '$_expectedEmpties crates' : 'Select store'),
                    key: const ValueKey(kCountEmptiesExpectedTextKey),
                    style: TextStyle(
                      fontSize: context.getRFontSize(14),
                      fontWeight: FontWeight.w800,
                      color: theme.colorScheme.onSurface,
                    ),
                  ),
                ],
              ),
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

            if (isCountInvalid) ...[
              SizedBox(height: context.getRSize(4)),
              Text(
                'Count cannot be negative or invalid',
                style: TextStyle(
                  color: theme.colorScheme.error,
                  fontSize: context.getRFontSize(12),
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],

            SizedBox(height: context.getRSize(12)),

            // Difference and what will be recorded
            if (differenceLine != null)
              Container(
                key: const ValueKey(kCountEmptiesDifferenceTextKey),
                padding: EdgeInsets.all(context.getRSize(12)),
                decoration: BoxDecoration(
                  color: (counted != null && _expectedEmpties != null && counted < _expectedEmpties!)
                      ? AppColors.warning.withValues(alpha: 0.1)
                      : theme.colorScheme.primary.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(AppSpacing.borderRadiusM),
                  border: Border.all(
                    color: (counted != null && _expectedEmpties != null && counted < _expectedEmpties!)
                        ? AppColors.warning.withValues(alpha: 0.3)
                        : theme.colorScheme.primary.withValues(alpha: 0.2),
                  ),
                ),
                child: Row(
                  children: [
                    Icon(
                      (counted != null && _expectedEmpties != null && counted < _expectedEmpties!)
                          ? FontAwesomeIcons.triangleExclamation.data
                          : FontAwesomeIcons.circleInfo.data,
                      size: context.getRSize(14),
                      color: (counted != null && _expectedEmpties != null && counted < _expectedEmpties!)
                          ? AppColors.warning
                          : theme.colorScheme.primary,
                    ),
                    SizedBox(width: context.getRSize(8)),
                    Expanded(
                      child: Text(
                        differenceLine,
                        style: TextStyle(
                          fontSize: context.getRFontSize(12),
                          fontWeight: FontWeight.w600,
                          color: (counted != null && _expectedEmpties != null && counted < _expectedEmpties!)
                              ? AppColors.warning
                              : theme.colorScheme.onSurface,
                        ),
                      ),
                    ),
                  ],
                ),
              ),

            if (_errorMessage != null) ...[
              SizedBox(height: context.getRSize(10)),
              Text(
                _errorMessage!,
                style: TextStyle(
                  color: theme.colorScheme.error,
                  fontSize: context.getRFontSize(12),
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],

            SizedBox(height: context.getRSize(24)),

            // Actions row
            Row(
              children: [
                Expanded(
                  child: AppButton(
                    key: const ValueKey(kCountEmptiesCancelButtonKey),
                    text: 'Cancel',
                    variant: AppButtonVariant.ghost,
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ),
                SizedBox(width: context.getRSize(12)),
                Expanded(
                  child: AppButton(
                    key: const ValueKey(kCountEmptiesSaveButtonKey),
                    text: 'Save Count',
                    variant: AppButtonVariant.primary,
                    onPressed: _handleSave,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
