import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reebaplus_pos/core/theme/app_decorations.dart';
import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/theme/fixed_colors.dart';
import 'package:reebaplus_pos/core/utils/factory_barcode.dart';
import 'package:reebaplus_pos/features/inventory/widgets/inventory_parts.dart';
import 'package:reebaplus_pos/features/inventory/widgets/product_detail_cards.dart';
import 'package:reebaplus_pos/features/inventory/widgets/product_detail_figures.dart';
import 'package:reebaplus_pos/features/inventory/widgets/product_detail_parts.dart';
import 'package:reebaplus_pos/features/inventory/widgets/product_sales_history_cards.dart';
import 'package:reebaplus_pos/features/inventory/screens/product_stock_history_screen.dart';
import 'package:reebaplus_pos/features/inventory/widgets/update_product_sheet.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/redesign.dart';
import 'package:reebaplus_pos/core/result.dart';
import 'package:reebaplus_pos/core/permissions/permissions.dart';

import 'package:reebaplus_pos/shared/widgets/auto_lock_wrapper.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';

import 'package:reebaplus_pos/core/utils/currency_input_formatter.dart';
import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/features/inventory/data/models/inventory_item.dart';
import 'package:reebaplus_pos/features/inventory/widgets/catalogue_report_link.dart';
import 'package:reebaplus_pos/shared/widgets/app_dropdown.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/services/crash_reporter.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:reebaplus_pos/core/utils/notifications.dart';
import 'package:reebaplus_pos/shared/widgets/app_input.dart';
import 'package:reebaplus_pos/core/utils/product_unit.dart';
import 'package:reebaplus_pos/core/theme/colors.dart';

// ─────────────────────────────────────────────────────────────────────────────
// ProductDetailScreen — full-screen product information view (#487 PR 3)
//
// Read-only cards in the redesign's style. Nothing is edited inline: the
// Description and Sales Target have a small pencil pop-up, "Edit Product" opens
// the product editor, "Adjust Stock" the stock sheet, and Archive / Delete sit
// in Manage Product.
// ─────────────────────────────────────────────────────────────────────────────

class ProductDetailScreen extends ConsumerStatefulWidget {
  final InventoryItem item;
  final VoidCallback onUpdateStock;
  final String?
  selectedStoreId; // null = "All Stores" — quantity editing blocked

  /// The clock the Sales Target and expiry words read; tests pin it.
  @visibleForTesting
  final DateTime Function()? clock;

  const ProductDetailScreen({
    super.key,
    required this.item,
    required this.onUpdateStock,
    this.selectedStoreId,
    this.clock,
  });

  @override
  ConsumerState<ProductDetailScreen> createState() =>
      _ProductDetailScreenState();
}

enum _MenuAction { adjustStock, editProduct, report }

class _ProductDetailScreenState extends ConsumerState<ProductDetailScreen> {
  ProductData? _productData; // full DB row, kept live by the stream below

  List<ProductDaySales>? _salesDays;
  bool _contentReady = false; // deferred load flag
  String? _imagePath;

  // ── Role gating (master plan §16.6 / §16.7) ────────────────────────────────
  // Read (not watch) so these getters are safe to call from tap handlers; build
  // watches gateContextProvider, so the screen rebuilds when a role changes.
  // Editing (Edit Product, the Description pencil, Archive) is
  // `products.edit_price`; delete is its own `products.delete`; cost and the
  // profit rows are `products.edit_buying_price`; Adjust Stock needs
  // `stock.add` or `stock.adjust`. The Sales Target is CEO-only.
  bool get _canEdit => Gates.editProductPrice.allowsNow(ref);
  bool get _canDelete => Gates.deleteProduct.allowsNow(ref);
  bool get _canEditBuying => Gates.editBuyingPrice.allowsNow(ref);
  bool get _canAdjustStock => Gates.adjustStock.allowsNow(ref);
  // Add-stock is its own permission (§16.7), separate from adjust/remove. The
  // Adjust Stock sheet opens if the viewer holds either; the Add and Remove
  // modes inside are gated individually (stock.add vs stock.adjust).
  bool get _canAddStock => Gates.addStock.allowsNow(ref);
  bool get _canOpenAdjust => _canAddStock || _canAdjustStock;
  // Sales Target is CEO-only (a Manager may edit everything else but not the
  // target — explicit user requirement).
  bool get _isCeo => ref.read(currentUserRoleProvider)?.slug == 'ceo';

  /// Whether a stored `Bottle` reads "Bottle Crate" / "crates" (#487): only in
  /// a shop that counts empty crates. Watched, for the build-time labels.
  bool get _crates => businessTracksCrates(ref.watch(currentBusinessProvider));

  DateTime get _now => (widget.clock ?? DateTime.now)();

