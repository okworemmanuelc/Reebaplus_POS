import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/core/utils/notifications.dart';
import 'package:reebaplus_pos/features/receiving/state/receive_cart.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:reebaplus_pos/shared/widgets/app_dropdown.dart';
import 'package:reebaplus_pos/shared/widgets/app_input.dart';
import 'package:reebaplus_pos/core/services/crash_reporter.dart';

class ReceiveCheckoutScreen extends ConsumerStatefulWidget {
  const ReceiveCheckoutScreen({super.key});

  @override
  ConsumerState<ReceiveCheckoutScreen> createState() => _ReceiveCheckoutScreenState();
}

class _ReceiveCheckoutScreenState extends ConsumerState<ReceiveCheckoutScreen> {
  final _noteCtrl = TextEditingController();
  bool _isLoading = true;
  bool _isSaving = false;
  
  List<SupplierData> _suppliers = [];
  SupplierData? _selectedSupplier;
  
  // Maps productId to the number of empties returned
  final Map<String, int> _emptiesReturned = {};
  final Map<String, TextEditingController> _emptiesControllers = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _loadData();
    });
  }

  @override
  void dispose() {
    _noteCtrl.dispose();
    for (final c in _emptiesControllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _loadData() async {
    final db = ref.read(databaseProvider);
    final suppliers = await db.catalogDao.getAllSuppliers();
    
    // Auto-select a supplier if all cart items share the same supplier
    // Wait, the cart doesn't have supplierId, but we can look it up if we wanted.
    
    if (mounted) {
      setState(() {
        _suppliers = suppliers;
        _isLoading = false;
      });
      
      final cart = ref.read(receiveCartProvider);
      for (final line in cart) {
        if (line.trackEmpties) {
          final c = TextEditingController(text: '0');
          c.addListener(() {
            _emptiesReturned[line.productId] = int.tryParse(c.text) ?? 0;
          });
          _emptiesControllers[line.productId] = c;
          _emptiesReturned[line.productId] = 0;
        }
      }
    }
  }

  Future<void> _confirmReceipt() async {
    if (_selectedSupplier == null) {
      AppNotification.showError(context, 'Please select a supplier');
      return;
    }

    final cart = ref.read(receiveCartProvider);
    if (cart.isEmpty) {
      AppNotification.showError(context, 'Cart is empty');
      return;
    }

    setState(() => _isSaving = true);
    final db = ref.read(databaseProvider);
    final auth = ref.read(authProvider);
    final currentUserId = auth.currentUser?.id ?? 'unknown';
    
    final storeId = ref.read(lockedStoreProvider).value ?? 
                    ref.read(selectableStoresProvider).firstOrNull?.id;
                    
    if (storeId == null) {
      setState(() => _isSaving = false);
      AppNotification.showError(context, 'No store selected');
      return;
    }

    try {
      final totalInvoiceKobo = ref.read(receiveCartProvider.notifier).invoiceTotalKobo;
      
      await db.transaction(() async {
        // 1. Log Invoice / Update Supplier Ledger
        await ref.read(supplierAccountServiceProvider).recordInvoice(
          supplierId: _selectedSupplier!.id,
          amountKobo: totalInvoiceKobo,
          dateReceived: DateTime.now(),
          staffId: currentUserId,
          storeId: storeId,
          note: _noteCtrl.text.trim(),
        );

        // 2. Process each cart item
        for (final line in cart) {
          // A. Add Stock
          await db.inventoryDao.adjustStock(
            line.productId,
            storeId,
            line.qty,
            'Stock received (Invoice)',
            currentUserId,
          );

          // B. Crate Ledger Movements
          if (line.trackEmpties && line.manufacturerId != null) {
            // Received full crates increases our owed balance
            await db.crateLedgerDao.recordCrateReceiveFromManufacturer(
              manufacturerId: line.manufacturerId!,
              quantity: line.qty,
              performedBy: currentUserId,
              storeId: storeId,
            );

            // Returned empty crates decreases our owed balance
            final returned = _emptiesReturned[line.productId] ?? 0;
            if (returned > 0) {
              await db.crateLedgerDao.recordCrateReturnByManufacturer(
                manufacturerId: line.manufacturerId!,
                quantity: returned,
                performedBy: currentUserId,
                storeId: storeId,
              );
            }
          }
        }
      });
      
      if (mounted) {
        AppNotification.showSuccess(context, 'Stock received successfully');
        ref.read(receiveCartProvider.notifier).clear();
        Navigator.of(context).popUntil((route) => route.isFirst);
      }
    } catch (e, st) {
      CrashReporter.record(e, st, context: 'receive_checkout');
      if (mounted) {
        AppNotification.showError(context, 'Failed to complete receipt: $e');
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cart = ref.watch(receiveCartProvider);
    final notifier = ref.read(receiveCartProvider.notifier);
    final bg = Theme.of(context).colorScheme.surface;
    final cardColor = Theme.of(context).cardColor;
    final textColor = Theme.of(context).colorScheme.onSurface;
    final primary = Theme.of(context).colorScheme.primary;
    final border = Theme.of(context).dividerColor;
    final subtext = Theme.of(context).textTheme.bodySmall?.color;

    final totalValueStr = formatCurrency(notifier.invoiceTotalKobo / 100);
    
    final emptiesLines = cart.where((l) => l.trackEmpties).toList();

    return Scaffold(
      backgroundColor: bg,
      appBar: AppBar(
        title: const Text('Checkout / Confirm'),
        elevation: 0,
        backgroundColor: bg,
      ),
      body: _isLoading 
        ? const Center(child: CircularProgressIndicator())
        : SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(20, 16, 20, 100 + context.deviceBottomPadding),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Summary Card
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: primary.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: primary.withValues(alpha: 0.2)),
                  ),
                  child: Column(
                    children: [
                      Text(
                        'Invoice Total',
                        style: TextStyle(color: primary, fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        totalValueStr,
                        style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800, color: primary),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '${notifier.totalUnits} total items • ${cart.length} unique products',
                        style: TextStyle(color: primary.withValues(alpha: 0.8), fontSize: 13),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),
                
                // Supplier Selection
                Text('SUPPLIER *', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: subtext)),
                const SizedBox(height: 8),
                AppDropdown<SupplierData?>(
                  value: _selectedSupplier,
                  items: _suppliers.map((s) => DropdownMenuItem(value: s, child: Text(s.name))).toList(),
                  onChanged: (v) => setState(() => _selectedSupplier = v),
                  hintText: 'Select Supplier',
                ),
                const SizedBox(height: 16),
                
                // Note
                AppInput(
                  controller: _noteCtrl,
                  labelText: 'Reference Note (Optional)',
                  hintText: 'e.g. Invoice #12345',
                ),
                
                // Empties Section
                if (emptiesLines.isNotEmpty) ...[
                  const SizedBox(height: 32),
                  Row(
                    children: [
                      Icon(FontAwesomeIcons.wineBottle.data, size: 16, color: subtext),
                      const SizedBox(width: 8),
                      Text('EMPTY CRATES RETURNED', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: subtext)),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Container(
                    decoration: BoxDecoration(
                      color: cardColor,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: border),
                    ),
                    child: ListView.separated(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      itemCount: emptiesLines.length,
                      separatorBuilder: (_, __) => Divider(height: 1, color: border),
                      itemBuilder: (context, index) {
                        final line = emptiesLines[index];
                        final ctrl = _emptiesControllers[line.productId];
                        return Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                          child: Row(
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(line.productName, style: TextStyle(fontWeight: FontWeight.w600, color: textColor)),
                                    const SizedBox(height: 2),
                                    Text('Received full crates: ${line.qty}', style: TextStyle(fontSize: 12, color: subtext)),
                                  ],
                                ),
                              ),
                              SizedBox(
                                width: 80,
                                child: AppInput(
                                  controller: ctrl,
                                  keyboardType: TextInputType.number,
                                  textAlign: TextAlign.center,
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ],
            ),
          ),
      bottomSheet: Container(
        padding: EdgeInsets.fromLTRB(20, 16, 20, 16 + context.deviceBottomPadding),
        decoration: BoxDecoration(
          color: cardColor,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.05),
              offset: const Offset(0, -4),
              blurRadius: 12,
            ),
          ],
        ),
        child: AppButton(
          text: 'Confirm Receipt',
          onPressed: _selectedSupplier == null || _isSaving ? null : _confirmReceipt,
          isLoading: _isSaving,
          isFullWidth: true,
        ),
      ),
    );
  }
}
