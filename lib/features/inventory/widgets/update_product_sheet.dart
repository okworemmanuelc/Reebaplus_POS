import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:reebaplus_pos/core/industry/lexicon.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/result.dart';
import 'package:reebaplus_pos/core/permissions/permissions.dart';
import 'package:reebaplus_pos/core/utils/currency_input_formatter.dart';
import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/core/utils/notifications.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/services/crash_reporter.dart';

import 'package:reebaplus_pos/shared/widgets/app_dropdown.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/shared/widgets/auto_lock_wrapper.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:reebaplus_pos/shared/widgets/app_input.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/redesign.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/theme/design_tokens.dart';
import 'package:reebaplus_pos/core/theme/fixed_colors.dart';
import 'package:reebaplus_pos/core/theme/scheme_colors.dart';
import 'package:reebaplus_pos/features/inventory/widgets/inventory_parts.dart';
import 'package:reebaplus_pos/features/receiving/state/receive_cart.dart';

class UpdateProductSheet extends ConsumerStatefulWidget {
  final ProductData product;
  final int totalStock;
  final String? currentStoreId;
  final void Function(ProductData)? onProductUpdated;

  final bool receiveMode;

  const UpdateProductSheet({
    super.key,
    required this.product,
    required this.totalStock,
    this.currentStoreId,
    this.onProductUpdated,
    this.receiveMode = false,
  });

  @override
  ConsumerState<UpdateProductSheet> createState() => _UpdateProductSheetState();
}

class _UpdateProductSheetState extends ConsumerState<UpdateProductSheet> {
  late final TextEditingController _nameCtrl;
  late final TextEditingController _subtitleCtrl;
  late final TextEditingController _retailPriceCtrl;
  late final TextEditingController _wholesalePriceCtrl;
  late final TextEditingController _buyingPriceCtrl;
  late final TextEditingController _emptyCrateValueCtrl;
  late final TextEditingController _lowStockCtrl;
  late final TextEditingController _qtyToAddCtrl;
  late final TextEditingController _supplierCtrl;
  late final TextEditingController _manufacturerCtrl;
  late final TextEditingController _categoryCtrl;
  late final TextEditingController _barcodeCtrl;

  /// The name of another product already using the typed barcode (#113). Non-
  /// null ⇒ a soft collision the sheet warns about; it never blocks the save.
  String? _barcodeCollisionName;

  // Nullable (#108): null = no unit. Seeded from the product (which may already
  // have no unit) and cleared via the dropdown's "No unit" option.
  String? _unit;
  late bool _trackEmpties;
  late bool _allowFractionalSales;
  late String _colorHex;
  late String? _size;
  DateTime? _expiryDate;
  StoreData? _selectedStore;
  SupplierData? _selectedSupplier;
  CategoryData? _selectedCategory;
  ManufacturerData? _selectedManufacturer;

  List<StoreData> _stores = [];
  List<SupplierData> _allSuppliers = [];
  List<CategoryData> _allCategories = [];
  List<CategoryData> _categorySuggestions = [];
  List<SupplierData> _supplierSuggestions = [];
  List<ManufacturerData> _allManufacturers = [];
  List<ManufacturerData> _manufacturerSuggestions = [];

  bool _isSaving = false;
  String? _errorMessage;
  // Renderable local path of the current photo (legacy local file or the
  // ProductImageService cache for a cross-device photo). [_pendingImageBytes]
  // holds a freshly picked image not yet saved (#78).
  String? _imagePath;
  Uint8List? _pendingImageBytes;

  // Unit suggestions come from the industry's Lexicon (#80); set in initState +
  // merged with the product's own unit and any already in use in _loadData.
  List<String> _dynamicUnits = const [];

  /// Whether the current role may see / edit the buying price (§16.5 / §16.7).
  /// Reads (not watches) so it is safe to call from `_save`.
  bool get _canEditBuying => Gates.editBuyingPrice.allowsNow(ref);

  /// Whether the current role may edit product details/prices (§16.7). This
  /// editor's primary purpose; re-checked at save time (hard rule #6).
  bool get _canEditPrice => Gates.editProductPrice.allowsNow(ref);

  /// Whether the current role may add stock to an existing product (§16.7).
  /// Gates the in-sheet "quantity to add" field and its save branch.
  bool get _canAddStock => Gates.addStock.allowsNow(ref);

  /// §13.4 / rule #13 — empty-crate tracking is Bar / Beer Distributor only.
  /// Gate the toggle (below) + force the saved value off for non-crate types.
  bool get _isCrateBusiness =>
      businessTracksCrates(ref.read(currentBusinessProvider));

  /// trackEmpties as actually saved — forced off for non-crate businesses.
  bool get _effectiveTrackEmpties => _isCrateBusiness && _trackEmpties;

  /// The active industry's words + presets (#80). Read (not watched); the sheet
  /// edits one product for one business, so the Lexicon is stable here.
  Lexicon get _lexicon => ref.read(industryLexiconProvider);

