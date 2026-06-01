import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/features/inventory/data/inventory_data.dart';
import 'package:reebaplus_pos/features/inventory/data/models/inventory_item.dart';
import 'package:reebaplus_pos/features/inventory/data/models/inventory_log.dart';
import 'package:reebaplus_pos/core/utils/currency_input_formatter.dart';
import 'package:reebaplus_pos/features/stores/data/models/store.dart';
import 'package:reebaplus_pos/shared/widgets/app_dropdown.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:reebaplus_pos/core/utils/notifications.dart';
import 'package:reebaplus_pos/shared/widgets/app_input.dart';

class StockTransferScreen extends ConsumerStatefulWidget {
  const StockTransferScreen({super.key});

  @override
  ConsumerState<StockTransferScreen> createState() => _StockTransferScreenState();
}

class _StockTransferScreenState extends ConsumerState<StockTransferScreen> {
  Store? _sourceStore;
  Store? _destinationStore;
  InventoryItem? _selectedProduct;

  final TextEditingController _productCtrl = TextEditingController();
  final TextEditingController _priceCtrl = TextEditingController();
  final TextEditingController _qtyCtrl = TextEditingController();
  Color get _bg => Theme.of(context).scaffoldBackgroundColor;
  Color get _surface => Theme.of(context).colorScheme.surface;
  Color get _text => Theme.of(context).colorScheme.onSurface;
  Color get _subtext =>
      Theme.of(context).textTheme.bodySmall?.color ??
      Theme.of(context).iconTheme.color!;
  Color get _border => Theme.of(context).dividerColor;

  @override
  void initState() {
    super.initState();
    if (kStores.isNotEmpty) {
      _sourceStore = kStores.first;
      if (kStores.length > 1) {
        _destinationStore = kStores[1];
      }
    }
  }

  @override
  void dispose() {
    _productCtrl.dispose();
    _priceCtrl.dispose();
    _qtyCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final qty = double.tryParse(_qtyCtrl.text) ?? 0;

    if (_sourceStore == null || _destinationStore == null) {
      _showError('Please select both source and destination stores.');
      return;
    }

    if (_sourceStore!.id == _destinationStore!.id) {
      _showError('Source and destination stores cannot be the same.');
      return;
    }

    if (_selectedProduct == null) {
      _showError('Please select a product.');
      return;
    }

    if (qty <= 0) {
      _showError('Please enter a quantity greater than 0.');
      return;
    }

    final available = _selectedProduct!.getStockForStore(
      _sourceStore!.id,
    );
    if (qty > available) {
      _showError(
        'Insufficient stock in ${_sourceStore!.name}. Available: ${available.toInt()}',
      );
      return;
    }

    // Perform Transfer
    setState(() {
      final newStockMap = Map<String, double>.from(
        _selectedProduct!.storeStock,
      );

      // Deduct from source
      newStockMap[_sourceStore!.id] = available - qty;

      // Add to destination
      final destCurrent = _selectedProduct!.getStockForStore(
        _destinationStore!.id,
      );
      newStockMap[_destinationStore!.id] = destCurrent + qty;

      _selectedProduct!.storeStock = newStockMap;

      // Log Inventory Movement
      kInventoryLogs.add(
        InventoryLog(
          timestamp: DateTime.now(),
          user: 'System (Transfer)',
          itemId: _selectedProduct!.id,
          itemName: _selectedProduct!.productName,
          action: 'transfer',
          previousValue: available, // Show source stock before
          newValue: available - qty, // Show source stock after
          note:
              'Stock Transfer: ${_sourceStore!.name} -> ${_destinationStore!.name}',
        ),
      );
    });

    // Log Activity (Source)
    await ref.read(activityLogProvider).logAction(
      "Stock Transfer (Out)",
      "Transferred ${qty.toInt()} ${_selectedProduct!.productName} OUT to ${_destinationStore!.name}",
      productId: _selectedProduct!.id,
      storeId: _sourceStore!.id,
    );

    // Log Activity (Destination)
    await ref.read(activityLogProvider).logAction(
      "Stock Transfer (In)",
      "Transferred ${qty.toInt()} ${_selectedProduct!.productName} IN from ${_sourceStore!.name}",
      productId: _selectedProduct!.id,
      storeId: _destinationStore!.id,
    );

    if (!mounted) return;

    AppNotification.showSuccess(
      context,
      'Successfully transferred ${qty.toInt()} items.',
    );

    Navigator.pop(context);
  }

