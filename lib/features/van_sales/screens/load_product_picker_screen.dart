import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:reebaplus_pos/core/utils/notifications.dart';
import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/features/pos/widgets/category_filter_bar.dart';
import 'package:reebaplus_pos/features/pos/widgets/pos_header_parts.dart';
import 'package:reebaplus_pos/features/pos/widgets/product_grid.dart';
import 'package:reebaplus_pos/shared/scanner/scanner_providers.dart';
import 'package:reebaplus_pos/shared/utils/quantity.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:reebaplus_pos/shared/widgets/app_input.dart';
import 'package:reebaplus_pos/shared/widgets/glassy_scaffold.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/product_tile.dart';

/// Key on the tile for [productId] in the load picker.
ValueKey<String> loadPickerTileKey(String productId) =>
    ValueKey<String>('load-picker-tile-$productId');

/// Pick what goes on the van from the shop's own product grid (#790 step 2).
///
/// The same tiles, search, category chips and scanner the checkout uses, so
/// loading 16 to 30 items is taps, not typing names. One tap adds one; a long
/// press sets the number. It only COUNTS: prices, crates and the dispatch stay
/// on the Load Van screen, and nothing is written here.
///
/// Pops with `productId -> quantity` for every product it was opened with or
/// touched (0 = take it off the load). Back and Done both return it, so a
/// stray back press never throws away twenty taps.
class LoadProductPickerScreen extends ConsumerStatefulWidget {
  /// The store the van loads from; only its in-stock products are listed.
  final String sourceStoreId;
  final String sourceStoreName;

  /// What is already on the load.
  final Map<String, int> initial;

  const LoadProductPickerScreen({
    super.key,
    required this.sourceStoreId,
    required this.sourceStoreName,
    required this.initial,
  });

  @override
  ConsumerState<LoadProductPickerScreen> createState() =>
      _LoadProductPickerScreenState();
}