  /// Empty-crate value in kobo, or null when not tracking empties / left blank.
  int? get _emptyCrateValueKobo {
    if (!(_effectiveTrackEmpties && _unit?.toLowerCase() == 'bottle')) {
      return null;
    }
    final raw = _emptyCrateValueCtrl.text.trim();
    if (raw.isEmpty) return null;
    return (parseCurrency(raw) * 100).round();
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

  @override
  void initState() {
    super.initState();
    final p = widget.product;
    _nameCtrl = TextEditingController(text: p.name);
    _subtitleCtrl = TextEditingController(text: p.subtitle ?? '');
    _retailPriceCtrl = TextEditingController(
      text: (p.retailerPriceKobo / 100).toStringAsFixed(2),
    );
    _wholesalePriceCtrl = TextEditingController(
      text: (p.wholesalerPriceKobo / 100).toStringAsFixed(2),
    );
    _buyingPriceCtrl = TextEditingController(
      text: (p.buyingPriceKobo / 100).toStringAsFixed(2),
    );
    _emptyCrateValueCtrl = TextEditingController(
      text: p.emptyCrateValueKobo > 0
          ? (p.emptyCrateValueKobo / 100).toStringAsFixed(2)
          : '',
    );
    _lowStockCtrl = TextEditingController(text: p.lowStockThreshold.toString());
    final initialQty = widget.receiveMode
        ? ref
                  .read(receiveCartProvider)
                  .where((l) => l.productId == p.id)
                  .firstOrNull
                  ?.qty ??
              0
        : 0;
    _qtyToAddCtrl = TextEditingController(text: initialQty.toString());
    _supplierCtrl = TextEditingController();
    // Manufacturer name is populated in _loadData() via FK lookup.
    _manufacturerCtrl = TextEditingController();
    _categoryCtrl = TextEditingController();
    _barcodeCtrl = TextEditingController(text: p.barcode ?? '');
    _imagePath = p.imagePath;

    _unit = p.unit;
    // The industry's starter units, plus this product's own unit so the
    // dropdown always includes the selected value (#80). A unitless product
    // (#108) contributes nothing.
    _dynamicUnits = <String>{
      ..._lexicon.starterUnits,
      if (p.unit != null) p.unit!,
    }.toList()..sort();
    _trackEmpties = p.trackEmpties;
    _allowFractionalSales = p.allowFractionalSales;
    _size = p.size;
    _expiryDate = p.expiryDate;
    // Colour selector is deferred (§16.5); preserve whatever the product
    // already has (or the default) without exposing a picker.
    _colorHex = p.colorHex ?? '#3B82F6';

    _loadData();
  }

  Future<void> _loadData() async {
    final db = ref.read(databaseProvider);
    final whs = await db.storesDao.getActiveStores();
    final suppliers = await db.catalogDao.getAllSuppliers();
    final manufacturers = await db.inventoryDao.getAllManufacturers();
    final cats = await db.inventoryDao.getAllCategories();
    final uniqueUnits = await db.catalogDao.getUniqueProductUnits();
    // Resolve a renderable path for an existing photo (downloads from Storage
    // once if only the cloud URL is known), so a cross-device photo shows in
    // the edit preview. #78.
    final cachedPhoto = await ref
        .read(productImageServiceProvider)
        .ensureCached(
          productId: widget.product.id,
          imageUrl: widget.product.imageUrl,
        );

    if (!mounted) return;
    setState(() {
      _stores = whs;
      _allSuppliers = suppliers;
      _allManufacturers = manufacturers;
      _allCategories = cats;
      _dynamicUnits = <String>{
        ..._lexicon.starterUnits,
        if (_unit != null) _unit!,
        ...uniqueUnits,
      }.toList()..sort();
      if (cachedPhoto != null) _imagePath = cachedPhoto;

      // Pre-select store: prefer currentStoreId, else first
      if (widget.currentStoreId != null) {
        _selectedStore = whs.cast<StoreData?>().firstWhere(
          (w) => w?.id == widget.currentStoreId,
          orElse: () => whs.isNotEmpty ? whs.first : null,
        );
      } else if (whs.isNotEmpty) {
        _selectedStore = whs.first;
      }

      // Pre-select category
      _selectedCategory = cats.cast<CategoryData?>().firstWhere(
        (c) => c?.id == widget.product.categoryId,
        orElse: () => cats.isNotEmpty ? cats.first : null,
      );
      if (_selectedCategory != null) {
        _categoryCtrl.text = _selectedCategory!.name;
      }

      // Pre-select manufacturer
      _selectedManufacturer = manufacturers
          .cast<ManufacturerData?>()
          .firstWhere(
            (m) => m?.id == widget.product.manufacturerId,
            orElse: () => null,
          );
      if (_selectedManufacturer != null) {
        _manufacturerCtrl.text = _selectedManufacturer!.name;
      }

      // Pre-select supplier
      _selectedSupplier = suppliers.cast<SupplierData?>().firstWhere(
        (s) => s?.id == widget.product.supplierId,
        orElse: () => null,
      );
      if (_selectedSupplier != null) {
        _supplierCtrl.text = _selectedSupplier!.name;
      }
    });
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
    _qtyToAddCtrl.dispose();
    _supplierCtrl.dispose();
    _manufacturerCtrl.dispose();
    _categoryCtrl.dispose();
    _barcodeCtrl.dispose();
    super.dispose();
  }

  /// Soft barcode-collision check (#113): looks up the typed barcode and, if a
  /// DIFFERENT product already uses it, records that product's name so the field
  /// can warn. Never blocks — barcodes are only softly unique (no DB UNIQUE, to
  /// avoid jamming the offline outbox).
  Future<void> _onBarcodeChanged(String value) async {
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      if (_barcodeCollisionName != null) {
        setState(() => _barcodeCollisionName = null);
      }
      return;
    }
    final db = ref.read(databaseProvider);
    final match = await db.catalogDao.findProductByBarcode(trimmed);
    if (!mounted) return;
    final collision = (match != null && match.id != widget.product.id)
        ? match.name
        : null;
    if (collision != _barcodeCollisionName) {
      setState(() => _barcodeCollisionName = collision);
    }
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

  void _onCategoryChanged(String query) {
    final q = query.trim().toLowerCase();
    setState(() {
      _categorySuggestions = q.isEmpty
          ? []
          : _allCategories
                .where((c) => c.name.toLowerCase().contains(q))
                .take(20)
                .toList();
    });
  }

  void _selectCategory(CategoryData category) {
    _categoryCtrl.text = category.name;
    setState(() {
      _selectedCategory = category;
      _categorySuggestions = [];
    });
  }

  void _clearCategory() {
    _categoryCtrl.clear();
    setState(() {
      _selectedCategory = null;
      _categorySuggestions = [];
    });
  }

  Future<CategoryData?> _getOrCreateCategory(String name) async {
    final db = ref.read(databaseProvider);
    final businessId = ref.read(authProvider).currentUser?.businessId;
    if (businessId == null) return null;
    final existing = await db.inventoryDao.getAllCategories();
    final match = existing
        .where((c) => c.name.toLowerCase() == name.toLowerCase())
        .firstOrNull;
    if (match != null) return match;
    final id = await db.catalogDao.insertCategory(
      CategoriesCompanion.insert(name: name, businessId: businessId),
    );
    final categories = await db.inventoryDao.getAllCategories();
    if (!mounted) return null;
    setState(() {
      _allCategories = categories;
    });
    return categories.firstWhere((c) => c.id == id);
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

  Future<void> _pickImage() async {
    AutoLockWrapper.suppressNextResume = true;
    final svc = ref.read(productImageServiceProvider);
    final result = await svc.pickAndProcess();
    if (!mounted) return;
    switch (result) {
      case Ok(:final value):
        setState(() => _pendingImageBytes = value);
      case Err(:final error):
        if (!error.isCancelled) {
          setState(() => _errorMessage = 'Could not load image.');
        }
    }
  }

  Future<void> _save() async {
    final db = ref.read(databaseProvider);
    final auth = ref.read(authProvider);
    setState(() => _errorMessage = null);

    // Defense-in-depth (hard rule #6): this editor mutates product details, so
    // bail if `products.edit_price` was revoked while the sheet was open.
    if (!_canEditPrice) {
      setState(
        () => _errorMessage =
            'You no longer have permission to edit ${_lexicon.itemPluralLower}.',
      );
      return;
    }

    final canEditBuying = _canEditBuying;
    // Epic 2 / ADR 0005 (#41): remember the pre-edit cost so we can detect the
    // one-time 0 → real-value transition after the save and offer to backfill
    // the sales made before any cost existed.
    final oldBuyingKobo = widget.product.buyingPriceKobo;
    final name = _nameCtrl.text.trim();

    final retailPrice = parseCurrency(_retailPriceCtrl.text);
    final wholesalePrice = parseCurrency(_wholesalePriceCtrl.text);
    // Buying price stays hidden (and untouched) for roles without the
    // permission — preserve the stored value rather than zeroing it.
    final buyingPrice = canEditBuying
        ? parseCurrency(_buyingPriceCtrl.text)
        : widget.product.buyingPriceKobo / 100;
    final qtyToAdd = int.tryParse(_qtyToAddCtrl.text) ?? 0;

    if (buyingPrice > retailPrice) {
      setState(
        () => _errorMessage =
            'Buying price cannot be higher than retailer price.',
      );
      return;
    }

    setState(() => _isSaving = true);
    try {
      // Auto-handle manufacturer if typed but not explicitly selected
      if (_selectedManufacturer == null &&
          _manufacturerCtrl.text.trim().isNotEmpty) {
        _selectedManufacturer = await _getOrCreateManufacturer(
          _manufacturerCtrl.text.trim(),
        );
      }

      // Auto-handle category if typed but not explicitly selected
      if (_selectedCategory == null && _categoryCtrl.text.trim().isNotEmpty) {
        _selectedCategory = await _getOrCreateCategory(
          _categoryCtrl.text.trim(),
        );
      }

      // Auto-handle supplier if typed but not explicitly selected (optional)
      if (_selectedSupplier == null && _supplierCtrl.text.trim().isNotEmpty) {
        _selectedSupplier = await _getOrCreateSupplier(
          _supplierCtrl.text.trim(),
        );
      }

      String? missingField;
      if (name.isEmpty) {
        missingField = '${_lexicon.item} Name';
      } else if (_selectedCategory == null) {
        missingField = _lexicon.category;
      } else if (_retailPriceCtrl.text.trim().isEmpty) {
        missingField = 'Retailer Price';
      } else if (_wholesalePriceCtrl.text.trim().isEmpty) {
        missingField = 'Wholesaler Price';
      } else if (canEditBuying && _buyingPriceCtrl.text.trim().isEmpty) {
        missingField = 'Buying Price';
      } else if (!widget.receiveMode && _selectedStore == null) {
        missingField = 'Store';
      } else if (_effectiveTrackEmpties && _selectedManufacturer == null) {
        missingField = 'Manufacturer (required to track empty crates)';
      }

      if (missingField != null) {
        setState(() {
          _errorMessage = '$missingField is required.';
          _isSaving = false;
        });
        return;
      }

      final retailKobo = (retailPrice * 100).round();
      final wholesaleKobo = (wholesalePrice * 100).round();
      final buyingKobo = (buyingPrice * 100).round();
      final lowStock = int.tryParse(_lowStockCtrl.text) ?? 5;

      // Optional product photo (#78): upload a freshly picked image, keyed by
      // the product id. The photo lives in image_url + the ProductImageService
      // cache (never products.image_path, so it stays off the POS grid); the
      // cache path drives the local preview here. Offline, save() caches locally
      // + marks the product pending so the reconnect flush uploads it later.
      String? newImageUrl;
      if (_pendingImageBytes != null) {
        final businessId = auth.currentUser?.businessId;
        if (businessId != null) {
          final imgSvc = ref.read(productImageServiceProvider);
          final res = await imgSvc.save(
            businessId: businessId,
            productId: widget.product.id,
            bytes: _pendingImageBytes!,
          );
          _imagePath = await imgSvc.localPathFor(widget.product.id);
          if (res case Ok(:final value)) newImageUrl = value;
        }
      }

      // 1. Update product (core + cosmetic fields in one enqueue).
      await db.catalogDao.updateProductDetails(
        widget.product.id,
        name: name,
        manufacturerId: _selectedManufacturer?.id,
        buyingPriceKobo: buyingKobo,
        retailerPriceKobo: retailKobo,
        wholesalerPriceKobo: wholesaleKobo,
        emptyCrateValueKobo: _emptyCrateValueKobo,
        categoryId: _selectedCategory?.id,
        unit: _unit,
        trackEmpties: _effectiveTrackEmpties,
        allowFractionalSales: _allowFractionalSales,
        lowStockThreshold: lowStock,
        subtitle: _subtitleCtrl.text.trim().isEmpty
            ? null
            : _subtitleCtrl.text.trim(),
        colorHex: _colorHex,
        supplierId: _selectedSupplier?.id,
        size: _size,
        expiryDate: _expiryDate,
        barcode: _barcodeCtrl.text.trim().isEmpty
            ? null
            : _barcodeCtrl.text.trim(),
      );

      // Patch the cloud image URL (separate minimal upsert) so the photo
      // converges cross-device. Null when offline — the reconnect flush sets it.
      if (newImageUrl != null) {
        await db.catalogDao.setProductImageUrl(widget.product.id, newImageUrl);
      }

      // 2. Persist the crate value at the manufacturer level so every product
      //    of this manufacturer shares one value (§16.5).
      if (_selectedManufacturer != null && _emptyCrateValueKobo != null) {
        await db.catalogDao.updateManufacturerEmptyCrateValue(
          _selectedManufacturer!.id,
          _emptyCrateValueKobo!,
        );
      }

      // 3. Add stock if a quantity was entered. The quantity field only renders
      //    in receiveMode (the inventory-tab editor is details-only, §D4), so any
      //    quantity here is always routed to the Receive Cart and committed at
      //    the receive checkout — this sheet never writes inventory directly.
      //    Gated on `stock.add`, so stock keepers can add quantity (but not edit
      //    prices, which have their own gates).
      final currentCartLine = ref
          .read(receiveCartProvider)
          .where((l) => l.productId == widget.product.id)
          .firstOrNull;
      final initialQty = currentCartLine?.qty ?? 0;
      final adding = qtyToAdd != initialQty && _canAddStock;
      if (adding) {
        ref
            .read(receiveCartProvider.notifier)
            .setProductQty(widget.product, qtyToAdd);
        if (mounted) {
          if (qtyToAdd > 0) {
            AppNotification.showSuccess(
              context,
              'Quantity of $name set to $qtyToAdd in Receive Cart',
            );
          } else if (initialQty > 0) {
            AppNotification.showSuccess(
              context,
              '$name removed from Receive Cart',
            );
          }
        }
      }

      // 4. Log the update
      await ref
          .read(activityLogProvider)
          .logAction(
            'update_product',
            '${auth.currentUser?.name ?? 'Unknown'} updated product: $name'
                '${adding ? ', routed $qtyToAdd units to receive cart' : ''}',
            productId: widget.product.id,
          );

      // 5. Cost just became real (0 → a positive value): cost the still-
      //    uncosted batches for the future and, if there are past uncosted
      //    sales, offer once to backfill them (ADR 0005 "Cost backfill", #41).
      if (canEditBuying && oldBuyingKobo == 0 && buyingKobo > 0) {
        final offer = await db.costBatchesDao.onCostBecameReal(
          widget.product.id,
          buyingKobo,
        );
        if (mounted && !offer.isEmpty) {
          await _promptCostBackfill(db, offer, name, auth.currentUser?.id);
        }
      }

      if (mounted) {
        AppNotification.showSuccess(context, '$name updated successfully');
        Navigator.pop(context);
        final updatedProduct = await (db.select(
          db.products,
        )..where((t) => t.id.equals(widget.product.id))).getSingle();
        widget.onProductUpdated?.call(updatedProduct);
      }
    } catch (e, st) {
      CrashReporter.record(e, st, context: 'inventory.update_product');
      debugPrint('UpdateProductSheet._save error: $e');
      setState(
        () => _errorMessage = 'Could not update ${_lexicon.itemLower}: $e',
      );
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  /// One-time prompt (ADR 0005 "Cost backfill", #41) offered when a product's
  /// cost first becomes real and it has past uncosted sales. On accept, restates
  /// those lines' snapshots to the new cost — gaps only, each in its own period —
  /// and audits it with a single Activity Log row (owned by [applyCostBackfill]).
  Future<void> _promptCostBackfill(
    AppDatabase db,
    CostBackfillOffer offer,
    String productName,
    String? staffId,
  ) async {
    final costLabel = formatCurrency(offer.newCostKobo / 100);
    final apply = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        scrollable: true,
        title: Text(
          'Apply cost to past sales?',
          style: ctx.screenTitleStyle.copyWith(
            color: Theme.of(ctx).colorScheme.onSurface,
          ),
        ),
        content: Text(
          'You sold ${offer.unitsUncosted} unit(s) of "$productName" before a '
          'cost was recorded. Apply $costLabel per unit to those past sales so '
          'their profit is restated in the period they happened?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Not now'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Apply'),
          ),
        ],
      ),
    );
    if (apply != true) return;
    final restated = await db.costBatchesDao.applyCostBackfill(
      offer,
      description:
          '$productName: applied $costLabel/unit to ${offer.unitsUncosted} '
          'unit(s) across ${offer.lineIds.length} past uncosted sale(s)',
      staffId: staffId,
    );
    if (mounted && restated > 0) {
      AppNotification.showSuccess(
        context,
        'Restated $restated past sale(s) of $productName',
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    final gutter = context.getRSize(20);
    final gap = context.getRSize(14);
    final section = context.getRSize(16);
    // The sheet draws its own Surface and top corners: both call sites
    // (Inventory and Receive Stock) open it on a transparent background. It
    // takes the theme's sheet shape so it matches every other sheet (#392).
    final shape =
        t.bottomSheetTheme.shape ??
        const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(AppSpacing.borderRadiusXL),
          ),
        );

    return Container(
      constraints: BoxConstraints(maxHeight: context.sheetMaxHeight(0.92)),
      decoration: ShapeDecoration(color: t.colorScheme.surface, shape: shape),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Drag handle
          Padding(
            padding: EdgeInsets.only(top: context.getRSize(12)),
            child: Container(
              width: context.getRSize(40),
              height: context.getRSize(4),
              decoration: BoxDecoration(
                color: t.dividerColor,
                borderRadius: BorderRadius.circular(AppSpacing.borderRadiusS),
              ),
            ),
          ),
          // Header
          Padding(
            padding: EdgeInsets.fromLTRB(
              gutter,
              context.getRSize(16),
              gutter,
              0,
            ),
            child: Row(
              children: [
                const IconTile(icon: AppIcons.edit, size: 44),
                SizedBox(width: context.getRSize(12)),
                _photoButton(),
                SizedBox(width: context.getRSize(12)),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Update ${_lexicon.item}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: context.screenTitleStyle.copyWith(
                          color: t.colorScheme.onSurface,
                        ),
                      ),
                      Text(
                        'Edit details and add new stock below',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: context
                            .semiBoldStyle(13)
                            .copyWith(color: t.colorScheme.primary),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          // Scrollable form
          Flexible(
            child: SingleChildScrollView(
              padding: EdgeInsets.fromLTRB(
                gutter,
                context.getRSize(20),
                gutter,
                context.getRSize(8),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (_errorMessage != null) ...[
                    InventoryNotice(
                      icon: AppIcons.alertCircle,
                      tone: IconTileTone.danger,
                      message: _errorMessage!,
                      onClose: () => setState(() => _errorMessage = null),
                    ),
                    SizedBox(height: section),
                  ],

                  // ── PRODUCT NAME ─────────────────────────────────────────
                  AppInput(
                    controller: _nameCtrl,
                    labelText: '${_lexicon.item} Name *',
                    hintText: _lexicon.itemNameHint,
                  ),
                  SizedBox(height: gap),

                  // ── CATEGORY ─────────────────────────────────────────────
                  AppInput(
                    controller: _categoryCtrl,
                    labelText: '${_lexicon.category.toUpperCase()} *',
                    hintText: 'Search or type category name…',
                    prefixIcon: const InventorySearchIcon(),
                    onChanged: _onCategoryChanged,
                    suffixIcon: _selectedCategory != null
                        ? InventoryFieldClear(onPressed: _clearCategory)
                        : null,
                  ),
                  if (_categorySuggestions.isNotEmpty ||
                      (_categoryCtrl.text.trim().isNotEmpty &&
                          _selectedCategory == null))
                    InventorySuggestionList(
                      children: [
                        ..._categorySuggestions.map(
                          (c) => InventorySuggestionTile(
                            label: c.name,
                            icon: AppIcons.category,
                            onTap: () => _selectCategory(c),
                          ),
                        ),
                        if (_categoryCtrl.text.trim().isNotEmpty &&
                            !_categorySuggestions.any(
                              (c) =>
                                  c.name.toLowerCase() ==
                                  _categoryCtrl.text.trim().toLowerCase(),
                            ))
                          InventorySuggestionTile(
                            label: 'Create "${_categoryCtrl.text.trim()}"',
                            icon: AppIcons.addCircle,
                            emphasis: true,
                            onTap: () async {
                              try {
                                final c = await _getOrCreateCategory(
                                  _categoryCtrl.text.trim(),
                                );
                                if (c != null && mounted) _selectCategory(c);
                              } catch (e, st) {
                                CrashReporter.record(
                                  e,
                                  st,
                                  context:
                                      'inventory.update_product.create_category',
                                );
                                if (mounted) {
                                  setState(
                                    () => _errorMessage =
                                        'Could not create category. Please try again.',
                                  );
                                }
                              }
                            },
                          ),
                      ],
                    ),
                  SizedBox(height: gap),

                  // ── SUBTITLE ─────────────────────────────────────────────
                  AppInput(
                    controller: _subtitleCtrl,
                    labelText: 'Description / Subtitle',
                    hintText: _lexicon.itemDescriptionHint,
                  ),
                  SizedBox(height: gap),

                  // ── BARCODE (optional) ───────────────────────────────────
                  _barcodeField(),
                  SizedBox(height: gap),

                  // ── PRICES ───────────────────────────────────────────────
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: AppInput(
                          controller: _retailPriceCtrl,
                          labelText: 'Retailer Price ($activeCurrencySymbol) *',
                          hintText: 'e.g. 500',
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          inputFormatters: [CurrencyInputFormatter()],
                        ),
                      ),
                      SizedBox(width: context.getRSize(12)),
                      Expanded(
                        child: AppInput(
                          controller: _wholesalePriceCtrl,
                          labelText:
                              'Wholesaler Price ($activeCurrencySymbol) *',
                          hintText: '0.00',
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          inputFormatters: [CurrencyInputFormatter()],
                        ),
                      ),
                    ],
                  ),
                  if (_canEditBuying) ...[
                    SizedBox(height: gap),
                    AppInput(
                      controller: _buyingPriceCtrl,
                      labelText: 'Buying Price ($activeCurrencySymbol) *',
                      hintText: '0.00',
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      inputFormatters: [CurrencyInputFormatter()],
                    ),
                  ],
                  SizedBox(height: gap),

                  // ── LOW STOCK ALERT ──────────────────────────────────────
                  AppInput(
                    controller: _lowStockCtrl,
                    labelText: 'Low Stock Alert *',
                    hintText: '5',
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  ),
                  SizedBox(height: section),

                  // ── PRODUCT UNIT (optional, #108) ────────────────────────
                  const InventoryFieldLabel('PRODUCT UNIT'),
                  SizedBox(height: context.getRSize(8)),
                  AppDropdown<String?>(
                    value: _unit,
                    hintText: 'No unit',
                    // "No unit" (#108) clears the unit — the product keeps
                    // just its name and is hidden wherever the unit renders.
                    items: [
                      const DropdownMenuItem<String?>(
                        value: null,
                        child: Text('No unit'),
                      ),
                      ..._dynamicUnits.map(
                        (u) =>
                            DropdownMenuItem<String?>(value: u, child: Text(u)),
                      ),
                    ],
                    onChanged: (v) {
                      setState(() {
                        _unit = v;
                        // A null unit is not a bottle → no crate tracking.
                        _trackEmpties = v?.toLowerCase() == 'bottle';
                      });
                    },
                  ),
                  SizedBox(height: context.getRSize(8)),

                  // ── ALLOW FRACTIONAL SALES ───────────────────────────────
                  InventoryCheckRow(
                    value: _allowFractionalSales,
                    onChanged: (v) =>
                        setState(() => _allowFractionalSales = v ?? false),
                    title: 'Allow fractional sales',
                    subtitle:
                        'Enables ±0.5 quantity steps when selling this '
                        '${_lexicon.itemLower}',
                  ),
                  SizedBox(height: context.getRSize(8)),

                  // ── EXPIRY DATE (optional, all business types) ───────────
                  const InventoryFieldLabel('EXPIRY DATE'),
                  const InventoryFieldHelper(
                    'Optional — used to flag stock nearing expiry',
                  ),
                  SizedBox(height: context.getRSize(8)),
                  InventoryDateField(
                    label: _expiryLabel(),
                    placeholder: 'No expiry date',
                    onTap: _pickExpiryDate,
                    onClear: () => setState(() => _expiryDate = null),
                  ),
                  SizedBox(height: section),

                  // ── MANUFACTURER ─────────────────────────────────────────
                  AppInput(
                    controller: _manufacturerCtrl,
                    labelText: 'MANUFACTURER (optional)',
                    hintText: 'Search or type manufacturer name…',
                    prefixIcon: const InventorySearchIcon(),
                    onChanged: _onManufacturerChanged,
                    suffixIcon: _selectedManufacturer != null
                        ? InventoryFieldClear(onPressed: _clearManufacturer)
                        : null,
                  ),
                  if (_manufacturerSuggestions.isNotEmpty ||
                      (_manufacturerCtrl.text.trim().isNotEmpty &&
                          _selectedManufacturer == null))
                    InventorySuggestionList(
                      children: [
                        ..._manufacturerSuggestions.map(
                          (m) => InventorySuggestionTile(
                            label: m.name,
                            onTap: () => _selectManufacturer(m),
                          ),
                        ),
                        if (_manufacturerCtrl.text.trim().isNotEmpty &&
                            !_manufacturerSuggestions.any(
                              (m) =>
                                  m.name.toLowerCase() ==
                                  _manufacturerCtrl.text.trim().toLowerCase(),
                            ))
                          InventorySuggestionTile(
                            label: 'Create "${_manufacturerCtrl.text.trim()}"',
                            icon: AppIcons.addCircle,
                            emphasis: true,
                            onTap: () async {
                              try {
                                final m = await _getOrCreateManufacturer(
                                  _manufacturerCtrl.text.trim(),
                                );
                                if (m != null) _selectManufacturer(m);
                              } catch (e, st) {
                                CrashReporter.record(
                                  e,
                                  st,
                                  context:
                                      'inventory.update_product.create_manufacturer',
                                );
                                if (mounted) {
                                  setState(
                                    () => _errorMessage =
                                        'Could not create manufacturer. Please try again.',
                                  );
                                }
                              }
                            },
                          ),
                      ],
                    ),
                  SizedBox(height: section),

                  // ── TRACK EMPTIES + CRATE VALUE (below Manufacturer) ─────
                  // Crate-only (rule #13): hidden for non-Bar/Beer-distributor
                  // businesses; _effectiveTrackEmpties forces it off on save.
                  if (_unit?.toLowerCase() == 'bottle' && _isCrateBusiness) ...[
                    InventoryCheckRow(
                      value: _trackEmpties,
                      onChanged: (v) =>
                          setState(() => _trackEmpties = v ?? false),
                      title: 'Track empty crate returns',
                      subtitle:
                          'Enables deposit collection and crate return flow '
                          'for this ${_lexicon.itemLower}',
                    ),
                    // Crate value is shared at the manufacturer level;
                    // selecting a manufacturer autofills it (§16.5).
                    if (_trackEmpties) ...[
                      SizedBox(height: context.getRSize(6)),
                      AppInput(
                        controller: _emptyCrateValueCtrl,
                        labelText: 'Empty Crate Value ($activeCurrencySymbol)',
                        hintText: '0.00',
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        inputFormatters: [CurrencyInputFormatter()],
                      ),
                    ],
                    SizedBox(height: section),
                  ],

                  if (!widget.receiveMode) ...[
                    // ── SUPPLIER ─────────────────────────────────────────────
                    AppInput(
                      controller: _supplierCtrl,
                      labelText: 'SUPPLIER (optional)',
                      hintText: 'Search supplier name…',
                      prefixIcon: const InventorySearchIcon(),
                      onChanged: _onSupplierChanged,
                      suffixIcon: _selectedSupplier != null
                          ? InventoryFieldClear(onPressed: _clearSupplier)
                          : null,
                    ),
                    if (_supplierSuggestions.isNotEmpty ||
                        (_supplierCtrl.text.trim().isNotEmpty &&
                            _selectedSupplier == null))
                      InventorySuggestionList(
                        children: [
                          ..._supplierSuggestions.map(
                            (s) => InventorySuggestionTile(
                              label: s.name,
                              onTap: () => _selectSupplier(s),
                            ),
                          ),
                          if (_supplierCtrl.text.trim().isNotEmpty &&
                              !_supplierSuggestions.any(
                                (s) =>
                                    s.name.toLowerCase() ==
                                    _supplierCtrl.text.trim().toLowerCase(),
                              ))
                            InventorySuggestionTile(
                              label: 'Create "${_supplierCtrl.text.trim()}"',
                              icon: AppIcons.addCircle,
                              emphasis: true,
                              onTap: () async {
                                try {
                                  final s = await _getOrCreateSupplier(
                                    _supplierCtrl.text.trim(),
                                  );
                                  if (!mounted) return;
                                  if (s != null) _selectSupplier(s);
                                } catch (e, st) {
                                  CrashReporter.record(
                                    e,
                                    st,
                                    context:
                                        'inventory.update_product.create_supplier',
                                  );
                                  if (!mounted) return;
                                  setState(
                                    () => _errorMessage =
                                        'Could not create supplier. Please try again.',
                                  );
                                }
                              },
                            ),
                        ],
                      ),
                    SizedBox(height: section),
                  ],

                  if (widget.receiveMode && _canAddStock) ...[
                    Divider(height: 1, color: t.dividerColor),
                    SizedBox(height: section),
                    Text(
                      'Stock Management',
                      style: context
                          .boldStyle(15)
                          .copyWith(color: t.colorScheme.onSurface),
                    ),
                    SizedBox(height: context.getRSize(4)),
                    Text(
                      'Current total stock: ${widget.totalStock}',
                      style: context.regularStyle(13).copyWith(color: muted),
                    ),
                    SizedBox(height: gap),
                    AppInput(
                      controller: _qtyToAddCtrl,
                      labelText: 'RECEIVE QUANTITY',
                      hintText: '0',
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    ),
                    InventoryFieldHelper(
                      'This will set the quantity of this '
                      '${_lexicon.itemLower} in the receive cart.',
                    ),
                    SizedBox(height: gap),
                  ],

                  if (!widget.receiveMode) ...[
                    // ── STORE ────────────────────────────────────────────
                    const InventoryFieldLabel('STORE *'),
                    SizedBox(height: context.getRSize(8)),
                    if (_stores.isEmpty)
                      const InventoryEmptyCard(
                        icon: AppIcons.store,
                        title: 'No stores',
                      )
                    else
                      AppDropdown<StoreData?>(
                        value: _selectedStore,
                        items: _stores
                            .map(
                              (w) => DropdownMenuItem<StoreData?>(
                                value: w,
                                child: Text(
                                  w.name,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            )
                            .toList(),
                        onChanged: (v) => setState(() => _selectedStore = v),
                      ),
                    SizedBox(height: context.getRSize(24)),
                  ],
                ],
              ),
            ),
          ),
          // Save button: pinned under the form, with the system-nav inset
          // inside the sheet's Surface (#392; it used to sit outside it).
          Container(
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: t.dividerColor)),
            ),
            padding: EdgeInsets.fromLTRB(
              gutter,
              context.getRSize(12),
              gutter,
              context.getRSize(16) + context.deviceBottomPadding,
            ),
            child: AppButton(
              text: 'Update ${_lexicon.item}',
              variant: AppButtonVariant.primary,
              isLoading: _isSaving,
              onPressed: _save,
            ),
          ),
        ],
      ),
    );
  }

  /// The photo picker in the header: a 48dp tile showing the pending or saved
  /// photo (else the image icon) with a small edit badge.
  Widget _photoButton() {
    final t = Theme.of(context);
    final tint =
        t.extension<AppSchemeColors>()?.primaryTint ??
        t.colorScheme.primary.withValues(alpha: 0.12);
    final side = math.max(context.getRSize(44), kMinInteractiveDimension);
    final radius = BorderRadius.circular(AppSpacing.borderRadiusM);
    Widget content;
    if (_pendingImageBytes != null) {
      content = Image.memory(_pendingImageBytes!, fit: BoxFit.cover);
    } else if (_imagePath != null) {
      content = Image.file(File(_imagePath!), fit: BoxFit.cover);
    } else {
      content = Center(
        child: AppIcon(
          AppIcons.image,
          size: context.getRSize(20),
          color: t.colorScheme.primary,
        ),
      );
    }
    return Tooltip(
      message: 'Change photo',
      child: InkWell(
        onTap: _pickImage,
        borderRadius: radius,
        child: SizedBox.square(
          dimension: side,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned.fill(
                child: ClipRRect(
                  borderRadius: radius,
                  child: ColoredBox(color: tint, child: content),
                ),
              ),
              PositionedDirectional(
                end: -2,
                bottom: -2,
                child: Container(
                  padding: EdgeInsets.all(context.getRSize(3)),
                  decoration: BoxDecoration(
                    color: t.colorScheme.primary,
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: t.colorScheme.surface,
                      width: 1.5,
                    ),
                  ),
                  child: AppIcon(
                    AppIcons.edit,
                    size: context.getRSize(10),
                    color: t.colorScheme.onPrimary,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String? _expiryLabel() {
    final d = _expiryDate;
    if (d == null) return null;
    return '${d.day.toString().padLeft(2, '0')}/'
        '${d.month.toString().padLeft(2, '0')}/${d.year}';
  }

  /// Optional barcode field (#113) with a live soft-collision warning. Typing
  /// runs [_onBarcodeChanged], which warns (never blocks) when another product
  /// already uses the code.
  Widget _barcodeField() {
    final f =
        Theme.of(context).extension<AppFixedColors>() ?? AppFixedColors.light;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AppInput(
          controller: _barcodeCtrl,
          labelText: 'Barcode (optional)',
          hintText: 'Type or scan the ${_lexicon.itemLower} barcode',
          onChanged: _onBarcodeChanged,
        ),
        if (_barcodeCollisionName != null)
          InventoryFieldHelper(
            'Already used by "$_barcodeCollisionName". You can still save.',
            icon: AppIcons.warning,
            color: f.danger,
          ),
      ],
    );
  }
}
