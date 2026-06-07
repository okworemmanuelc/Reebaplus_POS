import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import 'package:reebaplus_pos/core/data/business_types.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/core/utils/notifications.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:reebaplus_pos/shared/widgets/app_dropdown.dart';
import 'package:reebaplus_pos/shared/widgets/app_input.dart';

class StockTransferScreen extends ConsumerStatefulWidget {
  const StockTransferScreen({super.key});

  @override
  ConsumerState<StockTransferScreen> createState() =>
      _StockTransferScreenState();
}

class _StockTransferScreenState extends ConsumerState<StockTransferScreen> {
  StoreData? _sourceStore;
  StoreData? _destinationStore;
  ProductDataWithStock? _selectedProduct;

  final TextEditingController _productCtrl = TextEditingController();
  final TextEditingController _qtyCtrl = TextEditingController();
  final TextEditingController _crateCtrl = TextEditingController();
  bool _submitting = false;

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
    // Default source = active locked store (if any).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final lockedId = ref.read(lockedStoreProvider).value;
      if (lockedId == null) return;
      final stores =
          ref.read(allStoresProvider).valueOrNull ?? const <StoreData>[];
      final match = stores.where((s) => s.id == lockedId).firstOrNull;
      if (match != null) setState(() => _sourceStore = match);
    });
  }

  @override
  void dispose() {
    _productCtrl.dispose();
    _qtyCtrl.dispose();
    _crateCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    // Write-boundary re-check (layer 3 of 3, hard rule #6).
    if (!ref.read(currentUserPermissionsProvider).contains('stores.manage')) {
      return;
    }

    final src = _sourceStore;
    final dst = _destinationStore;
    final product = _selectedProduct;
    final qty = int.tryParse(_qtyCtrl.text.trim()) ?? 0;
    final crateQty = int.tryParse(_crateCtrl.text.trim()) ?? 0;

    if (src == null || dst == null) {
      AppNotification.showError(
        context,
        'Please select both source and destination stores.',
      );
      return;
    }
    if (src.id == dst.id) {
      AppNotification.showError(
        context,
        'Source and destination stores cannot be the same.',
      );
      return;
    }
    if (product == null) {
      AppNotification.showError(context, 'Please select a product.');
      return;
    }
    if (qty <= 0) {
      AppNotification.showError(
        context,
        'Please enter a quantity greater than 0.',
      );
      return;
    }

    final currentUser = ref.read(authProvider).currentUser;
    if (currentUser == null) return;

    setState(() => _submitting = true);
    try {
      final db = ref.read(databaseProvider);
      final transferId = await db.stockTransferDao.createTransfer(
        fromStoreId: src.id,
        toStoreId: dst.id,
        productId: product.product.id,
        quantity: qty,
        initiatedBy: currentUser.id,
      );

      // Phase 3: optionally transfer empty crates alongside the product.
      final mfrId = product.product.manufacturerId;
      if (crateQty > 0 && mfrId != null) {
        await db.stockTransferDao.transferCrates(
          transferId: transferId,
          fromStoreId: src.id,
          toStoreId: dst.id,
          manufacturerId: mfrId,
          quantity: crateQty,
          performedBy: currentUser.id,
        );
      }

      if (!mounted) return;
      AppNotification.showSuccess(
        context,
        'Dispatched to ${dst.name} — awaiting confirmation.',
      );
      Navigator.pop(context);
    } catch (e) {
      if (!mounted) return;
      final msg = e.toString();
      if (msg.contains('insufficient_stock') ||
          msg.contains('InsufficientStock')) {
        AppNotification.showError(
          context,
          'Insufficient stock in ${src.name} for that quantity.',
        );
      } else if (msg.contains('insufficient_crates')) {
        AppNotification.showError(
          context,
          'Not enough empty crates in ${src.name} for that count.',
        );
      } else {
        AppNotification.showError(context, 'Transfer failed. Please retry.');
      }
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Layer 1 (render gate): only users with stores.manage see this screen.
    final canManage = hasPermission(ref, 'stores.manage');

    // Layer 2 (body-guard): replace body if permission was revoked mid-session.
    if (!canManage) {
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
        body: Center(
          child: Text(
            'You do not have permission to transfer stock.',
            style: TextStyle(color: _subtext),
          ),
        ),
      );
    }

    final stores =
        ref.watch(allStoresProvider).valueOrNull ?? const <StoreData>[];
    final sourceId = _sourceStore?.id;
    final products = sourceId != null
        ? (ref.watch(productsByStoreProvider(sourceId)).valueOrNull ??
              const <ProductDataWithStock>[])
              .where((p) => p.totalStock > 0)
              .toList()
        : const <ProductDataWithStock>[];

    final businessId = ref.read(authProvider).currentUser?.businessId;
    final businessType = ref.watch(localBusinessesProvider).valueOrNull
        ?.where((b) => b.id == businessId)
        .map((b) => b.type)
        .firstOrNull;
    final showCrates =
        isCrateBusiness(businessType) && _selectedProduct?.product.manufacturerId != null;

    return Scaffold(
      resizeToAvoidBottomInset: false,
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
                  _buildStoreSection(context, stores),
                  SizedBox(height: context.getRSize(24)),
                  _buildProductSection(context, products),
                  if (showCrates) ...[
                    SizedBox(height: context.getRSize(24)),
                    _buildCrateSection(context),
                  ],
                ],
              ),
            ),
          ),
          Padding(
            padding: EdgeInsets.only(
              bottom: context.deviceBottomPadding,
              left: context.getRSize(16),
              right: context.getRSize(16),
              top: context.getRSize(8),
            ),
            child: AppButton(
              text: _submitting ? 'Dispatching…' : 'Dispatch Transfer',
              icon: FontAwesomeIcons.rightLeft,
              onPressed: _submitting ? null : _submit,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCrateSection(BuildContext context) {
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
            'Empty Crates (optional)',
            style: TextStyle(
              color: Theme.of(context).colorScheme.primary,
              fontWeight: FontWeight.bold,
              fontSize: context.getRFontSize(14),
            ),
          ),
          SizedBox(height: context.getRSize(8)),
          Text(
            'Transfer empty crates alongside this product. Enter 0 to skip.',
            style: TextStyle(
              color: _subtext,
              fontSize: context.getRFontSize(12),
            ),
          ),
          SizedBox(height: context.getRSize(16)),
          AppInput(
            labelText: 'Crate Quantity',
            controller: _crateCtrl,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            hintText: '0',
          ),
        ],
      ),
    );
  }

  Widget _buildStoreSection(BuildContext context, List<StoreData> stores) {
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
          AppDropdown<StoreData>(
            labelText: 'Source Store',
            value: _sourceStore,
            items: stores.map((s) {
              return DropdownMenuItem(value: s, child: Text(s.name));
            }).toList(),
            onChanged: (val) {
              setState(() {
                _sourceStore = val;
                // Reset product if it no longer has stock in the new source.
                _selectedProduct = null;
                _productCtrl.clear();
                _qtyCtrl.clear();
              });
            },
          ),
          SizedBox(height: context.getRSize(16)),
          AppDropdown<StoreData>(
            labelText: 'Destination Store',
            value: _destinationStore,
            items: stores
                .where((s) => s.id != _sourceStore?.id)
                .map((s) => DropdownMenuItem(value: s, child: Text(s.name)))
                .toList(),
            onChanged: (val) => setState(() => _destinationStore = val),
          ),
        ],
      ),
    );
  }

  Widget _buildProductSection(
    BuildContext context,
    List<ProductDataWithStock> products,
  ) {
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
          Autocomplete<ProductDataWithStock>(
            displayStringForOption: (p) => p.product.name,
            optionsBuilder: (TextEditingValue v) {
              if (v.text.isEmpty) return const [];
              final q = v.text.toLowerCase();
              return products.where(
                (p) => p.product.name.toLowerCase().contains(q),
              );
            },
            optionsViewBuilder: (ctx, onSelected, options) {
              return Align(
                alignment: Alignment.topLeft,
                child: Material(
                  elevation: 4,
                  borderRadius: BorderRadius.circular(14),
                  color: _surface,
                  child: Container(
                    width: MediaQuery.of(ctx).size.width - 64,
                    constraints: const BoxConstraints(maxHeight: 200),
                    child: ListView.builder(
                      padding: EdgeInsets.zero,
                      shrinkWrap: true,
                      itemCount: options.length,
                      itemBuilder: (_, i) {
                        final p = options.elementAt(i);
                        return InkWell(
                          onTap: () => onSelected(p),
                          child: Padding(
                            padding: const EdgeInsets.all(16),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Expanded(
                                  child: Text(
                                    p.product.name,
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
                                    color: Theme.of(context)
                                        .colorScheme
                                        .primary
                                        .withValues(alpha: 0.1),
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: Text(
                                    '${p.totalStock} in stock',
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
            onSelected: (p) {
              setState(() {
                _selectedProduct = p;
                _productCtrl.text = p.product.name;
                if (_qtyCtrl.text.isEmpty) _qtyCtrl.text = '1';
              });
            },
            fieldViewBuilder: (ctx, controller, focusNode, onEditingComplete) {
              if (controller.text.isEmpty && _productCtrl.text.isNotEmpty) {
                controller.text = _productCtrl.text;
              }
              controller.addListener(() => _productCtrl.text = controller.text);
              return AppInput(
                controller: controller,
                focusNode: focusNode,
                onFieldSubmitted: (_) => onEditingComplete(),
                hintText: _sourceStore == null
                    ? 'Select a source store first'
                    : 'Start typing product name…',
                enabled: _sourceStore != null,
              );
            },
          ),
          if (_selectedProduct != null) ...[
            SizedBox(height: context.getRSize(8)),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Text(
                'Available in source: ${_selectedProduct!.totalStock}',
                style: TextStyle(
                  color: _subtext,
                  fontSize: rFontSize(context, 12),
                ),
              ),
            ),
          ],
          SizedBox(height: context.getRSize(16)),
          AppInput(
            labelText: 'Quantity',
            controller: _qtyCtrl,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            hintText: '0',
          ),
        ],
      ),
    );
  }
}
