import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:reebaplus_pos/core/crates/crate_value_change_impact.dart';
import 'package:reebaplus_pos/core/crates/manufacturer_crate_position.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/permissions/permissions.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/utils/currency_input_formatter.dart';
import 'package:reebaplus_pos/core/utils/notifications.dart';
import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/features/inventory/widgets/crate_money_arrangement_section.dart';
import 'package:reebaplus_pos/features/inventory/widgets/crate_value_change_sheet.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:reebaplus_pos/shared/widgets/app_input.dart';

/// Test keys for the Settings tab (#295).
const String kManufacturerSettingsStorageKey = 'manufacturer_settings_tab';
const String kManufacturerSettingsNameFieldKey = 'manufacturer_settings_name';
const String kManufacturerSettingsCrateValueFieldKey =
    'manufacturer_settings_crate_value';
const String kManufacturerSettingsSaveButtonKey = 'manufacturer_settings_save';
const String kManufacturerSettingsArrangementKey =
    'manufacturer_settings_arrangement';

/// Whether the viewer can edit anything on the Settings tab. The tab is
/// omitted entirely (not disabled) when this is false.
bool canEditManufacturerSettings(WidgetRef ref) =>
    Gates.editProductPrice.allows(ref) ||
    Gates.crateMoneyArrangement.allows(ref);

/// The Settings tab's content as slivers (#295, PRD #284 §10).
///
/// Name and crate value save together through the inventory DAO's deposit write
/// only, behind a consequence confirmation. The Crate Money Arrangement sits
/// under a divider and saves on its own.
class ManufacturerSettingsSlivers extends ConsumerStatefulWidget {
  const ManufacturerSettingsSlivers({
    super.key,
    required this.manufacturer,
    required this.position,
  });

  final ManufacturerData manufacturer;
  final ManufacturerCratePosition position;

  @override
  ConsumerState<ManufacturerSettingsSlivers> createState() =>
      _ManufacturerSettingsSliversState();
}

class _ManufacturerSettingsSliversState
    extends ConsumerState<ManufacturerSettingsSlivers> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameCtrl;
  late final TextEditingController _valueCtrl;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _nameCtrl = TextEditingController(text: widget.manufacturer.name);
    _valueCtrl = TextEditingController(
      text: _plainNaira(widget.manufacturer.depositAmountKobo),
    );
  }

  /// The stored value as the plain number the field takes; blank when unset.
  static String _plainNaira(int kobo) {
    if (kobo <= 0) return '';
    return kobo % 100 == 0
        ? (kobo ~/ 100).toString()
        : (kobo / 100).toStringAsFixed(2);
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _valueCtrl.dispose();
    super.dispose();
  }

  int? get _newValueKobo {
    final text = _valueCtrl.text.trim();
    if (text.isEmpty) return null;
    return (parseCurrency(text) * 100).round();
  }

  String? _validateName(String? raw) {
    final name = raw?.trim() ?? '';
    if (name.isEmpty) return 'Enter the manufacturer name';
    final all = ref.read(allManufacturersProvider).valueOrNull ?? const [];
    final taken = all.any(
      (m) =>
          m.id != widget.manufacturer.id &&
          m.name.trim().toLowerCase() == name.toLowerCase(),
    );
    return taken ? 'A manufacturer with this name already exists' : null;
  }

  String? _validateValue(String? _) {
    final kobo = _newValueKobo;
    return kobo == null || kobo < 0 ? 'Enter the crate value' : null;
  }

  Future<void> _save() async {
    if (_saving || !_formKey.currentState!.validate()) return;
    // Re-check at fire time: access may have been revoked while the tab sat
    // open, and the tab only reflects the moment it was built.
    if (!Gates.editProductPrice.allowsNow(ref)) {
      showGateDenied(context, Gates.editProductPrice);
      return;
    }
    final mfr = widget.manufacturer;
    final name = _nameCtrl.text.trim();
    final newKobo = _newValueKobo!;
    final valueChanged = newKobo != mfr.depositAmountKobo;
    if (name == mfr.name && !valueChanged) {
      AppNotification.showSuccess(context, 'Nothing to change');
      return;
    }

    final db = ref.read(databaseProvider);
    if (valueChanged) {
      final debtCrates = await db.cratePoolDao.supplierCrateDebtCratesFor(
        mfr.id,
      );
      if (!mounted) return;
      final confirmed = await CrateValueChangeSheet.show(
        context,
        brandName: mfr.name,
        impact: computeCrateValueChangeImpact(
          position: widget.position,
          newKobo: newKobo,
          supplierDebtCrates: debtCrates,
        ),
      );
      // Backing out writes nothing.
      if (!confirmed || !mounted) return;
    }

    setState(() => _saving = true);
    try {
      await db.inventoryDao.updateManufacturerDeposit(
        mfr.id,
        newKobo,
        name: name,
      );
      await ref.read(activityLogProvider).logAction(
            'update_manufacturer',
            '${ref.read(authProvider).currentUser?.name ?? 'Unknown'} updated '
                'settings for ${mfr.name}',
          );
    } catch (_) {
      if (mounted) {
        setState(() => _saving = false);
        AppNotification.showError(
          context,
          'Could not save changes. Please try again.',
        );
      }
      return;
    }
    if (!mounted) return;
    setState(() => _saving = false);
    AppNotification.showSuccess(context, 'Saved');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final canEdit = Gates.editProductPrice.allows(ref);
    final gutter = context.getRSize(16);
    return SliverPadding(
      padding: EdgeInsets.fromLTRB(
        gutter,
        context.getRSize(8),
        gutter,
        gutter + context.deviceBottomPadding,
      ),
      sliver: SliverList(
        delegate: SliverChildListDelegate([
          if (canEdit)
            Form(
              key: _formKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  AppInput(
                    key: const ValueKey(kManufacturerSettingsNameFieldKey),
                    controller: _nameCtrl,
                    labelText: 'Name',
                    textInputAction: TextInputAction.next,
                    validator: _validateName,
                    fillColor: theme.cardColor,
                  ),
                  SizedBox(height: context.getRSize(12)),
                  AppInput(
                    key: const ValueKey(kManufacturerSettingsCrateValueFieldKey),
                    controller: _valueCtrl,
                    labelText: 'Crate value ($activeCurrencySymbol)',
                    hintText: 'e.g. 1,500',
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    inputFormatters: [CurrencyInputFormatter()],
                    validator: _validateValue,
                    fillColor: theme.cardColor,
                  ),
                  SizedBox(height: context.getRSize(16)),
                  AppButton(
                    key: const ValueKey(kManufacturerSettingsSaveButtonKey),
                    text: 'Save',
                    variant: AppButtonVariant.primary,
                    isLoading: _saving,
                    onPressed: _save,
                  ),
                ],
              ),
            ),
          if (Gates.crateMoneyArrangement.allows(ref)) ...[
            if (canEdit) ...[
              SizedBox(height: context.getRSize(20)),
              const Divider(),
            ],
            SizedBox(height: context.getRSize(8)),
            Text(
              'Saves on its own — not part of Save above',
              key: const ValueKey(kManufacturerSettingsArrangementKey),
              style: theme.textTheme.labelLarge?.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
            CrateMoneyArrangementSection(manufacturer: widget.manufacturer),
          ],
        ]),
      ),
    );
  }
}
