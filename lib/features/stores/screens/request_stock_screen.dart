import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/stores/van_store.dart';
import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/theme/design_tokens.dart';
import 'package:reebaplus_pos/core/utils/notifications.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/features/stores/state/stock_request_list.dart';
import 'package:reebaplus_pos/features/stores/widgets/request_product_grid.dart';
import 'package:reebaplus_pos/features/stores/widgets/stock_request_quantity_sheet.dart';
import 'package:reebaplus_pos/features/stores/widgets/stock_request_review_sheet.dart';
import 'package:reebaplus_pos/shared/services/ui_hint_service.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:reebaplus_pos/shared/widgets/app_dropdown.dart';
import 'package:reebaplus_pos/shared/widgets/app_input.dart';
import 'package:reebaplus_pos/shared/widgets/coach_hint_banner.dart';
import 'package:reebaplus_pos/shared/widgets/glassy_scaffold.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/fly_to_cart.dart';

/// Keys for tests.
abstract final class RequestStockKeys {
  static const scroll = Key('request-stock-scroll');
  static const search = Key('request-stock-search');
  static const hint = Key('request-stock-hint');
  static const reviewBar = Key('request-stock-review-bar');
  static const emptyState = Key('request-stock-empty');
}

/// Raise a stock-transfer REQUEST (§16.8.2). Requester-initiated: the store that
/// NEEDS stock asks a holder store to send it. `pending` rows are written — no
/// stock moves until the holder accepts and dispatches.
///
/// Picks **several products at once**, like POS (#380): browse or search the
/// source store's in-stock products, tap a tile to add one, tap and hold to
/// type a quantity, then "N items · Review request" opens the review sheet
/// (stepper + remove per line) and "Send request" confirms and writes one
/// `pending` row per product in ONE transaction
/// (`StockTransferDao.requestTransfers`) — all saved or none.
///
/// At most one of [fixedDestStoreId] / [fixedSourceStoreId] is supplied by
/// the caller, depending on the entry point:
/// - From your OWN store details (you need stock): pass [fixedDestStoreId] —
///   the user picks which other store to request FROM.
/// - From another store you're browsing (its inventory): pass
///   [fixedSourceStoreId] — the destination defaults to your selectable store.
/// - From Home's Stock Transfer quick action (#362): the locked store as
///   [fixedDestStoreId], or NEITHER under All Stores — then both pickers show
///   and the user chooses both ends (the sole-selectable-store auto-fill of the
///   destination still applies). Vans are never offered, and the two ends must
///   differ, in every mode.
///
/// Changing the source store clears the list (each store has different
/// stock); with products on it the user is asked first.
class RequestStockScreen extends ConsumerStatefulWidget {
  final String? fixedDestStoreId;
  final String? fixedSourceStoreId;

  const RequestStockScreen({
    super.key,
    this.fixedDestStoreId,
    this.fixedSourceStoreId,
  }) : assert(
         fixedDestStoreId == null || fixedSourceStoreId == null,
         'Supply at most one of fixedDestStoreId / fixedSourceStoreId.',
       );

  @override
  ConsumerState<RequestStockScreen> createState() => _RequestStockScreenState();
}

class _RequestStockScreenState extends ConsumerState<RequestStockScreen> {
  StoreData? _sourceStore;
  StoreData? _destStore;

  final TextEditingController _searchCtrl = TextEditingController();
  String _query = '';
  bool _showHint = false;
  bool _submitting = false;

  /// Bumped to rebuild the source picker on its current value after the user
  /// backs out of a store change (the dropdown already shows what they tapped).
  int _sourcePickerRevision = 0;

