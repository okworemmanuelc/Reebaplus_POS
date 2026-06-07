import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

import 'package:reebaplus_pos/shared/widgets/auto_lock_wrapper.dart';
import 'package:reebaplus_pos/core/theme/colors.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';

import 'package:reebaplus_pos/core/utils/currency_input_formatter.dart';
import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/core/utils/stock_calculator.dart';
import 'package:reebaplus_pos/features/inventory/data/models/inventory_item.dart';
import 'package:reebaplus_pos/shared/widgets/app_dropdown.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/services/crash_reporter.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:reebaplus_pos/core/utils/notifications.dart';
import 'package:reebaplus_pos/shared/widgets/app_input.dart';

// ─────────────────────────────────────────────────────────────────────────────
// ProductDetailScreen — full-screen product information view
// ─────────────────────────────────────────────────────────────────────────────

class ProductDetailScreen extends ConsumerStatefulWidget {
  final InventoryItem item;
  final VoidCallback onUpdateStock;
  final String?
  selectedStoreId; // null = "All Stores" — quantity editing blocked

  const ProductDetailScreen({
    super.key,
    required this.item,
    required this.onUpdateStock,
    this.selectedStoreId,
  });

  @override
  ConsumerState<ProductDetailScreen> createState() =>
      _ProductDetailScreenState();
}

class _ProductDetailScreenState extends ConsumerState<ProductDetailScreen> {
  late TextEditingController _nameController;
  late TextEditingController _subtitleController;
  late TextEditingController _buyingPriceController;
  late TextEditingController _retailPriceController;
  late TextEditingController _wholesalerPriceController;
  late TextEditingController _monthlyTargetController;
  late TextEditingController _emptyCratesController;
  late TextEditingController _emptyCrateValueController;
  late TextEditingController _lowStockController;

  int _monthlyTarget = 0;
  bool _editMode = false; // top Edit button toggles editing (CEO/Manager)
  bool _savingChanges = false;
  late double _liveStock; // live total stock, refreshed after adjustments
  int? _emptyCrateStock; // original value loaded from DB
  bool _allowFractionalSales = false;
  bool _trackEmpties = false;
  String? _size;
  DateTime? _expiryDate;
  String? _selectedManufacturerId; // DB id of the linked manufacturer
  String? _selectedCategoryId;
  String? _selectedSupplierId;
  String? _selectedUnit;
  List<String> _allUnits = [];
  List<CategoryData> _allCategories = [];
  List<ManufacturerData> _allManufacturers = [];
  List<SupplierData> _allSuppliers = [];

  ProductData? _productData; // full DB row, used by the inline save

  ProductSalesSummary? _salesSummary;
  LastShipmentInfo? _lastDelivery;
  bool _deliveryLoaded = false;
  bool _contentReady = false; // deferred load flag
  String? _imagePath;

  // ── Role gating (master plan §16.6 / §16.7) ────────────────────────────────
  // The screen is view-only until a CEO/Manager taps Edit (top bar). Editing is
  // CEO + Manager via `products.edit_price`; delete is gated SEPARATELY on
  // `products.delete` (see `_canDelete`). The Sales Target is CEO-only
  // (`_isCeo`). Buying price visibility is `products.edit_buying_price`
  // (CEO + Manager). Stock keeper can only adjust quantities via the "Update
  // Stock" modal (`stock.adjust`) and sees a restricted view. Cashier: view-only.
  // Read (not watch) so these getters are safe to call from non-build handlers.
  bool get _canEdit =>
      ref.read(currentUserPermissionsProvider).contains('products.edit_price');
  // Delete is its own permission, not edit. Granted to CEO + Manager by default;
  // the CEO can revoke it per role in Roles & Permissions and the change applies
  // live (build() watches currentUserPermissionsProvider, so the screen rebuilds
  // and this getter re-reads).
  bool get _canDelete =>
      ref.read(currentUserPermissionsProvider).contains('products.delete');
  bool get _canEditBuying => ref
      .read(currentUserPermissionsProvider)
      .contains('products.edit_buying_price');
  bool get _canAdjustStock =>
      ref.read(currentUserPermissionsProvider).contains('stock.adjust');
  // Add-stock is its own permission (§16.7), separate from adjust/remove. The
  // Update-Stock modal opens if the viewer holds either; the Add and Remove
  // modes inside are gated individually (stock.add vs stock.adjust).
  bool get _canAddStock =>
      ref.read(currentUserPermissionsProvider).contains('stock.add');
  // Sales Target is CEO-only (a Manager may edit everything else but not the
  // target — explicit user requirement).
  bool get _isCeo => ref.read(currentUserRoleProvider)?.slug == 'ceo';
  // Suppliers are gated (§16.7): Stock keeper / Cashier don't see the field.
  bool get _canSeeSuppliers =>
      ref.read(currentUserPermissionsProvider).contains('suppliers.manage');

  @override
  void initState() {
    super.initState();
    _liveStock = widget.item.totalStock;
    _nameController = TextEditingController(text: widget.item.productName);
    _subtitleController = TextEditingController(text: widget.item.subtitle);
    _buyingPriceController = TextEditingController(
      text: fmtNumber(widget.item.buyingPrice ?? 0),
    );
    _retailPriceController = TextEditingController(
      text: fmtNumber(widget.item.retailerPrice ?? 0),
    );
    _wholesalerPriceController = TextEditingController(
      text: fmtNumber(widget.item.wholesalerPrice ?? 0),
    );
    _monthlyTargetController = TextEditingController(text: '0');
    _emptyCratesController = TextEditingController(text: '0');
    _emptyCrateValueController = TextEditingController(text: '0');
    _lowStockController = TextEditingController(
      text: widget.item.lowStockThreshold.toInt().toString(),
    );
    _selectedUnit = widget.item.unit;
    _size = widget.item.size;
    _imagePath = widget.item.imagePath;

    _retailPriceController.addListener(_onRetailPriceChanged);

    // Defer heavy DB calls until after first frame.
    // _contentReady stays false until _loadProductData() finishes so the
    // shimmer skeleton is visible while SQLite queries run.
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

    // Load monthly target, categories, manufacturers from DB
    final product = await db.catalogDao.findById(productId);
    final categories = await db.inventoryDao.getAllCategories();
    final manufacturers = await db.inventoryDao.getAllManufacturers();
    final suppliers = await db.catalogDao.getAllSuppliers();
    final uniqueUnits = await db.catalogDao.getUniqueProductUnits();

    if (mounted) {
      setState(() {
        _allCategories = categories;
        _allManufacturers = manufacturers;
        _allSuppliers = suppliers;
        _allUnits = {
          ...kProductUnits,
          if (_selectedUnit != null) _selectedUnit!,
          ...uniqueUnits,
        }.toList()..sort();

        if (product != null) {
          _productData = product;
          _monthlyTarget = product.monthlyTargetUnits;
          _monthlyTargetController.text = _monthlyTarget.toString();
          _selectedCategoryId = product.categoryId;
          _selectedManufacturerId = product.manufacturerId;
          _selectedSupplierId = product.supplierId;
          _allowFractionalSales = product.allowFractionalSales;
          _trackEmpties = product.trackEmpties;
          _size = product.size;
          _expiryDate = product.expiryDate;
          _subtitleController.text = product.subtitle ?? '';
          _lowStockController.text = product.lowStockThreshold.toString();
          _emptyCrateValueController.text = (product.emptyCrateValueKobo / 100)
              .toStringAsFixed(0);
        }
      });
      // Load empty crate stock from manufacturer if linked
      if (product?.manufacturerId != null) {
        _loadEmptyCrateStock(product!.manufacturerId!);
      }
    }

    // Load sales summary from completed orders
    final summary = await db.ordersDao.getSalesSummaryForProduct(productId);
    if (mounted) setState(() => _salesSummary = summary);

    // Load last shipment from shipments
    final delivery = await db.shipmentsDao.getLastShipmentForProduct(
      productId,
    );
    if (mounted) {
      setState(() {
        _lastDelivery = delivery;
        _deliveryLoaded = true;
        _contentReady = true;
      });
    }
  }

