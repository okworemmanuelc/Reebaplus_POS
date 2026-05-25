import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/features/customers/data/models/customer.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:reebaplus_pos/shared/widgets/app_input.dart';
import 'package:reebaplus_pos/shared/widgets/app_dropdown.dart';

class AddCustomerSheet extends ConsumerStatefulWidget {
  final void Function(Customer)? onCustomerAdded;

  const AddCustomerSheet({super.key, this.onCustomerAdded});

  static void show(BuildContext context, {void Function(Customer)? onCustomerAdded}) {
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
  final _locationCtrl = TextEditingController();
  final _phoneCtrl = TextEditingController();
  CustomerGroup _selectedGroup = CustomerGroup.retailer;
  final _formKey = GlobalKey<FormState>();

  // Warehouse selection
  List<WarehouseData> _warehouses = [];
  String? _selectedWarehouseId;

  @override
  void initState() {
    super.initState();
    final db = ref.read(databaseProvider);
    db.select(db.warehouses).get().then((wh) {
      if (mounted) setState(() => _warehouses = wh);
    });
  }
  Color get _surface => Theme.of(context).colorScheme.surface;
  Color get _text => Theme.of(context).colorScheme.onSurface;
  Color get _border => Theme.of(context).dividerColor;

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
        AppDropdown<CustomerGroup>(
          labelText: 'Customer Group',
          value: _selectedGroup,
          items: const [
            DropdownMenuItem(value: CustomerGroup.retailer, child: Text('Retailer')),
            DropdownMenuItem(value: CustomerGroup.wholesaler, child: Text('Wholesaler')),
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
              decoration: BoxDecoration(
                color: _surface,
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(28),
                ),
              ),
              child: Form(
                key: _formKey,
                child: Column(
                  children: [
                    // Handle & Header
                    Padding(
                      padding: EdgeInsets.fromLTRB(
                        context.getRSize(20),
                        context.getRSize(12),
                        context.getRSize(20),
                        0,
                      ),
                      child: Column(
                        children: [
                          Container(
                            width: context.getRSize(40),
                            height: context.getRSize(4),
                            decoration: BoxDecoration(
                              color: _border,
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                          SizedBox(height: context.getRSize(20)),
                          Row(
                            children: [
                              Container(
                                width: context.getRSize(44),
                                height: context.getRSize(44),
                                decoration: BoxDecoration(
                                  gradient: LinearGradient(
                                    colors: [Theme.of(context).colorScheme.primary.withValues(alpha: 0.7), Theme.of(context).colorScheme.primary],
                                    begin: Alignment.topLeft,
                                    end: Alignment.bottomRight,
                                  ),
                                  borderRadius: BorderRadius.circular(12),
                                  boxShadow: [
                                    BoxShadow(
                                      color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.3),
                                      blurRadius: 8,
                                      offset: const Offset(0, 2),
                                    ),
                                  ],
                                ),
                                child: Icon(
                                  FontAwesomeIcons.userPlus,
                                  color: Colors.white,
                                  size: context.getRSize(20),
                                ),
                              ),
                              SizedBox(width: context.getRSize(14)),
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'Add New Customer',
                                    style: TextStyle(
                                      fontSize: context.getRFontSize(18),
                                      fontWeight: FontWeight.w800,
                                      color: _text,
                                    ),
                                  ),
                                  Text(
                                    'Client Details & Contact',
                                    style: TextStyle(
                                      fontSize: context.getRFontSize(13),
                                      color: Theme.of(context).colorScheme.primary,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                          SizedBox(height: context.getRSize(10)),
                        ],
                      ),
                    ),

                    // Scrollable Content
                    Expanded(
                      child: ListView(
                        controller: scrollController,
                        padding: EdgeInsets.fromLTRB(
                          context.getRSize(20),
                          context.getRSize(10),
                          context.getRSize(20),
                          context.getRSize(20),
                        ),
                        children: [
                          AppInput(
                            labelText: 'Customer Name',
                            controller: _nameCtrl,
                            hintText: 'e.g. John Doe',
                            validator: (v) => (v == null || v.trim().isEmpty) ? 'This field is required' : null,
                          ),
                          _groupDropdown(),
                          AppDropdown<String>(
                            labelText: 'Assign to Warehouse',
                            value: _selectedWarehouseId,
                            hintText: 'Select warehouse',
                            items: _warehouses.map((wh) {
                              return DropdownMenuItem<String>(
                                value: wh.id,
                                child: Text(wh.name),
                              );
                            }).toList(),
                            onChanged: (val) => setState(() => _selectedWarehouseId = val),
                            validator: (v) => v == null ? 'Please select a warehouse' : null,
                          ),
                          SizedBox(height: context.getRSize(16)),
                          AppInput(
                            labelText: 'Address',
                            controller: _addressCtrl,
                            hintText: 'e.g. 123 Main Street',
                            validator: (v) => (v == null || v.trim().isEmpty) ? 'This field is required' : null,
                          ),
                          AppInput(
                            labelText: 'Google Maps Location',
                            controller: _locationCtrl,
                            hintText: 'e.g. Plus Code or Link',
                            validator: (v) => (v == null || v.trim().isEmpty) ? 'This field is required' : null,
                          ),
                          AppInput(
                            labelText: 'Phone Number (Optional)',
                            controller: _phoneCtrl,
                            hintText: 'e.g. 08012345678',
                            keyboardType: TextInputType.phone,
                          ),
                        ],
                      ),
                    ),

                    // Button
                    Padding(
                        padding: EdgeInsets.fromLTRB(
                          context.getRSize(20),
                          context.getRSize(16),
                          context.getRSize(20),
                          context.getRSize(
                            context.bottomInset + 16,
                          ),
                        ),
                      child: AppButton(
                        text: 'Save Customer',
                        variant: AppButtonVariant.primary,
                        onPressed: () async {
                          if (_formKey.currentState!.validate()) {
                            // Refuse the save if we don't yet know which business this row
                            // belongs to — a NULL business_id will fail the cloud RLS check
                            // (`business_id = get_user_business_id()`) and the row would be
                            // unsyncable forever.
                            final businessId =
                                ref.read(authProvider).currentUser?.businessId;
                            if (businessId == null) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text(
                                      'Cannot save: account not fully loaded yet. Try again in a moment.'),
                                ),
                              );
                              return;
                            }

                            // Lone owner picks warehouse manually
                            final warehouseId = _selectedWarehouseId;

                            final newCustomer = Customer(
                              id: '', // Database will generate this
                              name: _nameCtrl.text.trim(),
                              addressText: _addressCtrl.text.trim(),
                              googleMapsLocation: _locationCtrl.text.trim(),
                              phone: _phoneCtrl.text.trim().isEmpty
                                  ? null
                                  : _phoneCtrl.text.trim(),
                              customerGroup: _selectedGroup,
                              isWalkIn: false,
                              warehouseId: warehouseId,
                            );
                            final saved = await ref.read(customerServiceProvider).addCustomer(
                              newCustomer,
                              businessId: businessId,
                            );
                            if (!context.mounted) return;
                            Navigator.pop(context);
                            if (saved != null) {
                              widget.onCustomerAdded?.call(saved);
                            }
                          }
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}