  @override
  void initState() {
    super.initState();
    uiHintService.shouldShow(UiHintService.hintRequestStockGestures).then((
      show,
    ) {
      if (show && mounted) {
        setState(() => _showHint = true);
        uiHintService.markShown(UiHintService.hintRequestStockGestures);
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // #140 — a van is loaded through the van dispatch flow (#141), never
      // through the generic store-transfer path, so it is not offered as either
      // endpoint here (van-sales spec §7.2).
      final all = withoutVans(
        ref.read(allStoresProvider).valueOrNull ?? const <StoreData>[],
      );
      final selectable = ref.read(selectableStoresProvider);
      StoreData? findIn(List<StoreData> list, String? id) =>
          id == null ? null : list.where((s) => s.id == id).firstOrNull;

      setState(() {
        _sourceStore = findIn(all, widget.fixedSourceStoreId);
        _destStore = findIn(all, widget.fixedDestStoreId);
        // Auto-fill the destination from the viewer's sole selectable store
        // when entering from another store's inventory.
        if (_destStore == null && widget.fixedDestStoreId == null) {
          final candidates = selectable
              .where((s) => s.id != _sourceStore?.id)
              .toList();
          if (candidates.length == 1) _destStore = candidates.first;
        }
      });
    });
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  // ── Store pickers ─────────────────────────────────────────────────────────

  Future<void> _changeSource(StoreData? next) async {
    if (next?.id == _sourceStore?.id) return;
    final items = ref.read(stockRequestListProvider);
    if (items.isNotEmpty) {
      final from = _sourceStore?.name ?? 'this store';
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Change the store?'),
          content: Text(
            'Your list has ${items.length} '
            '${items.length == 1 ? 'product' : 'products'} from $from. '
            'Each store has different stock, so changing the store clears '
            'the list.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Keep list'),
            ),
            AppButton(
              text: 'Clear and change',
              size: AppButtonSize.small,
              isFullWidth: false,
              onPressed: () => Navigator.pop(ctx, true),
            ),
          ],
        ),
      );
      if (!mounted) return;
      if (ok != true) {
        setState(() => _sourcePickerRevision++);
        return;
      }
    }
    ref.read(stockRequestListProvider.notifier).clear();
    setState(() {
      _sourceStore = next;
      if (_destStore?.id == next?.id) _destStore = null;
      _searchCtrl.clear();
      _query = '';
    });
  }

  void _changeDest(StoreData? next) {
    setState(() => _destStore = next);
  }

  // ── Adding products ───────────────────────────────────────────────────────

  void _add(ProductDataWithStock item) {
    ref.read(stockRequestListProvider.notifier).add(item.product);
  }

  Future<void> _chooseQuantity(ProductDataWithStock item) async {
    HapticFeedback.mediumImpact();
    final current = quantityOnRequest(
      ref.read(stockRequestListProvider),
      item.product.id,
    );
    final qty = await StockRequestQuantitySheet.show(
      context,
      productName: item.product.name,
      sourceStoreName: _sourceStore?.name ?? '',
      available: item.totalStock,
      initialQuantity: current > 0 ? current : 1,
    );
    if (!mounted || qty == null) return;
    ref.read(stockRequestListProvider.notifier).setQuantity(item.product, qty);
  }

  // ── Review → confirm → send ───────────────────────────────────────────────

  Future<void> _review(Map<String, String> categoryNames) async {
    final src = _sourceStore;
    if (src == null) return;
    FocusScope.of(context).unfocus();
    final send = await StockRequestReviewSheet.show(
      context,
      sourceStoreId: src.id,
      sourceStoreName: src.name,
      destStoreName: _destStore?.name,
      categoryNames: categoryNames,
    );
    if (!mounted || send != true) return;
    await _confirmAndSend();
  }

  Future<void> _confirmAndSend() async {
    // Write-boundary re-check (layer 3, hard rule #6).
    if (!ref
        .read(currentUserPermissionsProvider)
        .contains('stores.request_transfer')) {
      return;
    }

    final src = _sourceStore;
    final dst = _destStore;
    final items = ref.read(stockRequestListProvider);

    if (src == null) {
      AppNotification.showError(
        context,
        'Please select a store to request from.',
      );
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
    if (items.isEmpty) {
      AppNotification.showError(context, 'Add at least one product.');
      return;
    }
    // Only products the source still has: its stock may have moved since
    // the product was added.
    final inStock = {
      for (final p
          in ref.read(productsByStoreProvider(src.id)).valueOrNull ??
              const <ProductDataWithStock>[])
        if (p.totalStock > 0) p.product.id,
    };
    final gone = items.where((i) => !inStock.contains(i.product.id)).toList();
    if (gone.isNotEmpty) {
      AppNotification.showError(
        context,
        '${src.name} has no ${gone.first.product.name} left. '
        'Remove it to send.',
      );
      return;
    }

    final confirmed = await _showConfirmDialog(
      sourceName: src.name,
      destName: dst.name,
      productCount: items.length,
      units: totalRequestedUnits(items),
    );
    if (!mounted || confirmed != true) return;

    final currentUser = ref.read(authProvider).currentUser;
    if (currentUser == null) return;

    setState(() => _submitting = true);
    try {
      await ref
          .read(databaseProvider)
          .stockTransferDao
          .requestTransfers(
            fromStoreId: src.id,
            toStoreId: dst.id,
            lines: [
              for (final i in items)
                (productId: i.product.id, quantity: i.quantity),
            ],
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

  Future<bool?> _showConfirmDialog({
    required String sourceName,
    required String destName,
    required int productCount,
    required int units,
  }) {
    final t = Theme.of(context);
    Widget row(String label, String value) => Padding(
      padding: EdgeInsets.symmetric(vertical: context.getRSize(4)),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: context.getRSize(96),
            child: Text(label, style: t.textTheme.bodySmall),
          ),
          Expanded(child: Text(value, style: t.textTheme.titleMedium)),
        ],
      ),
    );
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Send this request?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            row('From', sourceName),
            row('Deliver to', destName),
            row(
              'Products',
              '$productCount ${productCount == 1 ? 'product' : 'products'}, '
                  '$units ${units == 1 ? 'unit' : 'units'}',
            ),
            SizedBox(height: context.getRSize(12)),
            Text(
              '$sourceName will be asked to send these. No stock moves until '
              'they accept and dispatch.',
              style: t.textTheme.bodySmall,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          AppButton(
            text: 'Send request',
            size: AppButtonSize.small,
            isFullWidth: false,
            onPressed: () => Navigator.pop(ctx, true),
          ),
        ],
      ),
    );
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final allStores = withoutVans(
      ref.watch(allStoresProvider).valueOrNull ?? const <StoreData>[],
    );
    final selectable = ref.watch(selectableStoresProvider);
    final items = ref.watch(stockRequestListProvider);
    final lexicon = ref.watch(industryLexiconProvider);
    final categoryNames = {
      for (final c
          in ref.watch(allCategoriesProvider).valueOrNull ??
              const <CategoryData>[])
        c.id: c.name,
    };

    final src = _sourceStore;
    final inStock = src == null
        ? const <ProductDataWithStock>[]
        : (ref.watch(productsByStoreProvider(src.id)).valueOrNull ??
                  const <ProductDataWithStock>[])
              .where((p) => p.totalStock > 0 && !p.product.isDeleted)
              .toList();
    final q = _query.trim().toLowerCase();
    final shown = q.isEmpty
        ? inStock
        : inStock
              .where(
                (p) =>
                    p.product.name.toLowerCase().contains(q) ||
                    (p.product.subtitle?.toLowerCase().contains(q) ?? false),
              )
              .toList();

    final gutter = context.getRSize(16);

    return GlassyScaffold(
      title: 'Request Stock',
      body: LayoutBuilder(
        builder: (context, _) {
          // Hidden while the keyboard is up (searching), like POS's View Cart
          // bar. Read from the raw view: the frame's Scaffold has already taken
          // the keyboard out of this screen's MediaQuery. The LayoutBuilder
          // re-runs this when the keyboard resizes the screen.
          final view = View.maybeOf(context);
          final keyboardUp =
              view != null &&
              MediaQueryData.fromView(view).viewInsets.bottom > 0;
          final showBar = items.isNotEmpty && !keyboardUp;

          return Column(
            children: [
              Expanded(
                child: CustomScrollView(
                  key: RequestStockKeys.scroll,
                  keyboardDismissBehavior:
                      ScrollViewKeyboardDismissBehavior.onDrag,
                  slivers: [
                    SliverPadding(
                      padding: EdgeInsets.fromLTRB(gutter, gutter, gutter, 0),
                      sliver: SliverToBoxAdapter(
                        child: _StorePickers(
                          source: _sourceStore,
                          dest: _destStore,
                          sourceLocked: widget.fixedSourceStoreId != null,
                          destLocked: widget.fixedDestStoreId != null,
                          sourceOptions: allStores
                              .where((s) => s.id != _destStore?.id)
                              .toList(),
                          destOptions: selectable
                              .where((s) => s.id != _sourceStore?.id)
                              .toList(),
                          sourcePickerKey: ValueKey(
                            'request-source-$_sourcePickerRevision',
                          ),
                          onSourceChanged: _changeSource,
                          onDestChanged: _changeDest,
                        ),
                      ),
                    ),
                    SliverPadding(
                      padding: EdgeInsets.fromLTRB(
                        gutter,
                        context.getRSize(12),
                        gutter,
                        0,
                      ),
                      sliver: SliverToBoxAdapter(
                        child: AppInput(
                          key: RequestStockKeys.search,
                          controller: _searchCtrl,
                          enabled: src != null,
                          hintText: src == null
                              ? 'Pick the store to request from first'
                              : 'Search ${lexicon.itemPluralLower} at '
                                    '${src.name}',
                          prefixIcon: Icon(
                            AppIcons.search,
                            size: context.getRSize(18),
                          ),
                          textInputAction: TextInputAction.search,
                          onChanged: (v) => setState(() => _query = v),
                        ),
                      ),
                    ),
                    if (_showHint && inStock.isNotEmpty)
                      SliverPadding(
                        padding: EdgeInsets.fromLTRB(
                          gutter,
                          context.getRSize(12),
                          gutter,
                          0,
                        ),
                        sliver: SliverToBoxAdapter(
                          child: CoachHintBanner(
                            key: RequestStockKeys.hint,
                            message:
                                'Tap a ${lexicon.itemLower} to add it to the '
                                'request, or tap and hold to choose a '
                                'quantity.',
                            onDismiss: () {
                              setState(() => _showHint = false);
                              uiHintService.markDismissed(
                                UiHintService.hintRequestStockGestures,
                              );
                            },
                          ),
                        ),
                      ),
                    SliverToBoxAdapter(
                      child: SizedBox(height: context.getRSize(16)),
                    ),
                    if (shown.isEmpty)
                      SliverFillRemaining(
                        hasScrollBody: false,
                        child: _EmptyState(
                          key: RequestStockKeys.emptyState,
                          message: src == null
                              ? 'Choose the store to request from to see '
                                    'what it has.'
                              : inStock.isEmpty
                              ? '${src.name} has no ${lexicon.itemPluralLower} '
                                    'in stock.'
                              : 'No ${lexicon.itemPluralLower} match '
                                    '"${_query.trim()}".',
                        ),
                      )
                    else
                      RequestProductGrid(
                        products: shown,
                        categoryNames: categoryNames,
                        quantityOf: (id) => quantityOnRequest(items, id),
                        onAdd: _add,
                        onChooseQuantity: _chooseQuantity,
                      ),
                    SliverToBoxAdapter(
                      child: SizedBox(
                        height:
                            gutter +
                            (showBar ? 0 : context.deviceBottomPadding),
                      ),
                    ),
                  ],
                ),
              ),
              if (showBar)
                _ReviewBar(
                  itemCount: items.length,
                  busy: _submitting,
                  onPressed: () => _review(categoryNames),
                ),
            ],
          );
        },
      ),
    );
  }
}