class _LoadProductPickerScreenState
    extends ConsumerState<LoadProductPickerScreen> {
  static const String _all = 'All';

  late final Map<String, int> _qty = {...widget.initial};
  String _query = '';
  String _category = _all;

  int get _itemCount => _qty.values.where((q) => q > 0).length;
  int get _unitCount => _qty.values.fold(0, (s, q) => s + q);

  /// Whole units only: a load is counted in whole items.
  int _maxFor(ProductDataWithStock p) => p.totalStock.floor();

  void _addOne(ProductDataWithStock p) {
    final now = _qty[p.product.id] ?? 0;
    if (now >= _maxFor(p)) {
      AppNotification.showError(
        context,
        'Only ${formatQty(p.totalStock)} of ${p.product.name} in '
        '${widget.sourceStoreName}.',
      );
      return;
    }
    HapticFeedback.selectionClick();
    setState(() => _qty[p.product.id] = now + 1);
  }

  Future<void> _typeQuantity(ProductDataWithStock p) async {
    final typed = await showDialog<int>(
      context: context,
      builder: (_) => _QuantityDialog(
        name: p.product.name,
        current: _qty[p.product.id] ?? 0,
        stockLabel: formatQty(p.totalStock),
      ),
    );
    if (typed == null || !mounted) return;
    final max = _maxFor(p);
    if (typed > max) {
      AppNotification.showError(
        context,
        'Only ${formatQty(p.totalStock)} of ${p.product.name} in '
        '${widget.sourceStoreName}.',
      );
    }
    setState(() => _qty[p.product.id] = math.min(typed, max));
  }

  /// Scan to add: each read adds one of the product it names. The session
  /// stays open until the scanner is closed, as at the checkout.
  Future<void> _scan(List<ProductDataWithStock> products) async {
    await ref
        .read(barcodeScannerProvider)
        .scanSession(
          context,
          onCode: (scanCtx, code) async {
            final trimmed = code.trim();
            if (trimmed.isEmpty) return;
            final matches = await ref
                .read(databaseProvider)
                .catalogDao
                .findProductsByBarcode(trimmed);
            if (!scanCtx.mounted || !mounted) return;
            final ids = {for (final m in matches) m.id};
            final here = [
              for (final p in products)
                if (ids.contains(p.product.id)) p,
            ];
            if (here.isEmpty) {
              AppNotification.showError(
                scanCtx,
                matches.isEmpty
                    ? 'No product has this barcode.'
                    : '${matches.first.name} is not in stock in '
                          '${widget.sourceStoreName}.',
              );
              return;
            }
            final p = here.first;
            final now = _qty[p.product.id] ?? 0;
            if (now >= _maxFor(p)) {
              AppNotification.showError(
                scanCtx,
                'Only ${formatQty(p.totalStock)} of ${p.product.name} in '
                '${widget.sourceStoreName}.',
              );
              return;
            }
            setState(() => _qty[p.product.id] = now + 1);
            AppNotification.showSuccess(
              scanCtx,
              '${p.product.name}: ${now + 1} on the load',
            );
          },
        );
  }

  void _done() => Navigator.pop(context, Map<String, int>.of(_qty));

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final lex = ref.watch(industryLexiconProvider);
    final all =
        (ref.watch(productsByStoreProvider(widget.sourceStoreId)).valueOrNull ??
                const <ProductDataWithStock>[])
            .where((p) => p.totalStock >= 1)
            .toList();
    final categoryNames = {
      for (final c
          in ref.watch(allCategoriesProvider).valueOrNull ??
              const <CategoryData>[])
        c.id: c.name,
    };
    // Only the categories that have something to load.
    final chips = <String>{
      for (final p in all)
        if (categoryNames[p.product.categoryId] != null)
          categoryNames[p.product.categoryId]!,
    }.toList()..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    if (_category != _all && !chips.contains(_category)) _category = _all;

    final q = _query.trim().toLowerCase();
    final shown = [
      for (final p in all)
        if ((_category == _all ||
                categoryNames[p.product.categoryId] == _category) &&
            (q.isEmpty || p.product.name.toLowerCase().contains(q)))
          p,
    ];
    final side = context.getRSize(16);
    final gap = context.getRSize(12);

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _done();
      },
      child: GlassyScaffold(
        title: 'Choose ${lex.itemPluralLower}',
        subtitle: 'From ${widget.sourceStoreName}',
        body: Column(
          children: [
            Expanded(
              child: CustomScrollView(
                slivers: [
                  PinnedHeaderSliver(
                    child: Container(
                      color: t.scaffoldBackgroundColor,
                      padding: EdgeInsets.fromLTRB(
                        side,
                        context.getRSize(8),
                        side,
                        context.getRSize(6),
                      ),
                      child: Column(
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: AppInput(
                                  key: const Key('load-picker-search'),
                                  hintText: 'Search ${lex.itemPluralLower}…',
                                  prefixIcon: const Icon(AppIcons.search),
                                  onChanged: (v) => setState(() => _query = v),
                                ),
                              ),
                              SizedBox(width: context.getRSize(8)),
                              IconButton.filledTonal(
                                key: const Key('load-picker-scan'),
                                onPressed: () => _scan(all),
                                icon: const Icon(AppIcons.barcode),
                                tooltip: 'Scan barcode',
                              ),
                            ],
                          ),
                          if (chips.length > 1) ...[
                            SizedBox(height: context.getRSize(8)),
                            CategoryFilterBar(
                              categories: [_all, ...chips],
                              selectedCategory: _category,
                              onCategorySelected: (c) =>
                                  setState(() => _category = c),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                  if (shown.isEmpty)
                    SliverFillRemaining(
                      hasScrollBody: false,
                      child: Center(
                        child: Padding(
                          padding: EdgeInsets.all(side),
                          child: Text(
                            all.isEmpty
                                ? 'Nothing in stock in '
                                      '${widget.sourceStoreName}.'
                                : 'No ${lex.itemPluralLower} found.',
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ),
                    )
                  else
                    SliverPadding(
                      padding: EdgeInsets.fromLTRB(
                        side,
                        context.getRSize(8),
                        side,
                        side,
                      ),
                      sliver: SliverLayoutBuilder(
                        builder: (context, constraints) {
                          // The checkout's own grid maths, so a tile here is
                          // the tile staff already know.
                          final width = constraints.crossAxisExtent + side * 2;
                          final columns = math.max(
                            kPosMinColumns,
                            width ~/ kPosTileMinWidth,
                          );
                          final tileWidth =
                              (constraints.crossAxisExtent -
                                  gap * (columns - 1)) /
                              columns;
                          final scale = posTileScale(tileWidth);
                          final tileHeight = posTileExtent(context);
                          return SliverGrid.builder(
                            gridDelegate:
                                SliverGridDelegateWithFixedCrossAxisCount(
                                  crossAxisCount: columns,
                                  mainAxisExtent: tileHeight * scale,
                                  crossAxisSpacing: gap,
                                  mainAxisSpacing: gap,
                                ),
                            itemCount: shown.length,
                            itemBuilder: (context, i) {
                              final p = shown[i];
                              final onLoad = _qty[p.product.id] ?? 0;
                              final tile = ProductTile(
                                name: p.product.name,
                                subtitle: posTileSubtitle(p.product),
                                subtitleMaxLines: posTileSubtitleLines(context),
                                showArt: !posShortHeight(context),
                                priceLabel: formatCurrency(
                                  p.product.retailerPriceKobo / 100,
                                ),
                                stockLabel: formatQty(p.totalStock),
                                stockLevel: p.totalStock <= kPosLowStockAt
                                    ? StockLevel.low
                                    : StockLevel.ok,
                                categoryName:
                                    categoryNames[p.product.categoryId],
                                photoPath: p.product.imagePath,
                                inCartQty: onLoad,
                                onTap: () => _addOne(p),
                                onLongPress: () => _typeQuantity(p),
                              );
                              return KeyedSubtree(
                                key: loadPickerTileKey(p.product.id),
                                child: scale < 1
                                    ? FittedBox(
                                        child: SizedBox(
                                          width: kPosTileDesignWidth,
                                          height: tileHeight,
                                          child: tile,
                                        ),
                                      )
                                    : tile,
                              );
                            },
                          );
                        },
                      ),
                    ),
                ],
              ),
            ),
            Padding(
              padding: EdgeInsets.fromLTRB(
                side,
                context.getRSize(8),
                side,
                context.getRSize(12) + context.deviceBottomPadding,
              ),
              child: AppButton(
                key: const Key('load-picker-done'),
                text: _itemCount == 0
                    ? 'Done'
                    : 'Done  ·  $_itemCount '
                          '${_itemCount == 1 ? 'item' : 'items'}, '
                          '$_unitCount ${_unitCount == 1 ? 'unit' : 'units'}',
                onPressed: _done,
                isFullWidth: true,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// "How many?" for one product. Its own widget so the text controller lives
/// exactly as long as the dialog (it is still on screen while it closes).
class _QuantityDialog extends StatefulWidget {
  final String name;
  final int current;
  final String stockLabel;

  const _QuantityDialog({
    required this.name,
    required this.current,
    required this.stockLabel,
  });

  @override
  State<_QuantityDialog> createState() => _QuantityDialogState();
}

class _QuantityDialogState extends State<_QuantityDialog> {
  late final TextEditingController _ctrl = TextEditingController(
    text: widget.current == 0 ? '' : '${widget.current}',
  );

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _set() => Navigator.pop(context, int.tryParse(_ctrl.text.trim()) ?? 0);

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      scrollable: true,
      title: Text(widget.name),
      content: AppInput(
        key: const Key('load-picker-qty'),
        controller: _ctrl,
        autofocus: true,
        labelText: 'How many?',
        hintText: 'In stock: ${widget.stockLabel}',
        keyboardType: TextInputType.number,
        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        onFieldSubmitted: (_) => _set(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        TextButton(
          key: const Key('load-picker-qty-ok'),
          onPressed: _set,
          child: const Text('Set'),
        ),
      ],
    );
  }
}
