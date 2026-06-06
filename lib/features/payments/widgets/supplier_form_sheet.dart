import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:reebaplus_pos/shared/widgets/app_input.dart';
import 'package:drift/drift.dart' show Value;

/// Add or edit a supplier (§21.5). Editing is CEO-only — gate at the caller
/// (the caller only opens this with `existing != null` for a CEO).
class SupplierFormSheet extends ConsumerStatefulWidget {
  final SupplierData? existing;

  const SupplierFormSheet({super.key, this.existing});

  static void show(BuildContext context, {SupplierData? existing}) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => SupplierFormSheet(existing: existing),
    );
  }

  @override
  ConsumerState<SupplierFormSheet> createState() => _SupplierFormSheetState();
}

class _SupplierFormSheetState extends ConsumerState<SupplierFormSheet> {
  late final TextEditingController _nameCtrl;
  late final TextEditingController _phoneCtrl;
  late final TextEditingController _emailCtrl;
  late final TextEditingController _addressCtrl;
  late final TextEditingController _bankAcctNameCtrl;
  late final TextEditingController _bankAcctNumberCtrl;
  late final TextEditingController _bankNameCtrl;
  late final TextEditingController _notesCtrl;
  final _formKey = GlobalKey<FormState>();
  bool _saving = false;

  bool get _isEdit => widget.existing != null;

  @override
  void initState() {
    super.initState();
    final s = widget.existing;
    _nameCtrl = TextEditingController(text: s?.name ?? '');
    _phoneCtrl = TextEditingController(text: s?.phone ?? '');
    _emailCtrl = TextEditingController(text: s?.email ?? '');
    _addressCtrl = TextEditingController(text: s?.address ?? '');
    _bankAcctNameCtrl = TextEditingController(text: s?.bankAccountName ?? '');
    _bankAcctNumberCtrl =
        TextEditingController(text: s?.bankAccountNumber ?? '');
    _bankNameCtrl = TextEditingController(text: s?.bankName ?? '');
    _notesCtrl = TextEditingController(text: s?.notes ?? '');
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _phoneCtrl.dispose();
    _emailCtrl.dispose();
    _addressCtrl.dispose();
    _bankAcctNameCtrl.dispose();
    _bankAcctNumberCtrl.dispose();
    _bankNameCtrl.dispose();
    _notesCtrl.dispose();
    super.dispose();
  }

  Color get _surface => Theme.of(context).colorScheme.surface;
  Color get _text => Theme.of(context).colorScheme.onSurface;
  Color get _border => Theme.of(context).dividerColor;