/// "Request from store" and "Deliver to store", side by side. A fixed end
/// shows as a locked field; the other is a dropdown.
class _StorePickers extends StatelessWidget {
  const _StorePickers({
    required this.source,
    required this.dest,
    required this.sourceLocked,
    required this.destLocked,
    required this.sourceOptions,
    required this.destOptions,
    required this.sourcePickerKey,
    required this.onSourceChanged,
    required this.onDestChanged,
  });

  final StoreData? source;
  final StoreData? dest;
  final bool sourceLocked;
  final bool destLocked;
  final List<StoreData> sourceOptions;
  final List<StoreData> destOptions;
  final Key sourcePickerKey;
  final ValueChanged<StoreData?> onSourceChanged;
  final ValueChanged<StoreData?> onDestChanged;

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).textTheme.bodySmall?.color;
    Widget picker({
      required Key? key,
      required String label,
      required StoreData? value,
      required List<StoreData> options,
      required ValueChanged<StoreData?> onChanged,
    }) => AppDropdown<StoreData>(
      key: key,
      labelText: label,
      hintText: 'Select a store',
      value: value,
      prefixIcon: Icon(AppIcons.store, size: 14, color: muted),
      items: [
        for (final s in options)
          DropdownMenuItem(
            value: s,
            child: Text(s.name, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
      ],
      onChanged: onChanged,
    );

    final from = sourceLocked
        ? _LockedStoreField(label: 'Request from store', name: source?.name)
        : picker(
            key: sourcePickerKey,
            label: 'Request from store',
            value: source,
            options: sourceOptions,
            onChanged: onSourceChanged,
          );
    final to = destLocked
        ? _LockedStoreField(label: 'Deliver to store', name: dest?.name)
        : picker(
            key: null,
            label: 'Deliver to store',
            value: dest,
            options: destOptions,
            onChanged: onDestChanged,
          );
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(child: from),
        SizedBox(width: context.getRSize(12)),
        Expanded(child: to),
      ],
    );
  }
}

