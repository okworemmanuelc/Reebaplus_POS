import 'dart:async';

import 'package:drift/drift.dart' as drift;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/industry/lexicon.dart';
import 'package:reebaplus_pos/core/listings/listing_content.dart';
import 'package:reebaplus_pos/core/permissions/permissions.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/result.dart';
import 'package:reebaplus_pos/core/services/barcode_suggestion.dart';
import 'package:reebaplus_pos/core/services/crash_reporter.dart';
import 'package:reebaplus_pos/core/services/product_listing_service.dart';
import 'package:reebaplus_pos/core/theme/app_decorations.dart';
import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/theme/fixed_colors.dart';
import 'package:reebaplus_pos/core/utils/name_case.dart';
import 'package:reebaplus_pos/core/utils/currency_input_formatter.dart';
import 'package:reebaplus_pos/core/services/catalogue_lookup.dart';
import 'package:reebaplus_pos/core/utils/factory_barcode.dart';
import 'package:reebaplus_pos/shared/scanner/scanner_providers.dart';
import 'package:reebaplus_pos/core/utils/notifications.dart';
import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/core/utils/product_name.dart';
import 'package:reebaplus_pos/core/utils/product_unit.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/features/inventory/models/fast_add_product_model.dart';
import 'package:reebaplus_pos/features/inventory/models/product_form_rules.dart';
import 'package:reebaplus_pos/features/inventory/widgets/catalogue_filled_note.dart';
import 'package:reebaplus_pos/features/inventory/widgets/inventory_parts.dart';
import 'package:reebaplus_pos/features/inventory/widgets/listing_content_fields.dart';
import 'package:reebaplus_pos/features/inventory/widgets/product_details_route.dart';
import 'package:reebaplus_pos/features/inventory/widgets/product_form_parts.dart';
import 'package:reebaplus_pos/features/payments/widgets/supplier_form_sheet.dart';
import 'package:reebaplus_pos/features/receiving/state/receive_cart.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:reebaplus_pos/shared/widgets/app_dropdown.dart';
import 'package:reebaplus_pos/shared/widgets/app_input.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/redesign.dart';

/// Keys the Add Product tests find its boxes and buttons by (#487).
abstract final class AddProductKeys {
  static const name = ValueKey('add-product-name');
  static const barcode = ValueKey('add-product-barcode');
  static const category = ValueKey('add-product-category');
  static const manufacturer = ValueKey('add-product-manufacturer');
  static const unitsPerPack = ValueKey('add-product-units-per-pack');
  static const listingCard = ValueKey('add-product-listing');
  static const cost = ValueKey('add-product-cost');
  static const retail = ValueKey('add-product-retail');
  static const wholesale = ValueKey('add-product-wholesale');
  static const store = ValueKey('add-product-store');
  static const quantity = ValueKey('add-product-quantity');
  static const lowStock = ValueKey('add-product-low-stock');
  static const trackEmpties = ValueKey('add-product-track-empties');
  static const crateDeposit = ValueKey('add-product-crate-deposit');
  static const description = ValueKey('add-product-description');
  static const supplier = ValueKey('add-product-supplier');
  static const save = ValueKey('add-product-save');
  static const saveAndNew = ValueKey('add-product-save-and-new');
  static const preview = ValueKey('add-product-preview');

  /// One unit chip, by its SAVED value ("Bottle", shown as "Bottle Crate").
  static ValueKey<String> unitChip(String unit) =>
      ValueKey('add-product-unit-$unit');
}

/// How the form is laid out, from the MEASURED body width (#487).
enum _FormLayout {
  /// Under 600: one column of cards, the footer bar.
  phone,

  /// 600 to 1000: two columns of cards, the footer bar.
  twoColumn,

  /// 1000 and over: two columns plus the Preview panel, which holds the save
  /// buttons (no footer bar).
  wide;

  static _FormLayout of(double width) => width >= 1000
      ? _FormLayout.wide
      : (width >= 600 ? _FormLayout.twoColumn : _FormLayout.phone);
}