  Future<void> _loadEmptyCrateStock(String manufacturerId) async {
    final manufacturers = await ref
        .read(databaseProvider)
        .inventoryDao
        .getAllManufacturers();
    final mfr = manufacturers.where((m) => m.id == manufacturerId).firstOrNull;
    if (mfr != null && mounted) {
      setState(() {
        _emptyCrateStock = mfr.emptyCrateStock;
        _emptyCratesController.text = mfr.emptyCrateStock.toString();
      });
    }
  }

  /// Re-read this product's current total stock (scoped to the selected store,
  /// or summed across stores when "All Stores" is active) and update the status
  /// badge + quantity field, so the detail screen reflects a stock change
  /// without leaving and re-entering (#1).
  Future<void> _refreshLiveStock() async {
    final productId = widget.item.id;
    if (productId.isEmpty) return;
    final rows = await ref
        .read(databaseProvider)
        .inventoryDao
        .getProductsWithStock(storeId: widget.selectedStoreId);
    final match = rows.where((r) => r.product.id == productId).firstOrNull;
    if (match != null && mounted) {
      setState(() => _liveStock = match.totalStock.toDouble());
    }
  }

  /// Re-seed the editable controllers/fields from the loaded product so a
  /// Cancel discards unsaved edits.
  void _resetEdits() {
    final product = _productData;
    setState(() {
      _nameController.text = widget.item.productName;
      if (product != null) {
        _subtitleController.text = product.subtitle ?? '';
        _buyingPriceController.text = (product.buyingPriceKobo / 100)
            .toStringAsFixed(0);
        _retailPriceController.text = (product.retailerPriceKobo / 100)
            .toStringAsFixed(0);
        _wholesalerPriceController.text = (product.wholesalerPriceKobo / 100)
            .toStringAsFixed(0);
        _emptyCrateValueController.text = (product.emptyCrateValueKobo / 100)
            .toStringAsFixed(0);
        _lowStockController.text = product.lowStockThreshold.toString();
        _monthlyTarget = product.monthlyTargetUnits;
        _monthlyTargetController.text = _monthlyTarget.toString();
        _selectedCategoryId = product.categoryId;
        _selectedManufacturerId = product.manufacturerId;
        _selectedSupplierId = product.supplierId;
        _selectedUnit = product.unit;
        _allowFractionalSales = product.allowFractionalSales;
        _trackEmpties = product.trackEmpties;
        _size = product.size;
        _expiryDate = product.expiryDate;
        _imagePath = product.imagePath;
      }
    });
  }

  /// Re-seed the displayed (non-editing) fields from a freshly-synced product
  /// row so a realtime cloud edit reflects immediately (§5). Synchronous — the
  /// caller wraps it in setState. Never called while `_editMode` is true.
  void _seedFieldsFrom(ProductData product) {
    _nameController.text = product.name;
    _subtitleController.text = product.subtitle ?? '';
    _buyingPriceController.text =
        (product.buyingPriceKobo / 100).toStringAsFixed(0);
    _retailPriceController.text =
        (product.retailerPriceKobo / 100).toStringAsFixed(0);
    _wholesalerPriceController.text =
        (product.wholesalerPriceKobo / 100).toStringAsFixed(0);
    _emptyCrateValueController.text =
        (product.emptyCrateValueKobo / 100).toStringAsFixed(0);
    _lowStockController.text = product.lowStockThreshold.toString();
    _monthlyTarget = product.monthlyTargetUnits;
    _monthlyTargetController.text = _monthlyTarget.toString();
    _selectedCategoryId = product.categoryId;
    _selectedManufacturerId = product.manufacturerId;
    _selectedSupplierId = product.supplierId;
    _selectedUnit = product.unit;
    _allowFractionalSales = product.allowFractionalSales;
    _trackEmpties = product.trackEmpties;
    _size = product.size;
    _expiryDate = product.expiryDate;
    _imagePath = product.imagePath;
    // Keep the unit dropdown inclusive of a (possibly new) synced unit value.
    if (!_allUnits.contains(product.unit)) {
      _allUnits = ({..._allUnits, product.unit}.toList())..sort();
    }
  }

  /// Re-read the derived blocks (Sales Summary + Last Delivery) after a stock
  /// change syncs in, so they stay live alongside the product fields.
  Future<void> _reloadDerived() async {
    final db = ref.read(databaseProvider);
    final id = widget.item.id;
    final summary = await db.ordersDao.getSalesSummaryForProduct(id);
    if (mounted) setState(() => _salesSummary = summary);
    final delivery = await db.shipmentsDao.getLastShipmentForProduct(id);
    if (mounted) setState(() => _lastDelivery = delivery);
  }

