import 'dart:io';
import 'package:flutter/material.dart';
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
import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:reebaplus_pos/core/utils/notifications.dart';
import 'package:reebaplus_pos/shared/widgets/app_input.dart';
import 'package:reebaplus_pos/features/inventory/widgets/update_product_sheet.dart';

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
  late TextEditingController _quantityController;
  late TextEditingController _buyingPriceController;
  late TextEditingController _retailPriceController;
  late TextEditingController _wholesalerPriceController;
  late TextEditingController _monthlyTargetController;
  late TextEditingController _emptyCratesController;
  late TextEditingController _emptyCrateValueController;

  int _monthlyTarget = 0;
  int? _emptyCrateStock; // original value loaded from DB
  String? _selectedManufacturerId; // DB id of the linked manufacturer
  String? _selectedCategoryId;
  String? _selectedUnit;
  List<String> _allUnits = [];
  List<CategoryData> _allCategories = [];
  List<ManufacturerData> _allManufacturers = [];

  ProductData? _productData; // full DB row, used by UpdateProductSheet

  ProductSalesSummary? _salesSummary;
  LastShipmentInfo? _lastDelivery;
  bool _deliveryLoaded = false;
  bool _contentReady = false; // deferred load flag
  String? _imagePath;

  // ── Role gating (master plan §16.6 / §16.7) ────────────────────────────────
  // Full edit (inline fields, "Update Product", delete) is CEO + Manager via
  // `products.edit_price`. Buying price visibility is `products.edit_buying_price`
  // (also CEO + Manager). Stock keeper can only adjust quantities via the
  // "Update Stock" modal (`stock.adjust`). Cashier has none → view-only.
  // Read (not watch) so these getters are safe to call from non-build handlers.
  bool get _canEdit =>
      ref.read(currentUserPermissionsProvider).contains('products.edit_price');
  bool get _canEditBuying => ref
      .read(currentUserPermissionsProvider)
      .contains('products.edit_buying_price');
  bool get _canAdjustStock =>
      ref.read(currentUserPermissionsProvider).contains('stock.adjust');

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.item.productName);
    _subtitleController = TextEditingController(text: widget.item.subtitle);
    _quantityController = TextEditingController(
      text: widget.item.totalStock.toStringAsFixed(
        widget.item.totalStock % 1 == 0 ? 0 : 1,
      ),
    );
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
    _selectedUnit = widget.item.unit;
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
    final uniqueUnits = await db.catalogDao.getUniqueProductUnits();

    if (mounted) {
      setState(() {
        _allCategories = categories;
        _allManufacturers = manufacturers;
        _allUnits = {
          'Bottle',
          'Crate',
          'Pack',
          'Carton',
          'Keg',
          'Can',
          if (_selectedUnit != null) _selectedUnit!,
          ...uniqueUnits,
        }.toList()..sort();

        if (product != null) {
          _productData = product;
          _monthlyTarget = product.monthlyTargetUnits;
          _monthlyTargetController.text = _monthlyTarget.toString();
          _selectedCategoryId = product.categoryId;
          _selectedManufacturerId = product.manufacturerId;
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

  void _onRetailPriceChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _retailPriceController.removeListener(_onRetailPriceChanged);
    _nameController.dispose();
    _subtitleController.dispose();
    _quantityController.dispose();
    _buyingPriceController.dispose();
    _retailPriceController.dispose();
    _wholesalerPriceController.dispose();
    _monthlyTargetController.dispose();
    _emptyCratesController.dispose();
    _emptyCrateValueController.dispose();
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
    // Subscribe to permission changes so the role-gated UI (buying row,
    // action button) rebuilds when the role + its grants resolve locally.
    // The `_canEdit` family of getters read the same provider.
    ref.watch(currentUserPermissionsProvider);
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
        widget.item.totalStock > 0 &&
        widget.item.totalStock <= widget.item.lowStockThreshold;
    final isOut = widget.item.totalStock == 0;
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
        if (_canEdit)
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
                              border: Border.all(color: Colors.white, width: 2),
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
                    readOnly: !_canEdit,
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
      widget.item.totalStock,
    );

    // Display size nicely (big → Big, medium → Medium, small → Small)
    final sizeLabel = widget.item.size != null
        ? '${widget.item.size![0].toUpperCase()}${widget.item.size!.substring(1)}'
        : 'N/A';

    return Padding(
      padding: EdgeInsets.fromLTRB(
        context.getRSize(20),
        context.getRSize(16),
        context.getRSize(20),
        context.getRSize(16) + context.bottomInset,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Stock & Info ─────────────────────────────────────────
          _sectionTitle(context, 'Stock & Info'),
          SizedBox(height: context.getRSize(12)),
          _infoCard(context, [
            _infoRow(
              context,
              FontAwesomeIcons.cubesStacked,
              'Total Quantity',
              '',
              Theme.of(context).colorScheme.primary,
              trailing: Container(
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
                child: GestureDetector(
                  onTap: widget.selectedStoreId == null && _canEdit
                      ? () => AppNotification.showError(
                          context,
                          'Select a specific store to edit stock quantity.',
                        )
                      : null,
                  child: AppInput(
                    controller: _quantityController,
                    readOnly: !_canEdit || widget.selectedStoreId == null,
                    keyboardType: TextInputType.number,
                    textAlign: TextAlign.center,
                    onChanged: (v) => setState(() {}),
                    border: InputBorder.none,
                    contentPadding: EdgeInsets.zero,
                    fillColor: Colors.transparent,
                  ),
                ),
              ),
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
                  onChanged: _canEdit
                      ? (v) => setState(() => _selectedManufacturerId = v)
                      : (_) {},
                ),
              ),
            ),
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
                  onChanged: _canEdit
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
                  onChanged: _canEdit
                      ? (val) => setState(() => _selectedUnit = val)
                      : (_) {},
                ),
              ),
            ),
            _divider(context),
            // Empty Crate Value
            _infoRow(
              context,
              FontAwesomeIcons.circleDollarToSlot,
              'Empty Crate Value',
              '',
              const Color(0xFF14B8A6),
              trailing: Container(
                width: context.getRSize(90),
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
                  controller: _emptyCrateValueController,
                  readOnly: true,
                  keyboardType: TextInputType.number,
                  textAlign: TextAlign.end,
                  onChanged: (v) => setState(() {}),
                  border: InputBorder.none,
                  contentPadding: EdgeInsets.zero,
                  prefixText: '₦',
                  fillColor: Colors.transparent,
                ),
              ),
            ),
            _divider(context),
            // Empty Crates — uneditable, shows manufacturer total
            _infoRow(
              context,
              FontAwesomeIcons.beerMugEmpty,
              'Empty Crates',
              '',
              const Color(0xFFF59E0B),
              trailing: Container(
                padding: EdgeInsets.symmetric(
                  horizontal: context.getRSize(12),
                  vertical: context.getRSize(6),
                ),
                decoration: BoxDecoration(
                  color: Theme.of(
                    context,
                  ).colorScheme.primary.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: Theme.of(
                      context,
                    ).colorScheme.primary.withValues(alpha: 0.2),
                  ),
                ),
                child: Text(
                  _emptyCrateStock?.toString() ?? '0',
                  style: TextStyle(
                    fontSize: context.getRFontSize(14),
                    fontWeight: FontWeight.bold,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
              ),
            ),
            _divider(context),
            _infoRow(
              context,
              FontAwesomeIcons.layerGroup,
              'Size',
              sizeLabel,
              const Color(0xFF8B5CF6),
            ),
            // ── Expiry Date (if set) + near-expiry badge (§16.6) ───────
            if (_productData?.expiryDate != null) ...[
              _divider(context),
              _infoRow(
                context,
                FontAwesomeIcons.calendarXmark,
                'Expiry Date',
                _formatDate(_productData!.expiryDate!),
                const Color(0xFFF59E0B),
                trailing: _expiryBadge(context, _productData!.expiryDate!),
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

          // ── Sales Target ────────────────────────────────────────────
          _sectionTitle(context, 'Sales Target'),
          SizedBox(height: context.getRSize(12)),
          _buildTargetGrid(context),

          SizedBox(height: context.getRSize(24)),

          // ── Last Delivery ───────────────────────────────────────────
          _sectionTitle(context, 'Last Delivery'),
          SizedBox(height: context.getRSize(12)),
          _buildDeliveryCard(context),

          SizedBox(height: context.getRSize(32)),
          if (_canEdit) ...[
            // ── CEO / Manager: full edit ──────────────────────────────
            AppButton(
              text: 'Update Product',
              variant: AppButtonVariant.primary,
              icon: FontAwesomeIcons.penToSquare,
              onPressed: _productData == null
                  ? null
                  : () => showModalBottomSheet<void>(
                      context: context,
                      isScrollControlled: true,
                      backgroundColor: Colors.transparent,
                      builder: (_) => UpdateProductSheet(
                        product: _productData!,
                        totalStock: widget.item.totalStock.toInt(),
                        currentStoreId: widget.selectedStoreId,
                        onProductUpdated: () {
                          widget.onUpdateStock();
                          if (mounted) Navigator.pop(context);
                        },
                      ),
                    ),
            ),
          ] else if (_canAdjustStock) ...[
            // ── Stock keeper: quantity adjustments only (§16.6) ───────
            AppButton(
              text: 'Update Stock',
              variant: AppButtonVariant.primary,
              icon: FontAwesomeIcons.boxesStacked,
              onPressed:
                  _productData == null ? null : () => _showUpdateStockModal(),
            ),
          ] else ...[
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
                    size: context.getRSize(16),
                    color: _subtext,
                  ),
                  SizedBox(width: context.getRSize(8)),
                  Flexible(
                    child: Text(
                      'View only — this product is not in your store',
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: context.getRFontSize(13),
                        color: _subtext,
                      ),
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
                        readOnly: !_canEdit,
                        keyboardType: TextInputType.number,
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
    if (!_canEdit) return;

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
    } catch (e) {
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

  /// Stock keeper "Update Stock" modal (master plan §16.6): add / remove a
  /// quantity against a store, with a required reason on removal, optional
  /// notes. Writes through `adjustStock` (so the cloud delta envelope is
  /// enqueued) and logs to History.
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

    final qtyCtrl = TextEditingController();
    final notesCtrl = TextEditingController();
    var isRemove = false;
    const reasons = ['Damage', 'Theft', 'Expired', 'Other'];
    String? reason;
    StoreData selectedStore = stores.cast<StoreData?>().firstWhere(
          (s) => s?.id == widget.selectedStoreId,
          orElse: () => stores.first,
        )!;
    var saving = false;

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetCtx) {
        return StatefulBuilder(
          builder: (sheetCtx, setSheet) {
            Future<void> doSave() async {
              final qty = int.tryParse(qtyCtrl.text.trim()) ?? 0;
              if (qty <= 0) {
                AppNotification.showError(
                  sheetCtx,
                  'Quantity must be greater than 0.',
                );
                return;
              }
              if (isRemove && reason == null) {
                AppNotification.showError(
                  sheetCtx,
                  'A reason is required when removing stock.',
                );
                return;
              }
              setSheet(() => saving = true);
              final auth = ref.read(authProvider);
              final actorName = auth.currentUser?.name ?? 'Unknown';
              final notes = notesCtrl.text.trim();
              final delta = isRemove ? -qty : qty;
              final note = isRemove
                  ? '${reason!}${notes.isEmpty ? '' : ': $notes'}'
                  : (notes.isEmpty ? 'Stock added by $actorName' : notes);
              try {
                await db.inventoryDao.adjustStock(
                  product.id,
                  selectedStore.id,
                  delta,
                  note,
                  auth.currentUser?.id,
                );
                await ref.read(activityLogProvider).logAction(
                      'stock_adjustment',
                      '$actorName ${isRemove ? 'removed' : 'added'} $qty '
                          '${product.unit}(s) of ${product.name} '
                          '(${selectedStore.name})'
                          '${isRemove ? ' — ${reason!}' : ''}',
                      productId: product.id,
                      storeId: selectedStore.id,
                    );
                if (sheetCtx.mounted) Navigator.pop(sheetCtx);
                widget.onUpdateStock();
              } catch (e) {
                debugPrint('UpdateStock modal save error: $e');
                if (sheetCtx.mounted) {
                  AppNotification.showError(
                    sheetCtx,
                    'Could not update stock: $e',
                  );
                }
                setSheet(() => saving = false);
              }
            }

            Widget modeChip(String label, bool removeMode) {
              final selected = isRemove == removeMode;
              final color = removeMode ? danger : success;
              return Expanded(
                child: GestureDetector(
                  onTap: () => setSheet(() {
                    isRemove = removeMode;
                    if (!removeMode) reason = null;
                  }),
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    decoration: BoxDecoration(
                      color: selected
                          ? color.withValues(alpha: 0.15)
                          : _surface,
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

            return Padding(
              padding: EdgeInsets.only(
                bottom: MediaQuery.of(sheetCtx).viewInsets.bottom,
              ),
              child: Container(
                decoration: BoxDecoration(
                  color: _bg,
                  borderRadius:
                      const BorderRadius.vertical(top: Radius.circular(28)),
                ),
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
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
                        modeChip('Add stock', false),
                        const SizedBox(width: 10),
                        modeChip('Remove stock', true),
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
                        value: selectedStore,
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
                            setSheet(() => selectedStore = v ?? selectedStore),
                      ),
                      const SizedBox(height: 14),
                    ],
                    AppInput(
                      controller: qtyCtrl,
                      labelText: 'Quantity *',
                      hintText: '0',
                      keyboardType: TextInputType.number,
                    ),
                    if (isRemove) ...[
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
                        value: reason,
                        hintText: 'Select a reason',
                        items: reasons
                            .map(
                              (r) =>
                                  DropdownMenuItem(value: r, child: Text(r)),
                            )
                            .toList(),
                        onChanged: (v) => setSheet(() => reason = v),
                      ),
                    ],
                    const SizedBox(height: 14),
                    AppInput(
                      controller: notesCtrl,
                      labelText: 'Notes (optional)',
                      hintText: 'Any extra detail…',
                    ),
                    const SizedBox(height: 20),
                    AppButton(
                      text: isRemove ? 'Remove Stock' : 'Add Stock',
                      variant: AppButtonVariant.primary,
                      isLoading: saving,
                      onPressed: doSave,
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
    qtyCtrl.dispose();
    notesCtrl.dispose();
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
        readOnly: !_canEdit,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        inputFormatters: [CurrencyInputFormatter()],
        textAlign: TextAlign.end,
        onChanged: (v) => setState(() {}),
        border: InputBorder.none,
        contentPadding: EdgeInsets.zero,
        prefixText: '₦',
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
              await ref
                  .read(databaseProvider)
                  .catalogDao
                  .softDeleteProduct(productId);
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
            },
          ),
        ],
      ),
    );
  }
}