  @override
  void initState() {
    super.initState();
    _imagePath = widget.item.imagePath;

    // Defer heavy DB calls until after first frame.
    // _contentReady stays false until _loadProductData() finishes.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _loadProductData();
    });
  }

  Future<void> _loadProductData() async {
    final productId = widget.item.id;
    if (productId.isEmpty) {
      if (mounted) setState(() => _contentReady = true);
      return;
    }

    final db = ref.read(databaseProvider);
    final product = await db.catalogDao.findById(productId);
    // Resolve a renderable path for the photo — downloads from Storage once if
    // only the cloud URL is known, so a cross-device photo shows here and
    // renders offline from the cache. #78.
    final cachedPhoto = await ref
        .read(productImageServiceProvider)
        .ensureCached(productId: productId, imageUrl: product?.imageUrl);

    if (mounted) {
      setState(() {
        if (product != null) {
          _productData = product;
          if (cachedPhoto != null) _imagePath = cachedPhoto;
        }
      });
    }

    // Load the per-day sales for the Sales card (recognized sales only).
    final days = await db.ordersDao.getProductSalesByDay(productId, now: _now);
    if (mounted) {
      setState(() {
        _salesDays = days;
        _contentReady = true;
      });
    }
  }

  /// Re-read the Sales card's days after a stock change or a sale syncs in, so
  /// it stays live alongside the product fields.
  Future<void> _reloadDerived() async {
    final days = await ref
        .read(databaseProvider)
        .ordersDao
        .getProductSalesByDay(widget.item.id, now: _now);
    if (mounted) setState(() => _salesDays = days);
  }

  // ── Theme helpers ─────────────────────────────────────────────────────────
  Color get _bg => Theme.of(context).scaffoldBackgroundColor;
  Color get _surface => Theme.of(context).colorScheme.surface;
  Color get _text => Theme.of(context).colorScheme.onSurface;

  // ── Derived figures ───────────────────────────────────────────────────────
  String get _name => _productData?.name ?? widget.item.productName;
  String? get _unit => _productData?.unit ?? widget.item.unit;
  int get _alertAt =>
      _productData?.lowStockThreshold ?? widget.item.lowStockThreshold.toInt();
  // The saved description; the list row's subtitle only until the row loads.
  String get _description => _productData == null
      ? widget.item.subtitle
      : (_productData!.subtitle ?? '');
  bool get _archived => _productData != null && !_productData!.isAvailable;

  @override
  Widget build(BuildContext context) {
    ref.watch(
      currencySymbolProvider,
    ); // rebuild money displays when currency changes
    // Subscribe to permission changes so the role-gated UI rebuilds when the
    // role + its grants resolve locally. The `_canEdit` family reads the same
    // provider.
    ref.watch(gateContextProvider);

    // Realtime sync (§5): watch this product's row so an edit (or an archive)
    // on another device reflects here live, without leaving the screen.
    ref.listen<AsyncValue<List<ProductDataWithStock>>>(
      productsWithStockProvider(widget.selectedStoreId),
      (prev, next) {
        final rows = next.valueOrNull;
        if (rows == null || !mounted) return;
        final match = rows
            .where((r) => r.product.id == widget.item.id)
            .firstOrNull;
        if (match == null) return;
        setState(() => _productData = match.product);
      },
    );

    // A stock change for this product (an Adjust Stock, a sale, a sync) means
    // the Sales card may have moved too.
    ref.listen(productStockByStoreProvider(widget.item.id), (prev, next) {
      if (prev?.valueOrNull == null || next.valueOrNull == null) return;
      _reloadDerived();
    });

    // A sale records an order (and its stock delta). Watch the orders stream
    // directly so every sale (this device or synced from another) refreshes
    // the summary live, including one in another store.
    ref.listen(allOrdersProvider, (prev, next) {
      if (next.valueOrNull == null || !mounted) return;
      _reloadDerived();
    });

    if (!_contentReady) {
      return Scaffold(
        backgroundColor: _bg,
        body: const SafeArea(child: Center(child: CircularProgressIndicator())),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final wide = width >= kProductDetailThreeColumnWidth;
        return Container(
          decoration: AppDecorations.pageBackground(context),
          child: Scaffold(
            backgroundColor: Colors.transparent,
            resizeToAvoidBottomInset: false,
            appBar: _buildTopBar(context, wide),
            body: SafeArea(
              top: false,
              bottom: false,
              child: SingleChildScrollView(
                padding: EdgeInsets.fromLTRB(
                  _gutter(context, width),
                  context.getRSize(16),
                  _gutter(context, width),
                  context.getRSize(16) + context.deviceBottomPadding,
                ),
                child: _buildBody(context, width),
              ),
            ),
          ),
        );
      },
    );
  }

  double _gutter(BuildContext context, double width) => math.max(
    context.getRSize(16),
    (width - kProductDetailMaxContentWidth) / 2,
  );

  // ═══════════════════════════════════════════════════════════════════════════
  // TOP BAR — back, title, and the actions
  // ═══════════════════════════════════════════════════════════════════════════

  PreferredSizeWidget _buildTopBar(BuildContext context, bool wide) {
    final f =
        Theme.of(context).extension<AppFixedColors>() ?? AppFixedColors.light;
    final t = Theme.of(context);
    final canAdjust = _canOpenAdjust;
    final canEdit = _canEdit;
    final hasReport = _hasReportLink;
    // The wide bar shows Adjust Stock and Edit Product as buttons, so the menu
    // keeps only what is left; the phone bar keeps everything in the menu.
    final menuHasAdjust = !wide && canAdjust;
    final menuHasEdit = !wide && canEdit;
    final showMenu = menuHasAdjust || menuHasEdit || hasReport;
    return ProductDetailTopBar(
      height: inventoryTopBarHeight(context),
      onBack: () => Navigator.pop(context),
      actions: [
        if (wide && canAdjust)
          DetailTonalButton(
            label: 'Adjust Stock',
            icon: AppIcons.tune,
            fill: f.infoTint,
            ink: f.info,
            expand: false,
            onTap: _openAdjustStock,
          ),
        if (wide && canEdit)
          AppButton(
            text: 'Edit Product',
            icon: AppIcons.edit,
            isFullWidth: false,
            onPressed: _openEditProduct,
          ),
        if (showMenu)
          PopupMenuButton<_MenuAction>(
            tooltip: 'More options',
            color: t.colorScheme.surface,
            onSelected: _onMenu,
            itemBuilder: (_) => [
              if (menuHasAdjust)
                _menuItem(
                  _MenuAction.adjustStock,
                  AppIcons.tune,
                  'Adjust Stock',
                ),
              if (menuHasEdit)
                _menuItem(
                  _MenuAction.editProduct,
                  AppIcons.edit,
                  'Edit Product',
                ),
              if (hasReport)
                _menuItem(
                  _MenuAction.report,
                  AppIcons.flag,
                  CatalogueReportLink.label,
                ),
            ],
            child: const IgnorePointer(
              child: DetailBarSquare(icon: AppIcons.moreVertical),
            ),
          ),
      ],
    );
  }

  PopupMenuItem<_MenuAction> _menuItem(
    _MenuAction value,
    IconData icon,
    String label,
  ) {
    return PopupMenuItem<_MenuAction>(
      value: value,
      child: Row(
        children: [
          AppIcon(icon, size: 20, color: _text),
          const SizedBox(width: 12),
          Flexible(child: Text(label)),
        ],
      ),
    );
  }

  /// The "Report a problem" menu item is for a factory barcode only (ADR 0029
  /// §6, #335); the link itself renders nothing otherwise.
  bool get _hasReportLink {
    final code = _productData?.barcode;
    if (code == null) return false;
    return FactoryBarcode.tryParse(code) != null;
  }

  void _onMenu(_MenuAction action) {
    switch (action) {
      case _MenuAction.adjustStock:
        _openAdjustStock();
      case _MenuAction.editProduct:
        _openEditProduct();
      case _MenuAction.report:
        final code = _productData?.barcode;
        if (code != null) CatalogueReportLink.open(context, code);
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // BODY — one, two or three columns by the measured width
  // ═══════════════════════════════════════════════════════════════════════════

  Widget _buildBody(BuildContext context, double width) {
    final gap = SizedBox(height: context.getRSize(16));
    final columns = width >= kProductDetailThreeColumnWidth
        ? 3
        : (width >= kProductDetailTwoColumnWidth ? 2 : 1);

    final stores = ref.watch(allStoresProvider).valueOrNull ?? const [];
    final stockMap =
        ref.watch(productStockByStoreProvider(widget.item.id)).valueOrNull ??
        const <String, int>{};
    final rows = [
      for (final s in stores)
        StoreStockRow(
          storeId: s.id,
          name: s.name,
          quantity: stockMap[s.id] ?? 0,
        ),
    ];
    final total = stores.isEmpty
        ? widget.item.totalStock.toInt()
        : rows.fold<int>(0, (a, r) => a + r.quantity);

    final hero = _buildHero(context, total);
    final description = ProductDescriptionCard(
      text: _description,
      onEdit: _canEdit ? _editDescription : null,
    );
    final prices = _buildPrices(context);
    final stock = ProductStockByStoreCard(
      rows: rows,
      alertAt: _alertAt,
      unit: _unit,
      crates: _crates,
    );
    final target = _buildTarget(context);
    final salesCard = _buildSalesCard(context);
    final history = _buildStockHistoryCard(context);
    final manage = _buildManage(context, columns >= 2);

    List<Widget> column(List<Widget?> cards) => [
      for (final c in cards)
        if (c != null) ...[c, gap],
    ];

    Widget cols(List<List<Widget?>> groups) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < groups.length; i++) ...[
            if (i > 0) SizedBox(width: context.getRSize(16)),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: column(groups[i]),
              ),
            ),
          ],
        ],
      );
    }

    final Widget body = switch (columns) {
      3 => cols([
        [hero, description, manage],
        [prices, stock, target],
        [salesCard, history],
      ]),
      2 => cols([
        [hero, description, prices, manage],
        [stock, target, salesCard, history],
      ]),
      _ => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: column([
          hero,
          description,
          prices,
          stock,
          target,
          salesCard,
          history,
          manage,
        ]),
      ),
    };
    return body;
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // CARDS
  // ═══════════════════════════════════════════════════════════════════════════

  Widget _buildHero(BuildContext context, int total) {
    final p = _productData;
    final level = stockLevelOf(total, _alertAt);
    final categories = ref.watch(allCategoriesProvider).valueOrNull ?? const [];
    final manufacturers =
        ref.watch(allManufacturersProvider).valueOrNull ?? const [];
    final categoryName = categories
        .where((c) => c.id == p?.categoryId)
        .map((c) => c.name)
        .firstOrNull;
    final manufacturer =
        manufacturers
            .where((m) => m.id == p?.manufacturerId)
            .map((m) => m.name)
            .firstOrNull ??
        widget.item.manufacturer;
    final expiry = p?.expiryDate;
    final retailKobo =
        p?.retailerPriceKobo ??
        ((widget.item.retailerPrice ?? 0) * 100).round();
    final visual = categoryVisual(
      categoryName,
      Theme.of(context).extension<AppFixedColors>() ?? AppFixedColors.light,
    );
    return ProductHeroCard(
      name: _name,
      kindLine: productKindLine(
        manufacturer: manufacturer,
        unit: _unit,
        unitsPerPack: p?.unitsPerPack,
        crates: _crates,
      ),
      barcode: p?.barcode,
      retailPrice: formatCurrency(retailKobo / 100),
      perNoun: unitCountNoun(_unit, 1, crates: _crates),
      categoryName: categoryName,
      stockLabel: level == StockLevel.out
          ? 'Out of stock'
          : '$total ${unitCountNoun(_unit, total, crates: _crates)} in stock',
      stockLevel: level,
      imagePath: _imagePath,
      // The same category picture as the POS and Receive Stock tiles.
      fallbackIcon: visual.icon,
      fallbackColor: visual.iconColor,
      expiry: expiry == null ? null : expiryPillFor(expiry, _now),
      archived: _archived,
      onChangePhoto: _canEdit ? _pickImage : null,
    );
  }

  Widget _buildPrices(BuildContext context) {
    final p = _productData;
    final costKobo =
        p?.buyingPriceKobo ?? ((widget.item.buyingPrice ?? 0) * 100).round();
    final retailKobo =
        p?.retailerPriceKobo ??
        ((widget.item.retailerPrice ?? 0) * 100).round();
    final wholesaleKobo =
        p?.wholesalerPriceKobo ??
        ((widget.item.wholesalerPrice ?? 0) * 100).round();
    final canSeeCost = _canEditBuying;
    return ProductPricesCard(
      perNoun: unitCountNoun(_unit, 1, crates: _crates),
      retailKobo: retailKobo,
      wholesaleKobo: wholesaleKobo,
      costKobo: canSeeCost ? costKobo : null,
      showProfit: canSeeCost && costKobo > 0,
    );
  }

  /// Units sold so far this (business-local) month, from the Sales card's days.
  int get _monthUnits {
    final days = _salesDays;
    if (days == null || days.isEmpty) return 0;
    final m = days.last.date.month;
    return days.where((d) => d.date.month == m).fold(0, (a, d) => a + d.units);
  }

  Widget _buildTarget(BuildContext context) {
    return ProductSalesTargetCard(
      figures: SalesTargetFigures(
        sold: _monthUnits,
        target: _productData?.monthlyTargetUnits ?? 0,
        now: _now,
      ),
      unit: _unit,
      crates: _crates,
      onEdit: _isCeo ? _editTarget : null,
    );
  }

  Widget? _buildManage(BuildContext context, bool sideBySide) {
    final canArchive = _canEdit;
    final canDelete = _canDelete;
    if (!canArchive && !canDelete) return null;
    return ProductManageCard(
      archived: _archived,
      sideBySide: sideBySide,
      onArchiveToggle: canArchive
          ? (_archived ? _unarchive : _confirmArchive)
          : null,
      onDelete: canDelete ? () => _confirmDelete(context) : null,
    );
  }

  // ── Sales + Stock History (#487 PR 5) ───────────────────────────────────

  Widget _buildSalesCard(BuildContext context) => ProductSalesCard(
    days: _salesDays,
    unit: _unit,
    crates: _crates,
    showProfit: _canEditBuying,
  );

  Widget _buildStockHistoryCard(BuildContext context) {
    final page = ref.watch(
      paginatedStockHistoryProvider((
        storeId: null,
        period: 'All',
        productId: widget.item.id,
      )),
    );
    return ProductStockHistoryCard(
      rows: page.transactions,
      loading: page.isLoading,
      unit: _unit,
      crates: _crates,
      now: _now,
      onViewAll: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => ProductStockHistoryScreen(
            productId: widget.item.id,
            unit: _unit,
            crates: _crates,
            clock: widget.clock,
          ),
        ),
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // ACTIONS — every one re-checks its gate on tap
  // ═══════════════════════════════════════════════════════════════════════════

  /// Edit Product opens the existing product editor sheet, exactly as
  /// Inventory's long-press does. PR 4 rewires this one method to the new form.
  void _openEditProduct() {
    if (!Gates.editProductPrice.allowsNow(ref)) {
      showGateDenied(context, Gates.editProductPrice);
      return;
    }
    final product = _productData;
    if (product == null) return;
    final total =
        (ref.read(productStockByStoreProvider(widget.item.id)).valueOrNull ??
                const <String, int>{})
            .values
            .fold<int>(0, (a, b) => a + b);
    HapticFeedback.mediumImpact();
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => UpdateProductSheet(
        product: product,
        totalStock: total,
        onProductUpdated: (_) => widget.onUpdateStock(),
      ),
    );
  }

  /// Writes the description ([setSubtitle], null clears it) or the monthly
  /// target ([monthlyTarget]) through the same product-update path every other
  /// edit uses: the row is re-read first, so a price or name another device
  /// changed a moment ago is written back as it is now, and the DAO stamps
  /// `lastUpdatedAt` and enqueues the push. Returns an error message or null.
  Future<String?> _saveProductField({
    bool setSubtitle = false,
    String? subtitle,
    int? monthlyTarget,
  }) async {
    final db = ref.read(databaseProvider);
    try {
      final fresh = await db.catalogDao.findById(widget.item.id);
      if (fresh == null) return 'This product is no longer available.';
      if (setSubtitle) {
        await db.catalogDao.updateProductDetails(
          fresh.id,
          name: fresh.name,
          manufacturerId: fresh.manufacturerId,
          buyingPriceKobo: fresh.buyingPriceKobo,
          retailerPriceKobo: fresh.retailerPriceKobo,
          wholesalerPriceKobo: fresh.wholesalerPriceKobo,
          categoryId: fresh.categoryId,
          subtitle: subtitle,
        );
      } else {
        await db.catalogDao.updateProductDetails(
          fresh.id,
          name: fresh.name,
          manufacturerId: fresh.manufacturerId,
          buyingPriceKobo: fresh.buyingPriceKobo,
          retailerPriceKobo: fresh.retailerPriceKobo,
          wholesalerPriceKobo: fresh.wholesalerPriceKobo,
          categoryId: fresh.categoryId,
          monthlyTargetUnits: monthlyTarget,
        );
      }
      final refreshed = await db.catalogDao.findById(fresh.id);
      if (mounted && refreshed != null) {
        setState(() => _productData = refreshed);
      }
      widget.onUpdateStock();
      return null;
    } catch (e, st) {
      CrashReporter.record(e, st, context: 'inventory.product_detail.save');
      debugPrint('ProductDetail._saveProductField error: $e');
      return 'Could not save: $e';
    }
  }

  Future<void> _editDescription() async {
    if (!Gates.editProductPrice.allowsNow(ref)) {
      showGateDenied(context, Gates.editProductPrice);
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (_) => ProductEditDialog(
        title: 'Description',
        initialText: _description,
        hint: 'What is this product?',
        maxLines: 4,
        onSave: (text) async {
          if (!Gates.editProductPrice.allowsNow(ref)) {
            return 'You no longer have access to Edit Price.';
          }
          return _saveProductField(
            setSubtitle: true,
            subtitle: text.isEmpty ? null : text,
          );
        },
      ),
    );
  }

  Future<void> _editTarget() async {
    if (!_isCeo) {
      AppNotification.showError(
        context,
        'Only the CEO can change the sales target.',
      );
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (_) => ProductEditDialog(
        title: 'Sales Target',
        fieldLabel: 'Crates to sell each month',
        helper: 'Leave it at 0 for no target.',
        initialText: '${_productData?.monthlyTargetUnits ?? 0}',
        numbersOnly: true,
        onSave: (text) async {
          if (!_isCeo) return 'Only the CEO can change the sales target.';
          return _saveProductField(monthlyTarget: int.tryParse(text) ?? 0);
        },
      ),
    );
  }

  Future<void> _confirmArchive() async {
    if (!Gates.editProductPrice.allowsNow(ref)) {
      showGateDenied(context, Gates.editProductPrice);
      return;
    }
    final name = _name;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        scrollable: true,
        backgroundColor: _surface,
        title: Text(
          'Archive Product',
          style: ctx.screenTitleStyle.copyWith(color: _text),
        ),
        content: Text(
          'Archive $name? It will be hidden from sale. Its sales history is '
          'kept.',
          style: ctx.regularStyle(14).copyWith(color: _text),
        ),
        actions: [
          AppButton(
            text: 'Cancel',
            variant: AppButtonVariant.ghost,
            isFullWidth: false,
            onPressed: () => Navigator.pop(ctx, false),
          ),
          AppButton(
            text: 'Archive',
            isFullWidth: false,
            onPressed: () => Navigator.pop(ctx, true),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await _setArchived(true);
  }

  Future<void> _unarchive() async {
    if (!Gates.editProductPrice.allowsNow(ref)) {
      showGateDenied(context, Gates.editProductPrice);
      return;
    }
    await _setArchived(false);
  }

  Future<void> _setArchived(bool archived) async {
    if (!Gates.editProductPrice.allowsNow(ref)) {
      showGateDenied(context, Gates.editProductPrice);
      return;
    }
    final db = ref.read(databaseProvider);
    final name = _name;
    try {
      await db.catalogDao.setProductArchived(widget.item.id, archived);
      // The change is saved; a failed log line must not read as a failed
      // archive.
      try {
        final actor = ref.read(authProvider).currentUser?.name ?? 'Unknown';
        await ref
            .read(activityLogProvider)
            .logAction(
              archived ? 'archive_product' : 'unarchive_product',
              '$actor ${archived ? 'archived' : 'unarchived'} product: $name',
              productId: widget.item.id,
            );
      } catch (e, st) {
        CrashReporter.record(
          e,
          st,
          context: 'inventory.product_detail.archive_log',
        );
      }
      final refreshed = await db.catalogDao.findById(widget.item.id);
      if (!mounted) return;
      if (refreshed != null) setState(() => _productData = refreshed);
      widget.onUpdateStock();
      AppNotification.showSuccess(
        context,
        archived ? '$name archived' : '$name is back on sale',
      );
    } catch (e, st) {
      CrashReporter.record(e, st, context: 'inventory.product_detail.archive');
      if (mounted) {
        AppNotification.showError(
          context,
          'Could not ${archived ? 'archive' : 'unarchive'} the product. '
          'Please try again.',
        );
      }
    }
  }

  /// "Adjust Stock" sheet (master plan §16.6): add / remove a quantity against
  /// a store, with a required reason on removal, optional notes, and — on an
  /// add — what the goods cost per unit (#197, PRD #155 US 22), which is what
  /// prices the FIFO batch the increase mints. A **stock keeper**'s change is
  /// queued for Manager/CEO approval (§16.6.1) via `requestStockAdjustment`,
  /// carrying that cost on the request — inventory is untouched until approved.
  /// A Manager/CEO applies it directly through `adjustStock` (cloud delta
  /// envelope enqueued) and logs to History.
  Future<void> _openAdjustStock() async {
    if (!_canOpenAdjust) {
      showGateDenied(context, Gates.adjustStock);
      return;
    }
    final product = _productData;
    if (product == null) return;
    final db = ref.read(databaseProvider);
    final stores = await db.storesDao.getActiveStores();
    if (!mounted) return;
    if (stores.isEmpty) {
      AppNotification.showError(context, 'No store to adjust stock against.');
      return;
    }

    // The sheet owns its own text controllers and disposes them in its
    // State.dispose() (matches every other sheet in the app). Disposing them
    // here, after `await showModalBottomSheet`, raced the closing animation and
    // threw "TextEditingController used after being disposed".
    // Flipped by onSave when a stock keeper's change is queued for approval
    // (§16.6.1) rather than applied directly — drives the confirmation toast.
    var sentForApproval = false;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _UpdateStockSheet(
        product: product,
        stores: stores,
        initialStoreId: widget.selectedStoreId,
        // Add and Remove are gated separately (stock.add vs stock.adjust).
        canAdd: _canAddStock,
        canRemove: _canAdjustStock,
        // Re-checked live at save time (hard rule #6) in case a permission is
        // revoked while the sheet is open — these getters read live perms.
        canAddNow: () => _canAddStock,
        canRemoveNow: () => _canAdjustStock,
        onSave:
            ({
              required bool isRemove,
              required int qty,
              required StoreData store,
              String? reason,
              required String notes,
              int? unitCostKobo,
            }) async {
              final auth = ref.read(authProvider);
              final actorName = auth.currentUser?.name ?? 'Unknown';
              final delta = isRemove ? -qty : qty;
              final note = isRemove
                  ? '${reason!}${notes.isEmpty ? '' : ': $notes'}'
                  : (notes.isEmpty ? 'Stock added by $actorName' : notes);
              final unitWord = unitLabel(
                product.unit,
                crates: businessTracksCrates(ref.read(currentBusinessProvider)),
              );
              final summary =
                  '$actorName ${isRemove ? 'removed' : 'added'} $qty '
                  '${unitWord != null ? '$unitWord(s) ' : ''}of ${product.name} '
                  '(${store.name})'
                  '${isRemove ? ' — ${reason!}' : ''}';
              final isStockKeeper =
                  ref.read(currentUserRoleProvider)?.slug == 'stock_keeper';
              try {
                if (isStockKeeper) {
                  // §16.6.1 — a stock keeper's change needs Manager/CEO approval.
                  // Record a pending request; inventory stays untouched until it is
                  // approved in the Reports hub. The DAO fires the approval-request
                  // notification to the CEO + the affected store's Manager(s).
                  // #197 (US 22): the captured cost rides ON the request, so the
                  // batch the approval mints is priced at what the goods
                  // actually cost instead of whatever could be inferred later.
                  await db.stockAdjustmentRequestsDao.requestStockAdjustment(
                    productId: product.id,
                    storeId: store.id,
                    quantityDiff: delta,
                    reason: note,
                    summary: summary,
                    requestedBy: auth.currentUser?.id,
                    unitCostKobo: unitCostKobo,
                  );
                  sentForApproval = true;
                  return null;
                }
                // Manager / CEO adjust directly — no approval needed. Their add
                // mints the same inflow batch an approval does, so the sheet's
                // cost has to reach it here too (#197); null keeps #189's
                // recorded-price fallback.
                await db.inventoryDao.adjustStock(
                  product.id,
                  store.id,
                  delta,
                  note,
                  auth.currentUser?.id,
                  inflowUnitCostKobo: unitCostKobo,
                );
                await ref
                    .read(activityLogProvider)
                    .logAction(
                      'stock_adjustment',
                      summary,
                      productId: product.id,
                      storeId: store.id,
                    );
                widget.onUpdateStock();
                return null;
              } catch (e, st) {
                CrashReporter.record(
                  e,
                  st,
                  context: 'inventory.product_detail.stock_adjust',
                );
                debugPrint('UpdateStock modal save error: $e');
                return isStockKeeper
                    ? 'Could not send for approval: $e'
                    : 'Could not update stock: $e';
              }
            },
      ),
    );
    if (!mounted) return;
    if (sentForApproval) {
      AppNotification.showSuccess(
        context,
        'Sent for approval. A manager or the CEO must approve before the '
        'stock changes.',
      );
    }
  }

  Future<void> _pickImage() async {
    if (!Gates.editProductPrice.allowsNow(ref)) {
      showGateDenied(context, Gates.editProductPrice);
      return;
    }

    AutoLockWrapper.suppressNextResume = true;
    final imgSvc = ref.read(productImageServiceProvider);
    final picked = await imgSvc.pickAndProcess();
    if (!mounted) return;

    final Uint8List bytes;
    switch (picked) {
      case Ok(:final value):
        bytes = value;
      case Err(:final error):
        if (!error.isCancelled) {
          AppNotification.showError(context, 'Could not load image.');
        }
        return;
    }

    final productId = widget.item.id;
    final businessId = ref.read(authProvider).currentUser?.businessId;
    if (productId.isEmpty || businessId == null) return;

    try {
      // Upload (keyed by product id) + local cache; offline it caches locally
      // and queues for the reconnect flush. The photo lives in image_url + the
      // ProductImageService cache (never products.image_path, so it stays off
      // the POS grid); the cache path drives the local preview. #78.
      final res = await imgSvc.save(
        businessId: businessId,
        productId: productId,
        bytes: bytes,
      );
      final localPath = await imgSvc.localPathFor(productId);
      if (!mounted) return;
      setState(() => _imagePath = localPath);

      final db = ref.read(databaseProvider);
      if (res case Ok(:final value)) {
        // Persists the URL and enqueues the FULL product row (coalesce-safe).
        await db.catalogDao.setProductImageUrl(productId, value);
      }

      if (mounted) {
        AppNotification.showSuccess(context, 'Product image updated');
        widget.onUpdateStock(); // Refresh parent view
      }
    } catch (e, st) {
      CrashReporter.record(
        e,
        st,
        context: 'inventory.product_detail.update_image',
      );
      if (mounted) {
        AppNotification.showError(context, 'Failed to update image: $e');
      }
    }
  }

  void _confirmDelete(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        // Scrolls rather than overflows on a small or sideways screen (#392).
        scrollable: true,
        backgroundColor: _surface,
        title: Text(
          'Delete Product',
          style: ctx.screenTitleStyle.copyWith(color: _text),
        ),
        content: Text(
          'Are you sure you want to delete ${widget.item.productName}? This action cannot be undone.',
          style: ctx.regularStyle(14).copyWith(color: _text),
        ),
        actions: [
          AppButton(
            text: 'Cancel',
            variant: AppButtonVariant.ghost,
            isFullWidth: false,
            onPressed: () => Navigator.pop(ctx),
          ),
          AppButton(
            text: 'Delete',
            variant: AppButtonVariant.danger,
            isFullWidth: false,
            onPressed: () async {
              if (!Gates.deleteProduct.allowsNow(ref)) {
                Navigator.pop(ctx);
                showGateDenied(context, Gates.deleteProduct);
                return;
              }
              final productName = widget.item.productName;
              final productId = widget.item.id;
              final db = ref.read(databaseProvider);
              final actorId = ref.read(authProvider).currentUser?.id;
              // Remove any remaining stock first, so the deletion is recorded
              // in the History tab as adjustment rows (§16.8) and the product
              // stops counting toward stock totals. #170 #7c: the write-off draws
              // the FIFO cost batches down and SNAPSHOTS the value, returning the
              // total so the delete is booked with a VISIBLE value instead of the
              // value silently vanishing.
              //
              // #193: the write-off is a PRECONDITION of the delete, not a
              // best-effort side errand. It used to be swallowed — the product was
              // soft-deleted anyway, and its remaining stock value was orphaned:
              // no write-off row, and the deleted product is filtered out of every
              // cost lookup, so the loss became unreportable. So a failure here
              // aborts: the product stays, the dialog stays open, and the user can
              // retry rather than lose the value silently.
              final int writtenOffKobo;
              try {
                writtenOffKobo = await db.inventoryDao
                    .writeOffAllStockForDelete(productId, actorId);
              } catch (e, st) {
                CrashReporter.record(
                  e,
                  st,
                  context: 'inventory.product_detail.delete_stock_zero',
                );
                if (!context.mounted) return;
                AppNotification.showError(
                  context,
                  'Could not write off the remaining stock, so $productName was '
                  'not deleted. Please try again.',
                );
                return;
              }
              try {
                await db.catalogDao.softDeleteProduct(productId);
                final actorName =
                    ref.read(authProvider).currentUser?.name ?? 'Unknown';
                final writeOffNote = writtenOffKobo > 0
                    ? ' (wrote off ${formatCurrency(writtenOffKobo / 100)} of '
                          'remaining stock)'
                    : '';
                await ref
                    .read(activityLogProvider)
                    .logAction(
                      'delete_product',
                      '$actorName deleted product: $productName$writeOffNote',
                      productId: productId,
                    );
                ref.read(cartProvider).removeItem(productName);
                if (!context.mounted) return;
                Navigator.pop(ctx);
                Navigator.pop(context);
                AppNotification.showSuccess(context, '$productName deleted');
              } catch (e, st) {
                CrashReporter.record(
                  e,
                  st,
                  context: 'inventory.product_detail.delete',
                );
                if (!context.mounted) return;
                AppNotification.showError(
                  context,
                  'Could not delete product. Please try again.',
                );
              }
            },
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// _UpdateStockSheet — the Stock keeper's "Adjust Stock" bottom sheet (§16.6).
//
// Owns its own text controllers and disposes them in State.dispose(), so the
// framework tears the fields down before the controllers go away. The previous
// inline version created the controllers in the caller and disposed them right
// after `await showModalBottomSheet`, which raced the closing animation and
// threw "TextEditingController used after being disposed". The save side
// effects — a stock keeper's approval request, or a Manager/CEO's direct
// adjustment + activity log + screen refresh — stay on the screen (private
// members) and run via [onSave].
// ─────────────────────────────────────────────────────────────────────────────
class _UpdateStockSheet extends ConsumerStatefulWidget {
  const _UpdateStockSheet({
    required this.product,
    required this.stores,
    required this.initialStoreId,
    required this.canAdd,
    required this.canRemove,
    required this.canAddNow,
    required this.canRemoveNow,
    required this.onSave,
  });

  final ProductData product;
  final List<StoreData> stores;
  final String? initialStoreId;
  final bool canAdd;
  final bool canRemove;
  // Live permission re-checks evaluated at save time (hard rule #6).
  final bool Function() canAddNow;
  final bool Function() canRemoveNow;
  // Performs the movement on the screen. Returns null on success, or an error
  // message to surface in the sheet (the sheet stays open on error).
  // [unitCostKobo] is what the added goods cost per unit (#197, US 22) — null on
  // a removal, and null on an add where the user stated nothing.
  final Future<String?> Function({
    required bool isRemove,
    required int qty,
    required StoreData store,
    String? reason,
    required String notes,
    int? unitCostKobo,
  })
  onSave;

  @override
  ConsumerState<_UpdateStockSheet> createState() => _UpdateStockSheetState();
}

class _UpdateStockSheetState extends ConsumerState<_UpdateStockSheet> {
  final _qtyCtrl = TextEditingController();
  final _notesCtrl = TextEditingController();
  // #197 (US 22): what the added goods cost, per unit. Add mode only — a
  // removal is valued by drawing this store's FIFO queue, not by the person
  // filing it.
  final _costCtrl = TextEditingController();
  static const _reasons = ['Damage', 'Theft', 'Expired', 'Other'];

  late bool _isRemove;
  String? _reason;
  late StoreData _selectedStore;
  bool _saving = false;

  Color get _bg => Theme.of(context).scaffoldBackgroundColor;
  Color get _surface => Theme.of(context).colorScheme.surface;
  Color get _text => Theme.of(context).colorScheme.onSurface;
  Color get _subtext =>
      Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6);
  Color get _border => Theme.of(context).dividerColor;

  @override
  void initState() {
    super.initState();
    // Start in whichever mode is allowed (Add by default).
    _isRemove = !widget.canAdd && widget.canRemove;
    _selectedStore = widget.stores.cast<StoreData?>().firstWhere(
      (s) => s?.id == widget.initialStoreId,
      orElse: () => widget.stores.first,
    )!;
  }

  @override
  void dispose() {
    _qtyCtrl.dispose();
    _notesCtrl.dispose();
    _costCtrl.dispose();
    super.dispose();
  }

  /// #197 (US 22): the per-unit cost typed into the sheet, in kobo — `null` when
  /// none was stated, which is what lets the approval fall back to the product's
  /// recorded price (#189) instead of minting a phantom-0 batch.
  ///
  /// A typed `0` also reads as "not stated": the field is optional and offers no
  /// way to say "these goods were genuinely free", so honouring it as the
  /// deliberate Uncosted 0 that `adjustStock` treats an explicit 0 as would turn
  /// a slip of the finger into units that sell at 0 COGS forever.
  int? get _unitCostKobo {
    if (_isRemove) return null;
    final naira = parseCurrency(_costCtrl.text.trim());
    final kobo = (naira * 100).round();
    return kobo > 0 ? kobo : null;
  }

  /// The product's recorded buying price, shown as the cost field's placeholder
  /// so the number a blank field will use is visible before it is used. Empty
  /// when nothing is on file — a `0.00` placeholder there would read as a price
  /// rather than as the absence of one, contradicting [_blankCostNote] directly
  /// beneath it.
  String get _recordedCostHint {
    final recordedKobo = widget.product.buyingPriceKobo;
    if (recordedKobo <= 0) return '';
    return (recordedKobo / 100).toStringAsFixed(2);
  }

  /// Says out loud what leaving the cost blank will do — the recorded price
  /// (#189), or nothing at all when the product has no price on file. Naming the
  /// consequence is the difference between an optional field and a silent one.
  String get _blankCostNote {
    final recordedKobo = widget.product.buyingPriceKobo;
    if (recordedKobo > 0) {
      return 'Leave blank to use the recorded '
          '${formatCurrency(recordedKobo / 100)}.';
    }
    return 'Leave blank if you don\'t know — these units will carry no cost '
        'until a price is set.';
  }

  Future<void> _doSave() async {
    final qty = int.tryParse(_qtyCtrl.text.trim()) ?? 0;
    if (qty <= 0) {
      AppNotification.showError(context, 'Quantity must be greater than 0.');
      return;
    }
    if (_isRemove && _reason == null) {
      AppNotification.showError(
        context,
        'A reason is required when removing stock.',
      );
      return;
    }
    // Defense-in-depth (hard rule #6): re-check the mode's permission live, in
    // case it was revoked while the sheet was open.
    if (_isRemove && !widget.canRemoveNow()) {
      AppNotification.showError(
        context,
        'You don\'t have permission to remove stock.',
      );
      return;
    }
    if (!_isRemove && !widget.canAddNow()) {
      AppNotification.showError(
        context,
        'You don\'t have permission to add stock.',
      );
      return;
    }
    setState(() => _saving = true);
    final error = await widget.onSave(
      isRemove: _isRemove,
      qty: qty,
      store: _selectedStore,
      reason: _reason,
      notes: _notesCtrl.text.trim(),
      unitCostKobo: _unitCostKobo,
    );
    if (!mounted) return;
    if (error == null) {
      Navigator.pop(context);
    } else {
      AppNotification.showError(context, error);
      setState(() => _saving = false);
    }
  }

  Widget _modeChip(String label, bool removeMode) {
    final selected = _isRemove == removeMode;
    final color = removeMode ? danger : success;
    return Expanded(
      child: GestureDetector(
        onTap: () => setState(() {
          _isRemove = removeMode;
          if (!removeMode) _reason = null;
        }),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 12),
          decoration: BoxDecoration(
            color: selected ? color.withValues(alpha: 0.15) : _surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: selected ? color : _border,
              width: selected ? 1.5 : 1,
            ),
          ),
          child: Center(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: selected ? color : _subtext,
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final product = widget.product;
    final stores = widget.stores;
    return Container(
      decoration: BoxDecoration(
        color: _bg,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
      ),
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
          20,
          16,
          20,
          20 + context.deviceBottomPadding,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: _border,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'Adjust Stock',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w800,
                color: _text,
              ),
            ),
            Text(product.name, style: TextStyle(fontSize: 13, color: _subtext)),
            const SizedBox(height: 16),
            Row(
              children: [
                if (widget.canAdd) _modeChip('Add stock', false),
                if (widget.canAdd && widget.canRemove)
                  const SizedBox(width: 10),
                if (widget.canRemove) _modeChip('Remove stock', true),
              ],
            ),
            const SizedBox(height: 14),
            if (stores.length > 1) ...[
              Text(
                'STORE',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: _subtext,
                  letterSpacing: 0.8,
                ),
              ),
              const SizedBox(height: 8),
              AppDropdown<StoreData>(
                value: _selectedStore,
                items: stores
                    .map(
                      (s) => DropdownMenuItem(
                        value: s,
                        child: Text(s.name, overflow: TextOverflow.ellipsis),
                      ),
                    )
                    .toList(),
                onChanged: (v) =>
                    setState(() => _selectedStore = v ?? _selectedStore),
              ),
              const SizedBox(height: 14),
            ],
            AppInput(
              controller: _qtyCtrl,
              labelText: 'Quantity *',
              hintText: '0',
              keyboardType: TextInputType.number,
            ),
            // #197 (US 22): what the goods cost. Add mode only — a removal is
            // valued by drawing this store's FIFO queue (#7a), which the person
            // filing the change cannot know. Optional: a recount that simply
            // found more units has no invoice behind it, and then the recorded
            // price is used (#189).
            if (!_isRemove) ...[
              SizedBox(height: context.getRSize(14)),
              AppInput(
                controller: _costCtrl,
                labelText: 'Cost per unit (optional)',
                hintText: _recordedCostHint,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                inputFormatters: [CurrencyInputFormatter()],
                prefixText: '$activeCurrencySymbol ',
              ),
              SizedBox(height: context.getRSize(6)),
              Text(
                _blankCostNote,
                style: Theme.of(
                  context,
                ).textTheme.labelSmall?.copyWith(color: _subtext),
              ),
            ],
            if (_isRemove) ...[
              const SizedBox(height: 14),
              Text(
                'REASON *',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: _subtext,
                  letterSpacing: 0.8,
                ),
              ),
              const SizedBox(height: 8),
              AppDropdown<String?>(
                value: _reason,
                hintText: 'Select a reason',
                items: _reasons
                    .map((r) => DropdownMenuItem(value: r, child: Text(r)))
                    .toList(),
                onChanged: (v) => setState(() => _reason = v),
              ),
            ],
            const SizedBox(height: 14),
            AppInput(
              controller: _notesCtrl,
              labelText: 'Notes (optional)',
              hintText: 'Any extra detail…',
            ),
            const SizedBox(height: 20),
            AppButton(
              text: _isRemove ? 'Remove Stock' : 'Add Stock',
              variant: AppButtonVariant.primary,
              isLoading: _saving,
              onPressed: _doSave,
            ),
          ],
        ),
      ),
    );
  }
}
