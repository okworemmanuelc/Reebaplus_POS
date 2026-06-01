import 'package:drift/drift.dart' as drift;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/utils/currency_input_formatter.dart';
import 'package:reebaplus_pos/core/utils/notifications.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';

import 'package:reebaplus_pos/shared/widgets/app_dropdown.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/core/utils/product_name.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:reebaplus_pos/shared/widgets/app_input.dart';

/// Add Product — a full pushed screen (master plan §16.5, amended 2026-05-30:
/// the form outgrew a bottom-sheet modal). Also doubles as the "add stock to an
/// existing product" surface when a name search matches an existing product.
///
/// Pivot step 15 changes vs the old `AddProductSheet`:
///  - Scaffold screen (AppBar + body + pinned save button) instead of a modal.
///  - Three prices: Retailer + Wholesaler (both required), Buying (required,
///    hidden unless the role grants `products.edit_buying_price`). The interim
///    "wholesaler mirrors retailer" stopgap is gone.
///  - Empty Crate Value (₦) shown only when "Track empty crate returns" is on.
///  - Optional Expiry Date (all business types).
///  - Colour selector removed (products keep a default `colorHex`).
class AddProductScreen extends ConsumerStatefulWidget {
  final VoidCallback? onProductAdded;
  const AddProductScreen({super.key, this.onProductAdded});

  @override
  ConsumerState<AddProductScreen> createState() => _AddProductScreenState();
}

class _AddProductScreenState extends ConsumerState<AddProductScreen> {
  final _nameCtrl = TextEditingController();
  final _subtitleCtrl = TextEditingController();
  final _retailPriceCtrl = TextEditingController();
  final _wholesalePriceCtrl = TextEditingController();
  final _buyingPriceCtrl = TextEditingController();
  final _emptyCrateValueCtrl = TextEditingController();
  final _lowStockCtrl = TextEditingController(text: '5');
  final _initialStockCtrl = TextEditingController(text: '0');
  final _supplierCtrl = TextEditingController();
  final _manufacturerCtrl = TextEditingController();

  String _unit = 'Bottle';
  bool _trackEmpties = true; // defaults true when unit is Bottle
  bool _allowFractionalSales = false;
  // Colour selector is deferred (master plan §16.5); products keep a default.
  final String _colorHex = '#3B82F6';
  String? _size; // null = not a crate-based product
  DateTime? _expiryDate; // optional single expiry date (all business types)
  StoreData? _selectedStore;
  SupplierData? _selectedSupplier;
  CategoryData? _selectedCategory;
  ManufacturerData? _selectedManufacturer;

  List<StoreData> _stores = [];
  List<SupplierData> _allSuppliers = [];
  List<CategoryData> _allCategories = [];
  List<SupplierData> _supplierSuggestions = [];
  List<ManufacturerData> _allManufacturers = [];
  List<ManufacturerData> _manufacturerSuggestions = [];

  List<ProductData> _allProducts = [];
  List<ProductData> _productSuggestions = [];
  ProductData? _selectedExistingProduct;
  bool _isSaving = false;
  String? _errorMessage;

  static const _units = kProductUnits;
  List<String> _dynamicUnits = _units;

  /// Whether the current role may see / set the buying price (master plan
  /// §16.5 / §16.7). Reads (not watches) so it is safe to call from `_save`.
  bool get _canEditBuying =>
      ref.read(currentUserPermissionsProvider).contains('products.edit_buying_price');

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    final db = ref.read(databaseProvider);
    final whs = await db.storesDao.getActiveStores();
    final suppliers = await db.catalogDao.getAllSuppliers();
    final manufacturers = await db.inventoryDao.getAllManufacturers();
    var cats = await db.inventoryDao.getAllCategories();
    final productsList = await (db.select(
      db.products,
    )..where((t) => t.isDeleted.not())).get();
    final uniqueUnits = await db.catalogDao.getUniqueProductUnits();

    if (cats.isEmpty) {
      final defaultCats = [
        'Alcoholic',
        'Non-Alcoholic',
        'Energy Drinks',
        'Wines',
        'Spirits',
      ];
      final businessId = ref.read(authProvider).currentUser?.businessId;
      if (businessId != null) {
        for (final name in defaultCats) {
          await db.catalogDao.insertCategory(
            CategoriesCompanion.insert(name: name, businessId: businessId),
          );
        }
      }
      cats = await db.inventoryDao.getAllCategories();
    }

