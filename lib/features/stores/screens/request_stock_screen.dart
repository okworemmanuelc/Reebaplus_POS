import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/core/utils/notifications.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:reebaplus_pos/shared/widgets/app_dropdown.dart';
import 'package:reebaplus_pos/shared/widgets/app_input.dart';
import 'package:reebaplus_pos/shared/widgets/glassy_scaffold.dart';

/// Raise a stock-transfer REQUEST (§16.8.2). Requester-initiated: the store that
/// NEEDS stock asks a holder store to send it. A `pending` row is written — no
/// stock moves until the holder accepts and dispatches.
///
/// Exactly one of [fixedDestStoreId] / [fixedSourceStoreId] is supplied by the
/// caller, depending on the entry point:
/// - From your OWN store details (you need stock): pass [fixedDestStoreId] —
///   the user picks which other store to request FROM.
/// - From another store you're browsing (its inventory): pass
///   [fixedSourceStoreId] — the destination defaults to your selectable store.
class RequestStockScreen extends ConsumerStatefulWidget {
  final String? fixedDestStoreId;
  final String? fixedSourceStoreId;

  const RequestStockScreen({
    super.key,
    this.fixedDestStoreId,
    this.fixedSourceStoreId,
  }) : assert(
          (fixedDestStoreId == null) != (fixedSourceStoreId == null),
          'Supply exactly one of fixedDestStoreId / fixedSourceStoreId.',
        );

  @override
  ConsumerState<RequestStockScreen> createState() => _RequestStockScreenState();
}

class _RequestStockScreenState extends ConsumerState<RequestStockScreen> {
  StoreData? _sourceStore;
  StoreData? _destStore;
  ProductDataWithStock? _selectedProduct;

  final TextEditingController _productCtrl = TextEditingController();
  final TextEditingController _qtyCtrl = TextEditingController();
  bool _submitting = false;

  Color get _text => Theme.of(context).colorScheme.onSurface;
  Color get _subtext =>
      Theme.of(context).textTheme.bodySmall?.color ??
      Theme.of(context).iconTheme.color!;
  Color get _border => Theme.of(context).dividerColor;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final all = ref.read(allStoresProvider).valueOrNull ?? const <StoreData>[];
      final selectable = ref.read(selectableStoresProvider);
      StoreData? findIn(List<StoreData> list, String? id) =>
          id == null ? null : list.where((s) => s.id == id).firstOrNull;