  static String? _orNull(String s) {
    final t = s.trim();
    return t.isEmpty ? null : t;
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate() || _saving) return;
    // Write-boundary re-check (hard rule #6 / 3-layer enforcement).
    if (!ref.read(currentUserPermissionsProvider).contains('suppliers.manage')) {
      Navigator.pop(context);
      return;
    }
    final db = ref.read(databaseProvider);
    setState(() => _saving = true);
    try {
      if (_isEdit) {
        await db.catalogDao.updateSupplier(SuppliersCompanion(
          id: Value(widget.existing!.id),
          name: Value(_nameCtrl.text.trim()),
          phone: Value(_orNull(_phoneCtrl.text)),
          email: Value(_orNull(_emailCtrl.text)),
          address: Value(_orNull(_addressCtrl.text)),
          bankAccountName: Value(_orNull(_bankAcctNameCtrl.text)),
          bankAccountNumber: Value(_orNull(_bankAcctNumberCtrl.text)),
          bankName: Value(_orNull(_bankNameCtrl.text)),
          notes: Value(_orNull(_notesCtrl.text)),
        ));
        await db.activityLogDao.logActivity(
          action: 'supplier.edit',
          description: 'Edited supplier ${_nameCtrl.text.trim()}',
          staffId: ref.read(authProvider).currentUser?.id,
          entityType: 'supplier',
          entityId: widget.existing!.id,
        );
      } else {
        final businessId = ref.read(authProvider).currentUser?.businessId;
        if (businessId == null) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
              content: Text(
                  'Cannot save: account not fully loaded yet. Try again in a moment.'),
            ));
            setState(() => _saving = false);
          }
          return;
        }
        final id = await db.catalogDao.insertSupplier(SuppliersCompanion.insert(
          businessId: businessId,
          name: _nameCtrl.text.trim(),
          phone: Value(_orNull(_phoneCtrl.text)),
          email: Value(_orNull(_emailCtrl.text)),
          address: Value(_orNull(_addressCtrl.text)),
          bankAccountName: Value(_orNull(_bankAcctNameCtrl.text)),
          bankAccountNumber: Value(_orNull(_bankAcctNumberCtrl.text)),
          bankName: Value(_orNull(_bankNameCtrl.text)),
          notes: Value(_orNull(_notesCtrl.text)),
        ));
        await db.activityLogDao.logActivity(
          action: 'supplier.add',
          description: 'Added supplier ${_nameCtrl.text.trim()}',
          staffId: ref.read(authProvider).currentUser?.id,
          entityType: 'supplier',
          entityId: id,
        );
      }
      if (mounted) Navigator.pop(context);
    } catch (_) {
      if (mounted) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not save supplier. Try again.')),
        );
      }
    }
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
            onTap: () {},
            child: Container(
              decoration: BoxDecoration(
                color: _surface,
                borderRadius:
                    const BorderRadius.vertical(top: Radius.circular(28)),
              ),
              child: Form(
                key: _formKey,
                child: Column(
                  children: [
                    _buildHeader(context),
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
                            labelText: 'Supplier Name',
                            controller: _nameCtrl,
                            hintText: 'e.g. SABMiller Nigeria',
                            validator: (v) => (v == null || v.trim().isEmpty)
                                ? 'This field is required'
                                : null,
                          ),
                          SizedBox(height: context.getRSize(16)),
                          AppInput(
                            labelText: 'Phone (optional)',
                            controller: _phoneCtrl,
                            hintText: 'e.g. 08012345678',
                            keyboardType: TextInputType.phone,
                            inputFormatters: [
                              FilteringTextInputFormatter.digitsOnly,
                            ],
                          ),
                          SizedBox(height: context.getRSize(16)),
                          AppInput(
                            labelText: 'Email (optional)',
                            controller: _emailCtrl,
                            hintText: 'e.g. sales@supplier.com',
                            keyboardType: TextInputType.emailAddress,
                          ),
                          SizedBox(height: context.getRSize(16)),
                          AppInput(
                            labelText: 'Address (optional)',
                            controller: _addressCtrl,
                            hintText: 'e.g. 123 Industrial Ave',
                          ),
                          SizedBox(height: context.getRSize(16)),
                          AppInput(
                            labelText: 'Bank Account Name (optional)',
                            controller: _bankAcctNameCtrl,
                            hintText: 'e.g. SABMiller Nigeria Ltd',
                          ),
                          SizedBox(height: context.getRSize(16)),
                          AppInput(
                            labelText: 'Account Number (optional)',
                            controller: _bankAcctNumberCtrl,
                            hintText: 'e.g. 0123456789',
                            keyboardType: TextInputType.number,
                            inputFormatters: [
                              FilteringTextInputFormatter.digitsOnly,
                            ],
                          ),
                          SizedBox(height: context.getRSize(16)),
                          AppInput(
                            labelText: 'Bank (optional)',
                            controller: _bankNameCtrl,
                            hintText: 'e.g. GTBank',
                          ),
                          SizedBox(height: context.getRSize(16)),
                          AppInput(
                            labelText: 'Notes (optional)',
                            controller: _notesCtrl,
                            hintText: 'Any extra details',
                            maxLines: 3,
                          ),
                        ],
                      ),
                    ),
                    Padding(
                      padding: EdgeInsets.fromLTRB(
                        context.getRSize(20),
                        context.getRSize(16),
                        context.getRSize(20),
                        context.deviceBottomInset + context.getRSize(16),
                      ),
                      child: AppButton(
                        text: _isEdit ? 'Save Changes' : 'Add Supplier',
                        onPressed: _save,
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

  Widget _buildHeader(BuildContext context) {
    return Padding(
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
                    colors: [
                      Theme.of(context).colorScheme.primary.withValues(alpha: 0.7),
                      Theme.of(context).colorScheme.primary,
                    ],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  FontAwesomeIcons.buildingColumns,
                  color: Colors.white,
                  size: context.getRSize(20),
                ),
              ),
              SizedBox(width: context.getRSize(14)),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _isEdit ? 'Edit Supplier' : 'Add New Supplier',
                    style: TextStyle(
                      fontSize: context.getRFontSize(18),
                      fontWeight: FontWeight.w800,
                      color: _text,
                    ),
                  ),
                  Text(
                    'Company & bank details',
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
    );
  }
}
