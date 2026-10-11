import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reebaplus_pos/core/theme/app_icons.dart';

import 'package:reebaplus_pos/core/permissions/permissions.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/utils/notifications.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/features/customers/data/models/customer.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:reebaplus_pos/shared/widgets/app_input.dart';
import 'package:reebaplus_pos/shared/widgets/app_dropdown.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/screen_header.dart';
import 'package:reebaplus_pos/features/customers/widgets/customer_parts.dart';

/// §18 — Edit Customer Details. Mirrors [AddCustomerSheet] but prefilled with
/// the customer's current values. Intentionally cannot be dismissed by tapping
/// the barrier or dragging it down (`isDismissible: false`, `enableDrag: false`,
/// no tap-to-pop) so details aren't lost by mistake — it closes only via the
/// header back button (or the system back button) or the Save Details button.
class EditCustomerSheet extends ConsumerStatefulWidget {
  final String customerId;
  final String initialName;
  final String initialPhone;
  final String initialAddress;
  final String initialLocation;
  final PriceTier initialPriceTier;
  final String? initialStoreId;
  final void Function(Customer)? onCustomerUpdated;

  const EditCustomerSheet({
    super.key,
    required this.customerId,
    required this.initialName,
    required this.initialPhone,
    required this.initialAddress,
    required this.initialLocation,
    required this.initialPriceTier,
    required this.initialStoreId,
    this.onCustomerUpdated,
  });

  static void show(
    BuildContext context, {
    required String customerId,
    required String initialName,
    required String initialPhone,
    required String initialAddress,
    required String initialLocation,
    required PriceTier initialPriceTier,
    required String? initialStoreId,
    void Function(Customer)? onCustomerUpdated,
  }) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      isDismissible:
          false, // no tap-outside dismiss — guard against losing edits
      enableDrag: false, // no drag-down dismiss
      backgroundColor: Colors.transparent,
      builder: (_) => EditCustomerSheet(
        customerId: customerId,
        initialName: initialName,
        initialPhone: initialPhone,
        initialAddress: initialAddress,
        initialLocation: initialLocation,
        initialPriceTier: initialPriceTier,
        initialStoreId: initialStoreId,
        onCustomerUpdated: onCustomerUpdated,
      ),
    );
  }

  @override
  ConsumerState<EditCustomerSheet> createState() => _EditCustomerSheetState();
}

class _EditCustomerSheetState extends ConsumerState<EditCustomerSheet> {
  late final _nameCtrl = TextEditingController(text: widget.initialName);
  late final _addressCtrl = TextEditingController(text: widget.initialAddress);
  // The Google Maps Location field was removed from the UI, but we keep the
  // controller seeded with the existing value so editing a customer doesn't
  // wipe a location captured before the field was retired.
  late final _locationCtrl = TextEditingController(
    text: widget.initialLocation,
  );
  late final _phoneCtrl = TextEditingController(text: widget.initialPhone);
  late PriceTier _selectedGroup = widget.initialPriceTier;
  final _formKey = GlobalKey<FormState>();

  // Store selection
  List<StoreData> _stores = [];
  String? _selectedStoreId;

  @override
  void initState() {
    super.initState();
    final db = ref.read(databaseProvider);
    db.storesDao.getActiveStores().then((wh) {
      if (!mounted) return;
      setState(() {
        _stores = wh;
        // Preselect only once the items exist (AppDropdown asserts the value is
        // present in its items). If the customer's store is no longer active,
        // leave it null so the validator forces a re-pick.
        if (widget.initialStoreId != null &&
            wh.any((s) => s.id == widget.initialStoreId)) {
          _selectedStoreId = widget.initialStoreId;
        }
      });
    });
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _addressCtrl.dispose();
    _locationCtrl.dispose();
    _phoneCtrl.dispose();
    super.dispose();
  }