      setState(() {
        _sourceStore = findIn(all, widget.fixedSourceStoreId);
        _destStore = findIn(all, widget.fixedDestStoreId);
        // Auto-fill the destination from the viewer's sole selectable store
        // when entering from another store's inventory.
        if (_destStore == null && widget.fixedDestStoreId == null) {
          final candidates =
              selectable.where((s) => s.id != _sourceStore?.id).toList();
          if (candidates.length == 1) _destStore = candidates.first;
        }
      });
    });
  }

  @override
  void dispose() {
    _productCtrl.dispose();
    _qtyCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    // Write-boundary re-check (layer 3, hard rule #6).
    if (!ref
        .read(currentUserPermissionsProvider)
        .contains('stores.request_transfer')) {
      return;
    }

    final src = _sourceStore;
    final dst = _destStore;
    final product = _selectedProduct;
    final qty = int.tryParse(_qtyCtrl.text.trim()) ?? 0;

    if (src == null) {
      AppNotification.showError(context, 'Please select a store to request from.');
      return;
    }
    if (dst == null) {
      AppNotification.showError(context, 'Please select which store needs it.');
      return;
    }
    if (src.id == dst.id) {
      AppNotification.showError(
        context,
        'The source and destination stores must differ.',
      );
      return;
    }
    if (product == null) {
      AppNotification.showError(context, 'Please select a product.');
      return;
    }
    if (qty <= 0) {
      AppNotification.showError(context, 'Enter a quantity greater than 0.');
      return;
    }

    final currentUser = ref.read(authProvider).currentUser;
    if (currentUser == null) return;

    setState(() => _submitting = true);
    try {
      await ref.read(databaseProvider).stockTransferDao.requestTransfer(
            fromStoreId: src.id,
            toStoreId: dst.id,
            productId: product.product.id,
            quantity: qty,
            requestedBy: currentUser.id,
          );
      if (!mounted) return;
      AppNotification.showSuccess(
        context,
        'Request sent to ${src.name} — awaiting dispatch.',
      );
      Navigator.pop(context);
    } catch (e) {
      if (!mounted) return;
      AppNotification.showError(context, 'Could not send the request. Retry.');
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  Widget _lockedStoreField(String label, String? storeName) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            color: _subtext,
            fontSize: context.getRFontSize(12),
            fontWeight: FontWeight.w600,
          ),
        ),
        SizedBox(height: context.getRSize(6)),
        Container(
          width: double.infinity,
          padding: EdgeInsets.symmetric(
            horizontal: context.getRSize(14),
            vertical: context.getRSize(14),
          ),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: _border),
          ),
          child: Row(
            children: [
              Icon(
                FontAwesomeIcons.store.data,
                size: context.getRSize(14),
                color: _subtext,
              ),
              SizedBox(width: context.getRSize(10)),
              Expanded(
                child: Text(
                  storeName ?? '—',
                  style: TextStyle(
                    color: _text,
                    fontWeight: FontWeight.w600,
                    fontSize: context.getRFontSize(14),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final allStores =
        ref.watch(allStoresProvider).valueOrNull ?? const <StoreData>[];
    final selectable = ref.watch(selectableStoresProvider);
    final sourceLocked = widget.fixedSourceStoreId != null;
    final destLocked = widget.fixedDestStoreId != null;

    final sourceId = _sourceStore?.id;
    final products = sourceId != null
        ? (ref.watch(productsByStoreProvider(sourceId)).valueOrNull ??
                const <ProductDataWithStock>[])
            .where((p) => p.totalStock > 0)
            .toList()
        : const <ProductDataWithStock>[];

    return GlassyScaffold(
      title: 'Request Stock',
      body: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
          context.getRSize(20),
          context.getRSize(20),
          context.getRSize(20),
          context.getRSize(20) + context.deviceBottomPadding,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Source store (the holder we request FROM).
            if (sourceLocked)
              _lockedStoreField('Request from store', _sourceStore?.name)
            else
              AppDropdown<StoreData>(
                labelText: 'Request from store',
                hintText: 'Select a store',
                value: _sourceStore,
                prefixIcon: Icon(
                  FontAwesomeIcons.store.data,
                  size: 14,
                  color: _subtext,
                ),
                items: allStores
                    .where((s) => s.id != _destStore?.id)
                    .map(
                      (s) => DropdownMenuItem(value: s, child: Text(s.name)),
                    )
                    .toList(),
                onChanged: (val) => setState(() {
                  _sourceStore = val;
                  if (_destStore?.id == val?.id) {
                    _destStore = null;
                  }
                  _selectedProduct = null;
                  _productCtrl.clear();
                  _qtyCtrl.clear();
                }),
              ),
            SizedBox(height: context.getRSize(16)),

            // Destination store (the requester — needs the stock).
            if (destLocked)
              _lockedStoreField('Deliver to store', _destStore?.name)
            else
              AppDropdown<StoreData>(
                labelText: 'Deliver to store',
                hintText: 'Select a store',
                value: _destStore,
                prefixIcon: Icon(
                  FontAwesomeIcons.store.data,
                  size: 14,
                  color: _subtext,
                ),
                items: selectable
                    .where((s) => s.id != _sourceStore?.id)
                    .map(
                      (s) => DropdownMenuItem(value: s, child: Text(s.name)),
                    )
                    .toList(),
                onChanged: (val) => setState(() {
                  _destStore = val;
                  if (_sourceStore?.id == val?.id) {
                    _sourceStore = null;
                    _selectedProduct = null;
                    _productCtrl.clear();
                    _qtyCtrl.clear();
                  }
                }),
              ),
            SizedBox(height: context.getRSize(16)),

            // Product picker (from the source store's in-stock products).
            Autocomplete<ProductDataWithStock>(
              displayStringForOption: (p) => p.product.name,
              optionsBuilder: (TextEditingValue v) {
                if (v.text.isEmpty) return const Iterable.empty();
                final q = v.text.toLowerCase();
                return products
                    .where((p) => p.product.name.toLowerCase().contains(q));
              },
              onSelected: (p) {
                setState(() {
                  _selectedProduct = p;
                  _productCtrl.text = p.product.name;
                  if (_qtyCtrl.text.isEmpty) _qtyCtrl.text = '1';
                });
              },
              fieldViewBuilder:
                  (ctx, controller, focusNode, onEditingComplete) {
                if (controller.text.isEmpty && _productCtrl.text.isNotEmpty) {
                  controller.text = _productCtrl.text;
                }
                controller.addListener(
                  () => _productCtrl.text = controller.text,
                );
                return AppInput(
                  controller: controller,
                  focusNode: focusNode,
                  labelText: 'Product',
                  onFieldSubmitted: (_) => onEditingComplete(),
                  prefixIcon: Icon(
                    FontAwesomeIcons.boxesStacked.data,
                    size: 14,
                    color: _subtext,
                  ),
                  hintText: _sourceStore == null
                      ? 'Pick a source store first'
                      : 'Start typing a product name…',
                  enabled: _sourceStore != null,
                );
              },
            ),
            if (_selectedProduct != null) ...[
              SizedBox(height: context.getRSize(6)),
              Text(
                'Available at ${_sourceStore?.name}: '
                '${_selectedProduct!.totalStock}',
                style: TextStyle(
                  color: _subtext,
                  fontSize: context.getRFontSize(12),
                ),
              ),
            ],
            SizedBox(height: context.getRSize(16)),

            AppInput(
              labelText: 'Quantity requested',
              controller: _qtyCtrl,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              hintText: '0',
            ),
            SizedBox(height: context.getRSize(24)),

            AppButton(
              text: _submitting ? 'Sending…' : 'Send Request',
              icon: FontAwesomeIcons.paperPlane.data,
              onPressed: _submitting ? null : _submit,
              isFullWidth: true,
            ),
          ],
        ),
      ),
    );
  }
}
