import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/permissions/permissions.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/utils/currency_input_formatter.dart';
import 'package:reebaplus_pos/core/utils/notifications.dart';
import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:reebaplus_pos/shared/widgets/app_input.dart';

/// The Crates tab's Add Manufacturer sheet (#292): name + crate value only.
///
/// There is deliberately no opening empties box — a new brand's first number
/// comes from its first count (an Opening Count, #290). Callers gate the
/// entry point on `Gates.addManufacturer`; the save re-checks it at fire time.
class AddManufacturerSheet extends ConsumerStatefulWidget {
  const AddManufacturerSheet({super.key, required this.existingNames});

  /// Names of the business's live manufacturers, used to reject duplicates.
  final List<String> existingNames;

  /// Shows the sheet over [context]. Scroll-controlled so it can grow to the
  /// full height on short screens and scroll instead of overflowing.
  static Future<void> show(
    BuildContext context, {
    required List<String> existingNames,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => AddManufacturerSheet(existingNames: existingNames),
    );
  }

  @override
  ConsumerState<AddManufacturerSheet> createState() =>
      _AddManufacturerSheetState();
}

class _AddManufacturerSheetState extends ConsumerState<AddManufacturerSheet> {
  final _formKey = GlobalKey<FormState>();
  final _nameCtrl = TextEditingController();
  final _crateValueCtrl = TextEditingController();
  bool _saving = false;

  @override
  void dispose() {
    _nameCtrl.dispose();
    _crateValueCtrl.dispose();
    super.dispose();
  }

  String? _validateName(String? raw) {
    final name = raw?.trim() ?? '';
    if (name.isEmpty) return 'Enter the manufacturer name';
    final taken = widget.existingNames.any(
      (n) => n.trim().toLowerCase() == name.toLowerCase(),
    );
    if (taken) return 'A manufacturer with this name already exists';
    return null;
  }

  Future<void> _save() async {
    if (_saving || !_formKey.currentState!.validate()) return;
    // Re-check at fire time: access may have been revoked while the sheet was
    // open, and the button that opened it only reflects the moment of the tap.
    if (!Gates.addManufacturer.allowsNow(ref)) {
      showGateDenied(context, Gates.addManufacturer);
      return;
    }
    final name = _nameCtrl.text.trim();
    final user = ref.read(authProvider).currentUser;
    final businessId = user?.businessId;
    if (businessId == null) return;

    setState(() => _saving = true);
    try {
      await ref
          .read(databaseProvider)
          .inventoryDao
          .insertManufacturer(
            ManufacturersCompanion.insert(
              name: name,
              businessId: businessId,
              depositAmountKobo: Value(
                (parseCurrency(_crateValueCtrl.text) * 100).round(),
              ),
            ),
          );
    } catch (_) {
      if (mounted) {
        setState(() => _saving = false);
        AppNotification.showError(
          context,
          'Could not add manufacturer. Please try again.',
        );
      }
      return;
    }

    // The manufacturer is saved from here on. A failed log must not read as a
    // failed add, or a retry would create a second manufacturer.
    try {
      await ref
          .read(activityLogProvider)
          .logAction(
            'add_manufacturer',
            '${user?.name ?? 'Unknown'} added manufacturer: $name',
          );
    } catch (_) {
      if (mounted) {
        AppNotification.showError(
          context,
          'Manufacturer added, but the activity log could not be saved.',
        );
      }
    }
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
      ),
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
          24,
          24,
          24,
          24 + context.deviceBottomPadding,
        ),
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Add Manufacturer',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w900,
                  color: theme.colorScheme.onSurface,
                ),
              ),
              const SizedBox(height: 20),
              AppInput(
                controller: _nameCtrl,
                labelText: 'Name',
                hintText: 'e.g. Nigerian Breweries',
                textInputAction: TextInputAction.next,
                validator: _validateName,
                fillColor: theme.cardColor,
              ),
              const SizedBox(height: 12),
              AppInput(
                controller: _crateValueCtrl,
                labelText: 'Crate value ($activeCurrencySymbol)',
                hintText: '0',
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                inputFormatters: [CurrencyInputFormatter()],
                fillColor: theme.cardColor,
              ),
              const SizedBox(height: 32),
              AppButton(
                text: 'Add Manufacturer',
                variant: AppButtonVariant.primary,
                isLoading: _saving,
                onPressed: _save,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