    if (mounted) {
      setState(() {
        _stores = whs;
        _allSuppliers = suppliers;
        _allManufacturers = manufacturers;
        _allCategories = cats;
        _allProducts = productsList;
        // Merge fetched units with defaults to ensure a rich list
        final mergedUnits = {
          ..._units, // static defaults
          ...uniqueUnits,
        }.toList()..sort();
        _dynamicUnits = mergedUnits;

        if (whs.isNotEmpty) _selectedStore = whs.first;
        if (cats.isNotEmpty) _selectedCategory = cats.first;
      });
    }
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _subtitleCtrl.dispose();
    _retailPriceCtrl.dispose();
    _wholesalePriceCtrl.dispose();
    _buyingPriceCtrl.dispose();
    _emptyCrateValueCtrl.dispose();
    _lowStockCtrl.dispose();
    _initialStockCtrl.dispose();
    _supplierCtrl.dispose();
    _manufacturerCtrl.dispose();
    super.dispose();
  }

  void _onSupplierChanged(String query) {
    final q = query.trim().toLowerCase();
    setState(() {
      _supplierSuggestions = q.isEmpty
          ? []
          : _allSuppliers
                .where((s) => s.name.toLowerCase().contains(q))
                .take(20)
                .toList();
    });
  }

  void _selectSupplier(SupplierData supplier) {
    _supplierCtrl.text = supplier.name;
    setState(() {
      _selectedSupplier = supplier;
      _supplierSuggestions = [];
    });
  }

  void _clearSupplier() {
    _supplierCtrl.clear();
    setState(() {
      _selectedSupplier = null;
      _supplierSuggestions = [];
    });
  }

  void _onManufacturerChanged(String query) {
    final q = query.trim().toLowerCase();
    setState(() {
      _manufacturerSuggestions = q.isEmpty
          ? []
          : _allManufacturers
                .where((m) => m.name.toLowerCase().contains(q))
                .take(20)
                .toList();
    });
  }

  void _selectManufacturer(ManufacturerData manufacturer) {
    _manufacturerCtrl.text = manufacturer.name;
    setState(() {
      _selectedManufacturer = manufacturer;
      _manufacturerSuggestions = [];
      // Crate value is shared at the manufacturer level — autofill it from the
      // chosen manufacturer (§16.5). The user can still override the field.
      if (manufacturer.depositAmountKobo > 0) {
        _emptyCrateValueCtrl.text = (manufacturer.depositAmountKobo / 100)
            .toStringAsFixed(2);
      }
    });
  }

  void _clearManufacturer() {
    _manufacturerCtrl.clear();
    setState(() {
      _selectedManufacturer = null;
      _manufacturerSuggestions = [];
    });
  }

  void _onNameChanged(String query) {
    final q = query.trim().toLowerCase();
    setState(() {
      _selectedExistingProduct = null;
      _productSuggestions = q.isEmpty
          ? []
          : _allProducts
                .where((p) => p.name.toLowerCase().contains(q))
                .take(20)
                .toList();
    });
  }

  void _selectProduct(ProductData product) {
    _nameCtrl.text = product.name;
    _subtitleCtrl.text = product.subtitle ?? '';
    _retailPriceCtrl.text =
        (product.retailerPriceKobo / 100).toStringAsFixed(2);
    _wholesalePriceCtrl.text =
        (product.wholesalerPriceKobo / 100).toStringAsFixed(2);
    _buyingPriceCtrl.text = (product.buyingPriceKobo / 100).toStringAsFixed(2);
    _emptyCrateValueCtrl.text = product.emptyCrateValueKobo > 0
        ? (product.emptyCrateValueKobo / 100).toStringAsFixed(2)
        : '';
    _lowStockCtrl.text = product.lowStockThreshold.toString();

    setState(() {
      _selectedExistingProduct = product;
      _unit = product.unit;
      _size = product.size;
      _trackEmpties = product.trackEmpties;
      _allowFractionalSales = product.allowFractionalSales;
      _expiryDate = product.expiryDate;
      _selectedCategory = _allCategories.cast<CategoryData?>().firstWhere(
        (c) => c?.id == product.categoryId,
        orElse: () => _selectedCategory,
      );
      _selectedManufacturer = _allManufacturers
          .cast<ManufacturerData?>()
          .firstWhere(
            (m) => m?.id == product.manufacturerId,
            orElse: () => null,
          );
      if (_selectedManufacturer != null) {
        _manufacturerCtrl.text = _selectedManufacturer!.name;
      }
      _selectedSupplier = _allSuppliers.cast<SupplierData?>().firstWhere(
        (s) => s?.id == product.supplierId,
        orElse: () => null,
      );
      if (_selectedSupplier != null) {
        _supplierCtrl.text = _selectedSupplier!.name;
      }
      _productSuggestions = [];
    });
  }

  void _clearExistingProduct() {
    _nameCtrl.clear();
    _subtitleCtrl.clear();
    _retailPriceCtrl.clear();
    _wholesalePriceCtrl.clear();
    _buyingPriceCtrl.clear();
    _emptyCrateValueCtrl.clear();
    _lowStockCtrl.text = '5';
    _initialStockCtrl.text = '0';
    _manufacturerCtrl.clear();
    _supplierCtrl.clear();
    setState(() {
      _selectedExistingProduct = null;
      _unit = 'Bottle';
      _size = null;
      _expiryDate = null;
      _trackEmpties = true;
      _allowFractionalSales = false;
      _selectedManufacturer = null;
      _selectedSupplier = null;
    });
  }

  Future<void> _createNewManufacturer(String name) async {
    final db = ref.read(databaseProvider);
    final businessId = ref.read(authProvider).currentUser?.businessId;
    if (businessId == null) return;
    final id = await db.inventoryDao.insertManufacturer(
      ManufacturersCompanion.insert(name: name, businessId: businessId),
    );
    final manufacturers = await db.inventoryDao.getAllManufacturers();
    final newM = manufacturers.firstWhere((m) => m.id == id);
    setState(() {
      _allManufacturers = manufacturers;
      _selectManufacturer(newM);
    });
  }

  Future<void> _createNewSupplier(String name) async {
    final db = ref.read(databaseProvider);
    final businessId = ref.read(authProvider).currentUser?.businessId;
    if (businessId == null) return;
    final id = await db.catalogDao.insertSupplier(
      SuppliersCompanion.insert(name: name, businessId: businessId),
    );
    final suppliers = await db.catalogDao.getAllSuppliers();
    final newS = suppliers.firstWhere((s) => s.id == id);
    setState(() {
      _allSuppliers = suppliers;
      _selectSupplier(newS);
    });
  }

  Future<ManufacturerData?> _getOrCreateManufacturer(String name) async {
    final db = ref.read(databaseProvider);
    final businessId = ref.read(authProvider).currentUser?.businessId;
    if (businessId == null) return null;
    final existing = await db.inventoryDao.getAllManufacturers();
    final match = existing
        .where((m) => m.name.toLowerCase() == name.toLowerCase())
        .firstOrNull;
    if (match != null) return match;

    final id = await db.inventoryDao.insertManufacturer(
      ManufacturersCompanion.insert(name: name, businessId: businessId),
    );
    final manufacturers = await db.inventoryDao.getAllManufacturers();
    return manufacturers.firstWhere((m) => m.id == id);
  }

  Future<SupplierData?> _getOrCreateSupplier(String name) async {
    final db = ref.read(databaseProvider);
    final businessId = ref.read(authProvider).currentUser?.businessId;
    if (businessId == null) return null;
    final existing = await db.catalogDao.getAllSuppliers();
    final match = existing
        .where((s) => s.name.toLowerCase() == name.toLowerCase())
        .firstOrNull;
    if (match != null) return match;

    final id = await db.catalogDao.insertSupplier(
      SuppliersCompanion.insert(name: name, businessId: businessId),
    );
    final suppliers = await db.catalogDao.getAllSuppliers();
    return suppliers.firstWhere((s) => s.id == id);
  }

  Future<void> _pickExpiryDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _expiryDate ?? now,
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year + 20),
      helpText: 'Select expiry date',
    );
    if (picked != null) setState(() => _expiryDate = picked);
  }

  /// Empty-crate value in kobo, or null when not tracking empties / left blank.
  int? get _emptyCrateValueKobo {
    if (!(_trackEmpties && _unit.toLowerCase() == 'bottle')) return null;
    final raw = _emptyCrateValueCtrl.text.trim();
    if (raw.isEmpty) return null;
    return (parseCurrency(raw) * 100).round();
  }

  Future<void> _save() async {
    final db = ref.read(databaseProvider);
    final auth = ref.read(authProvider);
    final canEditBuying = _canEditBuying;

    setState(() => _errorMessage = null);

    // ── EXISTING PRODUCT: update details + add stock ───────────────────────
    if (_selectedExistingProduct != null) {
      final existingName = _nameCtrl.text.trim();
      if (_selectedStore == null) {
        AppNotification.showError(context, 'Store is required.');
        return;
      }
      final qty = int.tryParse(_initialStockCtrl.text) ?? 0;
      if (qty <= 0) {
        AppNotification.showError(context, 'Quantity must be greater than 0.');
        return;
      }
      if (existingName.isEmpty) {
        AppNotification.showError(context, 'Product Name is required.');
        return;
      }
      if (_retailPriceCtrl.text.trim().isEmpty) {
        AppNotification.showError(context, 'Retailer Price is required.');
        return;
      }
      if (_wholesalePriceCtrl.text.trim().isEmpty) {
        AppNotification.showError(context, 'Wholesaler Price is required.');
        return;
      }
      final existingRetail = parseCurrency(_retailPriceCtrl.text);
      final existingWholesale = parseCurrency(_wholesalePriceCtrl.text);
      // Buying price stays hidden (and untouched) for roles without the
      // permission — preserve the stored value rather than zeroing it.
      final existingBuying = canEditBuying
          ? parseCurrency(_buyingPriceCtrl.text)
          : _selectedExistingProduct!.buyingPriceKobo / 100;
      if (existingBuying > existingRetail) {
        AppNotification.showError(
          context,
          'Buying price cannot be higher than retailer price.',
        );
        return;
      }

      // Auto-handle manufacturer/supplier if typed but not selected
      if (_selectedManufacturer == null &&
          _manufacturerCtrl.text.trim().isNotEmpty) {
        _selectedManufacturer = await _getOrCreateManufacturer(
          _manufacturerCtrl.text.trim(),
        );
      }
      if (_selectedSupplier == null && _supplierCtrl.text.trim().isNotEmpty) {
        _selectedSupplier = await _getOrCreateSupplier(
          _supplierCtrl.text.trim(),
        );
      }

      setState(() => _isSaving = true);
      try {
        final productId = _selectedExistingProduct!.id;
        final retailKobo = (existingRetail * 100).round();
        final wholesaleKobo = (existingWholesale * 100).round();
        final buyingKobo = (existingBuying * 100).round();
        final lowStock = int.tryParse(_lowStockCtrl.text) ?? 5;

        // 1. Update product details
        await db.catalogDao.updateProductDetails(
          productId,
          name: existingName,
          manufacturerId: _selectedManufacturer?.id,
          buyingPriceKobo: buyingKobo,
          retailerPriceKobo: retailKobo,
          wholesalerPriceKobo: wholesaleKobo,
          emptyCrateValueKobo: _emptyCrateValueKobo,
          categoryId: _selectedCategory?.id,
          unit: _unit,
          trackEmpties: _trackEmpties,
          allowFractionalSales: _allowFractionalSales,
          lowStockThreshold: lowStock,
          subtitle: _subtitleCtrl.text.trim().isEmpty
              ? null
              : _subtitleCtrl.text.trim(),
          colorHex: _colorHex,
          supplierId: _selectedSupplier?.id,
          size: _size,
          expiryDate: _expiryDate,
        );

        // Persist the crate value at the manufacturer level (§16.5).
        if (_selectedManufacturer != null && _emptyCrateValueKobo != null) {
          await db.catalogDao.updateManufacturerEmptyCrateValue(
            _selectedManufacturer!.id,
            _emptyCrateValueKobo!,
          );
        }

        // 2. Add stock
        await db.inventoryDao.adjustStock(
          productId,
          _selectedStore!.id,
          qty,
          'Restock by ${auth.currentUser?.name ?? 'Unknown'}',
          auth.currentUser?.id,
        );

        await ref
            .read(activityLogProvider)
            .logAction(
              'stock_update',
              '${auth.currentUser?.name ?? 'Unknown'} updated $existingName and added $qty units',
              productId: productId,
            );
        if (mounted) Navigator.pop(context);
        widget.onProductAdded?.call();
      } catch (e) {
        debugPrint('AddProductScreen._save (existing) error: $e');
        if (mounted) {
          AppNotification.showError(context, 'Could not update product: $e');
        }
      } finally {
        if (mounted) setState(() => _isSaving = false);
      }
      return;
    }

    // ── NEW PRODUCT ─────────────────────────────────────────────────────────
    final name = _nameCtrl.text.trim();

    String? missingField;
    if (name.isEmpty) {
      missingField = 'Product Name';
    } else if (_subtitleCtrl.text.trim().isEmpty) {
      missingField = 'Description / Subtitle';
    } else if (_selectedCategory == null) {
      missingField = 'Category';
    } else if (_retailPriceCtrl.text.trim().isEmpty) {
      missingField = 'Retailer Price';
    } else if (_wholesalePriceCtrl.text.trim().isEmpty) {
      missingField = 'Wholesaler Price';
    } else if (canEditBuying && _buyingPriceCtrl.text.trim().isEmpty) {
      missingField = 'Buying Price';
    } else if (_lowStockCtrl.text.trim().isEmpty) {
      missingField = 'Low Stock Alert';
    } else if (_selectedStore == null) {
      missingField = 'Store';
    } else if (_initialStockCtrl.text.trim().isEmpty) {
      missingField = 'Initial Quantity';
    }

    if (missingField != null) {
      AppNotification.showError(context, '$missingField is required.');
      return;
    }

    final retailPrice = parseCurrency(_retailPriceCtrl.text);
    final wholesalePrice = parseCurrency(_wholesalePriceCtrl.text);
    final buyingPrice =
        canEditBuying ? parseCurrency(_buyingPriceCtrl.text) : 0.0;

    if (canEditBuying && buyingPrice > retailPrice) {
      AppNotification.showError(
        context,
        'Buying price (₦$buyingPrice) cannot be higher than retailer price (₦$retailPrice).',
      );
      return;
    }

    // Check for duplicate product name
    final existing = await db.catalogDao.findByName(name);
    if (existing != null) {
      if (mounted) {
        AppNotification.showError(
          context,
          'A product named "$name" already exists.',
        );
      }
      return;
    }

    setState(() => _isSaving = true);
    try {
      // Auto-handle Manufacturer & Supplier if they were typed but not explicitly "selected"
      if (_selectedManufacturer == null &&
          _manufacturerCtrl.text.trim().isNotEmpty) {
        _selectedManufacturer = await _getOrCreateManufacturer(
          _manufacturerCtrl.text.trim(),
        );
      }
      if (_selectedSupplier == null && _supplierCtrl.text.trim().isNotEmpty) {
        _selectedSupplier = await _getOrCreateSupplier(
          _supplierCtrl.text.trim(),
        );
      }

      if (_selectedManufacturer == null) {
        setState(() => _isSaving = false);
        if (mounted) {
          AppNotification.showError(
            context,
            'Manufacturer is required. Please select or create one.',
          );
        }
        return;
      }

      final productBusinessId = auth.currentUser?.businessId;
      if (productBusinessId == null) {
        setState(() => _isSaving = false);
        if (mounted) {
          AppNotification.showError(context, 'Account not loaded yet.');
        }
        return;
      }

      final retailKobo = (retailPrice * 100).round();
      final wholesaleKobo = (wholesalePrice * 100).round();
      final buyingKobo = (buyingPrice * 100).round();
      final lowStock = int.tryParse(_lowStockCtrl.text) ?? 5;
      final initialStock = int.tryParse(_initialStockCtrl.text) ?? 0;
      final crateValueKobo = _emptyCrateValueKobo;
      final productId = await db.catalogDao.insertProductWithInitialStock(
        ProductsCompanion.insert(
          name: name,
          businessId: productBusinessId,
          subtitle: drift.Value(
            _subtitleCtrl.text.trim().isEmpty
                ? null
                : _subtitleCtrl.text.trim(),
          ),
          retailerPriceKobo: drift.Value(retailKobo),
          wholesalerPriceKobo: drift.Value(wholesaleKobo),
          buyingPriceKobo: drift.Value(buyingKobo),
          unit: drift.Value(_unit),
          trackEmpties: drift.Value(_trackEmpties),
          emptyCrateValueKobo: crateValueKobo == null
              ? const drift.Value.absent()
              : drift.Value(crateValueKobo),
          allowFractionalSales: drift.Value(_allowFractionalSales),
          colorHex: drift.Value(_colorHex),
          size: drift.Value(_size),
          expiryDate: drift.Value(_expiryDate),
          lowStockThreshold: drift.Value(lowStock),
          manufacturerId: drift.Value(_selectedManufacturer?.id),
          supplierId: drift.Value(_selectedSupplier?.id),
          categoryId: drift.Value(_selectedCategory?.id),
        ),
        initialStock: initialStock > 0 ? initialStock : null,
        storeId: _selectedStore?.id,
        performedBy: auth.currentUser?.id,
      );

      // Persist the crate value at the manufacturer level so every product of
      // this manufacturer shares one value (§16.5).
      if (_selectedManufacturer != null && _emptyCrateValueKobo != null) {
        await db.catalogDao.updateManufacturerEmptyCrateValue(
          _selectedManufacturer!.id,
          _emptyCrateValueKobo!,
        );
      }

      await ref
          .read(activityLogProvider)
          .logAction(
            'new_product',
            '${auth.currentUser?.name ?? 'Unknown'} added product: $name'
                '${initialStock > 0 ? ' with initial stock $initialStock' : ''}',
            productId: productId,
          );

      if (mounted) Navigator.pop(context);
      widget.onProductAdded?.call();
    } catch (e) {
      debugPrint('AddProductScreen._save error: $e');
      if (mounted) {
        AppNotification.showError(context, 'Could not save product: $e');
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final card = Theme.of(context).cardColor;
    final textColor = Theme.of(context).colorScheme.onSurface;
    final subtext =
        Theme.of(context).textTheme.bodySmall?.color ??
        Theme.of(context).iconTheme.color!;
    final border = Theme.of(context).dividerColor;
    final isExisting = _selectedExistingProduct != null;
    final canEditBuying = hasPermission(ref, 'products.edit_buying_price');

    return Scaffold(
      appBar: AppBar(
        leading: const BackButton(),
        title: Text(isExisting ? 'Add Stock' : 'Add Product'),
        titleTextStyle: TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.w800,
          color: textColor,
        ),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (_errorMessage != null) ...[
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 12,
                  ),
                  margin: const EdgeInsets.only(bottom: 16),
                  decoration: BoxDecoration(
                    color: Colors.red.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: Colors.red.withValues(alpha: 0.3),
                    ),
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.error_outline,
                        color: Colors.red,
                        size: 18,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          _errorMessage!,
                          style: const TextStyle(
                            color: Colors.red,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      GestureDetector(
                        onTap: () => setState(() => _errorMessage = null),
                        child: const Icon(
                          Icons.close,
                          color: Colors.red,
                          size: 16,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              // ── EXISTING PRODUCT BANNER ──────────────────────────────
              if (isExisting) ...[
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 12,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.green.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: Colors.green.withValues(alpha: 0.4),
                    ),
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.inventory_2_outlined,
                        color: Colors.green,
                        size: 18,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Adding stock to existing product',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: Colors.green.shade700,
                              ),
                            ),
                            Text(
                              productDisplayName(
                                _selectedExistingProduct!.name,
                                _selectedExistingProduct!.size,
                                unit: _selectedExistingProduct!.unit,
                              ),
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w800,
                                color: textColor,
                              ),
                            ),
                          ],
                        ),
                      ),
                      GestureDetector(
                        onTap: _clearExistingProduct,
                        child: Icon(Icons.close, size: 18, color: subtext),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
              ] else ...[
                // ── NAME SEARCH (new product mode only) ────────────────
                AppInput(
                  controller: _nameCtrl,
                  labelText: 'Product Name *',
                  hintText: 'e.g. Heineken 60cl',
                  prefixIcon: Icon(Icons.search, size: 18, color: subtext),
                  onChanged: _onNameChanged,
                ),
                if (_productSuggestions.isNotEmpty)
                  _suggestionList(
                    children: _productSuggestions
                        .map(
                          (p) => _suggestionTile(
                            label: productDisplayName(
                              p.name,
                              p.size,
                              unit: p.unit,
                            ),
                            textColor: textColor,
                            card: card,
                            border: border,
                            onTap: () => _selectProduct(p),
                          ),
                        )
                        .toList(),
                    card: card,
                    border: border,
                  ),
                const SizedBox(height: 14),
              ],
              // ── DETAIL FIELDS (always shown; pre-filled for existing) ─
              ...[
                _sectionLabel('CATEGORY *', subtext),
                const SizedBox(height: 8),
                if (_allCategories.isEmpty)
                  Text(
                    'No categories found',
                    style: TextStyle(color: subtext, fontSize: 13),
                  )
                else
                  AppDropdown<CategoryData?>(
                    value: _selectedCategory,
                    items: _allCategories
                        .map(
                          (c) => DropdownMenuItem<CategoryData?>(
                            value: c,
                            child: Text(c.name),
                          ),
                        )
                        .toList(),
                    onChanged: (v) => setState(() => _selectedCategory = v),
                  ),
                const SizedBox(height: 14),
                AppInput(
                  controller: _subtitleCtrl,
                  labelText: 'Description / Subtitle *',
                  hintText: 'e.g. Premium Lager',
                ),
                const SizedBox(height: 14),
                Row(
                  children: [
                    Expanded(
                      child: AppInput(
                        controller: _retailPriceCtrl,
                        labelText: 'Retailer Price (₦) *',
                        hintText: '0.00',
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        inputFormatters: [CurrencyInputFormatter()],
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: AppInput(
                        controller: _wholesalePriceCtrl,
                        labelText: 'Wholesaler Price (₦) *',
                        hintText: '0.00',
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        inputFormatters: [CurrencyInputFormatter()],
                      ),
                    ),
                  ],
                ),
                if (canEditBuying) ...[
                  const SizedBox(height: 14),
                  AppInput(
                    controller: _buyingPriceCtrl,
                    labelText: 'Buying Price (₦) *',
                    hintText: '0.00',
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    inputFormatters: [CurrencyInputFormatter()],
                  ),
                ],
                const SizedBox(height: 14),
                AppInput(
                  controller: _lowStockCtrl,
                  labelText: 'Low Stock Alert *',
                  hintText: '5',
                  keyboardType: TextInputType.number,
                ),
                const SizedBox(height: 16),

                // ── PRODUCT UNIT SELECTOR ──────────────────────────────
                _sectionLabel('PRODUCT UNIT *', subtext),
                const SizedBox(height: 8),
                AppDropdown<String>(
                  value: _unit,
                  items: _dynamicUnits
                      .map((u) => DropdownMenuItem(value: u, child: Text(u)))
                      .toList(),
                  onChanged: (v) {
                    if (v != null) {
                      setState(() {
                        _unit = v;
                        // Auto-enable tracking for bottle products,
                        // clear it for everything else.
                        _trackEmpties = v.toLowerCase() == 'bottle';
                      });
                    }
                  },
                ),
                const SizedBox(height: 8),

                // ── ALLOW FRACTIONAL SALES ─────────────────────────────
                CheckboxListTile(
                  value: _allowFractionalSales,
                  onChanged: (v) =>
                      setState(() => _allowFractionalSales = v ?? false),
                  title: const Text('Allow fractional sales'),
                  subtitle: const Text(
                    'Enables ±0.5 quantity steps when selling this product',
                  ),
                  controlAffinity: ListTileControlAffinity.leading,
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                ),
                const SizedBox(height: 16),

                // ── EXPIRY DATE (optional, all business types) ─────────
                _sectionLabel('EXPIRY DATE', subtext),
                const SizedBox(height: 4),
                Text(
                  'Optional — used to flag stock nearing expiry',
                  style: TextStyle(fontSize: 11, color: subtext),
                ),
                const SizedBox(height: 8),
                _expiryField(card: card, border: border, subtext: subtext,
                    textColor: textColor),
                const SizedBox(height: 16),

                // ── CRATE SIZE ─────────────────────────────────────────
                _sectionLabel('SIZE', subtext),
                const SizedBox(height: 4),
                Text(
                  'Only select for crate / bottle products',
                  style: TextStyle(fontSize: 11, color: subtext),
                ),
                const SizedBox(height: 8),
                AppDropdown<String?>(
                  value: _size,
                  items: const [
                    DropdownMenuItem(value: null, child: Text('None')),
                    DropdownMenuItem(value: 'big', child: Text('Big')),
                    DropdownMenuItem(value: 'medium', child: Text('Medium')),
                    DropdownMenuItem(value: 'small', child: Text('Small')),
                  ],
                  onChanged: (v) => setState(() => _size = v),
                ),
                const SizedBox(height: 16),

                // ── MANUFACTURER ───────────────────────────────────────
                AppInput(
                  controller: _manufacturerCtrl,
                  labelText: 'MANUFACTURER *',
                  hintText: 'Search or type manufacturer name…',
                  prefixIcon: Icon(Icons.search, size: 18, color: subtext),
                  onChanged: _onManufacturerChanged,
                  suffixIcon: _selectedManufacturer != null
                      ? GestureDetector(
                          onTap: _clearManufacturer,
                          child: Icon(Icons.close, size: 16, color: subtext),
                        )
                      : null,
                ),
                if (_manufacturerSuggestions.isNotEmpty ||
                    (_manufacturerCtrl.text.trim().isNotEmpty &&
                        _selectedManufacturer == null))
                  _suggestionList(
                    children: [
                      ..._manufacturerSuggestions.map(
                        (m) => _suggestionTile(
                          label: m.name,
                          textColor: textColor,
                          card: card,
                          border: border,
                          onTap: () => _selectManufacturer(m),
                        ),
                      ),
                      if (_manufacturerCtrl.text.trim().isNotEmpty &&
                          !_manufacturerSuggestions.any(
                            (m) =>
                                m.name.toLowerCase() ==
                                _manufacturerCtrl.text.trim().toLowerCase(),
                          ))
                        _suggestionTile(
                          label: 'Create "${_manufacturerCtrl.text.trim()}"',
                          icon: Icons.add_circle_outline,
                          textColor: Theme.of(context).colorScheme.primary,
                          card: card,
                          border: border,
                          onTap: () => _createNewManufacturer(
                            _manufacturerCtrl.text.trim(),
                          ),
                        ),
                    ],
                    card: card,
                    border: border,
                  ),
                const SizedBox(height: 16),

                // ── TRACK EMPTIES + CRATE VALUE (directly below Manufacturer) ─
                if (_unit.toLowerCase() == 'bottle') ...[
                  CheckboxListTile(
                    value: _trackEmpties,
                    onChanged: (v) =>
                        setState(() => _trackEmpties = v ?? false),
                    title: const Text('Track empty crate returns'),
                    subtitle: const Text(
                      'Enables deposit collection and crate return flow for this product',
                    ),
                    controlAffinity: ListTileControlAffinity.leading,
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                  ),
                  // Crate value is shared at the manufacturer level; selecting
                  // a manufacturer autofills it (§16.5).
                  if (_trackEmpties) ...[
                    const SizedBox(height: 6),
                    AppInput(
                      controller: _emptyCrateValueCtrl,
                      labelText: 'Empty Crate Value (₦)',
                      hintText: '0.00',
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      inputFormatters: [CurrencyInputFormatter()],
                    ),
                  ],
                  const SizedBox(height: 16),
                ],

                // ── SUPPLIER ───────────────────────────────────────────
                AppInput(
                  controller: _supplierCtrl,
                  labelText: 'SUPPLIER (optional)',
                  hintText: 'Search supplier name…',
                  prefixIcon: Icon(Icons.search, size: 18, color: subtext),
                  onChanged: _onSupplierChanged,
                  suffixIcon: _selectedSupplier != null
                      ? GestureDetector(
                          onTap: _clearSupplier,
                          child: Icon(Icons.close, size: 16, color: subtext),
                        )
                      : null,
                ),
                if (_supplierSuggestions.isNotEmpty ||
                    (_supplierCtrl.text.trim().isNotEmpty &&
                        _selectedSupplier == null))
                  _suggestionList(
                    children: [
                      ..._supplierSuggestions.map(
                        (s) => _suggestionTile(
                          label: s.name,
                          textColor: textColor,
                          card: card,
                          border: border,
                          onTap: () => _selectSupplier(s),
                        ),
                      ),
                      if (_supplierCtrl.text.trim().isNotEmpty &&
                          !_supplierSuggestions.any(
                            (s) =>
                                s.name.toLowerCase() ==
                                _supplierCtrl.text.trim().toLowerCase(),
                          ))
                        _suggestionTile(
                          label: 'Create "${_supplierCtrl.text.trim()}"',
                          icon: Icons.add_circle_outline,
                          textColor: Theme.of(context).colorScheme.primary,
                          card: card,
                          border: border,
                          onTap: () => _createNewSupplier(
                            _supplierCtrl.text.trim(),
                          ),
                        ),
                    ],
                    card: card,
                    border: border,
                  ),
                const SizedBox(height: 16),
              ], // end of new-product-only fields
              // ── QUANTITY & STORE (always visible) ───────────────
              AppInput(
                controller: _initialStockCtrl,
                labelText: isExisting
                    ? 'QUANTITY TO ADD *'
                    : 'INITIAL QUANTITY *',
                hintText: '0',
                keyboardType: TextInputType.number,
              ),
              const SizedBox(height: 16),
              _sectionLabel('STORE *', subtext),
              const SizedBox(height: 8),
              if (_stores.isEmpty)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 14,
                  ),
                  decoration: BoxDecoration(
                    color: card,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: border),
                  ),
                  child: Text(
                    'No stores',
                    style: TextStyle(fontSize: 14, color: subtext),
                  ),
                )
              else
                AppDropdown<StoreData?>(
                  value: _selectedStore,
                  items: _stores
                      .map(
                        (w) => DropdownMenuItem<StoreData?>(
                          value: w,
                          child: Text(w.name, overflow: TextOverflow.ellipsis),
                        ),
                      )
                      .toList(),
                  onChanged: (v) => setState(() => _selectedStore = v),
                ),
            ],
          ),
        ),
      ),
      bottomNavigationBar: Padding(
        padding: EdgeInsets.fromLTRB(20, 8, 20, 12 + context.deviceBottomInset),
        child: AppButton(
          text: isExisting ? 'Add Stock' : 'Add Product',
          variant: AppButtonVariant.primary,
          isLoading: _isSaving,
          onPressed: _save,
        ),
      ),
    );
  }

  // ── HELPERS ────────────────────────────────────────────────────────────────

  Widget _expiryField({
    required Color card,
    required Color border,
    required Color subtext,
    required Color textColor,
  }) {
    final hasDate = _expiryDate != null;
    String label() {
      final d = _expiryDate!;
      return '${d.day.toString().padLeft(2, '0')}/'
          '${d.month.toString().padLeft(2, '0')}/${d.year}';
    }

    return InkWell(
      onTap: _pickExpiryDate,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: card,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: border),
        ),
        child: Row(
          children: [
            Icon(Icons.event_outlined, size: 18, color: subtext),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                hasDate ? label() : 'No expiry date',
                style: TextStyle(
                  fontSize: 14,
                  color: hasDate ? textColor : subtext,
                  fontWeight: hasDate ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ),
            if (hasDate)
              GestureDetector(
                onTap: () => setState(() => _expiryDate = null),
                child: Icon(Icons.close, size: 16, color: subtext),
              ),
          ],
        ),
      ),
    );
  }

  Widget _sectionLabel(String text, Color subtext) => Text(
    text,
    style: TextStyle(
      fontSize: 11,
      fontWeight: FontWeight.w700,
      color: subtext,
      letterSpacing: 0.8,
    ),
  );

  Widget _suggestionList({
    required List<Widget> children,
    required Color card,
    required Color border,
  }) {
    return Container(
      margin: const EdgeInsets.only(top: 4),
      decoration: BoxDecoration(
        color: card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: border),
      ),
      child: Column(mainAxisSize: MainAxisSize.min, children: children),
    );
  }

  Widget _suggestionTile({
    required String label,
    required Color textColor,
    required Color card,
    required Color border,
    required VoidCallback onTap,
    IconData icon = Icons.person_outline,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Icon(icon, size: 16, color: Theme.of(context).colorScheme.primary),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: textColor,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