class _LockedStoreField extends StatelessWidget {
  const _LockedStoreField({required this.label, required this.name});

  final String label;
  final String? name;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.color;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: t.textTheme.labelMedium?.copyWith(color: muted)),
        SizedBox(height: context.getRSize(8)),
        Container(
          width: double.infinity,
          constraints: const BoxConstraints(
            minHeight: kMinInteractiveDimension,
          ),
          padding: EdgeInsets.symmetric(horizontal: context.getRSize(14)),
          decoration: BoxDecoration(
            color: t.inputDecorationTheme.fillColor ?? t.colorScheme.surface,
            borderRadius: BorderRadius.circular(AppSpacing.borderRadiusM),
            border: Border.all(color: t.dividerColor),
          ),
          child: Row(
            children: [
              Icon(AppIcons.store, size: context.getRSize(14), color: muted),
              SizedBox(width: context.getRSize(10)),
              Expanded(
                child: Text(
                  name ?? '—',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: context
                      .semiBoldStyle(14)
                      .copyWith(color: t.colorScheme.onSurface),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).textTheme.bodySmall?.color;
    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: context.getRSize(32),
        vertical: context.getRSize(24),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            AppIcons.inventory,
            size: context.getRSize(40),
            color: muted?.withValues(alpha: 0.5),
          ),
          SizedBox(height: context.getRSize(12)),
          Text(
            message,
            textAlign: TextAlign.center,
            style: context.semiBoldStyle(14).copyWith(color: muted),
          ),
        ],
      ),
    );
  }
}

/// "N items · Review request" at the foot of the screen; the fly-to target
/// for added products.
class _ReviewBar extends StatelessWidget {
  const _ReviewBar({
    required this.itemCount,
    required this.busy,
    required this.onPressed,
  });

  final int itemCount;
  final bool busy;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final gutter = context.getRSize(16);
    return Container(
      padding: EdgeInsets.fromLTRB(
        gutter,
        context.getRSize(12),
        gutter,
        context.getRSize(12) + context.deviceBottomPadding,
      ),
      decoration: BoxDecoration(
        color: t.colorScheme.surface,
        border: Border(top: BorderSide(color: t.dividerColor)),
      ),
      child: FlyTarget(
        id: FlyTargetId.stockRequest,
        child: AppButton(
          key: RequestStockKeys.reviewBar,
          text: busy
              ? 'Sending…'
              : '$itemCount ${itemCount == 1 ? 'item' : 'items'} · '
                    'Review request',
          trailingIcon: AppIcons.chevronRight,
          isFullWidth: true,
          onPressed: busy ? null : onPressed,
        ),
      ),
    );
  }
}
