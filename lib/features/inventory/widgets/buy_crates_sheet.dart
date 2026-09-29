import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:reebaplus_pos/core/crates/crate_count_store.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/permissions/permissions.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/utils/currency_input_formatter.dart';
import 'package:reebaplus_pos/core/utils/notifications.dart';
import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:reebaplus_pos/shared/widgets/app_dropdown.dart';
import 'package:reebaplus_pos/shared/widgets/app_input.dart';

/// The manufacturer screen's Buy crates button (#294).
const String kBuyCratesButtonKey = 'manufacturer_buy_crates_button';

/// Test keys for [BuyCratesSheet] (#294).
const String kBuyCratesSheetKey = 'buy_crates_sheet';
const String kBuyCratesStorePickerKey = 'buy_crates_store_picker';
const String kBuyCratesQuantityFieldKey = 'buy_crates_quantity_field';
const String kBuyCratesPriceFieldKey = 'buy_crates_price_field';
const String kBuyCratesRecordedLineKey = 'buy_crates_recorded_line';
const String kBuyCratesSaveButtonKey = 'buy_crates_save_button';
const String kBuyCratesCancelButtonKey = 'buy_crates_cancel_button';

/// Buy crates from a manufacturer into a store's warehouse (#294, PRD #284
/// decision 9).
///
/// Asks how many, which store, and the price paid per crate, and states what
/// will be recorded before saving. The store is asked only when it can't be
/// inferred: a locked store, or a user with a single pickable store, is used
/// as-is (the same rule a count uses, `crateCountStoreWithoutAsking`).
///
/// Saves through [CratePoolDao.recordCratePurchase], which raises the Empties
/// Pool and writes **no** money leg (Rule A: profit 0). Callers gate the entry
/// point on `Gates.confirmCrateDeposit`; the save re-checks it at fire time.
class BuyCratesSheet extends ConsumerStatefulWidget {
  const BuyCratesSheet({super.key, required this.manufacturer});

  final ManufacturerData manufacturer;

  /// Shows the sheet over [context]. Scroll-controlled so it can grow to the
  /// full height on short screens and scroll instead of overflowing.
  static Future<void> show(
    BuildContext context, {
    required ManufacturerData manufacturer,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => BuyCratesSheet(manufacturer: manufacturer),
    );
  }

  @override
  ConsumerState<BuyCratesSheet> createState() => _BuyCratesSheetState();
}

class _BuyCratesSheetState extends ConsumerState<BuyCratesSheet> {
  final _formKey = GlobalKey<FormState>();
  final _quantityCtrl = TextEditingController();
  final _priceCtrl = TextEditingController();
  late final List<StoreData> _stores;
  late final bool _mustPickStore;
  String? _storeId;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _stores = ref.read(selectableStoresProvider);
    _storeId = crateCountStoreWithoutAsking(
      lockedStoreId: ref.read(lockedStoreProvider).value,
      selectableStoreIds: [for (final s in _stores) s.id],
    );
    _mustPickStore = _storeId == null;
  }

  @override
  void dispose() {
    _quantityCtrl.dispose();
    _priceCtrl.dispose();
    super.dispose();
  }

  int? get _quantity {
    final n = int.tryParse(_quantityCtrl.text.trim());
    return n != null && n > 0 ? n : null;
  }

  int? get _pricePerCrateKobo {
    if (_priceCtrl.text.trim().isEmpty) return null;
    return (parseCurrency(_priceCtrl.text) * 100).round();
  }

  String? get _storeName {
    for (final s in _stores) {
      if (s.id == _storeId) return s.name;
    }
    return null;
  }

  String? _validateQuantity(String? _) =>
      _quantity == null ? 'Enter how many crates you bought' : null;

  String? _validatePrice(String? _) =>
      _pricePerCrateKobo == null ? 'Enter the price paid per crate' : null;

  Future<void> _save() async {
    if (_saving) return;
    if (_storeId == null) {
      AppNotification.showError(context, 'Choose the store receiving the crates');
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
      AppNotification.showError(context, 'Sign in again to buy crates.');
      return;
    }

    setState(() => _saving = true);
    try {
      await ref.read(databaseProvider).cratePoolDao.recordCratePurchase(
            manufacturerId: widget.manufacturer.id,
            storeId: _storeId!,
            performedBy: userId,
            quantity: _quantity!,
            pricePerCrateKobo: _pricePerCrateKobo!,
          );
    } catch (_) {
      if (mounted) {
        setState(() => _saving = false);
        AppNotification.showError(
          context,
          'Could not record the crates. Please try again.',
        );
      }
      return;
    }
    if (!mounted) return;
    AppNotification.showSuccess(
      context,
      '${_quantity!} crates of ${widget.manufacturer.name} added',
    );
    Navigator.pop(context);
  }

  /// The "this is what will be recorded" line, or what is still missing.
  String _recordedLine() {
    final quantity = _quantity;
    final price = _pricePerCrateKobo;
    final store = _storeName;
    if (store == null) return 'Choose the store receiving the crates.';
    if (quantity == null || price == null) {
      return 'Enter how many crates and the price paid per crate.';
    }
    final total = formatCurrency(quantity * price / 100);
    final each = formatCurrency(price / 100);
    return '+$quantity crates into $store\'s warehouse. '
        'Paid $total ($quantity × $each). '
        'This does not change profit.';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final crateValue = formatCurrency(widget.manufacturer.depositAmountKobo / 100);
    return Container(
      key: const ValueKey(kBuyCratesSheetKey),
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
                'Buy crates',
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
                  key: const ValueKey(kBuyCratesStorePickerKey),
                  value: _storeId,
                  labelText: 'Store receiving the crates',
                  hintText: 'Choose a store',
                  items: [
                    for (final store in _stores)
                      DropdownMenuItem(value: store.id, child: Text(store.name)),
                  ],
                  onChanged: (id) => setState(() => _storeId = id),
                ),
                SizedBox(height: context.getRSize(12)),
              ],
              AppInput(
                key: const ValueKey(kBuyCratesQuantityFieldKey),
                controller: _quantityCtrl,
                labelText: 'Number of crates',
                hintText: 'e.g. 10',
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                textInputAction: TextInputAction.next,
                validator: _validateQuantity,
                onChanged: (_) => setState(() {}),
                fillColor: theme.cardColor,
              ),
              SizedBox(height: context.getRSize(12)),
              AppInput(
                key: const ValueKey(kBuyCratesPriceFieldKey),
                controller: _priceCtrl,
                labelText: 'Price paid per crate ($activeCurrencySymbol)',
                hintText: 'Crate value is $crateValue',
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                inputFormatters: [CurrencyInputFormatter()],
                validator: _validatePrice,
                onChanged: (_) => setState(() {}),
                fillColor: theme.cardColor,
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
                      _recordedLine(),
                      key: const ValueKey(kBuyCratesRecordedLineKey),
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
                      key: const ValueKey(kBuyCratesCancelButtonKey),
                      text: 'Cancel',
                      variant: AppButtonVariant.outline,
                      onPressed: _saving ? null : () => Navigator.pop(context),
                    ),
                  ),
                  SizedBox(width: context.getRSize(12)),
                  Expanded(
                    child: AppButton(
                      key: const ValueKey(kBuyCratesSaveButtonKey),
                      text: 'Buy crates',
                      variant: AppButtonVariant.primary,
                      isLoading: _saving,
                      onPressed: _save,
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
