import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/features/inventory/data/models/supplier.dart';
import 'package:reebaplus_pos/shared/widgets/app_dropdown.dart';
import 'package:reebaplus_pos/features/deliveries/data/models/delivery.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/services/crash_reporter.dart';
import 'package:reebaplus_pos/core/utils/notifications.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:reebaplus_pos/shared/widgets/app_input.dart';
import 'package:reebaplus_pos/core/utils/currency_input_formatter.dart';

class ReceiveDeliverySheet extends ConsumerStatefulWidget {
  const ReceiveDeliverySheet({super.key});

  static void show(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const ReceiveDeliverySheet(),
    );
  }

  @override
  ConsumerState<ReceiveDeliverySheet> createState() =>
      _ReceiveDeliverySheetState();
}

class _DeliveryItemLine {
  final TextEditingController productCtrl = TextEditingController();
  final TextEditingController qtyCtrl = TextEditingController();
  final TextEditingController retailPriceCtrl = TextEditingController();

  ProductData? selectedProduct;
  Supplier? selectedSupplier;
  String selectedCategory = 'Other';
  CrateSizeGroupData? selectedCrateGroup;
  bool trackEmpties = false;

  double get lineTotal {
    final qty = double.tryParse(qtyCtrl.text) ?? 0;
    return qty; // cost price not stored in ProductData; lineTotal = qty for now
  }

  void dispose() {
    productCtrl.dispose();
    qtyCtrl.dispose();
    retailPriceCtrl.dispose();
  }
}

class _ReceiveDeliverySheetState extends ConsumerState<ReceiveDeliverySheet> {
  final List<_DeliveryItemLine> _lines = [];
  List<CrateSizeGroupData> _crateSizeGroups = [];
  List<ProductData> _allProducts = [];
  List<StoreData> _stores = [];
  StoreData? _selectedStore;
  Color get _surface => Theme.of(context).colorScheme.surface;
  Color get _text => Theme.of(context).colorScheme.onSurface;
  Color get _subtext =>
      Theme.of(context).textTheme.bodySmall?.color ??
      Theme.of(context).iconTheme.color!;
  Color get _border => Theme.of(context).dividerColor;
  Color get _cardBg => Theme.of(context).cardColor;

  @override
  void initState() {
    super.initState();
    _addLine(null);
    _loadCrateSizeGroups();
    _loadProducts();
    _loadStores();
  }

  Future<void> _loadCrateSizeGroups() async {
    final db = ref.read(databaseProvider);
    final groups = await db.inventoryDao.getAllCrateSizeGroups();
    if (mounted) setState(() => _crateSizeGroups = groups);
  }

  Future<void> _loadProducts() async {
    final db = ref.read(databaseProvider);
    final products = await db.catalogDao.watchAvailableProductDatas().first;
    if (mounted) setState(() => _allProducts = products);
  }

  Future<void> _loadStores() async {
    final db = ref.read(databaseProvider);
    final whs = await db.storesDao.getActiveStores();
    if (mounted) {
      setState(() {
        _stores = whs;
        if (whs.isNotEmpty) _selectedStore = whs.first;
      });
    }
  }

  @override
  void dispose() {
    for (var l in _lines) {
      l.dispose();
    }
    super.dispose();
  }

