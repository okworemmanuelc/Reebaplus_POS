import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reebaplus_pos/core/theme/app_icons.dart';

import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/utils/notifications.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/features/customers/data/models/customer.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:reebaplus_pos/shared/widgets/app_input.dart';
import 'package:reebaplus_pos/shared/widgets/app_dropdown.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/screen_header.dart';
import 'package:reebaplus_pos/features/customers/widgets/customer_parts.dart';

class AddCustomerSheet extends ConsumerStatefulWidget {
  final void Function(Customer)? onCustomerAdded;

  const AddCustomerSheet({super.key, this.onCustomerAdded});

  static void show(
    BuildContext context, {
    void Function(Customer)? onCustomerAdded,
  }) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => AddCustomerSheet(onCustomerAdded: onCustomerAdded),
    );
  }

  @override
  ConsumerState<AddCustomerSheet> createState() => _AddCustomerSheetState();
}

class _AddCustomerSheetState extends ConsumerState<AddCustomerSheet> {
  final _nameCtrl = TextEditingController();
  final _addressCtrl = TextEditingController();
  final _phoneCtrl = TextEditingController();
  PriceTier _selectedGroup = PriceTier.retailer;
  final _formKey = GlobalKey<FormState>();

  // Store selection
  List<StoreData> _stores = [];
  String? _selectedStoreId;

  @override
  void initState() {
    super.initState();
    final db = ref.read(databaseProvider);
    db.storesDao.getActiveStores().then((wh) {
      if (mounted) setState(() => _stores = wh);
    });
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _addressCtrl.dispose();
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
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => Navigator.pop(context),
      child: DraggableScrollableSheet(
        initialChildSize: 0.9,
        minChildSize: 0.5,
        maxChildSize: 0.9,
        snap: true,
        snapSizes: const [0.5, 0.9],
        builder: (context, scrollController) {
          return GestureDetector(
            onTap: () {}, // Prevent tap from reaching the barrier
            child: Container(
              key: CustomersKeys.addSheet,
              decoration: ShapeDecoration(
                color: Theme.of(context).colorScheme.surface,
                shape: customerSheetShape(context),
              ),
              child: Form(
                key: _formKey,
                child: CustomerFormSheetLayout(
                  scrollController: scrollController,
                  // Handle & Header
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
                        const ScreenHeader(
                          icon: AppIcons.userAdd,
                          title: 'Add New Customer',
                          subtitle: 'Client Details & Contact',
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
                      onChanged: (val) =>
                          setState(() => _selectedStoreId = val),
                      validator: (v) =>
                          v == null ? 'Please select a store' : null,
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
                      text: 'Save Customer',
                      variant: AppButtonVariant.primary,
                      onPressed: () async {
                        // Defense-in-depth (hard rule #6): this is the single
                        // chokepoint for creating a customer — the Cart "New"
                        // button and the Customers screen both route here — so
                        // re-check `customers.add` at the write boundary.
                        if (!ref
                            .read(currentUserPermissionsProvider)
                            .contains('customers.add')) {
                          Navigator.pop(context);
                          return;
                        }
                        if (_formKey.currentState!.validate()) {
                          // Refuse the save if we don't yet know which business this row
                          // belongs to — a NULL business_id will fail the cloud RLS check
                          // (`business_id = get_user_business_id()`) and the row would be
                          // unsyncable forever.
                          final businessId = ref
                              .read(authProvider)
                              .currentUser
                              ?.businessId;
                          if (businessId == null) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text(
                                  'Cannot save: account not fully loaded yet. Try again in a moment.',
                                ),
                              ),
                            );
                            return;
                          }

                          // Lone owner picks store manually
                          final storeId = _selectedStoreId;

                          final newCustomer = Customer(
                            id: '', // Database will generate this
                            name: _nameCtrl.text.trim(),
                            addressText: _addressCtrl.text.trim(),
                            googleMapsLocation: '',
                            phone: _phoneCtrl.text.trim().isEmpty
                                ? null
                                : _phoneCtrl.text.trim(),
                            priceTier: _selectedGroup,
                            isWalkIn: false,
                            storeId: storeId,
                          );
                          try {
                            final saved = await ref
                                .read(customerServiceProvider)
                                .addCustomer(
                                  newCustomer,
                                  businessId: businessId,
                                );
                            if (!context.mounted) return;
                            Navigator.pop(context);
                            if (saved == null) {
                              if (context.mounted) {
                                AppNotification.showError(
                                  context,
                                  'Customer saved but could not be loaded. Pull to refresh.',
                                );
                              }
                              return;
                            }
                            widget.onCustomerAdded?.call(saved);
                          } catch (e) {
                            if (!context.mounted) return;
                            AppNotification.showError(
                              context,
                              'Could not save customer. Please try again.',
                            );
                          }
                        }
                      },
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
