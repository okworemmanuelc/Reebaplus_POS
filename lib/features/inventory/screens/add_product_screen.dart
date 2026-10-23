import 'dart:async';

import 'package:drift/drift.dart' as drift;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:reebaplus_pos/core/permissions/permissions.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/industry/lexicon.dart';
import 'package:reebaplus_pos/core/result.dart';
import 'package:reebaplus_pos/features/inventory/widgets/product_photo_field.dart';
import 'package:reebaplus_pos/core/utils/currency_input_formatter.dart';
import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/core/utils/notifications.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/services/barcode_suggestion.dart';
import 'package:reebaplus_pos/core/services/crash_reporter.dart';
import 'package:reebaplus_pos/core/utils/factory_barcode.dart';
import 'package:reebaplus_pos/features/inventory/widgets/catalogue_filled_note.dart';
import 'package:reebaplus_pos/features/inventory/widgets/inventory_parts.dart';
import 'package:reebaplus_pos/core/theme/app_decorations.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/theme/design_tokens.dart';
import 'package:reebaplus_pos/core/theme/fixed_colors.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/redesign.dart';

import 'package:reebaplus_pos/features/inventory/models/fast_add_product_model.dart';
import 'package:reebaplus_pos/shared/widgets/app_dropdown.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/core/utils/product_name.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:reebaplus_pos/shared/widgets/app_input.dart';
import 'package:reebaplus_pos/features/receiving/state/receive_cart.dart';
import 'package:reebaplus_pos/features/payments/widgets/supplier_form_sheet.dart';

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
  final void Function(ProductData)? onProductAdded;
  final bool receiveMode;

  /// Optional barcode to pre-fill the Barcode field with (#118). Set when this
  /// screen is opened from a POS scan of an unknown barcode, so the cashier can
  /// catalogue the just-scanned product without retyping the code.
  final String? prefilledBarcode;

  /// Optional store to start the Store field on (#320). Set when this screen
  /// is opened from a POS scan, so the opening stock lands in the store the
  /// POS is selling from rather than the first store. Ignored when the id is
  /// not among the active stores (falls back to the first store).
  final String? initialStoreId;
  const AddProductScreen({
    super.key,
    this.onProductAdded,
    this.receiveMode = false,
    this.prefilledBarcode,
    this.initialStoreId,
  });

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
  final _categoryCtrl = TextEditingController();
  final _barcodeCtrl = TextEditingController();

  /// The name of another product already using the typed barcode (#113). Non-
  /// null ⇒ a soft collision the form warns about; it never blocks the save.
  String? _barcodeCollisionName;

  // Nullable (#108): null = no unit. Pre-filled with the trade's Lexicon unit
  // as a clearable suggestion (initState / _clearExistingProduct); clearing it
  // via the dropdown's "No unit" option saves null.
  String? _unit;
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
  List<CategoryData> _categorySuggestions = [];
  List<SupplierData> _supplierSuggestions = [];
  List<ManufacturerData> _allManufacturers = [];
  List<ManufacturerData> _manufacturerSuggestions = [];

  List<ProductData> _allProducts = [];
  List<ProductData> _productSuggestions = [];
  ProductData? _selectedExistingProduct;
  bool _isSaving = false;
  String? _errorMessage;

  /// Optional product photo picked but not yet saved (#78). Uploaded after the
  /// new product row is created, in [_persistNewProduct].
  Uint8List? _pendingImageBytes;

  /// Which boxes the shared barcode catalogue filled in (ADR 0029 §8, #332).
  /// Each one shows [CatalogueFilledNote] until the person edits that field.
  bool _isNameFromCatalogue = false;
  bool _isUnitFromCatalogue = false;
  bool _isPhotoFromCatalogue = false;

  /// A catalogue-suggested unit missing from the business's starter list, kept
  /// so [_loadData] re-adds it when it rebuilds [_dynamicUnits].
  String? _catalogueUnit;

  /// Debounces catalogue lookups while the barcode box is being typed in.
  Timer? _catalogueDebounce;
  static const _catalogueDebounceDelay = Duration(milliseconds: 500);

  /// Fast-Add: the "More details" section is collapsed by default (ADR 0006).
  bool _showMoreDetails = false;

  /// The required fields that live in the always-visible fast section. A
  /// validation error naming anything else (only Store today) expands "More
  /// details" first, so an error never points at a collapsed field. The item
  /// label morphs per trade (#112), so the name entry is built from the active
  /// Lexicon — a hardcoded 'Product Name' would never match 'Medicine Name'.
  Set<String> get _fastSectionFields => {
    '${_lexicon.item} Name',
    'Selling Price',
    'Quantity',
    'Buying Price',
    'Manufacturer',
  };

  List<String> _dynamicUnits = kProductUnits;

  /// The active industry's words + presets (#80). Read (not watched) in helpers
  /// called during build; the form is opened for one business so it is stable.
  Lexicon get _lexicon => ref.read(industryLexiconProvider);

  String get _nameHint => _lexicon.itemNameHint;
  String get _descriptionHint => _lexicon.itemDescriptionHint;

  /// Whether the current role may see / set the buying price (master plan
  /// §16.5 / §16.7). Reads (not watches) so it is safe to call from `_save`.
  bool get _canEditBuying => Gates.editBuyingPrice.allowsNow(ref);

  @override
  void initState() {
    super.initState();
    // Default to "No unit" (owner request): the unit is a deliberate, up-front
    // choice, not a pre-filled trade guess. The trade's starter units are still
    // OFFERED in the dropdown (via _dynamicUnits) — just not pre-selected — so a
    // crate business picks Bottle itself to engage empty-crate tracking.
    _unit = null;
    _dynamicUnits = _lexicon.starterUnits;
    _trackEmpties = _unit?.toLowerCase() == 'bottle';
    // #118: seed the Barcode field from a POS scan of an unknown code so the
    // cashier catalogues the just-scanned product without retyping it.
    final prefillBarcode = widget.prefilledBarcode?.trim() ?? '';
    if (prefillBarcode.isNotEmpty) _barcodeCtrl.text = prefillBarcode;
    _loadData();
    // #332: a POS scan of an unknown code looks it up in the shared catalogue.
    if (prefillBarcode.isNotEmpty) _lookUpCatalogue(prefillBarcode);
  }

  Future<void> _loadData() async {
    final db = ref.read(databaseProvider);
    final whs = await db.storesDao.getActiveStores();
    final suppliers = await db.catalogDao.getAllSuppliers();
    final manufacturers = await db.inventoryDao.getAllManufacturers();
    // Categories are no longer preloaded — they are created on the fly via the
    // searchable category dropdown (_createNewCategory / _getOrCreateCategory).
    final cats = await db.inventoryDao.getAllCategories();
    final productsList = await (db.select(
      db.products,
    )..where((t) => t.isDeleted.not())).get();
    final uniqueUnits = await db.catalogDao.getUniqueProductUnits();

    if (mounted) {
      setState(() {
        _stores = whs;
        _allSuppliers = suppliers;
        _allManufacturers = manufacturers;
        _allCategories = cats;
        _allProducts = productsList;
        // Merge the industry's starter units (#80) with any already in use.
        final listedUnits = {..._lexicon.starterUnits, ...uniqueUnits};
        // A catalogue unit (#332) filled in before this load: take the
        // list's own spelling when it is listed after all, else keep it.
        final catalogueUnit = _catalogueUnit;
        if (catalogueUnit != null) {
          final listed = listedUnits
              .where((u) => u.toLowerCase() == catalogueUnit.toLowerCase())
              .firstOrNull;
          if (listed != null) {
            if (_unit == catalogueUnit) _unit = listed;
            _catalogueUnit = null;
          }
        }
        final mergedUnits = {...listedUnits, ?_catalogueUnit}.toList()..sort();
        _dynamicUnits = mergedUnits;

        // #320: start on the caller's store (the POS active store) when it is
        // one of the active stores; otherwise the first store, as before.
        if (whs.isNotEmpty) {
          _selectedStore = whs.firstWhere(
            (w) => w.id == widget.initialStoreId,
            orElse: () => whs.first,
          );
        }
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
    _categoryCtrl.dispose();
    _barcodeCtrl.dispose();
    _catalogueDebounce?.cancel();
    super.dispose();
  }

  /// Soft barcode-collision check (#113): looks up the typed barcode and, if a
  /// DIFFERENT product already uses it, records that product's name so the field
  /// can warn. Never blocks — barcodes are only softly unique (no DB UNIQUE, to
  /// avoid jamming the offline outbox).
  Future<void> _onBarcodeChanged(String value) async {
    final trimmed = value.trim();
    _scheduleCatalogueLookup(trimmed);
    if (trimmed.isEmpty) {
      if (_barcodeCollisionName != null) {
        setState(() => _barcodeCollisionName = null);
      }
      return;
    }
    final db = ref.read(databaseProvider);
    final match = await db.catalogDao.findProductByBarcode(trimmed);
    if (!mounted) return;
    final collision =
        (match != null && match.id != _selectedExistingProduct?.id)
        ? match.name
        : null;
    if (collision != _barcodeCollisionName) {
      setState(() => _barcodeCollisionName = collision);
    }
  }

  // ── Shared barcode catalogue (ADR 0029 §8, #332) ─────────────────────────

  /// Only a brand-new product is filled in: never with an existing product
  /// picked for restock. (Edits use Update Product, and the #321 "link to an
  /// existing product" flow never opens this screen.)
  bool get _canSuggestFromCatalogue => _selectedExistingProduct == null;

  /// The photo box only exists on the Fast-Add form for a new product, so a
  /// suggested photo is only held there.
  bool get _showsPhotoField =>
      _selectedExistingProduct == null && !widget.receiveMode;

  /// Looks a typed or scanned [code] up after a short pause. A code that is
  /// not a factory barcode never reaches the service.
  void _scheduleCatalogueLookup(String code) {
    _catalogueDebounce?.cancel();
    if (!_canSuggestFromCatalogue || FactoryBarcode.tryParse(code) == null) {
      return;
    }
    _catalogueDebounce = Timer(
      _catalogueDebounceDelay,
      () => _lookUpCatalogue(code),
    );
  }

  /// Asks the shared catalogue about [code] and fills only the boxes that are
  /// still empty when the answer comes. The answer is dropped when the barcode
  /// box no longer holds [code]. Any failure leaves the form alone, silently;
  /// saving never waits on this.
  Future<void> _lookUpCatalogue(String code) async {
    if (!_canSuggestFromCatalogue || FactoryBarcode.tryParse(code) == null) {
      return;
    }
    final service = ref.read(barcodeCatalogueServiceProvider);
    // Only download the photo when it could be used (saves phone data);
    // _applyCatalogueSuggestion re-checks before using the bytes.
    final suggestion = await service.lookup(
      code,
      includePhoto: _showsPhotoField && _pendingImageBytes == null,
    );
    if (suggestion == null || !mounted) return;
    if (_barcodeCtrl.text.trim() != code || !_canSuggestFromCatalogue) return;
    _applyCatalogueSuggestion(suggestion);
  }

  void _applyCatalogueSuggestion(BarcodeSuggestion suggestion) {
    final name = suggestion.name;
    final fillName = name != null && _nameCtrl.text.trim().isEmpty;
    final unit = suggestion.unit == null
        ? null
        : _matchListedUnit(suggestion.unit!);
    final fillUnit = unit != null && _unit == null;
    final photo = _showsPhotoField && _pendingImageBytes == null
        ? _processCataloguePhoto(suggestion.photoBytes)
        : null;
    if (!fillName && !fillUnit && photo == null) return;

    if (fillName) _nameCtrl.text = name;
    setState(() {
      if (fillName) _isNameFromCatalogue = true;
      if (fillUnit) {
        if (!_dynamicUnits.contains(unit)) {
          _catalogueUnit = unit;
          _dynamicUnits = [..._dynamicUnits, unit]..sort();
        }
        _unit = unit;
        // As picking a unit by hand: Bottle turns empties tracking on.
        _trackEmpties = unit.toLowerCase() == 'bottle';
        _isUnitFromCatalogue = true;
      }
      if (photo != null) {
        _pendingImageBytes = photo;
        _isPhotoFromCatalogue = true;
        // The photo box sits in "More details": open it so the filled photo
        // is seen rather than saved unnoticed.
        _showMoreDetails = true;
      }
    });
  }

  /// The dropdown's own spelling of [unit] when it is already listed (case
  /// aside), else [unit] as suggested.
  String _matchListedUnit(String unit) {
    final lower = unit.toLowerCase();
    return _dynamicUnits.firstWhere(
      (u) => u.toLowerCase() == lower,
      orElse: () => unit,
    );
  }

  /// Runs the suggested photo through the same processing as a picked photo,
  /// so it is held and saved as the shop's own photo. Null when it can't be
  /// decoded.
  Uint8List? _processCataloguePhoto(Uint8List? raw) {
    if (raw == null) return null;
    final result = ref.read(productImageServiceProvider).processBytes(raw);
    return switch (result) {
      Ok(:final value) => value,
      Err() => null,
    };
  }

  void _onUnitPicked(String? value) {
    setState(() {
      _unit = value;
      // Auto-enable tracking for bottle products, off otherwise (a null unit
      // is not a bottle).
      _trackEmpties = value?.toLowerCase() == 'bottle';
      _isUnitFromCatalogue = false;
    });
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

  void _onNameChanged(String query) {
    final q = query.trim().toLowerCase();
    setState(() {
      _isNameFromCatalogue = false;
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
    _retailPriceCtrl.text = (product.retailerPriceKobo / 100).toStringAsFixed(
      2,
    );
    _wholesalePriceCtrl.text = (product.wholesalerPriceKobo / 100)
        .toStringAsFixed(2);
    _buyingPriceCtrl.text = (product.buyingPriceKobo / 100).toStringAsFixed(2);
    _emptyCrateValueCtrl.text = product.emptyCrateValueKobo > 0
        ? (product.emptyCrateValueKobo / 100).toStringAsFixed(2)
        : '';
    _lowStockCtrl.text = product.lowStockThreshold.toString();
    // #320: a barcode already in the field (scanned or typed) is kept, so
    // picking the product it belongs to saves that code onto it. Only an empty
    // field takes the product's own barcode.
    final keepTypedBarcode = _barcodeCtrl.text.trim().isNotEmpty;
    if (!keepTypedBarcode) _barcodeCtrl.text = product.barcode ?? '';

    _catalogueDebounce?.cancel();
    setState(() {
      _selectedExistingProduct = product;
      _barcodeCollisionName = null;
      _isNameFromCatalogue = false;
      _isUnitFromCatalogue = false;
      _unit = product.unit;
      _size = product.size;
      _trackEmpties = product.trackEmpties;
      _allowFractionalSales = product.allowFractionalSales;
      _expiryDate = product.expiryDate;
      _selectedCategory = _allCategories.cast<CategoryData?>().firstWhere(
        (c) => c?.id == product.categoryId,
        orElse: () => null,
      );
      if (_selectedCategory != null) {
        _categoryCtrl.text = _selectedCategory!.name;
      }
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
    // The kept code may belong to a third product: re-run the soft warning
    // against the newly picked one.
    if (keepTypedBarcode) _onBarcodeChanged(_barcodeCtrl.text);
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
    _categoryCtrl.clear();
    _barcodeCtrl.clear();
    setState(() {
      _selectedExistingProduct = null;
      _barcodeCollisionName = null;
      _isNameFromCatalogue = false;
      _isUnitFromCatalogue = false;
      // Clearing an existing selection to add fresh resets to "No unit" (owner
      // request) — the same up-front, non-pre-filled default as initState.
      _unit = null;
      _size = null;
      _expiryDate = null;
      _trackEmpties = _unit?.toLowerCase() == 'bottle';
      _allowFractionalSales = false;
      _selectedManufacturer = null;
      _selectedSupplier = null;
      _selectedCategory = null;
    });
  }

  Future<void> _createNewManufacturer(String name) async {
    final db = ref.read(databaseProvider);
    final businessId = ref.read(authProvider).currentUser?.businessId;
    if (businessId == null) return;
    try {
      final id = await db.inventoryDao.insertManufacturer(
        ManufacturersCompanion.insert(name: name, businessId: businessId),
      );
      final manufacturers = await db.inventoryDao.getAllManufacturers();
      final newM = manufacturers.firstWhere((m) => m.id == id);
      if (!mounted) return;
      setState(() {
        _allManufacturers = manufacturers;
        _selectManufacturer(newM);
      });
    } catch (_) {
      if (mounted) {
        AppNotification.showError(
          context,
          'Could not create manufacturer. Please try again.',
        );
      }
    }
  }

  Future<void> _createNewCategory(String name) async {
    final db = ref.read(databaseProvider);
    final businessId = ref.read(authProvider).currentUser?.businessId;
    if (businessId == null) return;
    try {
      final id = await db.catalogDao.insertCategory(
        CategoriesCompanion.insert(name: name, businessId: businessId),
      );
      final categories = await db.inventoryDao.getAllCategories();
      final newC = categories.firstWhere((c) => c.id == id);
      if (!mounted) return;
      setState(() {
        _allCategories = categories;
        _selectCategory(newC);
      });
    } catch (_) {
      if (mounted) {
        AppNotification.showError(
          context,
          'Could not create category. Please try again.',
        );
      }
    }
  }

  Future<void> _createNewSupplier(String name) async {
    final db = ref.read(databaseProvider);
    final businessId = ref.read(authProvider).currentUser?.businessId;
    if (businessId == null) return;
    try {
      final id = await db.catalogDao.insertSupplier(
        SuppliersCompanion.insert(name: name, businessId: businessId),
      );
      final suppliers = await db.catalogDao.getAllSuppliers();
      final newS = suppliers.firstWhere((s) => s.id == id);
      if (!mounted) return;
      setState(() {
        _allSuppliers = suppliers;
        _selectSupplier(newS);
      });
    } catch (_) {
      if (mounted) {
        AppNotification.showError(
          context,
          'Could not create supplier. Please try again.',
        );
      }
    }
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
    return categories.firstWhere((c) => c.id == id);
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

  /// §13.4 / rule #13 — empty-crate tracking only exists for Bar / Beer
  /// Distributor businesses. `Bottle` is the default unit and the toggle below
  /// defaults on, so gate it on the business type — otherwise a non-crate
  /// business would silently create trackEmpties products (which leak the crate
  /// deposit UI into the cart/checkout and accrue crate-owed ledger rows).
  bool get _isCrateBusiness =>
      businessTracksCrates(ref.read(currentBusinessProvider));

  /// The adaptive Fast-Add layout is used for creating a brand-new product in
  /// direct mode. Receive Stock's mini-form and the "add stock to an existing
  /// product" path keep the full classic layout untouched.
  bool get _useFastLayout =>
      !widget.receiveMode && _selectedExistingProduct == null;

  /// trackEmpties as actually saved — forced off for non-crate businesses even
  /// if the (hidden) checkbox state is on.
  bool get _effectiveTrackEmpties => _isCrateBusiness && _trackEmpties;

  /// Empty-crate value in kobo, or null when not tracking empties / left blank.
  int? get _emptyCrateValueKobo {
    if (!(_effectiveTrackEmpties && _unit?.toLowerCase() == 'bottle')) {
      return null;
    }
    final raw = _emptyCrateValueCtrl.text.trim();
    if (raw.isEmpty) return null;
    return (parseCurrency(raw) * 100).round();
  }

  Future<bool> _confirmSaveProduct(String name) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        // Scrolls rather than overflows over a sideways keyboard (#392).
        scrollable: true,
        title: Text(
          'Save ${_lexicon.item}?',
          style: ctx.screenTitleStyle.copyWith(
            color: Theme.of(ctx).colorScheme.onSurface,
          ),
        ),
        content: Text(
          'Are you sure you want to save "$name"?',
          style: ctx
              .regularStyle(14)
              .copyWith(color: Theme.of(ctx).colorScheme.onSurface),
        ),
        actions: [
          AppButton(
            text: 'Cancel',
            variant: AppButtonVariant.ghost,
            size: AppButtonSize.small,
            onPressed: () => Navigator.pop(ctx, false),
          ),
          AppButton(
            text: 'Save',
            variant: AppButtonVariant.primary,
            size: AppButtonSize.small,
            onPressed: () => Navigator.pop(ctx, true),
          ),
        ],
      ),
    );
    return confirmed ?? false;
  }

  Future<void> _save() async {
    final db = ref.read(databaseProvider);
    final auth = ref.read(authProvider);
    final canEditBuying = _canEditBuying;

    setState(() => _errorMessage = null);

    // ── EXISTING PRODUCT: update details + add stock ───────────────────────
    if (_selectedExistingProduct != null) {
      final existingName = _nameCtrl.text.trim();
      if (!widget.receiveMode && _selectedStore == null) {
        AppNotification.showError(context, 'Store is required.');
        return;
      }
      final qty = int.tryParse(_initialStockCtrl.text) ?? 0;
      if (qty <= 0) {
        AppNotification.showError(context, 'Quantity must be greater than 0.');
        return;
      }
      if (existingName.isEmpty) {
        AppNotification.showError(
          context,
          '${_lexicon.item} Name is required.',
        );
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

      final confirmed = await _confirmSaveProduct(existingName);
      if (!confirmed) return;

      setState(() => _isSaving = true);
      try {
        // Auto-handle manufacturer/supplier/category if typed but not selected
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
        if (_selectedCategory == null && _categoryCtrl.text.trim().isNotEmpty) {
          _selectedCategory = await _getOrCreateCategory(
            _categoryCtrl.text.trim(),
          );
        }

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

        // Persist the crate value at the manufacturer level (§16.5).
        if (_selectedManufacturer != null && _emptyCrateValueKobo != null) {
          await db.catalogDao.updateManufacturerEmptyCrateValue(
            _selectedManufacturer!.id,
            _emptyCrateValueKobo!,
          );
        }

        // 2. Add to receive cart if in receive mode; otherwise adjust stock directly.
        final updatedProduct = await (db.select(
          db.products,
        )..where((t) => t.id.equals(productId))).getSingle();
        if (qty > 0) {
          if (widget.receiveMode) {
            ref
                .read(receiveCartProvider.notifier)
                .addOrIncrement(updatedProduct, amount: qty);
            if (mounted) {
              AppNotification.showSuccess(
                context,
                '$qty units of $existingName added to Receive Cart',
              );
            }
          } else {
            // #170 #7a: the existing-product "Add quantity" shortcut now records
            // its cost like a delivery — adjustStock creates a Cost Batch at the
            // entered buying price (0 → Uncosted), so these units no longer sell
            // at phantom 0 COGS.
            await db.inventoryDao.adjustStock(
              productId,
              _selectedStore!.id,
              qty,
              'Stock received',
              auth.currentUser?.id ?? 'unknown',
              inflowUnitCostKobo: buyingKobo,
            );
            if (mounted) {
              AppNotification.showSuccess(
                context,
                '$qty units of $existingName added to stock',
              );
            }
          }
        }

        await ref
            .read(activityLogProvider)
            .logAction(
              'product_update',
              '${auth.currentUser?.name ?? 'Unknown'} updated $existingName${qty > 0 ? (widget.receiveMode ? ' and routed $qty units to receive cart' : ' and added $qty units to stock') : ''}',
              productId: productId,
            );
        if (mounted) Navigator.pop(context);
        widget.onProductAdded?.call(updatedProduct);
      } catch (e, st) {
        CrashReporter.record(e, st, context: 'inventory.add_product');
        debugPrint('AddProductScreen._save (existing) error: $e');
        if (mounted) {
          AppNotification.showError(
            context,
            'Could not update ${_lexicon.itemLower}: $e',
          );
        }
      } finally {
        if (mounted) setState(() => _isSaving = false);
      }
      return;
    }

    // ── NEW PRODUCT ─────────────────────────────────────────────────────────
    // Direct-mode (Fast-Add) creates run through the pure Fast-Add form model
    // (Seam 1). Receive Stock's mini-form and the "add stock to an existing
    // product" path keep the full classic layout untouched.
    if (!widget.receiveMode) {
      await _saveFastAddNewProduct();
      return;
    }

    final name = _nameCtrl.text.trim();
    final hasCategory =
        _selectedCategory != null || _categoryCtrl.text.trim().isNotEmpty;

    if (!mounted) return;

    String? missingField;
    if (name.isEmpty) {
      missingField = '${_lexicon.item} Name';
    } else if (_subtitleCtrl.text.trim().isEmpty) {
      missingField = 'Description / Subtitle';
    } else if (!hasCategory) {
      missingField = _lexicon.category;
    } else if (_retailPriceCtrl.text.trim().isEmpty) {
      missingField = 'Retailer Price';
    } else if (_wholesalePriceCtrl.text.trim().isEmpty) {
      missingField = 'Wholesaler Price';
    } else if (canEditBuying && _buyingPriceCtrl.text.trim().isEmpty) {
      missingField = 'Buying Price';
    } else if (_lowStockCtrl.text.trim().isEmpty) {
      missingField = 'Low Stock Alert';
    } else if (!widget.receiveMode && _selectedStore == null) {
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
    final buyingPrice = canEditBuying
        ? parseCurrency(_buyingPriceCtrl.text)
        : 0.0;

    if (canEditBuying && buyingPrice > retailPrice) {
      AppNotification.showError(
        context,
        'Buying price (${formatCurrency(buyingPrice)}) cannot be higher than retailer price (${formatCurrency(retailPrice)}).',
      );
      return;
    }

    // Check for duplicate product name
    final existing = await db.catalogDao.findByName(name);
    if (existing != null) {
      if (mounted) {
        AppNotification.showError(
          context,
          'A ${_lexicon.itemLower} named "$name" already exists.',
        );
      }
      return;
    }

    final confirmed = await _confirmSaveProduct(name);
    if (!confirmed) return;

    setState(() => _isSaving = true);
    try {
      if (_selectedCategory == null && _categoryCtrl.text.trim().isNotEmpty) {
        _selectedCategory = await _getOrCreateCategory(
          _categoryCtrl.text.trim(),
        );
      }
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
          trackEmpties: drift.Value(_effectiveTrackEmpties),
          emptyCrateValueKobo: crateValueKobo == null
              ? const drift.Value.absent()
              : drift.Value(crateValueKobo),
          allowFractionalSales: drift.Value(_allowFractionalSales),
          colorHex: drift.Value(_colorHex),
          size: drift.Value(_size),
          expiryDate: drift.Value(_expiryDate),
          barcode: drift.Value(
            _barcodeCtrl.text.trim().isEmpty ? null : _barcodeCtrl.text.trim(),
          ),
          lowStockThreshold: drift.Value(lowStock),
          manufacturerId: drift.Value(_selectedManufacturer?.id),
          supplierId: drift.Value(_selectedSupplier?.id),
          categoryId: drift.Value(_selectedCategory?.id),
        ),
        initialStock: widget.receiveMode ? null : initialStock,
        storeId: widget.receiveMode ? null : _selectedStore?.id,
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

      final newProduct = await (db.select(
        db.products,
      )..where((t) => t.id.equals(productId))).getSingle();
      if (initialStock > 0 && widget.receiveMode) {
        ref
            .read(receiveCartProvider.notifier)
            .addOrIncrement(newProduct, amount: initialStock);
        if (mounted) {
          AppNotification.showSuccess(
            context,
            '$name added to catalog and $initialStock units routed to Receive Cart',
          );
        }
      } else {
        if (mounted) {
          AppNotification.showSuccess(context, '$name added to catalog');
        }
      }

      await ref
          .read(activityLogProvider)
          .logAction(
            'new_product',
            '${auth.currentUser?.name ?? 'Unknown'} added product: $name'
                '${initialStock > 0 ? ' and routed $initialStock units to receive cart' : ''}',
            productId: productId,
          );

      if (mounted) Navigator.pop(context);
      widget.onProductAdded?.call(newProduct);
    } catch (e, st) {
      CrashReporter.record(e, st, context: 'inventory.add_product');
      debugPrint('AddProductScreen._save error: $e');
      if (mounted) {
        AppNotification.showError(
          context,
          'Could not save ${_lexicon.itemLower}: $e',
        );
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  /// Fast-Add (direct mode) create: validate + shape through the pure Fast-Add
  /// form model (Seam 1, ADR 0006), then persist via the existing DAOs.
  Future<void> _saveFastAddNewProduct() async {
    final businessId = ref.read(authProvider).currentUser?.businessId;
    if (businessId == null) {
      AppNotification.showError(context, 'Account not loaded yet.');
      return;
    }

    final result = resolveFastAdd(
      FastAddInput(
        name: _nameCtrl.text,
        sellingPrice: _retailPriceCtrl.text,
        quantity: _initialStockCtrl.text,
        buyingPrice: _buyingPriceCtrl.text,
        wholesalePrice: _wholesalePriceCtrl.text,
        lowStock: _lowStockCtrl.text,
        unit: _unit,
        trackEmpties: _trackEmpties,
        emptyCrateValue: _emptyCrateValueCtrl.text,
        hasManufacturer:
            _selectedManufacturer != null ||
            _manufacturerCtrl.text.trim().isNotEmpty,
        selectedStoreId: _selectedStore?.id,
        barcode: _barcodeCtrl.text,
      ),
      FastAddContext(
        tracksCrates: _isCrateBusiness,
        canEditBuying: _canEditBuying,
        storeIds: _stores.map((s) => s.id).toList(),
      ),
    );

    switch (result) {
      case FastAddInvalid(:final field, :final message):
        // Reveal a "More details" field before pointing at it, so an error
        // never references a collapsed field (ADR 0006).
        if (!_fastSectionFields.contains(field) && !_showMoreDetails) {
          setState(() => _showMoreDetails = true);
        }
        AppNotification.showError(context, message);
      case FastAddIntent():
        final confirmed = await _confirmSaveProduct(result.name);
        if (!confirmed) return;
        await _persistNewProduct(result);
    }
  }

  /// Persist a resolved Fast-Add write intent through the existing catalog /
  /// inventory DAOs — the same path a fully-filled form has always used. Only
  /// the shaped scalar values come from the model; the get-or-create foreign
  /// keys and pass-through fields are attached here.
  Future<void> _persistNewProduct(FastAddIntent intent) async {
    final db = ref.read(databaseProvider);
    final auth = ref.read(authProvider);
    final businessId = auth.currentUser?.businessId;
    if (businessId == null) return;

    // Duplicate-name guard (unchanged behaviour).
    final duplicate = await db.catalogDao.findByName(intent.name);
    if (duplicate != null) {
      if (mounted) {
        AppNotification.showError(
          context,
          'A ${_lexicon.itemLower} named "${intent.name}" already exists.',
        );
      }
      return;
    }

    setState(() => _isSaving = true);
    try {
      // Get-or-create the typed-but-unselected foreign keys, exactly as before.
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
      if (_selectedCategory == null && _categoryCtrl.text.trim().isNotEmpty) {
        _selectedCategory = await _getOrCreateCategory(
          _categoryCtrl.text.trim(),
        );
      }

      final productId = await db.catalogDao.insertProductWithInitialStock(
        ProductsCompanion.insert(
          name: intent.name,
          businessId: businessId,
          subtitle: drift.Value(
            _subtitleCtrl.text.trim().isEmpty
                ? null
                : _subtitleCtrl.text.trim(),
          ),
          retailerPriceKobo: drift.Value(intent.retailerPriceKobo),
          wholesalerPriceKobo: drift.Value(intent.wholesalerPriceKobo),
          buyingPriceKobo: drift.Value(intent.buyingPriceKobo),
          unit: drift.Value(intent.unit),
          trackEmpties: drift.Value(intent.trackEmpties),
          emptyCrateValueKobo: intent.emptyCrateValueKobo == null
              ? const drift.Value.absent()
              : drift.Value(intent.emptyCrateValueKobo!),
          allowFractionalSales: drift.Value(_allowFractionalSales),
          colorHex: drift.Value(_colorHex),
          size: drift.Value(_size),
          expiryDate: drift.Value(_expiryDate),
          barcode: drift.Value(intent.barcode),
          lowStockThreshold: drift.Value(intent.lowStockThreshold),
          manufacturerId: drift.Value(_selectedManufacturer?.id),
          supplierId: drift.Value(_selectedSupplier?.id),
          categoryId: drift.Value(_selectedCategory?.id),
        ),
        initialStock: intent.initialStock,
        storeId: intent.storeId,
        performedBy: auth.currentUser?.id,
      );

      // Persist the crate value at the manufacturer level so every product of
      // this manufacturer shares one value (§16.5).
      if (_selectedManufacturer != null && intent.emptyCrateValueKobo != null) {
        await db.catalogDao.updateManufacturerEmptyCrateValue(
          _selectedManufacturer!.id,
          intent.emptyCrateValueKobo!,
        );
      }

      // Optional product photo (#78): the row exists now, so upload keyed by its
      // id and write the URL (which syncs). The service also caches the bytes
      // locally, so the photo renders offline; if the upload fails (offline) the
      // reconnect flush patches image_url later.
      if (_pendingImageBytes != null) {
        final imgSvc = ref.read(productImageServiceProvider);
        final res = await imgSvc.save(
          businessId: businessId,
          productId: productId,
          bytes: _pendingImageBytes!,
        );
        if (res case Ok(:final value)) {
          await db.catalogDao.setProductImageUrl(productId, value);
        }
      }

      final newProduct = await (db.select(
        db.products,
      )..where((t) => t.id.equals(productId))).getSingle();
      if (mounted) {
        AppNotification.showSuccess(context, '${intent.name} added to catalog');
      }

      await ref
          .read(activityLogProvider)
          .logAction(
            'new_product',
            '${auth.currentUser?.name ?? 'Unknown'} added product: ${intent.name}',
            productId: productId,
          );

      if (mounted) Navigator.pop(context);
      widget.onProductAdded?.call(newProduct);
    } catch (e, st) {
      CrashReporter.record(e, st, context: 'inventory.add_product');
      debugPrint('AddProductScreen._persistNewProduct error: $e');
      if (mounted) {
        AppNotification.showError(
          context,
          'Could not save ${_lexicon.itemLower}: $e',
        );
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  /// Pick + process an optional product photo, held in memory until the product
  /// is saved (#78). Cancelling or a decode error leaves the current selection.
  Future<void> _pickPhoto() async {
    final svc = ref.read(productImageServiceProvider);
    final result = await svc.pickAndProcess();
    if (!mounted) return;
    switch (result) {
      case Ok(:final value):
        setState(() {
          _pendingImageBytes = value;
          _isPhotoFromCatalogue = false;
        });
      case Err(:final error):
        if (!error.isCancelled) {
          AppNotification.showError(context, 'Could not load image.');
        }
    }
  }

  Future<void> _addSupplierViaForm() async {
    final created = await SupplierFormSheet.show(context);
    if (created == null || !mounted) return;
    _allSuppliers = await ref
        .read(databaseProvider)
        .catalogDao
        .getAllSuppliers();
    if (!mounted) return;
    _selectSupplier(created);
  }

  @override
  Widget build(BuildContext context) {
    final isExisting = _selectedExistingProduct != null;
    final canEditBuying = Gates.editBuyingPrice.allows(ref);
    final gap = context.getRSize(14);

    return Container(
      decoration: AppDecorations.pageBackground(context),
      child: Scaffold(
        backgroundColor: Colors.transparent,
        // Keep the body + save button above the keyboard. This screen is
        // pushed from two places onto DIFFERENT navigators: the Inventory FAB
        // pushes it on the tab's nested navigator (under MainLayout, whose
        // Scaffold already resizes for the keyboard), but the post-onboarding
        // auto-show (main_layout.dart) pushes it on the ROOT navigator, ABOVE
        // MainLayout — there nothing resizes for the keyboard, so the save
        // button and the bottom Quantity/Store fields end up hidden behind it.
        // `true` is correct in BOTH cases: nested, MainLayout's Scaffold has
        // already zeroed the bottom viewInsets for descendants, so this is a
        // no-op; on the root navigator it lifts the body + bottomNavigationBar
        // above the keyboard. The save-button padding stays nav-only
        // (deviceBottomPadding) — when the keyboard is up the system nav bar
        // is occluded, so the extra is harmless.
        resizeToAvoidBottomInset: true,
        appBar: InventoryTopBar(
          icon: isExisting ? AppIcons.inventory : AppIcons.tag,
          title: isExisting ? 'Add Stock' : 'Add ${_lexicon.item}',
          height: inventoryTopBarHeight(context),
          // Same pop as the old BackButton, drawn with the app's icon set
          // like CEO Settings' back button.
          leading: IconButton(
            tooltip: MaterialLocalizations.of(context).backButtonTooltip,
            constraints: const BoxConstraints(
              minWidth: kMinInteractiveDimension,
              minHeight: kMinInteractiveDimension,
            ),
            onPressed: () => Navigator.of(context).maybePop(),
            icon: AppIcon(
              AppIcons.arrowBack,
              size: context.getRSize(24),
              color: Theme.of(context).colorScheme.onSurface,
            ),
          ),
        ),
        body: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              // Forms cap at the fixed 720 and centre (#392), measured.
              final gutter = inventoryGutter(context, constraints.maxWidth);
              return SingleChildScrollView(
                padding: EdgeInsets.fromLTRB(
                  gutter,
                  context.getRSize(16),
                  gutter,
                  context.getRSize(16),
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
                      SizedBox(height: context.getRSize(16)),
                    ],
                    // ── FAST-ADD (direct mode, new product) vs the classic
                    // full layout (Receive Stock mini-form / add-stock-to-
                    // existing). ───────────────────────────────────────────
                    if (_useFastLayout)
                      ..._fastFormChildren(canEditBuying: canEditBuying)
                    else
                      ..._classicFormChildren(
                        isExisting: isExisting,
                        canEditBuying: canEditBuying,
                        gap: gap,
                      ),
                  ],
                ),
              );
            },
          ),
        ),
        bottomNavigationBar: InventoryFormFooter(
          child: AppButton(
            text: isExisting ? 'Add Stock' : 'Add ${_lexicon.item}',
            variant: AppButtonVariant.primary,
            isLoading: _isSaving,
            onPressed: _save,
          ),
        ),
      ),
    );
  }

  // ── CLASSIC LAYOUT (Receive Stock mini-form / add stock to existing) ──────

  List<Widget> _classicFormChildren({
    required bool isExisting,
    required bool canEditBuying,
    required double gap,
  }) {
    final section = context.getRSize(16);
    return [
      InventoryFormCard(
        children: [
          // ── EXISTING PRODUCT BANNER ──────────────────────────────
          if (isExisting) ...[
            InventoryNotice(
              icon: AppIcons.inventory,
              tone: IconTileTone.green,
              title: 'Adding stock to existing ${_lexicon.itemLower}',
              message: productDisplayName(
                _selectedExistingProduct!.name,
                _selectedExistingProduct!.size,
                unit: _selectedExistingProduct!.unit,
              ),
              onClose: _clearExistingProduct,
              closeTooltip: 'Clear',
            ),
            SizedBox(height: section),
          ] else ...[
            // ── NAME SEARCH (new product mode only) ────────────────
            AppInput(
              controller: _nameCtrl,
              labelText: '${_lexicon.item} Name *',
              hintText: _nameHint,
              prefixIcon: const InventorySearchIcon(),
              onChanged: _onNameChanged,
            ),
            if (_isNameFromCatalogue) const CatalogueFilledNote(),
            if (_productSuggestions.isNotEmpty) _productSuggestionsList(),
            SizedBox(height: gap),
          ],
          // ── DETAIL FIELDS (always shown; pre-filled for existing) ─
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
          // Starter category suggestions for a fresh shop (#80) — shown
          // before the owner types and only while they have no categories
          // yet, so a new business isn't a blank slate.
          if (_allCategories.isEmpty &&
              _selectedCategory == null &&
              _categoryCtrl.text.trim().isEmpty)
            InventorySuggestionList(
              children: [
                for (final name in _lexicon.starterCategories)
                  InventorySuggestionTile(
                    label: name,
                    icon: AppIcons.addCircle,
                    onTap: () {
                      _categoryCtrl.text = name;
                      _onCategoryChanged(name);
                    },
                  ),
              ],
            ),
          if (_categorySuggestions.isNotEmpty ||
              (_categoryCtrl.text.trim().isNotEmpty &&
                  _selectedCategory == null))
            _categorySuggestionsList(),
          SizedBox(height: section),
          AppInput(
            controller: _subtitleCtrl,
            labelText: 'Description / Subtitle *',
            hintText: _descriptionHint,
          ),
          SizedBox(height: gap),
          // ── BARCODE (optional) ─────────────────────────────────
          _barcodeField(),
          SizedBox(height: gap),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: AppInput(
                  controller: _retailPriceCtrl,
                  labelText: 'Retailer Price ($activeCurrencySymbol) *',
                  hintText: '0.00',
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
                  labelText: 'Wholesaler Price ($activeCurrencySymbol) *',
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
          AppInput(
            controller: _lowStockCtrl,
            labelText: 'Low Stock Alert *',
            hintText: '5',
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          ),
          SizedBox(height: section),

          // ── PRODUCT UNIT SELECTOR (optional, #108) ─────────────
          const InventoryFieldLabel('PRODUCT UNIT'),
          SizedBox(height: context.getRSize(8)),
          _unitDropdown(),
          if (_isUnitFromCatalogue && !isExisting) const CatalogueFilledNote(),
          SizedBox(height: context.getRSize(8)),

          // ── ALLOW FRACTIONAL SALES ─────────────────────────────
          _fractionalRow(),
          SizedBox(height: section),

          // ── EXPIRY DATE (optional, all business types) ─────────
          ..._expiryChildren(),
          SizedBox(height: section),

          // ── MANUFACTURER ───────────────────────────────────────
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
            _manufacturerSuggestionsList(),
          SizedBox(height: section),

          // ── TRACK EMPTIES + CRATE VALUE (directly below Manufacturer) ─
          // Crate-only (rule #13): hidden for non-Bar/Beer-distributor
          // businesses; _effectiveTrackEmpties also forces it off on save.
          if (_unit?.toLowerCase() == 'bottle' && _isCrateBusiness) ...[
            ..._trackEmptiesChildren(),
            SizedBox(height: section),
          ],

          if (!widget.receiveMode) ...[
            // ── SUPPLIER ───────────────────────────────────────────
            ..._supplierChildren(labelText: 'SUPPLIER (optional)'),
            SizedBox(height: section),
          ],
        ],
      ),
      SizedBox(height: section),
      InventoryFormCard(
        children: [
          // ── QUANTITY & STORE (always visible) ───────────────
          AppInput(
            controller: _initialStockCtrl,
            labelText: isExisting ? 'QUANTITY TO ADD *' : 'INITIAL QUANTITY *',
            hintText: '0',
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          ),
          if (!widget.receiveMode) ...[
            SizedBox(height: section),
            const InventoryFieldLabel('STORE *'),
            SizedBox(height: context.getRSize(8)),
            if (_stores.isEmpty)
              const InventoryEmptyCard(icon: AppIcons.store, title: 'No stores')
            else
              _storeDropdown(),
          ],
        ],
      ),
    ];
  }

  // ── FAST-ADD LAYOUT (direct mode) ───────────────────────────────────────────

  /// The adaptive Fast-Add form (ADR 0006): a short fast section — Name (with a
  /// size hint), Selling Price, skippable Buying Price, optional Category, and
  /// (crate businesses only) a required Manufacturer, then Quantity — followed
  /// by a collapsible "More details" section holding everything else.
  List<Widget> _fastFormChildren({required bool canEditBuying}) {
    final gap = context.getRSize(14);
    final section = context.getRSize(16);
    return [
      InventoryFormCard(
        children: [
          // ── NAME (include the size) ─────────────────────────────────────
          AppInput(
            controller: _nameCtrl,
            labelText: '${_lexicon.item} Name *',
            hintText: _nameHint,
            prefixIcon: const InventorySearchIcon(),
            onChanged: _onNameChanged,
          ),
          const InventoryFieldHelper(
            'Include the size or key detail in the name.',
          ),
          if (_isNameFromCatalogue) const CatalogueFilledNote(),
          if (_productSuggestions.isNotEmpty) _productSuggestionsList(),
          SizedBox(height: section),

          // ── SELLING PRICE ───────────────────────────────────────────────
          AppInput(
            controller: _retailPriceCtrl,
            labelText: 'Selling Price ($activeCurrencySymbol) *',
            hintText: '0.00',
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [CurrencyInputFormatter()],
          ),
          SizedBox(height: gap),

          // ── BUYING PRICE (skippable) ────────────────────────────────────
          if (canEditBuying) ...[
            AppInput(
              controller: _buyingPriceCtrl,
              labelText: 'Buying Price ($activeCurrencySymbol)',
              hintText: '0.00',
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              inputFormatters: [CurrencyInputFormatter()],
            ),
            const InventoryFieldHelper(
              'Add what you paid so profit shows correctly. You can add it '
              'later.',
            ),
            SizedBox(height: gap),
          ],

          // ── CATEGORY (optional, with examples) ──────────────────────────
          AppInput(
            controller: _categoryCtrl,
            labelText: _lexicon.category,
            hintText: 'Search or type category name…',
            prefixIcon: const InventorySearchIcon(),
            onChanged: _onCategoryChanged,
            suffixIcon: _selectedCategory != null
                ? InventoryFieldClear(onPressed: _clearCategory)
                : null,
          ),
          InventoryFieldHelper(
            'e.g. ${_lexicon.starterCategories.take(3).join(', ')}',
          ),
          if (_categorySuggestions.isNotEmpty ||
              (_categoryCtrl.text.trim().isNotEmpty &&
                  _selectedCategory == null))
            _categorySuggestionsList(),
          SizedBox(height: section),

          // ── MANUFACTURER (crate businesses only, optional) ──────────────
          if (_isCrateBusiness) ...[
            AppInput(
              controller: _manufacturerCtrl,
              labelText: 'Manufacturer (optional)',
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
              _manufacturerSuggestionsList(),
            SizedBox(height: section),
          ],

          // ── QUANTITY ────────────────────────────────────────────────────
          AppInput(
            controller: _initialStockCtrl,
            labelText: 'Quantity *',
            hintText: '0',
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          ),
          SizedBox(height: context.getRSize(20)),

          // ── PRODUCT UNIT (surfaced up-front, owner request) ─────────────
          // Always visible — not tucked inside "More details". Defaults to
          // "No unit"; the trade's starter units are offered but not
          // pre-selected. "No unit" is a real, always-valid choice, so save
          // is never blocked.
          const InventoryFieldLabel('PRODUCT UNIT'),
          SizedBox(height: context.getRSize(8)),
          _unitDropdown(),
          if (_isUnitFromCatalogue) const CatalogueFilledNote(),
        ],
      ),
      SizedBox(height: section),

      // ── MORE DETAILS (collapsible) ──────────────────────────────────────
      InventoryFormCard(
        children: [
          _moreDetailsHeader(),
          if (_showMoreDetails) ...[
            SizedBox(height: section),
            ..._moreDetailsChildren(),
          ],
        ],
      ),
    ];
  }

  /// The collapsed "More details" fields: everything optional or defaulted.
  List<Widget> _moreDetailsChildren() {
    final gap = context.getRSize(14);
    final section = context.getRSize(16);
    return [
      // ── PHOTO (optional, new products only — edits use Update Product) ───
      if (_selectedExistingProduct == null && !widget.receiveMode) ...[
        ProductPhotoField(
          pendingBytes: _pendingImageBytes,
          onPick: _pickPhoto,
          onRemove: _pendingImageBytes == null
              ? null
              : () => setState(() {
                  _pendingImageBytes = null;
                  _isPhotoFromCatalogue = false;
                }),
        ),
        if (_isPhotoFromCatalogue) const CatalogueFilledNote(),
        SizedBox(height: gap),
      ],
      // ── DESCRIPTION (optional) ──────────────────────────────────────────
      AppInput(
        controller: _subtitleCtrl,
        labelText: 'Description',
        hintText: _descriptionHint,
      ),
      SizedBox(height: gap),

      // ── BARCODE (optional) ──────────────────────────────────────────────
      _barcodeField(),
      SizedBox(height: gap),

      // ── WHOLESALER PRICE (optional; mirrors selling on save) ────────────
      AppInput(
        controller: _wholesalePriceCtrl,
        labelText: 'Wholesaler Price ($activeCurrencySymbol)',
        hintText: 'Defaults to the selling price',
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        inputFormatters: [CurrencyInputFormatter()],
      ),
      SizedBox(height: section),

      // ── ALLOW FRACTIONAL SALES ──────────────────────────────────────────
      _fractionalRow(),
      SizedBox(height: section),

      // ── TRACK EMPTIES + CRATE VALUE (crate business + bottle only) ──────
      if (_unit?.toLowerCase() == 'bottle' && _isCrateBusiness) ...[
        ..._trackEmptiesChildren(),
        SizedBox(height: section),
      ],

      // ── LOW STOCK ALERT (default 5) ─────────────────────────────────────
      AppInput(
        controller: _lowStockCtrl,
        labelText: 'Low Stock Alert',
        hintText: '5',
        keyboardType: TextInputType.number,
        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
      ),
      SizedBox(height: section),

      // ── SUPPLIER (optional) ─────────────────────────────────────────────
      ..._supplierChildren(labelText: 'Supplier'),
      SizedBox(height: section),

      // ── EXPIRY DATE (optional) ──────────────────────────────────────────
      ..._expiryChildren(),

      // ── STORE (multi-store only; single-store is used silently) ─────────
      if (_stores.length > 1) ...[
        SizedBox(height: section),
        const InventoryFieldLabel('STORE *'),
        SizedBox(height: context.getRSize(8)),
        _storeDropdown(),
      ],
    ];
  }

  // ── SHARED FIELDS ───────────────────────────────────────────────────────────

  Widget _unitDropdown() => AppDropdown<String?>(
    value: _unit,
    hintText: 'No unit',
    // "No unit" (#108) clears the unit — the product saves with just its
    // name and is hidden wherever the unit would render.
    items: [
      const DropdownMenuItem<String?>(value: null, child: Text('No unit')),
      ..._dynamicUnits.map(
        (u) => DropdownMenuItem<String?>(value: u, child: Text(u)),
      ),
    ],
    onChanged: _onUnitPicked,
  );

  Widget _storeDropdown() => AppDropdown<StoreData?>(
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
  );

  Widget _fractionalRow() => InventoryCheckRow(
    value: _allowFractionalSales,
    onChanged: (v) => setState(() => _allowFractionalSales = v ?? false),
    title: 'Allow fractional sales',
    subtitle:
        'Enables ±0.5 quantity steps when selling this ${_lexicon.itemLower}',
  );

  List<Widget> _trackEmptiesChildren() => [
    InventoryCheckRow(
      value: _trackEmpties,
      onChanged: (v) => setState(() => _trackEmpties = v ?? false),
      title: 'Track empty crate returns',
      subtitle:
          'Enables deposit collection and crate return flow for this '
          '${_lexicon.itemLower}',
    ),
    // Crate value is shared at the manufacturer level; selecting a
    // manufacturer autofills it (§16.5).
    if (_trackEmpties) ...[
      SizedBox(height: context.getRSize(6)),
      AppInput(
        controller: _emptyCrateValueCtrl,
        labelText: 'Empty Crate Value ($activeCurrencySymbol)',
        hintText: '0.00',
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        inputFormatters: [CurrencyInputFormatter()],
      ),
    ],
  ];

  List<Widget> _supplierChildren({required String labelText}) => [
    AppInput(
      controller: _supplierCtrl,
      labelText: labelText,
      hintText: 'Search supplier name…',
      prefixIcon: const InventorySearchIcon(),
      onChanged: _onSupplierChanged,
      suffixIcon: _selectedSupplier != null
          ? InventoryFieldClear(onPressed: _clearSupplier)
          : null,
    ),
    if (_supplierSuggestions.isNotEmpty ||
        (_supplierCtrl.text.trim().isNotEmpty && _selectedSupplier == null))
      _supplierSuggestionsList(),
    if (Gates.manageSuppliers.allows(ref)) ...[
      SizedBox(height: context.getRSize(8)),
      AppButton(
        text: 'Add new supplier',
        variant: AppButtonVariant.outline,
        onPressed: _addSupplierViaForm,
      ),
    ],
  ];

  List<Widget> _expiryChildren() {
    String? label() {
      final d = _expiryDate;
      if (d == null) return null;
      return '${d.day.toString().padLeft(2, '0')}/'
          '${d.month.toString().padLeft(2, '0')}/${d.year}';
    }

    return [
      const InventoryFieldLabel('EXPIRY DATE'),
      const InventoryFieldHelper(
        'Optional — used to flag stock nearing expiry',
      ),
      SizedBox(height: context.getRSize(8)),
      InventoryDateField(
        label: label(),
        placeholder: 'No expiry date',
        onTap: _pickExpiryDate,
        onClear: () => setState(() => _expiryDate = null),
      ),
    ];
  }

  /// Optional barcode field (#113) with a live soft-collision warning. Shared by
  /// the Fast-Add and classic layouts. Typing runs [_onBarcodeChanged], which
  /// warns (never blocks) if another product already uses the code.
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

  /// The "More details" toggle: a 48dp row, Bold 15 title and a chevron.
  Widget _moreDetailsHeader() {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    return Semantics(
      button: true,
      expanded: _showMoreDetails,
      child: InkWell(
        onTap: () => setState(() => _showMoreDetails = !_showMoreDetails),
        borderRadius: BorderRadius.circular(AppSpacing.borderRadiusM),
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            minHeight: kMinInteractiveDimension,
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'More details',
                  style: context
                      .boldStyle(15)
                      .copyWith(color: t.colorScheme.onSurface),
                ),
              ),
              AppIcon(
                _showMoreDetails ? AppIcons.chevronUp : AppIcons.chevronDown,
                size: context.getRSize(24),
                color: muted,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _productSuggestionsList() => InventorySuggestionList(
    children: [
      for (final p in _productSuggestions)
        InventorySuggestionTile(
          label: productDisplayName(p.name, p.size, unit: p.unit),
          onTap: () => _selectProduct(p),
        ),
    ],
  );

  Widget _categorySuggestionsList() => InventorySuggestionList(
    children: [
      ..._categorySuggestions.map(
        (c) => InventorySuggestionTile(
          label: c.name,
          onTap: () => _selectCategory(c),
        ),
      ),
      if (_categoryCtrl.text.trim().isNotEmpty &&
          !_categorySuggestions.any(
            (c) =>
                c.name.toLowerCase() == _categoryCtrl.text.trim().toLowerCase(),
          ))
        InventorySuggestionTile(
          label: 'Create "${_categoryCtrl.text.trim()}"',
          icon: AppIcons.addCircle,
          emphasis: true,
          onTap: () => _createNewCategory(_categoryCtrl.text.trim()),
        ),
    ],
  );

  Widget _manufacturerSuggestionsList() => InventorySuggestionList(
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
          onTap: () => _createNewManufacturer(_manufacturerCtrl.text.trim()),
        ),
    ],
  );

  Widget _supplierSuggestionsList() => InventorySuggestionList(
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
                s.name.toLowerCase() == _supplierCtrl.text.trim().toLowerCase(),
          ))
        InventorySuggestionTile(
          label: 'Create "${_supplierCtrl.text.trim()}"',
          icon: AppIcons.addCircle,
          emphasis: true,
          onTap: () => _createNewSupplier(_supplierCtrl.text.trim()),
        ),
    ],
  );
}