  Widget _groupDropdown() {
    return Column(
      children: [
        AppDropdown<PriceTier>(
          labelText: 'Price Tier',
          value: _selectedGroup,
          items: const [
            DropdownMenuItem(
              value: PriceTier.retailer,
              child: Text('Retailer'),
            ),
            DropdownMenuItem(
              value: PriceTier.wholesaler,
              child: Text('Wholesaler'),
            ),
          ],
          onChanged: (val) {
            if (val != null) setState(() => _selectedGroup = val);
          },
        ),
        SizedBox(height: context.getRSize(16)),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.9,
      minChildSize: 0.5,
      maxChildSize: 0.9,
      snap: true,
      snapSizes: const [0.5, 0.9],
      builder: (context, scrollController) {
        return Container(
          key: CustomersKeys.editSheet,
          decoration: ShapeDecoration(
            color: Theme.of(context).colorScheme.surface,
            shape: customerSheetShape(context),
          ),
          child: Form(
            key: _formKey,
            child: CustomerFormSheetLayout(
              scrollController: scrollController,
              // Handle & Header — the back button is one of the two ways to close the sheet.
              header: Padding(
                padding: EdgeInsets.fromLTRB(
                  context.getRSize(20),
                  context.getRSize(12),
                  context.getRSize(20),
                  context.getRSize(10),
                ),
                child: Column(
                  children: [
                    const CustomerSheetHandle(),
                    SizedBox(height: context.getRSize(16)),
                    ScreenHeader(
                      icon: AppIcons.edit,
                      title: 'Edit Customer Details',
                      subtitle: 'Update Client Information',
                      leading: IconButton(
                        key: CustomersKeys.editBack,
                        onPressed: () => Navigator.pop(context),
                        tooltip: 'Back',
                        constraints: const BoxConstraints(
                          minWidth: kMinInteractiveDimension,
                          minHeight: kMinInteractiveDimension,
                        ),
                        icon: AppIcon(
                          AppIcons.arrowBack,
                          size: context.getRSize(24),
                          color: Theme.of(context).colorScheme.onSurface,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              fields: [
                AppInput(
                  labelText: 'Customer Name',
                  controller: _nameCtrl,
                  hintText: 'e.g. John Doe',
                  validator: (v) => (v == null || v.trim().isEmpty)
                      ? 'This field is required'
                      : null,
                ),
                _groupDropdown(),
                AppDropdown<String>(
                  labelText: 'Assign to Store',
                  value: _selectedStoreId,
                  hintText: 'Select store',
                  items: _stores.map((wh) {
                    return DropdownMenuItem<String>(
                      value: wh.id,
                      child: Text(wh.name),
                    );
                  }).toList(),
                  onChanged: (val) => setState(() => _selectedStoreId = val),
                  validator: (v) => v == null ? 'Please select a store' : null,
                ),
                SizedBox(height: context.getRSize(16)),
                AppInput(
                  labelText: 'Address (optional)',
                  controller: _addressCtrl,
                  hintText: 'e.g. 123 Main Street',
                ),
                AppInput(
                  labelText: 'Phone Number',
                  controller: _phoneCtrl,
                  hintText: 'e.g. 08012345678',
                  keyboardType: TextInputType.phone,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  validator: (v) => (v == null || v.trim().isEmpty)
                      ? 'This field is required'
                      : null,
                ),
              ],
              footer: Padding(
                padding: EdgeInsets.fromLTRB(
                  context.getRSize(20),
                  context.getRSize(16),
                  context.getRSize(20),
                  context.deviceBottomPadding + context.getRSize(16),
                ),
                child: AppButton(
                  text: 'Save Details',
                  variant: AppButtonVariant.primary,
                  onPressed: () async {
                    // Defense-in-depth (hard rule #6): re-check the gate at
                    // the write boundary (fire-time decision, no subscribe).
                    if (!Gates.editCustomer.allowsNow(ref)) {
                      Navigator.pop(context);
                      return;
                    }
                    if (_formKey.currentState!.validate()) {
                      final updated = Customer(
                        id: widget.customerId,
                        name: _nameCtrl.text.trim(),
                        addressText: _addressCtrl.text.trim(),
                        googleMapsLocation: _locationCtrl.text.trim(),
                        phone: _phoneCtrl.text.trim().isEmpty
                            ? null
                            : _phoneCtrl.text.trim(),
                        priceTier: _selectedGroup,
                        isWalkIn: false,
                        storeId: _selectedStoreId,
                      );
                      try {
                        await ref
                            .read(customerServiceProvider)
                            .updateCustomer(updated);
                        if (!context.mounted) return;
                        Navigator.pop(context);
                        widget.onCustomerUpdated?.call(updated);
                      } catch (_) {
                        if (!context.mounted) return;
                        AppNotification.showError(
                          context,
                          'Could not update customer. Please try again.',
                        );
                      }
                    }
                  },
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