  Future<void> _pickExpiry() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _expiryDate ?? now,
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year + 20),
      helpText: 'Select expiry date',
    );
    if (picked != null && mounted) setState(() => _expiryDate = picked);
  }

  /// CEO / Manager edit-and-save: persist every editable field in a SINGLE
  /// `products` upsert (so the sync queue can't coalesce away one of two writes
  /// — that was the bug where the Sales Target never reached the cloud). The
  /// Sales Target is only included for a CEO. Also mirrors the crate value to
  /// the manufacturer level (§16.5). Shows a success / error banner.
  Future<void> _saveChanges() async {
    final product = _productData;
    if (product == null) {
      AppNotification.showError(context, 'Product is still loading.');
      return;
    }
    final db = ref.read(databaseProvider);
    final auth = ref.read(authProvider);
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      AppNotification.showError(context, 'Product name is required.');
      return;
    }
    setState(() => _savingChanges = true);
    try {
      final crateValueKobo =
          (parseCurrency(_emptyCrateValueController.text) * 100).toInt();
      // One upsert carries everything — including the Sales Target (CEO only),
      // so prices + target + flags all reach the cloud in one payload.
      await db.catalogDao.updateProductDetails(
        product.id,
        name: name,
        manufacturerId: _selectedManufacturerId,
        buyingPriceKobo:
            (parseCurrency(_buyingPriceController.text) * 100).round(),
        retailerPriceKobo:
            (parseCurrency(_retailPriceController.text) * 100).round(),
        wholesalerPriceKobo:
            (parseCurrency(_wholesalerPriceController.text) * 100).round(),
        emptyCrateValueKobo: crateValueKobo,
        categoryId: _selectedCategoryId,
        unit: _selectedUnit,
        trackEmpties: _trackEmpties,
        allowFractionalSales: _allowFractionalSales,
        lowStockThreshold: int.tryParse(_lowStockController.text.trim()) ??
            product.lowStockThreshold,
        imagePath: _imagePath,
        monthlyTargetUnits: _isCeo ? _monthlyTarget : null,
        subtitle: _subtitleController.text.trim().isEmpty
            ? null
            : _subtitleController.text.trim(),
        supplierId: _selectedSupplierId,
        size: _size,
        expiryDate: _expiryDate,
      );
      // Crate value is shared at the manufacturer level so all products of this
      // manufacturer share one value (§16.5).
      if (_selectedManufacturerId != null && crateValueKobo > 0) {
        await db.catalogDao.updateManufacturerEmptyCrateValue(
          _selectedManufacturerId!,
          crateValueKobo,
        );
      }
      await ref
          .read(activityLogProvider)
          .logAction(
            'update_product',
            '${auth.currentUser?.name ?? 'Unknown'} updated product: $name',
            productId: product.id,
          );
      // Re-read the product so the screen shows the saved values and a fresh
      // baseline for the next edit.
      final refreshed = await db.catalogDao.findById(product.id);
      widget.onUpdateStock();
      if (mounted) {
        setState(() {
          if (refreshed != null) _productData = refreshed;
          _editMode = false;
        });
        AppNotification.showSuccess(context, 'Product updated');
      }
    } catch (e, st) {
      CrashReporter.record(e, st, context: 'inventory.product_detail.save');
      debugPrint('ProductDetail._saveChanges error: $e');
      if (mounted) {
        AppNotification.showError(context, 'Could not update product: $e');
      }
    } finally {
      if (mounted) setState(() => _savingChanges = false);
    }
  }

  void _onRetailPriceChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _retailPriceController.removeListener(_onRetailPriceChanged);
    _nameController.dispose();
    _subtitleController.dispose();
    _buyingPriceController.dispose();
    _retailPriceController.dispose();
    _wholesalerPriceController.dispose();
    _monthlyTargetController.dispose();
    _emptyCratesController.dispose();
    _emptyCrateValueController.dispose();
    _lowStockController.dispose();
    super.dispose();
  }

  // ── Theme helpers ─────────────────────────────────────────────────────────
  Color get _bg => Theme.of(context).scaffoldBackgroundColor;
  Color get _surface => Theme.of(context).colorScheme.surface;
  Color get _cardBg => Theme.of(context).cardColor;
  Color get _text => Theme.of(context).colorScheme.onSurface;
  Color get _subtext =>
      Theme.of(context).textTheme.bodySmall?.color ??
      Theme.of(context).iconTheme.color!;
  Color get _border => Theme.of(context).dividerColor;

  @override
  Widget build(BuildContext context) {
    ref.watch(currencySymbolProvider); // rebuild money displays when currency changes
    // Subscribe to permission changes so the role-gated UI (buying row,
    // action button) rebuilds when the role + its grants resolve locally.
    // The `_canEdit` family of getters read the same provider.
    ref.watch(currentUserPermissionsProvider);

    // Realtime sync (§5): watch this product's row + stock so an edit or stock
    // change on another device reflects here live, without leaving the screen.
    // The stream's LEFT join always carries the product row (even with 0 stock
    // in the selected store), so `match.product` gives every field its current
    // synced value. Stock (a non-editable field here) updates even mid-edit;
    // editable fields are re-seeded only when NOT editing, so an incoming sync
    // never clobbers the user's unsaved input.
    ref.listen<AsyncValue<List<ProductDataWithStock>>>(
      productsWithStockProvider(widget.selectedStoreId),
      (prev, next) {
        final rows = next.valueOrNull;
        if (rows == null || !mounted) return;
        final match =
            rows.where((r) => r.product.id == widget.item.id).firstOrNull;
        if (match == null) return;
        final p = match.product;
        final newStock = match.totalStock.toDouble();
        final stockChanged = newStock != _liveStock;
        setState(() {
          _liveStock = newStock;
          _productData = p; // keep the edit baseline fresh
          if (!_editMode) _seedFieldsFrom(p);
        });
        if (!_editMode && p.manufacturerId != null) {
          _loadEmptyCrateStock(p.manufacturerId!);
        }
        // A stock change for this product means a sale/adjustment landed —
        // refresh the Sales Summary + Last Delivery so those blocks stay live.
        if (stockChanged) _reloadDerived();
      },
    );

    // A sale records an order (and its stock delta). The stock listener above
    // only refreshes the Sales Summary when THIS store's total changes, so a
    // sale in another store — or any timing where the stock tick is missed —
    // wouldn't update the numbers. Watch the orders stream directly so every
    // sale (this device or synced from another) refreshes the summary live.
    ref.listen(allOrdersProvider, (prev, next) {
      if (next.valueOrNull == null || !mounted) return;
      _reloadDerived();
    });

    // Keep the dropdown OPTION lists live (§5): a category / manufacturer /
    // supplier added or renamed on another device relabels here without a
    // reopen. The existing dropdowns read these instance fields directly.
    ref.listen(allCategoriesProvider, (prev, next) {
      final v = next.valueOrNull;
      if (v != null && mounted) setState(() => _allCategories = v);
    });
    ref.listen(allManufacturersProvider, (prev, next) {
      final v = next.valueOrNull;
      if (v != null && mounted) setState(() => _allManufacturers = v);
    });
    ref.listen(allSuppliersProvider, (prev, next) {
      final v = next.valueOrNull;
      if (v != null && mounted) setState(() => _allSuppliers = v);
    });

    // Show shimmer skeleton while DB data loads (_contentReady becomes true
    // at the end of _loadProductData once all queries complete).
    if (!_contentReady) {
      return Scaffold(
        backgroundColor: _bg,
        body: const SafeArea(
          child: Center(child: CircularProgressIndicator()),
        ),
      );
    }

    return Scaffold(
      backgroundColor: _bg,
      resizeToAvoidBottomInset: false,
      body: CustomScrollView(
        slivers: [
          _buildSliverAppBar(context),
          SliverToBoxAdapter(child: _buildBody(context)),
        ],
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // SLIVER APP BAR — hero header with product icon and gradient
  // ═══════════════════════════════════════════════════════════════════════════

  Widget _buildSliverAppBar(BuildContext context) {
    final isLow =
        _liveStock > 0 && _liveStock <= widget.item.lowStockThreshold;
    final isOut = _liveStock == 0;
    Color statusColor = success;
    String statusLabel = 'In Stock';
    if (isOut) {
      statusColor = danger;
      statusLabel = 'Out of Stock';
    } else if (isLow) {
      statusColor = const Color(0xFFF59E0B);
      statusLabel = 'Low Stock';
    }

    return SliverAppBar(
      expandedHeight: context.getRSize(220),
      pinned: true,
      backgroundColor: _surface,
      leading: IconButton(
        icon: Container(
          padding: EdgeInsets.all(context.getRSize(8)),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.2),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(
            Icons.arrow_back_ios_new,
            size: context.getRSize(18),
            color: Colors.white,
          ),
        ),
        onPressed: () => Navigator.pop(context),
      ),
      actions: [
        // Edit toggle (CEO/Manager) — fields stay read-only until this is on.
        if (_canEdit)
          IconButton(
            tooltip: _editMode ? 'Cancel editing' : 'Edit product',
            onPressed: () {
              if (_editMode) {
                _resetEdits();
                setState(() => _editMode = false);
              } else {
                setState(() => _editMode = true);
              }
            },
            icon: Container(
              padding: EdgeInsets.all(context.getRSize(8)),
              decoration: BoxDecoration(
                color: _editMode
                    ? Theme.of(context).colorScheme.primary
                    : Colors.black.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(
                _editMode ? Icons.close : Icons.edit,
                size: context.getRSize(18),
                color: Colors.white,
              ),
            ),
          ),
        if (_canDelete)
          IconButton(
            onPressed: () => _confirmDelete(context),
            icon: Container(
              padding: EdgeInsets.all(context.getRSize(8)),
              decoration: BoxDecoration(
                color: Theme.of(
                  context,
                ).colorScheme.error.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(
                FontAwesomeIcons.trashCan,
                size: context.getRSize(18),
                color: Theme.of(context).colorScheme.error,
              ),
            ),
          ),
        SizedBox(width: context.getRSize(8)),
      ],
      flexibleSpace: FlexibleSpaceBar(
        background: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                widget.item.color.withValues(alpha: 0.8),
                widget.item.color.withValues(alpha: 0.4),
                _bg,
              ],
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
            ),
          ),
          child: SafeArea(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                SizedBox(height: context.getRSize(24)),
                Container(
                  width: context.getRSize(80),
                  height: context.getRSize(80),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(24),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.3),
                      width: 2,
                    ),
                  ),
                  child: Stack(
                    children: [
                      Center(
                        child: _imagePath != null
                            ? ClipRRect(
                                borderRadius: BorderRadius.circular(22),
                                child: Image.file(
                                  File(_imagePath!),
                                  width: context.getRSize(76),
                                  height: context.getRSize(76),
                                  fit: BoxFit.cover,
                                  errorBuilder: (ctx, _, __) => Icon(
                                    widget.item.icon,
                                    color: Colors.white,
                                    size: context.getRSize(36),
                                  ),
                                ),
                              )
                            : Icon(
                                widget.item.icon,
                                color: Colors.white,
                                size: context.getRSize(36),
                              ),
                      ),
                      if (_editMode)
                        Positioned(
                          right: 0,
                          bottom: 0,
                          child: GestureDetector(
                            onTap: _pickImage,
                            child: Container(
                              padding: EdgeInsets.all(context.getRSize(4)),
                              decoration: BoxDecoration(
                                color: Theme.of(context).colorScheme.primary,
                                shape: BoxShape.circle,
                                border:
                                    Border.all(color: Colors.white, width: 2),
                              ),
                              child: Icon(
                                Icons.edit,
                                color: Colors.white,
                                size: context.getRSize(12),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                SizedBox(height: context.getRSize(14)),
                ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: context.screenWidth * 0.8,
                  ),
                  child: AppInput(
                    controller: _nameController,
                    readOnly: !_editMode,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: context.getRFontSize(24),
                      fontWeight: FontWeight.w800,
                      color: Colors.white,
                      letterSpacing: -0.5,
                    ),
                    border: InputBorder.none,
                    contentPadding: EdgeInsets.zero,
                    hintText: 'Product Name',
                    fillColor: Colors.transparent,
                    onChanged: (v) => setState(() {}),
                  ),
                ),
                SizedBox(height: context.getRSize(6)),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    SizedBox(width: context.getRSize(12)),
                    Container(
                      padding: EdgeInsets.symmetric(
                        horizontal: context.getRSize(10),
                        vertical: context.getRSize(4),
                      ),
                      decoration: BoxDecoration(
                        color: statusColor.withValues(alpha: 0.2),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                          color: statusColor.withValues(alpha: 0.5),
                        ),
                      ),
                      child: Text(
                        statusLabel,
                        style: TextStyle(
                          fontSize: context.getRFontSize(11),
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // BODY — all detail sections
  // ═══════════════════════════════════════════════════════════════════════════

  Widget _buildBody(BuildContext context) {
    final double totalStockValue = stockValue(
      parseCurrency(_retailPriceController.text),
      _liveStock,
    );

    return Padding(
      padding: EdgeInsets.fromLTRB(
        context.getRSize(20),
        context.getRSize(16),
        context.getRSize(20),
        context.getRSize(16) + context.deviceBottomPadding,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Stock & Info ─────────────────────────────────────────
          _sectionTitle(context, 'Stock & Info'),
          SizedBox(height: context.getRSize(12)),
          _infoCard(context, [
            // Quantity is read-only here — it changes via Add Product
            // (restock) or the Stock keeper's Update Stock modal, never inline.
            _infoRow(
              context,
              FontAwesomeIcons.cubesStacked,
              'Total Quantity',
              '${_liveStock.toStringAsFixed(_liveStock % 1 == 0 ? 0 : 1)}'
                  '${_selectedUnit != null ? ' ${_selectedUnit!}' : ''}',
              Theme.of(context).colorScheme.primary,
            ),
            _divider(context),
            // Description / subtitle
            _infoRow(
              context,
              FontAwesomeIcons.alignLeft,
              'Description',
              _editMode ? '' : _subtitleController.text,
              const Color(0xFF06B6D4),
              trailing: _editMode
                  ? _textTrailing(_subtitleController, width: 150)
                  : null,
            ),
            _divider(context),
            _infoRow(
              context,
              FontAwesomeIcons.industry,
              'Manufacturer',
              '',
              const Color(0xFF6366F1),
              trailing: SizedBox(
                width: context.getRSize(160),
                child: AppDropdown<String?>(
                  value: _selectedManufacturerId,
                  items: [
                    DropdownMenuItem<String?>(
                      value: null,
                      child: Text(
                        'None',
                        style: TextStyle(
                          color: _subtext,
                          fontSize: context.getRFontSize(12),
                        ),
                      ),
                    ),
                    ..._allManufacturers.map(
                      (m) => DropdownMenuItem<String?>(
                        value: m.id,
                        child: Text(m.name, overflow: TextOverflow.ellipsis),
                      ),
                    ),
                  ],
                  onChanged: _editMode
                      ? (v) => setState(() {
                          _selectedManufacturerId = v;
                          // Crate value is shared at the manufacturer level —
                          // autofill from the chosen manufacturer (§16.5).
                          final m = _allManufacturers
                              .where((x) => x.id == v)
                              .firstOrNull;
                          if (m != null && m.depositAmountKobo > 0) {
                            _emptyCrateValueController.text =
                                (m.depositAmountKobo / 100).toStringAsFixed(0);
                          }
                        })
                      : (_) {},
                ),
              ),
            ),
            // Supplier (gated — Stock keeper / Cashier don't see it, §16.7)
            if (_canSeeSuppliers) ...[
              _divider(context),
              _infoRow(
                context,
                FontAwesomeIcons.truck,
                'Supplier',
                '',
                const Color(0xFF0EA5E9),
                trailing: SizedBox(
                  width: context.getRSize(160),
                  child: AppDropdown<String?>(
                    value: _allSuppliers.any((s) => s.id == _selectedSupplierId)
                        ? _selectedSupplierId
                        : null,
                    items: [
                      DropdownMenuItem<String?>(
                        value: null,
                        child: Text(
                          'None',
                          style: TextStyle(
                            color: _subtext,
                            fontSize: context.getRFontSize(12),
                          ),
                        ),
                      ),
                      ..._allSuppliers.map(
                        (s) => DropdownMenuItem<String?>(
                          value: s.id,
                          child: Text(s.name, overflow: TextOverflow.ellipsis),
                        ),
                      ),
                    ],
                    onChanged: _editMode
                        ? (v) => setState(() => _selectedSupplierId = v)
                        : (_) {},
                  ),
                ),
              ),
            ],
            _divider(context),
            // Category Dropdown
            _infoRow(
              context,
              FontAwesomeIcons.tag,
              'Category',
              '',
              success,
              trailing: SizedBox(
                width: context.getRSize(150),
                child: AppDropdown<String?>(
                  value: _selectedCategoryId,
                  items: [
                    const DropdownMenuItem<String?>(
                        value: null, child: Text("None")),
                    ..._allCategories.map(
                      (c) => DropdownMenuItem<String?>(
                          value: c.id, child: Text(c.name)),
                    ),
                  ],
                  onChanged: _editMode
                      ? (val) => setState(() => _selectedCategoryId = val)
                      : (_) {},
                ),
              ),
            ),
            _divider(context),
            // Product Unit Dropdown
            _infoRow(
              context,
              FontAwesomeIcons.box,
              'Product Unit',
              '',
              const Color(0xFFF59E0B),
              trailing: SizedBox(
                width: context.getRSize(150),
                child: AppDropdown<String?>(
                  value: _selectedUnit,
                  items: _allUnits
                      .map((u) => DropdownMenuItem(value: u, child: Text(u)))
                      .toList(),
                  onChanged: _editMode
                      ? (val) => setState(() => _selectedUnit = val)
                      : (_) {},
                ),
              ),
            ),
            _divider(context),
            // Low Stock Alert
            _infoRow(
              context,
              FontAwesomeIcons.triangleExclamation,
              'Low Stock Alert',
              '',
              const Color(0xFFEF4444),
              trailing: _textTrailing(
                _lowStockController,
                width: 70,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              ),
            ),
            _divider(context),
            // Size dropdown
            _infoRow(
              context,
              FontAwesomeIcons.layerGroup,
              'Size',
              '',
              const Color(0xFF8B5CF6),
              trailing: SizedBox(
                width: context.getRSize(130),
                child: AppDropdown<String?>(
                  value: _size,
                  items: const [
                    DropdownMenuItem(value: null, child: Text('None')),
                    DropdownMenuItem(value: 'big', child: Text('Big')),
                    DropdownMenuItem(value: 'medium', child: Text('Medium')),
                    DropdownMenuItem(value: 'small', child: Text('Small')),
                  ],
                  onChanged:
                      _editMode ? (v) => setState(() => _size = v) : (_) {},
                ),
              ),
            ),
            _divider(context),
            // Expiry date (editable)
            _infoRow(
              context,
              FontAwesomeIcons.calendarXmark,
              'Expiry Date',
              '',
              const Color(0xFFF59E0B),
              trailing: _expiryTrailing(context),
            ),
            _divider(context),
            // Allow fractional sales
            _infoRow(
              context,
              FontAwesomeIcons.divide,
              'Allow fractional sales',
              '',
              const Color(0xFF6366F1),
              trailing: Switch.adaptive(
                value: _allowFractionalSales,
                onChanged: _editMode
                    ? (v) => setState(() => _allowFractionalSales = v)
                    : null,
              ),
            ),
            _divider(context),
            // Track empty crate returns
            _infoRow(
              context,
              FontAwesomeIcons.recycle,
              'Track empty crates',
              '',
              const Color(0xFF14B8A6),
              trailing: Switch.adaptive(
                value: _trackEmpties,
                onChanged: _editMode
                    ? (v) => setState(() => _trackEmpties = v)
                    : null,
              ),
            ),
            if (_trackEmpties) ...[
              _divider(context),
              // Empty Crate Value — shared at the manufacturer level (§16.5)
              _infoRow(
                context,
                FontAwesomeIcons.circleDollarToSlot,
                'Empty Crate Value',
                '',
                const Color(0xFF14B8A6),
                trailing: _textTrailing(
                  _emptyCrateValueController,
                  width: 90,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  inputFormatters: [CurrencyInputFormatter()],
                  prefix: activeCurrencySymbol,
                ),
              ),
              _divider(context),
              // Empty Crates — manufacturer total (read-only)
              _infoRow(
                context,
                FontAwesomeIcons.beerMugEmpty,
                'Empty Crates',
                _emptyCrateStock?.toString() ?? '0',
                const Color(0xFFF59E0B),
              ),
            ],
          ]),

          SizedBox(height: context.getRSize(24)),

          // ── Pricing ─────────────────────────────────────────────────
          _sectionTitle(context, 'Pricing'),
          SizedBox(height: context.getRSize(12)),
          _infoCard(context, [
            // Buying price is hidden from roles without `products.edit_buying_price`
            // (Cashier, Stock keeper) — master plan §16.6 / §16.7.
            if (_canEditBuying) ...[
              _infoRow(
                context,
                FontAwesomeIcons.dollarSign,
                'Buying Price',
                '',
                const Color(0xFFF59E0B),
                trailing: _inlinePriceInput(_buyingPriceController),
              ),
              _divider(context),
            ],
            _infoRow(
              context,
              FontAwesomeIcons.tag,
              'Retailer Price',
              '',
              Theme.of(context).colorScheme.primary,
              trailing: _inlinePriceInput(_retailPriceController),
            ),
            _divider(context),
            _infoRow(
              context,
              FontAwesomeIcons.users,
              'Wholesaler Price',
              '',
              const Color(0xFF8B5CF6),
              trailing: _inlinePriceInput(_wholesalerPriceController),
            ),
            _divider(context),
            _infoRow(
              context,
              FontAwesomeIcons.chartLine,
              'Total Stock Value',
              formatCurrency(totalStockValue),
              Theme.of(context).colorScheme.primary,
            ),
          ]),

          SizedBox(height: context.getRSize(24)),

          // ── Sales Summary ───────────────────────────────────────────
          _sectionTitle(context, 'Sales Summary'),
          SizedBox(height: context.getRSize(12)),
          _buildSalesGrid(context),

          SizedBox(height: context.getRSize(24)),

          // ── Sales Target (editable by CEO only, in edit mode) ────────
          Row(
            children: [
              _sectionTitle(context, 'Sales Target'),
              if (_editMode && !_isCeo) ...[
                SizedBox(width: context.getRSize(8)),
                Text(
                  '(CEO only)',
                  style: TextStyle(
                    fontSize: context.getRFontSize(11),
                    color: _subtext,
                  ),
                ),
              ],
            ],
          ),
          SizedBox(height: context.getRSize(12)),
          _buildTargetGrid(context),

          SizedBox(height: context.getRSize(24)),

          // ── Last Delivery ───────────────────────────────────────────
          _sectionTitle(context, 'Last Delivery'),
          SizedBox(height: context.getRSize(12)),
          _buildDeliveryCard(context),

          SizedBox(height: context.getRSize(32)),
          if (_canEdit && _editMode) ...[
            // ── CEO / Manager (editing): save all fields in one update ─
            AppButton(
              text: 'Save Product',
              variant: AppButtonVariant.primary,
              icon: FontAwesomeIcons.floppyDisk,
              isLoading: _savingChanges,
              onPressed: _productData == null ? null : _saveChanges,
            ),
          ] else if ((_canAddStock || _canAdjustStock) && !_canEdit) ...[
            // ── Stock keeper: quantity adjustments only (§16.6) ───────
            AppButton(
              text: 'Update Stock',
              variant: AppButtonVariant.primary,
              icon: FontAwesomeIcons.boxesStacked,
              onPressed:
                  _productData == null ? null : () => _showUpdateStockModal(),
            ),
          ] else if (!_canEdit) ...[
            // ── Read-only notice ──────────────────────────────────────
            Container(
              width: double.infinity,
              padding: EdgeInsets.all(context.getRSize(16)),
              decoration: BoxDecoration(
                color: _surface,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: _border),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.lock_outline,
                    size: context.getRSize(14),
                    color: _subtext,
                  ),
                  SizedBox(width: context.getRSize(6)),
                  Text(
                    'VIEW ONLY',
                    style: TextStyle(
                      fontSize: context.getRFontSize(12),
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.8,
                      color: _subtext,
                    ),
                  ),
                ],
              ),
            ),
          ],
          SizedBox(height: context.getRSize(40)),
        ],
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // SHARED WIDGETS
  // ═══════════════════════════════════════════════════════════════════════════

  Widget _sectionTitle(BuildContext context, String title) {
    return Text(
      title,
      style: TextStyle(
        fontSize: context.getRFontSize(16),
        fontWeight: FontWeight.w800,
        color: _text,
      ),
    );
  }

  Widget _infoCard(BuildContext context, List<Widget> children) {
    return Container(
      decoration: BoxDecoration(
        color: _cardBg,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _border),
      ),
      child: Column(children: children),
    );
  }

  Widget _infoRow(
    BuildContext context,
    IconData icon,
    String label,
    String value,
    Color iconColor, {
    VoidCallback? onTap,
    Widget? trailing,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: context.getRSize(16),
          vertical: context.getRSize(14),
        ),
        child: Row(
          children: [
            Container(
              width: context.getRSize(38),
              height: context.getRSize(38),
              decoration: BoxDecoration(
                color: iconColor.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, size: context.getRSize(16), color: iconColor),
            ),
            SizedBox(width: context.getRSize(14)),
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: context.getRFontSize(13),
                  fontWeight: FontWeight.w600,
                  color: _subtext,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            SizedBox(width: context.getRSize(8)),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  value,
                  style: TextStyle(
                    fontSize: context.getRFontSize(14),
                    fontWeight: FontWeight.bold,
                    color: _text,
                  ),
                  textAlign: TextAlign.end,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
            if (trailing != null) ...[
              SizedBox(width: context.getRSize(8)),
              trailing,
            ],
          ],
        ),
      ),
    );
  }

  Widget _divider(BuildContext context) {
    return Divider(
      height: 1,
      color: _border,
      indent: context.getRSize(16),
      endIndent: context.getRSize(16),
    );
  }

  // ── Sales Summary Grid — reads from DB ───────────────────────────────────
  Widget _buildSalesGrid(BuildContext context) {
    final s = _salesSummary;
    return _infoCard(context, [
      _statRow(
        context,
        'Today',
        s != null ? '${s.todayUnits} units' : '—',
        s != null ? formatCurrency(s.todayRevenueKobo / 100) : '—',
      ),
      _divider(context),
      _statRow(
        context,
        'This Week',
        s != null ? '${s.weekUnits} units' : '—',
        s != null ? formatCurrency(s.weekRevenueKobo / 100) : '—',
      ),
      _divider(context),
      _statRow(
        context,
        'This Month',
        s != null ? '${s.monthUnits} units' : '—',
        s != null ? formatCurrency(s.monthRevenueKobo / 100) : '—',
      ),
    ]);
  }

  // ── Sales Target Grid — reads monthly target from DB ─────────────────────
  Widget _buildTargetGrid(BuildContext context) {
    final s = _salesSummary;
    final int currentMonthly = s?.monthUnits ?? 0;
    final int currentWeekly = s?.weekUnits ?? 0;
    final int currentDaily = s?.todayUnits ?? 0;

    return _infoCard(context, [
      _targetRow(context, 'Daily', currentDaily, _monthlyTarget ~/ 30),
      _divider(context),
      _targetRow(context, 'Weekly', currentWeekly, _monthlyTarget ~/ 4),
      _divider(context),
      _targetRow(
        context,
        'Monthly',
        currentMonthly,
        _monthlyTarget,
        isEditable: true,
      ),
    ]);
  }

  Widget _statRow(
    BuildContext context,
    String period,
    String qty,
    String revenue,
  ) {
    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: context.getRSize(16),
        vertical: context.getRSize(14),
      ),
      child: Row(
        children: [
          Expanded(
            flex: 2,
            child: Text(
              period,
              style: TextStyle(
                fontSize: context.getRFontSize(13),
                fontWeight: FontWeight.w600,
                color: _subtext,
              ),
            ),
          ),
          Expanded(
            flex: 2,
            child: Text(
              qty,
              style: TextStyle(
                fontSize: context.getRFontSize(13),
                fontWeight: FontWeight.bold,
                color: _text,
              ),
              textAlign: TextAlign.center,
            ),
          ),
          Expanded(
            flex: 3,
            child: Text(
              revenue,
              style: TextStyle(
                fontSize: context.getRFontSize(13),
                fontWeight: FontWeight.bold,
                color: success,
              ),
              textAlign: TextAlign.end,
            ),
          ),
        ],
      ),
    );
  }

  Widget _targetRow(
    BuildContext context,
    String period,
    int current,
    int target, {
    bool isEditable = false,
  }) {
    final progress = target > 0 ? (current / target).clamp(0.0, 1.0) : 0.0;
    final pct = (progress * 100).toInt();

    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: context.getRSize(16),
        vertical: context.getRSize(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                period,
                style: TextStyle(
                  fontSize: context.getRFontSize(13),
                  fontWeight: FontWeight.w600,
                  color: _subtext,
                ),
              ),
              if (isEditable)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '$current / ',
                      style: TextStyle(
                        fontSize: context.getRFontSize(12),
                        fontWeight: FontWeight.bold,
                        color: _text,
                      ),
                    ),
                    SizedBox(
                      width: context.getRSize(40),
                      child: AppInput(
                        controller: _monthlyTargetController,
                        readOnly: !(_editMode && _isCeo),
                        keyboardType: TextInputType.number,
                        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                        onChanged: (val) {
                          setState(() {
                            _monthlyTarget = int.tryParse(val) ?? 0;
                          });
                        },
                        border: InputBorder.none,
                        contentPadding: EdgeInsets.zero,
                        fillColor: Colors.transparent,
                      ),
                    ),
                    Text(
                      ' units ($pct%)',
                      style: TextStyle(
                        fontSize: context.getRFontSize(12),
                        fontWeight: FontWeight.bold,
                        color: _text,
                      ),
                    ),
                  ],
                )
              else
                Text(
                  '$current / $target units  ($pct%)',
                  style: TextStyle(
                    fontSize: context.getRFontSize(12),
                    fontWeight: FontWeight.bold,
                    color: _text,
                  ),
                ),
            ],
          ),
          SizedBox(height: context.getRSize(8)),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: LinearProgressIndicator(
              value: progress,
              minHeight: context.getRSize(6),
              backgroundColor: _border,
              valueColor: AlwaysStoppedAnimation<Color>(
                progress >= 1.0
                    ? success
                    : Theme.of(context).colorScheme.primary,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Last Delivery Card — reads from Shipments table ───────────────────────
  Widget _buildDeliveryCard(BuildContext context) {
    if (!_deliveryLoaded) {
      return _infoCard(context, [
        Padding(
          padding: EdgeInsets.all(context.getRSize(24)),
          child: Center(
            child: SizedBox(
              width: context.getRSize(20),
              height: context.getRSize(20),
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
          ),
        ),
      ]);
    }

    if (_lastDelivery == null) {
      return _infoCard(context, [
        Padding(
          padding: EdgeInsets.all(context.getRSize(24)),
          child: Center(
            child: Text(
              'No deliveries recorded yet',
              style: TextStyle(
                color: _subtext,
                fontSize: context.getRFontSize(13),
              ),
            ),
          ),
        ),
      ]);
    }

    final d = _lastDelivery!;
    return _infoCard(context, [
      _infoRow(
        context,
        FontAwesomeIcons.calendarDay,
        'Date',
        _fmtDate(d.date),
        Theme.of(context).colorScheme.primary,
      ),
      _divider(context),
      _infoRow(
        context,
        FontAwesomeIcons.truckFast,
        'Quantity Received',
        '${d.quantity} units',
        const Color(0xFF6366F1),
      ),
      _divider(context),
      _infoRow(
        context,
        FontAwesomeIcons.dollarSign,
        'Price Per Unit',
        formatCurrency(d.unitPriceKobo / 100),
        const Color(0xFFF59E0B),
      ),
      _divider(context),
      _infoRow(
        context,
        FontAwesomeIcons.receipt,
        'Total Delivery Cost',
        formatCurrency(d.totalKobo / 100),
        success,
      ),
    ]);
  }

  String _fmtDate(DateTime dt) {
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    return '${dt.day} ${months[dt.month - 1]} ${dt.year}';
  }

  Future<void> _pickImage() async {
    if (!_editMode) return;

    AutoLockWrapper.suppressNextResume = true;
    final picker = ImagePicker();
    try {
      final XFile? image = await picker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 800,
        maxHeight: 800,
        imageQuality: 85,
      );

      if (image == null) return;

      // Save image to app directory for persistence
      final appDir = await getApplicationDocumentsDirectory();
      final fileName =
          'product_${widget.item.id}_${DateTime.now().millisecondsSinceEpoch}${p.extension(image.path)}';
      final savedImage = await File(
        image.path,
      ).copy('${appDir.path}/$fileName');

      setState(() {
        _imagePath = savedImage.path;
      });

      // Update in DB
      final productId = widget.item.id;
      if (productId.isNotEmpty) {
        await ref
            .read(databaseProvider)
            .catalogDao
            .updateProductDetails(
              productId,
              name: _nameController.text.trim(),
              manufacturerId: _selectedManufacturerId,
              buyingPriceKobo:
                  ((parseCurrency(_buyingPriceController.text)) * 100).round(),
              retailerPriceKobo:
                  ((parseCurrency(_retailPriceController.text)) * 100).round(),
              wholesalerPriceKobo:
                  ((parseCurrency(_wholesalerPriceController.text)) * 100)
                      .round(),
              emptyCrateValueKobo:
                  (parseCurrency(_emptyCrateValueController.text) * 100)
                      .toInt(),
              categoryId: _selectedCategoryId,
              unit: _selectedUnit,
              lowStockThreshold: widget.item.lowStockThreshold.toInt(),
              imagePath: _imagePath,
            );

        if (mounted) {
          AppNotification.showSuccess(context, 'Product image updated');
          widget.onUpdateStock(); // Refresh parent view
        }
      }
    } catch (e, st) {
      CrashReporter.record(e, st,
          context: 'inventory.product_detail.update_image');
      if (mounted) {
        AppNotification.showError(context, 'Failed to pick image: $e');
      }
    }
  }

  String _formatDate(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}/'
      '${d.month.toString().padLeft(2, '0')}/${d.year}';

  /// Near-expiry badge (§16.6): red "Expired" once past, amber "Expires soon"
  /// within 30 days, otherwise nothing (the date row alone is enough).
  Widget? _expiryBadge(BuildContext context, DateTime expiry) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final days = DateTime(expiry.year, expiry.month, expiry.day)
        .difference(today)
        .inDays;
    String label;
    Color color;
    if (days < 0) {
      label = 'Expired';
      color = danger;
    } else if (days <= 30) {
      label = days == 0 ? 'Expires today' : 'Expires soon';
      color = const Color(0xFFF59E0B);
    } else {
      return null;
    }
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: context.getRSize(10),
        vertical: context.getRSize(4),
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: context.getRFontSize(11),
          fontWeight: FontWeight.w700,
          color: color,
        ),
      ),
    );
  }

  /// "Update Stock" modal (master plan §16.6): add / remove a quantity against
  /// a store, with a required reason on removal, optional notes. A **stock
  /// keeper**'s change is queued for Manager/CEO approval (§16.6.1) via
  /// `requestStockAdjustment` — inventory is untouched until approved. A
  /// Manager/CEO applies it directly through `adjustStock` (cloud delta
  /// envelope enqueued) and logs to History.
  Future<void> _showUpdateStockModal() async {
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
        onSave: ({
          required bool isRemove,
          required int qty,
          required StoreData store,
          String? reason,
          required String notes,
        }) async {
          final auth = ref.read(authProvider);
          final actorName = auth.currentUser?.name ?? 'Unknown';
          final delta = isRemove ? -qty : qty;
          final note = isRemove
              ? '${reason!}${notes.isEmpty ? '' : ': $notes'}'
              : (notes.isEmpty ? 'Stock added by $actorName' : notes);
          final summary = '$actorName ${isRemove ? 'removed' : 'added'} $qty '
              '${product.unit}(s) of ${product.name} '
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
              await db.stockAdjustmentRequestsDao.requestStockAdjustment(
                productId: product.id,
                storeId: store.id,
                quantityDiff: delta,
                reason: note,
                summary: summary,
                requestedBy: auth.currentUser?.id,
              );
              sentForApproval = true;
              return null;
            }
            // Manager / CEO adjust directly — no approval needed.
            await db.inventoryDao.adjustStock(
              product.id,
              store.id,
              delta,
              note,
              auth.currentUser?.id,
            );
            await ref.read(activityLogProvider).logAction(
                  'stock_adjustment',
                  summary,
                  productId: product.id,
                  storeId: store.id,
                );
            widget.onUpdateStock();
            // Reflect the change on this screen immediately (#1).
            await _refreshLiveStock();
            return null;
          } catch (e, st) {
            CrashReporter.record(e, st,
                context: 'inventory.product_detail.stock_adjust');
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

  /// Bordered inline text/number field used as an `_infoRow` trailing. Editable
  /// only in edit mode (CEO/Manager); read-only otherwise.
  Widget _textTrailing(
    TextEditingController controller, {
    double width = 120,
    TextInputType? keyboardType,
    List<TextInputFormatter>? inputFormatters,
    String? prefix,
  }) {
    return Container(
      width: context.getRSize(width),
      padding: EdgeInsets.symmetric(
        horizontal: context.getRSize(8),
        vertical: context.getRSize(4),
      ),
      decoration: BoxDecoration(
        color: _bg,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: _border),
      ),
      child: AppInput(
        controller: controller,
        readOnly: !_editMode,
        keyboardType: keyboardType,
        inputFormatters: inputFormatters,
        textAlign: TextAlign.end,
        onChanged: (v) => setState(() {}),
        border: InputBorder.none,
        contentPadding: EdgeInsets.zero,
        prefixText: prefix,
        fillColor: Colors.transparent,
      ),
    );
  }

  /// Expiry-date trailing: shows the date (+ near-expiry badge when viewing),
  /// and in edit mode is tappable to open the date picker with a clear button.
  Widget _expiryTrailing(BuildContext context) {
    final has = _expiryDate != null;
    return GestureDetector(
      onTap: _editMode ? _pickExpiry : null,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (has && !_editMode) ...[
            _expiryBadge(context, _expiryDate!) ?? const SizedBox.shrink(),
            SizedBox(width: context.getRSize(6)),
          ],
          Text(
            has ? _formatDate(_expiryDate!) : 'None',
            style: TextStyle(
              fontSize: context.getRFontSize(13),
              fontWeight: FontWeight.bold,
              color: has ? _text : _subtext,
            ),
          ),
          if (_editMode) ...[
            SizedBox(width: context.getRSize(6)),
            Icon(
              Icons.calendar_month,
              size: context.getRSize(16),
              color: Theme.of(context).colorScheme.primary,
            ),
            if (has)
              GestureDetector(
                onTap: () => setState(() => _expiryDate = null),
                child: Padding(
                  padding: EdgeInsets.only(left: context.getRSize(4)),
                  child: Icon(
                    Icons.close,
                    size: context.getRSize(14),
                    color: _subtext,
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }

  Widget _inlinePriceInput(TextEditingController controller) {
    return Container(
      width: context.getRSize(100),
      padding: EdgeInsets.symmetric(
        horizontal: context.getRSize(8),
        vertical: context.getRSize(4),
      ),
      decoration: BoxDecoration(
        color: _bg,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: _border),
      ),
      child: AppInput(
        controller: controller,
        readOnly: !_editMode,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        inputFormatters: [CurrencyInputFormatter()],
        textAlign: TextAlign.end,
        onChanged: (v) => setState(() {}),
        border: InputBorder.none,
        contentPadding: EdgeInsets.zero,
        prefixText: activeCurrencySymbol,
        fillColor: Colors.transparent,
      ),
    );
  }

  void _confirmDelete(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _surface,
        title: Text('Delete Product', style: TextStyle(color: _text)),
        content: Text(
          'Are you sure you want to delete ${widget.item.productName}? This action cannot be undone.',
          style: TextStyle(color: _text),
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
              final productName = widget.item.productName;
              final productId = widget.item.id;
              final db = ref.read(databaseProvider);
              final actorId = ref.read(authProvider).currentUser?.id;
              // Remove any remaining stock first, so the deletion is recorded
              // in the History tab as adjustment rows (§16.8) and the product
              // stops counting toward stock totals. Best-effort — a failure
              // here must not block the soft-delete + activity log.
              try {
                final stores = await db.storesDao.getActiveStores();
                for (final s in stores) {
                  final rows = await db.inventoryDao.getProductsWithStock(
                    storeId: s.id,
                  );
                  final qty = rows
                          .where((r) => r.product.id == productId)
                          .firstOrNull
                          ?.totalStock ??
                      0;
                  if (qty > 0) {
                    await db.inventoryDao.adjustStock(
                      productId,
                      s.id,
                      -qty,
                      'Product deleted: $productName',
                      actorId,
                    );
                  }
                }
              } catch (e, st) {
                CrashReporter.record(e, st,
                    context: 'inventory.product_detail.delete_stock_zero');
                debugPrint('Delete stock-zeroing error: $e');
              }
              try {
                await db.catalogDao.softDeleteProduct(productId);
                await ref
                    .read(activityLogProvider)
                    .logAction(
                      'delete_product',
                      '${ref.read(authProvider).currentUser?.name ?? 'Unknown'} deleted product: $productName',
                      productId: productId,
                    );
                ref.read(cartProvider).removeItem(productName);
                if (!context.mounted) return;
                Navigator.pop(ctx);
                Navigator.pop(context);
                AppNotification.showSuccess(context, '$productName deleted');
              } catch (e, st) {
                CrashReporter.record(e, st,
                    context: 'inventory.product_detail.delete');
                if (!context.mounted) return;
                AppNotification.showError(
                    context, 'Could not delete product. Please try again.');
              }
            },
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// _UpdateStockSheet — the Stock keeper's "Update Stock" bottom sheet (§16.6).
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
  final Future<String?> Function({
    required bool isRemove,
    required int qty,
    required StoreData store,
    String? reason,
    required String notes,
  }) onSave;

  @override
  ConsumerState<_UpdateStockSheet> createState() => _UpdateStockSheetState();
}

class _UpdateStockSheetState extends ConsumerState<_UpdateStockSheet> {
  final _qtyCtrl = TextEditingController();
  final _notesCtrl = TextEditingController();
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
    super.dispose();
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
          context, 'You don\'t have permission to remove stock.');
      return;
    }
    if (!_isRemove && !widget.canAddNow()) {
      AppNotification.showError(
          context, 'You don\'t have permission to add stock.');
      return;
    }
    setState(() => _saving = true);
    final error = await widget.onSave(
      isRemove: _isRemove,
      qty: qty,
      store: _selectedStore,
      reason: _reason,
      notes: _notesCtrl.text.trim(),
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
              'Update Stock',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w800,
                color: _text,
              ),
            ),
            Text(
              product.name,
              style: TextStyle(fontSize: 13, color: _subtext),
            ),
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
                        child: Text(
                          s.name,
                          overflow: TextOverflow.ellipsis,
                        ),
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
                    .map(
                      (r) => DropdownMenuItem(value: r, child: Text(r)),
                    )
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