  void _showError(String msg) {
    AppNotification.showError(context, msg);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: _surface,
        elevation: 0,
        iconTheme: IconThemeData(color: _text),
        title: Text(
          'Stock Transfer',
          style: TextStyle(
            color: _text,
            fontSize: rFontSize(context, 18),
            fontWeight: FontWeight.bold,
          ),
        ),
        centerTitle: true,
      ),
      body: Column(
        children: [
          Expanded(
            child: SingleChildScrollView(
              padding: EdgeInsets.all(context.getRSize(16)),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildStoreSection(context),
                  SizedBox(height: context.getRSize(24)),
                  _buildProductSection(context),
                ],
              ),
            ),
          ),
          Padding(
            padding: EdgeInsets.only(bottom: context.deviceBottomInset),
            child: AppButton(
              text: 'Confirm Transfer',
              icon: FontAwesomeIcons.rightLeft,
              onPressed: _submit,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStoreSection(BuildContext context) {
    return Container(
      padding: EdgeInsets.all(context.getRSize(16)),
      decoration: BoxDecoration(
        color: _surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Store Details',
            style: TextStyle(
              color: Theme.of(context).colorScheme.primary,
              fontWeight: FontWeight.bold,
              fontSize: context.getRFontSize(14),
            ),
          ),
          SizedBox(height: context.getRSize(16)),
          AppDropdown<Store>(
            labelText: 'Source Store',
            value: _sourceStore,
            items: kStores.map((w) {
              return DropdownMenuItem(value: w, child: Text(w.name));
            }).toList(),
            onChanged: (val) {
              setState(() {
                _sourceStore = val;
                if (_selectedProduct != null && val != null) {
                  final avail = _selectedProduct!.getStockForStore(val.id);
                  if (avail <= 0) {
                    _selectedProduct = null;
                    _productCtrl.clear();
                    _qtyCtrl.clear();
                  }
                }
              });
            },
          ),
          SizedBox(height: context.getRSize(16)),
          AppDropdown<Store>(
            labelText: 'Destination Store',
            value: _destinationStore,
            items: kStores.map((w) {
              return DropdownMenuItem(value: w, child: Text(w.name));
            }).toList(),
            onChanged: (val) => setState(() => _destinationStore = val),
          ),
        ],
      ),
    );
  }

  Widget _buildProductSection(BuildContext context) {
    return Container(
      padding: EdgeInsets.all(context.getRSize(16)),
      decoration: BoxDecoration(
        color: _surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Product & Quantity',
            style: TextStyle(
              color: Theme.of(context).colorScheme.primary,
              fontWeight: FontWeight.bold,
              fontSize: context.getRFontSize(14),
            ),
          ),
          SizedBox(height: context.getRSize(16)),
          Autocomplete<InventoryItem>(
            displayStringForOption: (item) => item.productName,
            optionsBuilder: (TextEditingValue textEditingValue) {
              if (textEditingValue.text.isEmpty) {
                return const Iterable<InventoryItem>.empty();
              }
              return kInventoryItems.where((InventoryItem item) {
                // 1. Match search text
                final matchesText = item.productName.toLowerCase().contains(
                  textEditingValue.text.toLowerCase(),
                );
                if (!matchesText) return false;

                // 2. Must have stock in selected source store
                if (_sourceStore == null) return false;
                final stock = item.getStockForStore(_sourceStore!.id);
                return stock > 0;
              });
            },
            optionsViewBuilder: (context, onSelected, options) {
              return Align(
                alignment: Alignment.topLeft,
                child: Material(
                  elevation: 4.0,
                  borderRadius: BorderRadius.circular(14),
                  color: _surface,
                  child: Container(
                    width:
                        MediaQuery.of(context).size.width -
                        64, // approximate width
                    constraints: const BoxConstraints(maxHeight: 200),
                    child: ListView.builder(
                      padding: EdgeInsets.zero,
                      shrinkWrap: true,
                      itemCount: options.length,
                      itemBuilder: (BuildContext context, int index) {
                        final InventoryItem option = options.elementAt(index);
                        final stock = option.getStockForStore(
                          _sourceStore?.id ?? "",
                        );
                        return InkWell(
                          onTap: () => onSelected(option),
                          child: Padding(
                            padding: const EdgeInsets.all(16.0),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Expanded(
                                  child: Text(
                                    option.productName,
                                    style: TextStyle(
                                      color: _text,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 2,
                                  ),
                                  decoration: BoxDecoration(
                                    color: Theme.of(context).colorScheme.primary
                                        .withValues(alpha: 0.1),
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: Text(
                                    '${stock.toInt()} in stock',
                                    style: TextStyle(
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.primary,
                                      fontSize: 12,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ),
              );
            },
            onSelected: (InventoryItem selection) {
              setState(() {
                _selectedProduct = selection;
                _productCtrl.text = selection.productName;
                if (_qtyCtrl.text.isEmpty) _qtyCtrl.text = '1';
                _priceCtrl.text = '0'; // Default price
              });
            },
            fieldViewBuilder:
                (context, controller, focusNode, onEditingComplete) {
                  if (controller.text.isEmpty && _productCtrl.text.isNotEmpty) {
                    controller.text = _productCtrl.text;
                  }
                  controller.addListener(() {
                    _productCtrl.text = controller.text;
                  });
                  return AppInput(
                    controller: controller,
                    focusNode: focusNode,
                    onFieldSubmitted: (_) => onEditingComplete(),
                    hintText: 'Start typing product name...',
                  );
                },
          ),
          if (_selectedProduct != null) ...[
            SizedBox(height: rSize(context, 8)),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4.0),
              child: Text(
                'Available in source: ${_selectedProduct!.getStockForStore(_sourceStore?.id ?? "").toInt()}',
                style: TextStyle(
                  color: _subtext,
                  fontSize: rFontSize(context, 12),
                ),
              ),
            ),
          ],
          SizedBox(height: rSize(context, 16)),
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    AppInput(
                      labelText: 'Unit Price ₦',
                      controller: _priceCtrl,
                      keyboardType: TextInputType.number,
                      inputFormatters: [CurrencyInputFormatter()],
                      hintText: '0.0',
                    ),
                  ],
                ),
              ),
              SizedBox(width: context.getRSize(12)),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    AppInput(
                      labelText: 'Quantity',
                      controller: _qtyCtrl,
                      keyboardType: TextInputType.number,
                      hintText: '0',
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