  void _addLine(ScrollController? scrollController) {
    setState(() {
      final line = _DeliveryItemLine();
      line.qtyCtrl.addListener(_updateScope);
      _lines.add(line);
    });
    if (scrollController != null && scrollController.hasClients) {
      Future.delayed(const Duration(milliseconds: 100), () {
        scrollController.animateTo(
          scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      });
    }
  }

  void _removeLine(int index) {
    if (_lines.length > 1) {
      setState(() {
        final l = _lines.removeAt(index);
        l.dispose();
      });
    }
  }

  void _updateScope() {
    setState(() {});
  }

  Future<void> _submit() async {
    // Validate store
    if (_selectedStore == null) {
      AppNotification.showError(context, 'Please select a destination store.');
      return;
    }

    // Validate each line
    for (var l in _lines) {
      if (l.selectedProduct == null) {
        AppNotification.showError(
          context,
          'Select a product from the list for each item.',
        );
        return;
      }
      if ((double.tryParse(l.qtyCtrl.text) ?? 0) <= 0) {
        AppNotification.showError(
          context,
          'Quantity must be greater than 0 for each item.',
        );
        return;
      }
      if (l.selectedSupplier == null) {
        AppNotification.showError(
          context,
          'Please select a supplier for each item.',
        );
        return;
      }
      if (l.selectedCategory == 'Alcoholic' && l.selectedCrateGroup == null) {
        AppNotification.showError(
          context,
          'Select a Crate Company for Crate items.',
        );
        return;
      }
    }

    final deliveryId = DateTime.now().millisecondsSinceEpoch.toString();
    double totalQty = 0;
    final List<DeliveryItem> deliveryItems = [];

    String mainSupplierName = _lines.first.selectedSupplier!.name;

    final db = ref.read(databaseProvider);

    try {
      for (var l in _lines) {
        final qty = (double.tryParse(l.qtyCtrl.text) ?? 0).toInt();
        totalQty += qty;

        // Update stock in the database
        await db.inventoryDao.adjustStock(
          l.selectedProduct!.id,
          _selectedStore!.id,
          qty,
          'Delivery received',
          null,
        );

        // Persist the trackEmpties setting if it differs from the product's saved value.
        if (l.selectedProduct!.trackEmpties != l.trackEmpties) {
          await db.catalogDao.updateTrackEmpties(
            l.selectedProduct!.id,
            l.trackEmpties,
          );
        }

        // When trackEmpties is on, received bottle crates enter the empty-crate pool
        // so the manufacturer's stock count reflects crates now in circulation.
        if (l.trackEmpties && l.selectedProduct!.manufacturerId != null) {
          await db.inventoryDao.addEmptyCrates(
            l.selectedProduct!.manufacturerId!,
            qty,
            storeId: _selectedStore?.id,
          );
        }

        deliveryItems.add(
          DeliveryItem(
            productId: l.selectedProduct!.id.toString(),
            productName: l.selectedProduct!.name,
            supplierName: l.selectedSupplier!.name,
            crateGroupLabel: l.selectedCrateGroup?.name,
            unitPrice: 0,
            quantity: qty.toDouble(),
          ),
        );
      }

      final delivery = Delivery(
        id: deliveryId,
        supplierName: mainSupplierName,
        deliveredAt: DateTime.now(),
        items: deliveryItems,
        totalValue: 0,
        status: 'confirmed',
      );

      ref.read(deliveryServiceProvider).addDelivery(delivery);

      await ref
          .read(activityLogProvider)
          .logAction(
            "Delivery Received",
            "Delivery from $mainSupplierName to ${_selectedStore!.name} — ${deliveryItems.length} item(s), ${totalQty.toInt()} units added to stock",
          );

      if (!mounted) return;

      Navigator.pop(context);
      AppNotification.showSuccess(
        context,
        '${totalQty.toInt()} units added to ${_selectedStore!.name}.',
      );
    } catch (e, st) {
      CrashReporter.record(e, st, context: 'deliveries.receive');
      if (!mounted) return;
      AppNotification.showError(
        context,
        'Could not save delivery. Please try again.',
      );
    }
  }

  Widget _inputField(
    String label,
    TextEditingController ctrl,
    String hint, {
    bool isNumber = false,
    bool isAutocomplete = false,
    bool isCurrency = false,
    _DeliveryItemLine? line,
  }) {
    if (isAutocomplete && line != null) {
      return Autocomplete<ProductData>(
        displayStringForOption: (p) => p.name,
        optionsBuilder: (TextEditingValue textEditingValue) {
          if (textEditingValue.text.isEmpty) {
            return const Iterable<ProductData>.empty();
          }
          final q = textEditingValue.text.toLowerCase();
          return _allProducts.where((p) => p.name.toLowerCase().contains(q));
        },
        onSelected: (ProductData selection) {
          setState(() {
            line.selectedProduct = selection;
            line.productCtrl.text = selection.name;
            line.selectedCategory = 'Other';
            line.retailPriceCtrl.text = (selection.retailerPriceKobo / 100)
                .round()
                .toString();
            // Pre-fill trackEmpties from the product's saved setting.
            line.trackEmpties = selection.trackEmpties;

            if (selection.crateSizeGroupId != null) {
              final match = _crateSizeGroups
                  .where((cg) => cg.id == selection.crateSizeGroupId)
                  .firstOrNull;
              line.selectedCrateGroup = match;
            } else {
              line.selectedCrateGroup = null;
            }

            if (line.qtyCtrl.text.isEmpty) {
              line.qtyCtrl.text = '1';
            }
          });
        },
        fieldViewBuilder: (context, controller, focusNode, onEditingComplete) {
          if (controller.text.isEmpty && line.productCtrl.text.isNotEmpty) {
            controller.text = line.productCtrl.text;
          }
          controller.addListener(() {
            line.productCtrl.text = controller.text;
          });
          return AppInput(
            controller: controller,
            focusNode: focusNode,
            onFieldSubmitted: (_) => onEditingComplete(),
            labelText: label,
            hintText: hint,
            fillColor: _cardBg,
          );
        },
      );
    }

    return AppInput(
      controller: ctrl,
      keyboardType: isNumber
          ? (isCurrency
                ? const TextInputType.numberWithOptions(decimal: true)
                : TextInputType.number)
          : TextInputType.text,
      inputFormatters: isCurrency
          ? [CurrencyInputFormatter()]
          : (isNumber ? [FilteringTextInputFormatter.digitsOnly] : null),
      labelText: label,
      hintText: hint,
      fillColor: _cardBg,
    );
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => Navigator.pop(context),
      child: DraggableScrollableSheet(
        // Open at maxChildSize: a draggable sheet auto-EXPANDS toward max when a
        // focused field is scrolled into view as the keyboard opens, which lurches
        // the whole form upward "like a second keyboard". Starting at max leaves
        // no room to expand. Matches add_customer_sheet.
        initialChildSize: 0.9,
        minChildSize: 0.5,
        maxChildSize: 0.9,
        snap: true,
        snapSizes: const [0.5, 0.9],
        builder: (context, scrollController) {
          double grandTotal = 0;
          for (var l in _lines) {
            grandTotal += l.lineTotal;
          }

          return GestureDetector(
            onTap: () {}, // Prevent tap from reaching the barrier
            child: Container(
              decoration: BoxDecoration(
                color: _surface,
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(28),
                ),
              ),
              child: Column(
                children: [
                  Padding(
                    padding: EdgeInsets.fromLTRB(
                      context.getRSize(20),
                      context.getRSize(20),
                      context.getRSize(20),
                      0,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Center(
                          child: Container(
                            width: context.getRSize(40),
                            height: context.getRSize(4),
                            decoration: BoxDecoration(
                              color: _border,
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                        ),
                        SizedBox(height: context.getRSize(20)),
                        Text(
                          'Receive Delivery',
                          style: TextStyle(
                            fontSize: context.getRFontSize(20),
                            fontWeight: FontWeight.w800,
                            color: _text,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Stock will be added to existing inventory',
                          style: TextStyle(
                            fontSize: context.getRFontSize(13),
                            color: _subtext,
                          ),
                        ),
                        SizedBox(height: context.getRSize(16)),
                        // ── STORE SELECTOR ─────────────────────────────
                        if (_stores.isEmpty)
                          Text(
                            'No stores found. Add a store first.',
                            style: TextStyle(
                              fontSize: 13,
                              color: Theme.of(context).colorScheme.error,
                            ),
                          )
                        else
                          AppDropdown<StoreData?>(
                            labelText: 'DESTINATION STORE *',
                            value: _selectedStore,
                            items: _stores
                                .map(
                                  (w) => DropdownMenuItem(
                                    value: w,
                                    child: Text(w.name),
                                  ),
                                )
                                .toList(),
                            onChanged: (v) =>
                                setState(() => _selectedStore = v),
                          ),
                        SizedBox(height: context.getRSize(16)),
                      ],
                    ),
                  ),
                  Expanded(
                    child: ListView.builder(
                      controller: scrollController,
                      padding: EdgeInsets.all(context.getRSize(16)),
                      itemCount: _lines.length,
                      itemBuilder: (context, index) {
                        return _buildProductCard(context, index);
                      },
                    ),
                  ),
                  _buildSummaryBar(context, grandTotal, scrollController),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildProductCard(BuildContext context, int index) {
    final line = _lines[index];

    return Container(
      decoration: BoxDecoration(
        color: _surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _border),
      ),
      child: Padding(
        padding: EdgeInsets.all(context.getRSize(16)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Item ${index + 1}',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.primary,
                    fontWeight: FontWeight.bold,
                    fontSize: context.getRFontSize(14),
                  ),
                ),
                if (_lines.length > 1)
                  InkWell(
                    onTap: () => _removeLine(index),
                    child: Icon(
                      FontAwesomeIcons.circleMinus.data,
                      color: Theme.of(context).colorScheme.error,
                      size: context.getRSize(18),
                    ),
                  ),
              ],
            ),
            SizedBox(height: context.getRSize(12)),

            _inputField(
              'Product *',
              line.productCtrl,
              'Start typing product name...',
              isAutocomplete: true,
              line: line,
            ),

            const SizedBox(height: 12),

            const SizedBox(height: 0),

            const SizedBox(height: 12),

            AppDropdown<String>(
              labelText: 'Category',
              value: line.selectedCategory,
              items: [
                'Alcoholic',
                'Cans & PET',
                'Kegs',
                'Other',
              ].map((c) => DropdownMenuItem(value: c, child: Text(c))).toList(),
              onChanged: (v) => setState(() => line.selectedCategory = v!),
            ),

            if (line.selectedCategory == 'Alcoholic') ...[
              const SizedBox(height: 12),
              AppDropdown<CrateSizeGroupData>(
                labelText: 'Crate Company *',
                value: line.selectedCrateGroup,
                items: _crateSizeGroups.map((cg) {
                  return DropdownMenuItem(
                    value: cg,
                    child: Text(
                      '${cg.name} (${cg.crateSizeLabel[0].toUpperCase()}${cg.crateSizeLabel.substring(1)})',
                    ),
                  );
                }).toList(),
                onChanged: (v) => setState(() => line.selectedCrateGroup = v),
              ),
            ],

            const SizedBox(height: 12),

            AppDropdown<Supplier>(
              labelText: 'Supplier *',
              value: line.selectedSupplier,
              items: ref.read(supplierServiceProvider).getAll().map((s) {
                return DropdownMenuItem(value: s, child: Text(s.name));
              }).toList(),
              onChanged: (val) => setState(() => line.selectedSupplier = val),
            ),

            const SizedBox(height: 12),

            _inputField(
              'Retail Price',
              line.retailPriceCtrl,
              '0',
              isNumber: true,
              isCurrency: true,
            ),

            const SizedBox(height: 12),

            _inputField(
              'Qty (${line.selectedProduct?.unit ?? ''}) *',
              line.qtyCtrl,
              '0',
              isNumber: true,
            ),

            // ── TRACK EMPTIES ──────────────────────────────────────────────
            if (line.selectedProduct?.unit.toLowerCase() == 'bottle') ...[
              const SizedBox(height: 8),
              CheckboxListTile(
                value: line.trackEmpties,
                onChanged: (v) =>
                    setState(() => line.trackEmpties = v ?? false),
                title: const Text('Track empty crate returns'),
                subtitle: const Text(
                  'Enables deposit and crate return flow when this product is sold',
                ),
                controlAffinity: ListTileControlAffinity.leading,
                contentPadding: EdgeInsets.zero,
                dense: true,
              ),
            ],

            SizedBox(height: context.getRSize(16)),
            Align(
              alignment: Alignment.centerRight,
              child: Text(
                'Line Total: ${formatCurrency(line.lineTotal)}',
                style: TextStyle(
                  color: _subtext,
                  fontWeight: FontWeight.bold,
                  fontSize: context.getRFontSize(14),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSummaryBar(
    BuildContext context,
    double grandTotal,
    ScrollController scrollController,
  ) {
    return Container(
      padding: EdgeInsets.fromLTRB(
        context.getRSize(16),
        context.getRSize(12),
        context.getRSize(16),
        context.deviceBottomPadding + context.getRSize(16),
      ),
      decoration: BoxDecoration(
        color: _surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 10,
            offset: const Offset(0, -4),
          ),
        ],
      ),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Grand Total',
                    style: TextStyle(
                      color: _subtext,
                      fontSize: context.getRFontSize(14),
                    ),
                  ),
                  Text(
                    formatCurrency(grandTotal),
                    style: TextStyle(
                      color: _text,
                      fontWeight: FontWeight.w800,
                      fontSize: context.getRFontSize(22),
                    ),
                  ),
                ],
              ),
              AppButton(
                text: 'Add Item',
                icon: FontAwesomeIcons.plus.data,
                variant: AppButtonVariant.ghost,
                isFullWidth: false,
                onPressed: () => _addLine(scrollController),
              ),
            ],
          ),
          SizedBox(height: context.getRSize(16)),
          SizedBox(
            width: double.infinity,
            child: AppButton(
              text: 'Confirm Delivery',
              size: AppButtonSize.large,
              onPressed: _submit,
            ),
          ),
        ],
      ),
    );
  }
}