/// Add Product (#487, `phone-add-product-light.png` /
/// `wide-add-product-light.png`): one form for every new product — from
/// Inventory, Home, a POS scan of an unknown code, and Receive Stock's "New
/// product". It only creates; typing a name you already have lists that
/// product, and tapping it opens its Product Details.
///
/// Cards: Product Details (photo, name, barcode, category, brand), Product
/// Unit (chips + "how many in one"), Pricing (cost, retail, wholesale, profit
/// rows), Stock (store, opening quantity, low-stock alert), Track Empty Crates
/// (crate business + Bottle only) and an open More details card. Validation
/// and defaulting stay in the pure Fast-Add model (ADR 0006); an error scrolls
/// to its box.
///
/// In [receiveMode] the Store box is hidden and the opening quantity goes onto
/// the Receive Stock delivery list instead of into a store.
/// The small note under the barcode box about the shared-list check (#465).
enum _BarcodeNote { offline, newBarcode }

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

  /// Edit mode (#487 PR 4): the product to change. The form opens filled in
  /// from it, hides Store and Opening Quantity (stock changes go through
  /// Adjust Stock) and saves through the same calls the old Edit pop-up used.
  final ProductData? editProduct;
  const AddProductScreen({
    super.key,
    this.onProductAdded,
    this.receiveMode = false,
    this.prefilledBarcode,
    this.initialStoreId,
    this.editProduct,
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
  final _barcodeCtrl = TextEditingController();
  final _unitsPerPackCtrl = TextEditingController();
  // Online listing boxes (#473), shown only with `products.manage_listing`.
  final _listing = ListingControllers();
  final _listingKeys = {for (final f in ListingField.values) f: GlobalKey()};
  // The brand last filled in from a manufacturer, so picking another
  // manufacturer replaces it but never a brand the user typed.
  String? _autoBrand;
  final _nameFocus = FocusNode();

  /// The boxes a validation error scrolls to.
  final _fieldKeys = {for (final f in FastAddField.values) f: GlobalKey()};

  /// The name of another product already using the typed barcode (#113). Non-
  /// null ⇒ a soft collision the form warns about; it never blocks the save.
  String? _barcodeCollisionName;

  // Nullable (#108): null = no unit, the default. Tapping the selected chip
  // again clears it.
  String? _unit;
  bool _trackEmpties = false; // turns on when Bottle is picked
  bool _allowFractionalSales = false;
  // Colour selector is deferred (master plan §16.5); products keep a default.
  final String _colorHex = '#3B82F6';
  DateTime? _expiryDate; // optional single expiry date (all business types)
  StoreData? _selectedStore;

  // Category / Brand / Supplier: an existing row, or a new name the save
  // creates (get-or-create, so nothing is written before the save is
  // confirmed).
  CategoryData? _selectedCategory;
  String? _newCategoryName;
  ManufacturerData? _selectedManufacturer;
  String? _newManufacturerName;
  SupplierData? _selectedSupplier;
  String? _newSupplierName;

  List<StoreData> _stores = [];
  List<SupplierData> _allSuppliers = [];
  List<CategoryData> _allCategories = [];
  List<ManufacturerData> _allManufacturers = [];

  List<ProductData> _allProducts = [];
  List<ProductData> _productSuggestions = [];
  bool _isSaving = false;

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

  /// Edit mode: the saved photo's local file, shown until a new one is picked.
  String? _existingImagePath;

  /// Edit mode: the category / brand / supplier are seeded once, on the first
  /// load, from the product's ids.
  bool _editSeeded = false;

  bool get _isEdit => widget.editProduct != null;

  /// The shop's own products that carry the barcode in the box (#465), the
  /// person's "Create a new product anyway", and the shared-list note.
  List<ProductData> _barcodeMatches = const [];
  bool _matchesDismissed = false;
  _BarcodeNote? _barcodeNote;

  /// Debounces catalogue lookups while the barcode box is being typed in.
  Timer? _catalogueDebounce;
  static const _catalogueDebounceDelay = Duration(milliseconds: 500);

  List<String> _dynamicUnits = kGenericUnits;

  /// The active industry's words + presets (#80). Read (not watched) in helpers
  /// called during build; the form is opened for one business so it is stable.
  Lexicon get _lexicon => ref.read(industryLexiconProvider);

  /// Whether the current role may see / set the buying price (master plan
  /// §16.5 / §16.7). Reads (not watches) so it is safe to call from `_save`.
  bool get _canEditBuying => Gates.editBuyingPrice.allowsNow(ref);

  @override
  void initState() {
    super.initState();
    // Default to "No unit" (owner request): the unit is a deliberate, up-front
    // choice. The trade's starter units are offered as chips, none selected.
    _dynamicUnits = _lexicon.starterUnits;
    // The preview and the profit rows follow what is typed.
    for (final c in [
      _nameCtrl,
      _retailPriceCtrl,
      _wholesalePriceCtrl,
      _buyingPriceCtrl,
      _initialStockCtrl,
      _lowStockCtrl,
      _unitsPerPackCtrl,
    ]) {
      c.addListener(_onFieldEdited);
    }
    // #118: seed the Barcode field from a POS scan of an unknown code so the
    // cashier catalogues the just-scanned product without retyping it.
    final prefillBarcode = _isEdit
        ? ''
        : (widget.prefilledBarcode?.trim() ?? '');
    if (prefillBarcode.isNotEmpty) _barcodeCtrl.text = prefillBarcode;
    if (_isEdit) _seedFromProduct(widget.editProduct!);
    _loadData();
    // #332: a POS scan of an unknown code looks it up in the shared catalogue.
    if (prefillBarcode.isNotEmpty) {
      _onBarcodeChanged(prefillBarcode, immediate: true);
    }
  }

  /// Edit mode: fills every box from [p]. Money boxes show a blank for a zero
  /// (an uncosted product), which is what "no cost yet" means.
  void _seedFromProduct(ProductData p) {
    String money(int kobo) => kobo == 0 ? '' : (kobo / 100).toStringAsFixed(2);
    _nameCtrl.text = p.name;
    _subtitleCtrl.text = p.subtitle ?? '';
    _barcodeCtrl.text = p.barcode ?? '';
    _retailPriceCtrl.text = money(p.retailerPriceKobo);
    _wholesalePriceCtrl.text = money(p.wholesalerPriceKobo);
    _buyingPriceCtrl.text = money(p.buyingPriceKobo);
    _emptyCrateValueCtrl.text = money(p.emptyCrateValueKobo);
    _lowStockCtrl.text = p.lowStockThreshold.toString();
    _unitsPerPackCtrl.text = p.unitsPerPack?.toString() ?? '';
    _listing.seed(ListingContent.of(p));
    _unit = p.unit;
    _trackEmpties = p.trackEmpties;
    _allowFractionalSales = p.allowFractionalSales;
    _expiryDate = p.expiryDate;
    _existingImagePath = p.imagePath;
  }

  void _onFieldEdited() {
    if (mounted) setState(() {});
  }

  /// Loads the pickers' lists. Re-run after Save & New, keeping the chosen
  /// store, category and manufacturer (re-read, so a row the save created or
  /// changed is current).
  Future<void> _loadData() async {
    final db = ref.read(databaseProvider);
    final whs = await db.storesDao.getActiveStores();
    final suppliers = await db.catalogDao.getAllSuppliers();
    final manufacturers = await db.inventoryDao.getAllManufacturers();
    final cats = await db.inventoryDao.getAllCategories();
    final productsList = await db.catalogDao.getActiveProducts();
    final uniqueUnits = await db.catalogDao.getUniqueProductUnits();
    // Edit mode: resolve a renderable path for the saved photo (downloads it
    // once if only the cloud URL is known), as the old Edit pop-up did.
    final edit = widget.editProduct;
    final cachedPhoto = edit == null
        ? null
        : await ref
              .read(productImageServiceProvider)
              .ensureCached(productId: edit.id, imageUrl: edit.imageUrl);

    if (!mounted) return;
    setState(() {
      _stores = whs;
      _allSuppliers = suppliers;
      _allManufacturers = manufacturers;
      _allCategories = cats;
      _allProducts = productsList;
      _dynamicUnits = _mergeUnits(uniqueUnits);

      if (cachedPhoto != null) _existingImagePath = cachedPhoto;
      if (edit != null && !_editSeeded) {
        _editSeeded = true;
        _selectedCategory = cats
            .where((c) => c.id == edit.categoryId)
            .firstOrNull;
        _selectedManufacturer = manufacturers
            .where((m) => m.id == edit.manufacturerId)
            .firstOrNull;
        _prefillBrand(_selectedManufacturer?.name);
        _selectedSupplier = suppliers
            .where((s) => s.id == edit.supplierId)
            .firstOrNull;
      }
      _selectedCategory = cats
          .where((c) => c.id == _selectedCategory?.id)
          .firstOrNull;
      _selectedManufacturer = manufacturers
          .where((m) => m.id == _selectedManufacturer?.id)
          .firstOrNull;
      // #320: start on the caller's store (the POS active store) when it is
      // one of the active stores; otherwise the first store. A store already
      // chosen is kept.
      if (whs.isNotEmpty) {
        final keep = _selectedStore?.id ?? widget.initialStoreId;
        _selectedStore = whs.firstWhere(
          (w) => w.id == keep,
          orElse: () => whs.first,
        );
      }
    });
  }

  /// The chips' units: the trade's starter units in their own order, then any
  /// other unit already in use (and a catalogue unit, #332), A–Z.
  List<String> _mergeUnits(List<String> inUse) {
    final starters = _lexicon.starterUnits;
    bool listed(String u, Iterable<String> list) =>
        list.any((s) => s.toLowerCase() == u.toLowerCase());
    // A catalogue unit (#332) filled in before this load: take the list's own
    // spelling when it is listed after all, else keep it.
    final catalogueUnit = _catalogueUnit;
    if (catalogueUnit != null) {
      final match = [...starters, ...inUse]
          .where((u) => u.toLowerCase() == catalogueUnit.toLowerCase())
          .firstOrNull;
      if (match != null) {
        if (_unit == catalogueUnit) _unit = match;
        _catalogueUnit = null;
      }
    }
    final extras = <String>[];
    for (final u in [...inUse, ?_catalogueUnit, ?widget.editProduct?.unit]) {
      if (!listed(u, starters) && !listed(u, extras)) extras.add(u);
    }
    extras.sort();
    return [...starters, ...extras];
  }

  @override
  void dispose() {
    for (final c in [
      _nameCtrl,
      _subtitleCtrl,
      _retailPriceCtrl,
      _wholesalePriceCtrl,
      _buyingPriceCtrl,
      _emptyCrateValueCtrl,
      _lowStockCtrl,
      _initialStockCtrl,
      _barcodeCtrl,
      _unitsPerPackCtrl,
    ]) {
      c.dispose();
    }
    _listing.dispose();
    _nameFocus.dispose();
    _catalogueDebounce?.cancel();
    super.dispose();
  }

  /// Checks the barcode in the box (#465): the shop's own products first (works
  /// offline), then, for a factory barcode, the shared list. Never blocks a
  /// save. Edit mode keeps only the soft "already used" warning (#113).
  Future<void> _onBarcodeChanged(String value, {bool immediate = false}) async {
    final code = value.trim();
    _catalogueDebounce?.cancel();
    if (code.isEmpty) {
      if (_barcodeCollisionName != null ||
          _barcodeMatches.isNotEmpty ||
          _barcodeNote != null) {
        setState(() {
          _barcodeCollisionName = null;
          _barcodeMatches = const [];
          _barcodeNote = null;
        });
      }
      return;
    }
    final matches = await ref
        .read(databaseProvider)
        .catalogDao
        .findProductsByBarcode(code);
    if (!mounted || _barcodeCtrl.text.trim() != code) return;
    if (_isEdit) {
      // The product's own barcode is not a collision.
      final other = matches
          .where((p) => p.id != widget.editProduct!.id)
          .firstOrNull;
      if (other?.name != _barcodeCollisionName) {
        setState(() => _barcodeCollisionName = other?.name);
      }
      return;
    }
    setState(() {
      _barcodeMatches = matches;
      _matchesDismissed = false;
      _barcodeNote = null;
    });
    if (matches.isNotEmpty) return;
    if (FactoryBarcode.tryParse(code) == null) {
      // A shop-made code never reaches the shared list.
      setState(() => _barcodeNote = _BarcodeNote.newBarcode);
    } else if (immediate) {
      await _lookUpCatalogue(code);
    } else {
      _catalogueDebounce = Timer(
        _catalogueDebounceDelay,
        () => _lookUpCatalogue(code),
      );
    }
  }

  /// The camera button (#465). A new product checks the code like a typed one,
  /// at once; edit mode only drops it into the box. The camera closes after
  /// the first read here (POS keeps scanning).
  Future<void> _scanBarcode() async {
    await ref
        .read(barcodeScannerProvider)
        .scanSession(
          context,
          onCode: (scannerContext, code) async {
            final trimmed = code.trim();
            if (trimmed.isEmpty) return;
            _barcodeCtrl.text = trimmed;
            Navigator.of(scannerContext).pop();
            if (!_isEdit) await _onBarcodeChanged(trimmed, immediate: true);
          },
        );
  }

  // ── Shared barcode catalogue (ADR 0029 §8, #332) ─────────────────────────

  /// Asks the shared catalogue about [code] and fills only the boxes that are
  /// still empty when the answer comes. The answer is dropped when the barcode
  /// box no longer holds [code]. Any failure leaves the form alone, silently;
  /// saving never waits on this.
  Future<void> _lookUpCatalogue(String code) async {
    if (FactoryBarcode.tryParse(code) == null) return;
    final service = ref.read(barcodeCatalogueServiceProvider);
    // Only download the photo while none is held (saves phone data);
    // _applyCatalogueSuggestion re-checks before using the bytes.
    final outcome = await service.lookupOutcome(
      code,
      includePhoto: _pendingImageBytes == null,
    );
    if (!mounted || _barcodeCtrl.text.trim() != code) return;
    switch (outcome) {
      case CatalogueFound(:final suggestion) when !suggestion.isEmpty:
        _applyCatalogueSuggestion(suggestion);
      case CatalogueUnreachable():
        setState(() => _barcodeNote = _BarcodeNote.offline);
      case CatalogueLookupFailed():
        break;
      case CatalogueFound() || CatalogueNothingShared():
        setState(() => _barcodeNote = _BarcodeNote.newBarcode);
    }
  }

  void _applyCatalogueSuggestion(BarcodeSuggestion suggestion) {
    final name = suggestion.name;
    final fillName = name != null && _nameCtrl.text.trim().isEmpty;
    final unit = suggestion.unit == null
        ? null
        : _matchListedUnit(suggestion.unit!);
    // A suggested plain Crate is not filled in: new products can't pick it
    // (#487).
    final fillUnit =
        unit != null && _unit == null && !isUnitHiddenForNewProducts(unit);
    final photo = _pendingImageBytes == null
        ? _processCataloguePhoto(suggestion.photoBytes)
        : null;
    if (!fillName && !fillUnit && photo == null) return;

    if (fillName) _nameCtrl.text = name;
    setState(() {
      if (fillName) _isNameFromCatalogue = true;
      if (fillUnit) {
        if (!_dynamicUnits.contains(unit)) {
          _catalogueUnit = unit;
          _dynamicUnits = [..._dynamicUnits, unit];
        }
        _unit = unit;
        // As picking a unit by hand: Bottle turns empties tracking on.
        _trackEmpties = unit.toLowerCase() == 'bottle';
        _isUnitFromCatalogue = true;
      }
      if (photo != null) {
        _pendingImageBytes = photo;
        _isPhotoFromCatalogue = true;
      }
    });
  }

  /// The chips' own spelling of [unit] when it is already listed (case
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

  /// A chip tap: picks [value], or clears the unit when it is already picked
  /// ("No unit" stays a valid choice, #108).
  void _onUnitTapped(String value) {
    final next = _unit == value ? null : value;
    setState(() {
      _unit = next;
      // Auto-enable tracking for bottle products, off otherwise (a null unit
      // is not a bottle).
      _trackEmpties = next?.toLowerCase() == 'bottle';
      _isUnitFromCatalogue = false;
    });
  }

  void _onNameChanged(String query) {
    final q = query.trim().toLowerCase();
    setState(() {
      _isNameFromCatalogue = false;
      // Edit mode has no name-match list.
      _productSuggestions = (q.isEmpty || _isEdit)
          ? []
          : _allProducts
                .where((p) => p.name.toLowerCase().contains(q))
                .take(20)
                .toList();
    });
  }

  /// A name match was tapped (#487 owner decision 8): open that product's
  /// Product Details over the form, which stays as it is underneath.
  Future<void> _openExistingProduct(ProductData product) async {
    FocusScope.of(context).unfocus();
    final storeId = ref.read(lockedStoreProvider).value;
    final rows = await ref
        .read(databaseProvider)
        .inventoryDao
        .getProductsWithStock(storeId: storeId);
    if (!mounted) return;
    final stock = rows.where((r) => r.product.id == product.id).firstOrNull;
    await openProductDetails(
      context,
      product,
      manufacturerName: _allManufacturers
          .where((m) => m.id == product.manufacturerId)
          .map((m) => m.name)
          .firstOrNull,
      totalStock: stock?.totalStock.toDouble() ?? 0,
      storeId: storeId,
    );
  }

  void _selectManufacturer(ManufacturerData manufacturer) {
    setState(() {
      _selectedManufacturer = manufacturer;
      _newManufacturerName = null;
      _prefillBrand(manufacturer.name);
      // Crate value is shared at the manufacturer level — autofill it from the
      // chosen manufacturer (§16.5). The user can still override the field.
      if (manufacturer.depositAmountKobo > 0) {
        _emptyCrateValueCtrl.text = (manufacturer.depositAmountKobo / 100)
            .toStringAsFixed(2);
      }
    });
  }

  Future<void> _pickCategory() async {
    final choice = await showProductPickerSheet(
      context,
      title: _lexicon.category,
      searchHint: 'Search or add a ${_lexicon.category.toLowerCase()}',
      options: [
        for (final c in _allCategories)
          ProductPickerOption(id: c.id, label: c.name),
      ],
      selectedId: _selectedCategory?.id,
      // Starter categories for a fresh shop (#80), offered while it has none.
      starterNames: _lexicon.starterCategories,
    );
    if (!mounted || choice == null) return;
    setState(() {
      switch (choice) {
        case ProductPickerPicked(:final id):
          _selectedCategory = _allCategories.firstWhere((c) => c.id == id);
          _newCategoryName = null;
        case ProductPickerNew(:final name):
          final match = _allCategories
              .where((c) => c.name.toLowerCase() == name.toLowerCase())
              .firstOrNull;
          _selectedCategory = match;
          _newCategoryName = match == null ? name : null;
        case ProductPickerAddFull():
          break;
      }
    });
  }

  Future<void> _pickManufacturer() async {
    final choice = await showProductPickerSheet(
      context,
      title: 'Brand / Manufacturer',
      searchHint: 'Search or add a brand',
      options: [
        for (final m in _allManufacturers)
          ProductPickerOption(id: m.id, label: m.name),
      ],
      selectedId: _selectedManufacturer?.id,
    );
    if (!mounted || choice == null) return;
    switch (choice) {
      case ProductPickerPicked(:final id):
        _selectManufacturer(_allManufacturers.firstWhere((m) => m.id == id));
      case ProductPickerNew(:final name):
        final match = _allManufacturers
            .where((m) => m.name.toLowerCase() == name.toLowerCase())
            .firstOrNull;
        if (match != null) {
          _selectManufacturer(match);
        } else {
          setState(() {
            _selectedManufacturer = null;
            _newManufacturerName = name;
            _prefillBrand(name);
          });
        }
      case ProductPickerAddFull():
        break;
    }
  }

  Future<void> _pickSupplier() async {
    final choice = await showProductPickerSheet(
      context,
      title: 'Supplier',
      searchHint: 'Search or add a supplier',
      options: [
        for (final s in _allSuppliers)
          ProductPickerOption(id: s.id, label: s.name),
      ],
      selectedId: _selectedSupplier?.id,
      addFullLabel: Gates.manageSuppliers.allows(ref)
          ? 'Add new supplier'
          : null,
    );
    if (!mounted || choice == null) return;
    switch (choice) {
      case ProductPickerPicked(:final id):
        setState(() {
          _selectedSupplier = _allSuppliers.firstWhere((s) => s.id == id);
          _newSupplierName = null;
        });
      case ProductPickerNew(:final name):
        final match = _allSuppliers
            .where((s) => s.name.toLowerCase() == name.toLowerCase())
            .firstOrNull;
        setState(() {
          _selectedSupplier = match;
          _newSupplierName = match == null ? name : null;
        });
      case ProductPickerAddFull():
        await _addSupplierViaForm();
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
      ManufacturersCompanion.insert(name: toNameCase(name), businessId: businessId),
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
      CategoriesCompanion.insert(name: toNameCase(name), businessId: businessId),
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
      SuppliersCompanion.insert(name: toNameCase(name), businessId: businessId),
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
  /// Distributor businesses. It also decides the unit words (#487): only such
  /// a shop reads a Bottle as "Bottle Crate" / "crates". Gate it on the business type — otherwise a
  /// non-crate business would silently create trackEmpties products (which
  /// leak the crate deposit UI into the cart/checkout and accrue crate-owed
  /// ledger rows).
  bool get _isCrateBusiness =>
      businessTracksCrates(ref.read(currentBusinessProvider));

  /// The Wholesale box shows unless the shop sells at one price (#493).
  bool get _hasWholesale =>
      !businessSellsOnePrice(ref.read(currentBusinessProvider));

  /// The Track Empty Crates card shows for a crate business AND unit Bottle.
  bool get _showsCrateCard =>
      _unit?.toLowerCase() == 'bottle' && _isCrateBusiness;

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

  /// Save Product ([andNew] false: save and close) or Save & New ([andNew]
  /// true: save, then clear the form for the next product). Validates and
  /// shapes through the pure Fast-Add form model (Seam 1, ADR 0006).
  /// Drink shops start the online brand from the manufacturer (#473). Only an
  /// empty box, or one still holding the last auto-filled name, is replaced.
  void _prefillBrand(String? manufacturerName) {
    if (!_isCrateBusiness || manufacturerName == null) return;
    final current = _listing.brand.text.trim();
    if (current.isNotEmpty && current != _autoBrand) return;
    final brand = manufacturerName.length > kBrandMaxLength
        ? manufacturerName.substring(0, kBrandMaxLength)
        : manufacturerName;
    _listing.brand.text = brand;
    _autoBrand = brand;
  }

  bool get _showsListing => Gates.manageListing.allows(ref);

  /// Saves the listing boxes after the product row exists (#473), only when
  /// they changed. The product itself is already saved, so a failure here is
  /// reported without undoing it.
  Future<void> _saveListing(String productId, ListingContent before) async {
    if (!Gates.manageListing.allowsNow(ref)) return;
    final content = _listing.parse().content;
    if (content == null || content == before) return;
    final result = await ProductListingService(
      ref.read(databaseProvider).catalogDao,
    ).saveContent(
      productId: productId,
      content: content,
      gateContext: ref.read(gateContextProvider),
    );
    if (result case Err(:final error) when mounted) {
      AppNotification.showError(context, error.message);
    }
  }

  Future<void> _save({required bool andNew}) async {
    if (_isSaving) return;
    final businessId = ref.read(authProvider).currentUser?.businessId;
    if (businessId == null) {
      AppNotification.showError(context, 'Account not loaded yet.');
      return;
    }
    // Defense-in-depth (hard rule #6): bail if the grant was revoked while the
    // form was open.
    if (_isEdit && !Gates.editProductPrice.allowsNow(ref)) {
      AppNotification.showError(
        context,
        'You no longer have permission to edit ${_lexicon.itemPluralLower}.',
      );
      return;
    }

    final result = resolveFastAdd(
      FastAddInput(
        name: _nameCtrl.text,
        sellingPrice: _retailPriceCtrl.text,
        // Edit mode has no opening quantity: any positive count passes.
        quantity: _isEdit ? '1' : _initialStockCtrl.text,
        buyingPrice: _buyingPriceCtrl.text,
        wholesalePrice: _wholesalePriceCtrl.text,
        lowStock: _lowStockCtrl.text,
        unit: _unit,
        trackEmpties: _trackEmpties,
        emptyCrateValue: _emptyCrateValueCtrl.text,
        hasManufacturer:
            _selectedManufacturer != null || _newManufacturerName != null,
        selectedStoreId: _selectedStore?.id,
        barcode: _barcodeCtrl.text,
        unitsPerPack: _unitsPerPackCtrl.text,
      ),
      FastAddContext(
        tracksCrates: _isCrateBusiness,
        canEditBuying: _canEditBuying,
        storeIds: _stores.map((s) => s.id).toList(),
        // Edit mode has no store either.
        routesToReceiveCart: widget.receiveMode || _isEdit,
        sellsOnePrice: !_hasWholesale,
        // Edit keeps the saved wholesale price in a one-price shop (#493).
        existingWholesalerPriceKobo: widget.editProduct?.wholesalerPriceKobo,
      ),
    );

    if (result is FastAddIntent && Gates.manageListing.allowsNow(ref)) {
      final listing = _listing.parse();
      if (!listing.isValid) {
        final box = _listingKeys[listing.field]!.currentContext;
        if (box != null) Scrollable.ensureVisible(box, alignment: 0.15);
        AppNotification.showError(context, listing.message!);
        return;
      }
    }

    switch (result) {
      case FastAddInvalid(:final field, :final message):
        _pointAt(field);
        AppNotification.showError(context, message);
      case FastAddIntent() when _isEdit:
        await _persistEdit(result);
      case FastAddIntent():
        final confirmed = await _confirmSaveProduct(result.name);
        if (!confirmed) return;
        await _persistNewProduct(result, andNew: andNew);
    }
  }

  /// Scrolls the box behind a validation error into view.
  void _pointAt(FastAddField field) {
    final target = _fieldKeys[field]!.currentContext;
    if (target == null) return;
    Scrollable.ensureVisible(
      target,
      duration: const Duration(milliseconds: 250),
      alignment: 0.15,
    );
  }

  /// Persist a resolved Fast-Add write intent through the existing catalog /
  /// inventory DAOs. Only the shaped scalar values come from the model; the
  /// get-or-create foreign keys and pass-through fields are attached here.
  Future<void> _persistNewProduct(
    FastAddIntent intent, {
    required bool andNew,
  }) async {
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
      // Get-or-create the new names picked in the sheets, only now that the
      // save is confirmed.
      final newManufacturer = _newManufacturerName;
      if (_selectedManufacturer == null && newManufacturer != null) {
        _selectedManufacturer = await _getOrCreateManufacturer(newManufacturer);
        _newManufacturerName = null;
      }
      final newSupplier = _newSupplierName;
      if (_selectedSupplier == null && newSupplier != null) {
        _selectedSupplier = await _getOrCreateSupplier(newSupplier);
        _newSupplierName = null;
      }
      final newCategory = _newCategoryName;
      if (_selectedCategory == null && newCategory != null) {
        _selectedCategory = await _getOrCreateCategory(newCategory);
        _newCategoryName = null;
      }

      final description = _subtitleCtrl.text.trim();
      final productId = await db.catalogDao.insertProductWithInitialStock(
        ProductsCompanion.insert(
          name: intent.name,
          businessId: businessId,
          subtitle: drift.Value(description.isEmpty ? null : description),
          retailerPriceKobo: drift.Value(intent.retailerPriceKobo),
          wholesalerPriceKobo: drift.Value(intent.wholesalerPriceKobo),
          buyingPriceKobo: drift.Value(intent.buyingPriceKobo),
          unit: drift.Value(intent.unit),
          trackEmpties: drift.Value(intent.trackEmpties),
          emptyCrateValueKobo: intent.emptyCrateValueKobo == null
              ? const drift.Value.absent()
              : drift.Value(intent.emptyCrateValueKobo!),
          // Left out when blank, so the push payload only carries the key
          // once a count is set (#487 PR 1).
          unitsPerPack: intent.unitsPerPack == null
              ? const drift.Value.absent()
              : drift.Value(intent.unitsPerPack),
          allowFractionalSales: drift.Value(_allowFractionalSales),
          colorHex: drift.Value(_colorHex),
          size: const drift.Value(null),
          expiryDate: drift.Value(_expiryDate),
          barcode: drift.Value(intent.barcode),
          lowStockThreshold: drift.Value(intent.lowStockThreshold),
          manufacturerId: drift.Value(_selectedManufacturer?.id),
          supplierId: drift.Value(_selectedSupplier?.id),
          categoryId: drift.Value(_selectedCategory?.id),
        ),
        // Receive Stock routes the opening quantity to its delivery list
        // below instead of into a store.
        initialStock: widget.receiveMode ? null : intent.initialStock,
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

      await _saveListing(productId, const ListingContent());

      final newProduct = (await db.catalogDao.findById(productId))!;
      final userName = auth.currentUser?.name ?? 'Unknown';
      if (widget.receiveMode) {
        ref
            .read(receiveCartProvider.notifier)
            .addOrIncrement(newProduct, amount: intent.initialStock);
        if (mounted) {
          AppNotification.showSuccess(
            context,
            '${intent.name} added to catalog and ${intent.initialStock} '
            'units routed to Receive Cart',
          );
        }
        await ref
            .read(activityLogProvider)
            .logAction(
              'new_product',
              '$userName added product: ${intent.name} and routed '
                  '${intent.initialStock} units to receive cart',
              productId: productId,
            );
      } else {
        if (mounted) {
          AppNotification.showSuccess(
            context,
            '${intent.name} added to catalog',
          );
        }
        await ref
            .read(activityLogProvider)
            .logAction(
              'new_product',
              '$userName added product: ${intent.name}',
              productId: productId,
            );
      }

      if (andNew) {
        widget.onProductAdded?.call(newProduct);
        if (mounted) await _resetForNextProduct();
      } else {
        if (mounted) Navigator.pop(context);
        widget.onProductAdded?.call(newProduct);
      }
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

  /// Edit mode save: EXACTLY what the old Edit pop-up's save did (moved from
  /// `UpdateProductSheet._save`, #487 PR 4) — details, photo, manufacturer
  /// crate value, activity log, the cost 0 -> real follow-up and the notice.
  Future<void> _persistEdit(FastAddIntent intent) async {
    final old = widget.editProduct!;
    final db = ref.read(databaseProvider);
    final auth = ref.read(authProvider);
    final name = intent.name;
    final canEditBuying = _canEditBuying;
    final oldBuyingKobo = old.buyingPriceKobo;
    // Cost stays untouched for roles without the permission.
    final buyingKobo = canEditBuying ? intent.buyingPriceKobo : oldBuyingKobo;

    setState(() => _isSaving = true);
    try {
      final newManufacturer = _newManufacturerName;
      if (_selectedManufacturer == null && newManufacturer != null) {
        _selectedManufacturer = await _getOrCreateManufacturer(newManufacturer);
        _newManufacturerName = null;
      }
      final newSupplier = _newSupplierName;
      if (_selectedSupplier == null && newSupplier != null) {
        _selectedSupplier = await _getOrCreateSupplier(newSupplier);
        _newSupplierName = null;
      }
      final newCategory = _newCategoryName;
      if (_selectedCategory == null && newCategory != null) {
        _selectedCategory = await _getOrCreateCategory(newCategory);
        _newCategoryName = null;
      }

      // Optional product photo (#78): upload a freshly picked image, keyed by
      // the product id (image_url + the ProductImageService cache).
      String? newImageUrl;
      if (_pendingImageBytes != null) {
        final businessId = auth.currentUser?.businessId;
        if (businessId != null) {
          final imgSvc = ref.read(productImageServiceProvider);
          final res = await imgSvc.save(
            businessId: businessId,
            productId: old.id,
            bytes: _pendingImageBytes!,
          );
          _existingImagePath = await imgSvc.localPathFor(old.id);
          if (res case Ok(:final value)) newImageUrl = value;
        }
      }

      final description = _subtitleCtrl.text.trim();
      // 1. Update product (core + cosmetic fields in one enqueue).
      await db.catalogDao.updateProductDetails(
        old.id,
        name: name,
        manufacturerId: _selectedManufacturer?.id,
        buyingPriceKobo: buyingKobo,
        retailerPriceKobo: intent.retailerPriceKobo,
        wholesalerPriceKobo: intent.wholesalerPriceKobo,
        emptyCrateValueKobo: intent.emptyCrateValueKobo,
        categoryId: _selectedCategory?.id,
        unit: intent.unit,
        trackEmpties: intent.trackEmpties,
        allowFractionalSales: _allowFractionalSales,
        lowStockThreshold: intent.lowStockThreshold,
        subtitle: description.isEmpty ? null : description,
        colorHex: old.colorHex ?? _colorHex,
        supplierId: _selectedSupplier?.id,
        size: old.size,
        expiryDate: _expiryDate,
        barcode: intent.barcode,
        unitsPerPack: intent.unitsPerPack,
      );

      // Patch the cloud image URL so the photo converges cross-device. Null
      // when offline: the reconnect flush sets it.
      if (newImageUrl != null) {
        await db.catalogDao.setProductImageUrl(old.id, newImageUrl);
      }

      // 2. The crate value is per manufacturer (§16.5).
      if (_selectedManufacturer != null && intent.emptyCrateValueKobo != null) {
        await db.catalogDao.updateManufacturerEmptyCrateValue(
          _selectedManufacturer!.id,
          intent.emptyCrateValueKobo!,
        );
      }

      // 3. A cleared box must reach the cloud: outbox payloads drop nulls, so
      //    push the full row with an explicit null for each cleared column.
      await db.catalogDao.enqueueProductEdit(
        old.id,
        clearedUnitsPerPack:
            old.unitsPerPack != null && intent.unitsPerPack == null,
        clearedSubtitle: (old.subtitle ?? '').isNotEmpty && description.isEmpty,
        clearedBarcode: old.barcode != null && intent.barcode == null,
        clearedExpiry: old.expiryDate != null && _expiryDate == null,
        clearedSupplier: old.supplierId != null && _selectedSupplier == null,
        clearedManufacturer:
            old.manufacturerId != null && _selectedManufacturer == null,
        clearedCategory: old.categoryId != null && _selectedCategory == null,
      );

      // 3b. Online listing (#473): its own gated write, only when changed.
      await _saveListing(old.id, ListingContent.of(old));

      // 4. Log the update.
      await ref
          .read(activityLogProvider)
          .logAction(
            'update_product',
            '${auth.currentUser?.name ?? 'Unknown'} updated product: $name',
            productId: old.id,
          );

      // 5. Cost just became real (0 -> a positive value): cost the still-
      //    uncosted batches and offer once to backfill past uncosted sales
      //    (ADR 0005 "Cost backfill", #41).
      if (canEditBuying && oldBuyingKobo == 0 && buyingKobo > 0) {
        final offer = await db.costBatchesDao.onCostBecameReal(
          old.id,
          buyingKobo,
        );
        if (mounted && !offer.isEmpty) {
          await _promptCostBackfill(db, offer, name, auth.currentUser?.id);
        }
      }

      if (mounted) {
        AppNotification.showSuccess(context, '$name updated successfully');
        // Business-scoped read (never a raw select of a tenant table).
        final updated = await db.catalogDao.findById(old.id);
        if (mounted) Navigator.pop(context, updated);
      }
    } catch (e, st) {
      CrashReporter.record(e, st, context: 'inventory.update_product');
      debugPrint('AddProductScreen._persistEdit error: $e');
      if (mounted) {
        AppNotification.showError(
          context,
          'Could not update ${_lexicon.itemLower}: $e',
        );
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  /// One-time prompt (ADR 0005 "Cost backfill", #41) offered when a product's
  /// cost first becomes real and it has past uncosted sales. On accept,
  /// restates those lines' snapshots to the new cost (gaps only, each in its
  /// own period); [applyCostBackfill] writes the single Activity Log row.
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

  /// Save & New: clears the form for the next product, keeping the store,
  /// category and manufacturer, and puts the cursor in Name.
  Future<void> _resetForNextProduct() async {
    _catalogueDebounce?.cancel();
    for (final c in [
      _nameCtrl,
      _subtitleCtrl,
      _retailPriceCtrl,
      _wholesalePriceCtrl,
      _buyingPriceCtrl,
      _emptyCrateValueCtrl,
      _barcodeCtrl,
      _unitsPerPackCtrl,
    ]) {
      c.clear();
    }
    _listing.seed(const ListingContent());
    _autoBrand = null;
    _lowStockCtrl.text = '5';
    _initialStockCtrl.text = '0';
    setState(() {
      _unit = null;
      _trackEmpties = false;
      _allowFractionalSales = false;
      _expiryDate = null;
      _selectedSupplier = null;
      _newSupplierName = null;
      _pendingImageBytes = null;
      _isNameFromCatalogue = false;
      _isUnitFromCatalogue = false;
      _isPhotoFromCatalogue = false;
      _barcodeCollisionName = null;
      _barcodeMatches = const [];
      _matchesDismissed = false;
      _barcodeNote = null;
      _productSuggestions = [];
    });
    await _loadData();
    if (!mounted) return;
    // The kept manufacturer's (possibly just saved) crate value.
    final manufacturer = _selectedManufacturer;
    if (manufacturer != null) _selectManufacturer(manufacturer);
    _nameFocus.requestFocus();
    final nameBox = _fieldKeys[FastAddField.name]!.currentContext;
    if (nameBox != null && nameBox.mounted) Scrollable.ensureVisible(nameBox);
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
    if (!Gates.manageSuppliers.allowsNow(ref)) return;
    final created = await SupplierFormSheet.show(context);
    if (created == null || !mounted) return;
    final suppliers = await ref
        .read(databaseProvider)
        .catalogDao
        .getAllSuppliers();
    if (!mounted) return;
    setState(() {
      _allSuppliers = suppliers;
      _selectedSupplier = created;
      _newSupplierName = null;
    });
  }

  // ── Derived values for the build ────────────────────────────────────────

  int _kobo(String raw) => (parseCurrency(raw.trim()) * 100).round();

  int get _openingQuantity => int.tryParse(_initialStockCtrl.text.trim()) ?? 0;

  /// The − / + buttons: reads the box at the tap, never below 0.
  void _stepQuantity(int by) {
    final next = _openingQuantity + by;
    _initialStockCtrl.text = '${next < 0 ? 0 : next}';
  }

  /// The profit rows (#487): only when a cost is filled and the person may
  /// see it. Wholesale mirrors retail when blank, as the model saves it.
  List<ProductProfitLine> _profitLines({
    required bool canSeeCost,
    String suffix = '',
  }) {
    final costRaw = _buyingPriceCtrl.text.trim();
    if (!canSeeCost || costRaw.isEmpty) return const [];
    final cost = _kobo(costRaw);
    final retail = _kobo(_retailPriceCtrl.text);
    final wholesaleRaw = _wholesalePriceCtrl.text.trim();
    final wholesale = wholesaleRaw.isEmpty ? retail : _kobo(wholesaleRaw);
    return [
      for (final (title, price) in [
        ('Retail profit', retail),
        if (_hasWholesale) ('Wholesale profit', wholesale),
      ])
        if (productProfit(priceKobo: price, costKobo: cost) case final p?)
          ProductProfitLine(
            title: '$title$suffix',
            share: '${p.percent}% of selling price',
            amount: formatCurrency(p.amountKobo / 100),
            isLoss: p.isLoss,
          ),
    ];
  }

  // ── Build ───────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final canEditBuying = Gates.editBuyingPrice.allows(ref);
    // Watched so the crate rule follows the business (and the provider stays
    // loaded for [_isCrateBusiness] at save time).
    ref.watch(currentBusinessProvider);

    return Container(
      decoration: AppDecorations.pageBackground(context),
      // The body width decides the layout. Measured here, around the Scaffold,
      // because it also decides whether there is a footer bar.
      child: LayoutBuilder(
        builder: (context, constraints) {
          final insets = MediaQuery.paddingOf(context);
          final layout = _FormLayout.of(
            constraints.maxWidth - insets.left - insets.right,
          );
          return Scaffold(
            backgroundColor: Colors.transparent,
            // Keep the body above the keyboard. This screen is pushed from two
            // places onto DIFFERENT navigators: the Inventory FAB pushes it on
            // the tab's nested navigator (under MainLayout, whose Scaffold
            // already resizes for the keyboard), but the post-onboarding
            // auto-show (main_layout.dart) pushes it on the ROOT navigator,
            // ABOVE MainLayout — there nothing resizes for the keyboard, so the
            // bottom boxes end up hidden behind it. `true` is correct in BOTH
            // cases: nested, MainLayout's Scaffold has already zeroed the
            // bottom viewInsets for descendants, so this is a no-op; on the
            // root navigator it lifts the body above the keyboard. The footer
            // padding stays nav-only (deviceBottomPadding) — when the keyboard
            // is up the system nav bar is occluded, so the extra is harmless.
            resizeToAvoidBottomInset: true,
            appBar: InventoryTopBar(
              icon: AppIcons.addSquare,
              title: _isEdit ? 'Edit ${_lexicon.item}' : 'Add ${_lexicon.item}',
              subtitle: _isEdit
                  ? "Update this item's details"
                  : 'Add a new item to your inventory',
              height: inventoryTopBarHeight(context),
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
              child: switch (layout) {
                _FormLayout.phone => _phoneBody(canEditBuying),
                _FormLayout.twoColumn => _columnsBody(canEditBuying),
                _FormLayout.wide => Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(child: _columnsBody(canEditBuying)),
                    _previewPanel(canEditBuying),
                  ],
                ),
              },
            ),
            bottomNavigationBar: layout == _FormLayout.wide ? null : _footer(),
          );
        },
      ),
    );
  }

  /// Under 600: one column of cards, capped at 720 and centred (#392).
  Widget _phoneBody(bool canEditBuying) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final gutter = inventoryGutter(context, constraints.maxWidth);
        return SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(
            gutter,
            context.getRSize(16),
            gutter,
            context.getRSize(16),
          ),
          child: _cardColumn([
            ..._leftCards(),
            ..._rightCards(canEditBuying: canEditBuying, sideBySide: false),
          ]),
        );
      },
    );
  }

  /// 600 and over: Product Details + Product Unit on the left; Pricing,
  /// Stock, Track Empty Crates and More details on the right.
  Widget _columnsBody(bool canEditBuying) {
    final gap = context.getRSize(16);
    return SingleChildScrollView(
      padding: EdgeInsets.all(gap),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: _cardColumn(_leftCards())),
          SizedBox(width: gap),
          Expanded(
            child: _cardColumn(
              _rightCards(canEditBuying: canEditBuying, sideBySide: true),
            ),
          ),
        ],
      ),
    );
  }

  Widget _cardColumn(List<Widget> cards) {
    final gap = context.getRSize(16);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < cards.length; i++) ...[
          if (i > 0) SizedBox(height: gap),
          cards[i],
        ],
      ],
    );
  }

  List<Widget> _leftCards() => [_detailsCard(), _unitCard()];

  List<Widget> _rightCards({
    required bool canEditBuying,
    required bool sideBySide,
  }) => [
    _pricingCard(canEditBuying),
    if (_showsListing) _listingCard(),
    _stockCard(allowSideBySide: sideBySide),
    if (_showsCrateCard) _cratesCard(),
    _moreDetailsCard(),
  ];

  Widget _footer() {
    if (_isEdit) {
      return InventoryFormFooter(
        child: AppButton(
          key: AddProductKeys.save,
          text: 'Save Changes',
          icon: AppIcons.check,
          isLoading: _isSaving,
          onPressed: () => _save(andNew: false),
        ),
      );
    }
    return InventoryFormFooter(
      child: Row(
        children: [
          Expanded(
            flex: 2,
            child: AppButton(
              key: AddProductKeys.saveAndNew,
              text: 'Save & New',
              variant: AppButtonVariant.secondary,
              onPressed: _isSaving ? null : () => _save(andNew: true),
            ),
          ),
          SizedBox(width: context.getRSize(12)),
          Expanded(
            flex: 3,
            child: AppButton(
              key: AddProductKeys.save,
              text: 'Save ${_lexicon.item}',
              icon: AppIcons.check,
              isLoading: _isSaving,
              onPressed: () => _save(andNew: false),
            ),
          ),
        ],
      ),
    );
  }

  // ── Cards ───────────────────────────────────────────────────────────────

  Widget _detailsCard() {
    final f =
        Theme.of(context).extension<AppFixedColors>() ?? AppFixedColors.light;
    final gap = context.getRSize(16);
    final categoryName = _selectedCategory?.name ?? _newCategoryName;
    final manufacturerName =
        _selectedManufacturer?.name ?? _newManufacturerName;
    return ProductFormSection(
      icon: AppIcons.tag,
      title: '${_lexicon.item} Details',
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ProductPhotoBox(
              pendingBytes: _pendingImageBytes,
              existingPath: _existingImagePath,
              onPick: _pickPhoto,
              onRemove: () => setState(() {
                _pendingImageBytes = null;
                _isPhotoFromCatalogue = false;
              }),
            ),
            SizedBox(width: gap),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  KeyedSubtree(
                    key: _fieldKeys[FastAddField.name],
                    child: AppInput(
                      key: AddProductKeys.name,
                      controller: _nameCtrl,
                      focusNode: _nameFocus,
                      labelText: '${_lexicon.item} Name',
                      hintText: _lexicon.itemNameHint,
                      textCapitalization: TextCapitalization.words,
                      onChanged: _onNameChanged,
                    ),
                  ),
                  if (_isNameFromCatalogue) const CatalogueFilledNote(),
                ],
              ),
            ),
          ],
        ),
        if (_isPhotoFromCatalogue) const CatalogueFilledNote(),
        if (_productSuggestions.isNotEmpty) _nameMatches(),
        SizedBox(height: gap),
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: AppInput(
                key: AddProductKeys.barcode,
                controller: _barcodeCtrl,
                labelText: 'Barcode',
                hintText: 'Scan or type the barcode',
                prefixIcon: AppIcon(
                  AppIcons.barcode,
                  size: context.getRSize(20),
                  color: Theme.of(context).textTheme.bodySmall?.color,
                ),
                onChanged: _onBarcodeChanged,
              ),
            ),
            SizedBox(width: gap),
            ProductScanButton(onTap: _scanBarcode),
          ],
        ),
        if (_barcodeCollisionName != null)
          InventoryFieldHelper(
            'Already used by "$_barcodeCollisionName". You can still save.',
            icon: AppIcons.warning,
            color: f.danger,
          ),
        if (_barcodeMatches.isNotEmpty && !_matchesDismissed && !_isEdit)
          ProductBarcodeMatchesCard(
            names: [for (final p in _barcodeMatches) p.name],
            onOpen: (i) => _openExistingProduct(_barcodeMatches[i]),
            onCreateAnyway: () => setState(() => _matchesDismissed = true),
          ),
        if (_barcodeNote == _BarcodeNote.offline)
          const InventoryFieldHelper(
            "Couldn't check the shared list — no internet",
            icon: AppIcons.warning,
          ),
        if (_barcodeNote == _BarcodeNote.newBarcode)
          const InventoryFieldHelper(
            'New barcode — fill in the details',
            icon: AppIcons.infoCircle,
          ),
        SizedBox(height: gap),
        ProductFieldLabel(_lexicon.category),
        ProductPickerField(
          key: AddProductKeys.category,
          value: categoryName,
          placeholder: 'Choose a ${_lexicon.category.toLowerCase()}',
          onTap: _pickCategory,
          onClear: () => setState(() {
            _selectedCategory = null;
            _newCategoryName = null;
          }),
        ),
        SizedBox(height: gap),
        const ProductFieldLabel('Brand / Manufacturer'),
        ProductPickerField(
          key: AddProductKeys.manufacturer,
          value: manufacturerName,
          placeholder: 'Choose a brand',
          onTap: _pickManufacturer,
          onClear: () => setState(() {
            _selectedManufacturer = null;
            _newManufacturerName = null;
          }),
        ),
      ],
    );
  }

  /// Products already named like the typed name (#487 owner decision 8).
  /// Tapping one opens its Product Details; an archived one says so.
  Widget _nameMatches() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const InventoryFieldHelper(
          'Already in your inventory. Tap one to open it.',
        ),
        InventorySuggestionList(
          children: [
            for (final p in _productSuggestions)
              InventorySuggestionTile(
                label: productDisplayName(
                  p.name,
                  p.size,
                  unit: p.unit,
                  crates: _isCrateBusiness,
                ),
                icon: AppIcons.inventory,
                trailing: p.isAvailable
                    ? null
                    : const TagPill(
                        label: 'Archived',
                        tone: TagPillTone.neutral,
                        dense: true,
                      ),
                onTap: () => _openExistingProduct(p),
              ),
          ],
        ),
      ],
    );
  }

  Widget _unitCard() {
    final packLabel = unitsPerPackLabel(_unit, crates: _isCrateBusiness);
    return ProductFormSection(
      icon: AppIcons.inventory,
      title: '${_lexicon.item} Unit',
      subtitle: 'How do you sell and count this ${_lexicon.itemLower}?',
      children: [
        Wrap(
          spacing: context.getRSize(8),
          runSpacing: context.getRSize(8),
          children: [
            // Plain "Crate" is not offered to a new product (#487); a stored
            // Bottle reads "Bottle Crate" but saves Bottle.
            for (final u in unitChoices(
              _dynamicUnits,
              keep: [_unit, widget.editProduct?.unit],
            ))
              ProductUnitChip(
                key: AddProductKeys.unitChip(u),
                label: formUnitLabel(u, crates: _isCrateBusiness)!,
                selected: _unit == u,
                onTap: () => _onUnitTapped(u),
              ),
          ],
        ),
        if (_isUnitFromCatalogue) const CatalogueFilledNote(),
        if (packLabel != null) ...[
          SizedBox(height: context.getRSize(16)),
          AppInput(
            key: AddProductKeys.unitsPerPack,
            controller: _unitsPerPackCtrl,
            labelText: packLabel,
            hintText: 'e.g. 12',
            suffixText: 'pieces',
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          ),
        ],
      ],
    );
  }

  /// Online listing (#473), after Pricing — mirrors the Product Details card.
  Widget _listingCard() {
    return ProductFormSection(
      key: AddProductKeys.listingCard,
      icon: AppIcons.storefront,
      title: 'Online listing',
      subtitle: 'What shoppers see in your online store.',
      children: [
        ListingContentFields(controllers: _listing, fieldKeys: _listingKeys),
        SizedBox(height: context.getRSize(8)),
        Text(
          'Leave the order boxes blank to let shoppers order any amount.',
          style: context.regularStyle(13).copyWith(
            color: Theme.of(context).textTheme.bodySmall?.color,
          ),
        ),
      ],
    );
  }

  Widget _pricingCard(bool canEditBuying) {
    final gap = context.getRSize(16);
    final lines = _profitLines(canSeeCost: canEditBuying);
    return ProductFormSection(
      icon: AppIcons.cash,
      title: 'Pricing',
      subtitle: pricingSubtitle(_unit, crates: _isCrateBusiness),
      children: [
        if (canEditBuying) ...[
          KeyedSubtree(
            key: _fieldKeys[FastAddField.buyingPrice],
            child: _moneyInput(
              key: AddProductKeys.cost,
              controller: _buyingPriceCtrl,
              label: 'Cost Price',
            ),
          ),
          // Blank is accepted: the product is saved Uncosted (ADR 0006).
          if (_buyingPriceCtrl.text.trim().isEmpty)
            const InventoryFieldHelper(
              'Add what you paid so profit shows correctly. You can add it '
              'later.',
            ),
          SizedBox(height: gap),
        ],
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: KeyedSubtree(
                key: _fieldKeys[FastAddField.sellingPrice],
                child: _moneyInput(
                  key: AddProductKeys.retail,
                  controller: _retailPriceCtrl,
                  label: 'Retail Price',
                ),
              ),
            ),
            if (_hasWholesale) ...[
              SizedBox(width: context.getRSize(12)),
              Expanded(
                child: _moneyInput(
                  key: AddProductKeys.wholesale,
                  controller: _wholesalePriceCtrl,
                  label: 'Wholesale Price',
                  hint: 'Same as retail',
                ),
              ),
            ],
          ],
        ),
        if (lines.isNotEmpty) ...[
          SizedBox(height: gap),
          ProductProfitBox(lines: lines),
        ],
      ],
    );
  }

  Widget _moneyInput({
    required Key key,
    required TextEditingController controller,
    required String label,
    String hint = '0',
    String? suffix,
  }) {
    return AppInput(
      key: key,
      controller: controller,
      labelText: label,
      hintText: hint,
      prefixText: '$activeCurrencySymbol ',
      suffixText: suffix,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      inputFormatters: [CurrencyInputFormatter()],
    );
  }

  /// [allowSideBySide] (two columns and wider): Opening Quantity and
  /// Low-Stock Alert share a row when the card is wide enough to hold the
  /// stepper's number (MEASURED).
  Widget _stockCard({required bool allowSideBySide}) {
    final gap = context.getRSize(16);
    final showsStore = !widget.receiveMode && !_isEdit && _stores.length > 1;
    return KeyedSubtree(
      // A store error with no store box to show points at the card.
      key: showsStore ? null : _fieldKeys[FastAddField.store],
      child: ProductFormSection(
        icon: AppIcons.warehouse,
        title: 'Stock',
        children: [
          if (showsStore) ...[
            KeyedSubtree(
              key: _fieldKeys[FastAddField.store],
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const ProductFieldLabel('Store'),
                  AppDropdown<StoreData?>(
                    key: AddProductKeys.store,
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
                ],
              ),
            ),
            SizedBox(height: gap),
          ],
          LayoutBuilder(
            builder: (context, constraints) => _stockFields(
              sideBySide: allowSideBySide && constraints.maxWidth >= 360,
            ),
          ),
        ],
      ),
    );
  }

  /// Opening Quantity and Low-Stock Alert. [sideBySide]: one row, each with
  /// its count word under it; else stacked with the count word in the box.
  Widget _stockFields({required bool sideBySide}) {
    final gap = context.getRSize(16);
    final quantity = _openingQuantity;
    final lowStock = int.tryParse(_lowStockCtrl.text.trim()) ?? 0;

    final quantityBox = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const ProductFieldLabel('Opening Quantity'),
        KeyedSubtree(
          key: _fieldKeys[FastAddField.quantity],
          child: ProductQuantityStepper(
            field: AppInput(
              key: AddProductKeys.quantity,
              controller: _initialStockCtrl,
              hintText: '0',
              textAlign: TextAlign.center,
              suffixText: sideBySide
                  ? null
                  : formCountNoun(_unit, quantity, crates: _isCrateBusiness),
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            ),
            onDecrement: () => _stepQuantity(-1),
            onIncrement: () => _stepQuantity(1),
          ),
        ),
        if (sideBySide)
          InventoryFieldHelper(
            'Counted in ${formCountNoun(_unit, 2, crates: _isCrateBusiness)}',
          ),
        if (widget.receiveMode)
          const InventoryFieldHelper(
            'This amount goes onto the delivery list.',
          ),
      ],
    );
    final lowStockBox = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AppInput(
          key: AddProductKeys.lowStock,
          controller: _lowStockCtrl,
          labelText: 'Low-Stock Alert',
          hintText: '5',
          prefixIcon: AppIcon(
            AppIcons.notification,
            size: context.getRSize(20),
            color: Theme.of(context).textTheme.bodySmall?.color,
          ),
          suffixText: sideBySide
              ? null
              : formCountNoun(_unit, lowStock, crates: _isCrateBusiness),
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        ),
        InventoryFieldHelper(
          sideBySide
              ? 'Notify me at this level'
              : 'You will get a notice when stock falls to this level.',
        ),
      ],
    );

    // Edit mode: stock changes go through Adjust Stock, so only the alert.
    if (_isEdit) return lowStockBox;
    if (sideBySide) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(flex: 3, child: quantityBox),
          SizedBox(width: gap),
          Expanded(flex: 2, child: lowStockBox),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        quantityBox,
        SizedBox(height: gap),
        lowStockBox,
      ],
    );
  }

  /// Track Empty Crates (crate business + Bottle only, rule #13). The crate
  /// value is shared at the manufacturer level: picking a manufacturer fills
  /// it, and the save writes it back manufacturer-wide (§16.5).
  Widget _cratesCard() {
    final manufacturerName =
        _selectedManufacturer?.name ?? _newManufacturerName;
    return ProductFormSection(
      icon: AppIcons.recycle,
      title: 'Track Empty Crates',
      subtitle: 'Count returnable crates and charge a deposit.',
      trailing: Switch(
        key: AddProductKeys.trackEmpties,
        value: _trackEmpties,
        onChanged: (v) => setState(() => _trackEmpties = v),
      ),
      children: [
        if (_trackEmpties) ...[
          _moneyInput(
            key: AddProductKeys.crateDeposit,
            controller: _emptyCrateValueCtrl,
            label: 'Crate Deposit',
            suffix: 'per crate',
          ),
          InventoryFieldHelper(
            manufacturerName == null
                ? 'Crates are counted under the brand / manufacturer you '
                      'choose above.'
                : 'Crates are counted under the manufacturer: '
                      '$manufacturerName.',
            icon: AppIcons.infoCircle,
          ),
        ],
      ],
    );
  }

  Widget _moreDetailsCard() {
    final gap = context.getRSize(16);
    final expiry = _expiryDate;
    final expiryLabel = expiry == null
        ? null
        : '${expiry.day.toString().padLeft(2, '0')}/'
              '${expiry.month.toString().padLeft(2, '0')}/${expiry.year}';
    return ProductFormSection(
      icon: AppIcons.description,
      title: 'More details',
      children: [
        AppInput(
          key: AddProductKeys.description,
          controller: _subtitleCtrl,
          labelText: 'Description',
          hintText: _lexicon.itemDescriptionHint,
        ),
        // Receive Stock's delivery carries its own supplier (as before).
        if (!widget.receiveMode) ...[
          SizedBox(height: gap),
          const ProductFieldLabel('Supplier'),
          ProductPickerField(
            key: AddProductKeys.supplier,
            value: _selectedSupplier?.name ?? _newSupplierName,
            placeholder: 'Choose a supplier',
            onTap: _pickSupplier,
            onClear: () => setState(() {
              _selectedSupplier = null;
              _newSupplierName = null;
            }),
          ),
        ],
        SizedBox(height: gap),
        const ProductFieldLabel('Expiry Date'),
        InventoryDateField(
          label: expiryLabel,
          placeholder: 'No expiry date',
          onTap: _pickExpiryDate,
          onClear: () => setState(() => _expiryDate = null),
        ),
        const InventoryFieldHelper(
          'Optional — used to flag stock nearing expiry',
        ),
        SizedBox(height: context.getRSize(8)),
        InventoryCheckRow(
          value: _allowFractionalSales,
          onChanged: (v) => setState(() => _allowFractionalSales = v ?? false),
          title: 'Allow fractional sales',
          subtitle:
              'Enables ±0.5 quantity steps when selling this '
              '${_lexicon.itemLower}',
        ),
      ],
    );
  }

  /// 1000 and over: the Preview side panel with the save buttons.
  Widget _previewPanel(bool canEditBuying) {
    final name = toNameCase(_nameCtrl.text);
    final pack = int.tryParse(_unitsPerPackCtrl.text.trim());
    final noun = priceUnitNoun(_unit, crates: _isCrateBusiness);
    final lines = _profitLines(canSeeCost: canEditBuying, suffix: ' per $noun');
    final retail = _retailPriceCtrl.text.trim();
    return ProductPreviewPanel(
      key: AddProductKeys.preview,
      preview: ProductPreviewCard(
        name: name.isEmpty ? '${_lexicon.item} name' : name,
        stockLabel: _isEdit ? null : '$_openingQuantity in stock',
        detailLine: previewDetailLine(
          unit: _unit,
          crates: _isCrateBusiness,
          unitsPerPack: (pack != null && pack > 0) ? pack : null,
          category: _selectedCategory?.name ?? _newCategoryName,
        ),
        priceLabel: formatCurrency(retail.isEmpty ? 0 : _kobo(retail) / 100),
        categoryName: _selectedCategory?.name ?? _newCategoryName,
        photoBytes: _pendingImageBytes,
      ),
      profit: lines.isEmpty ? null : ProductProfitBox(lines: lines),
      actions: [
        AppButton(
          key: AddProductKeys.save,
          text: _isEdit ? 'Save Changes' : 'Save ${_lexicon.item}',
          icon: AppIcons.check,
          isLoading: _isSaving,
          onPressed: () => _save(andNew: false),
        ),
        if (!_isEdit) ...[
          SizedBox(height: context.getRSize(12)),
          AppButton(
            key: AddProductKeys.saveAndNew,
            text: 'Save & Add Another',
            variant: AppButtonVariant.secondary,
            onPressed: _isSaving ? null : () => _save(andNew: true),
          ),
        ],
        SizedBox(height: context.getRSize(8)),
        AppButton(
          text: 'Cancel',
          variant: AppButtonVariant.ghost,
          onPressed: () => Navigator.of(context).maybePop(),
        ),
      ],
    );
  }
}
