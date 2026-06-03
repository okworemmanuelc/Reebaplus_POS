import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/utils/currency_input_formatter.dart';
import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/core/utils/notifications.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';

import 'package:reebaplus_pos/shared/widgets/app_dropdown.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/shared/widgets/auto_lock_wrapper.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:reebaplus_pos/shared/widgets/app_input.dart';

class UpdateProductSheet extends ConsumerStatefulWidget {
  final ProductData product;
  final int totalStock;
  final String? currentStoreId;
  final VoidCallback? onProductUpdated;

  const UpdateProductSheet({
    super.key,
    required this.product,
    required this.totalStock,
    this.currentStoreId,
    this.onProductUpdated,
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

  late String _unit;
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
  List<SupplierData> _supplierSuggestions = [];
  List<ManufacturerData> _allManufacturers = [];
  List<ManufacturerData> _manufacturerSuggestions = [];

  bool _isSaving = false;
  String? _errorMessage;
  String? _imagePath;

  static const _units = ['Crate', 'Bottle', 'Pack', 'Carton', 'Keg', 'Can'];
  List<String> _dynamicUnits = _units;

  /// Whether the current role may see / edit the buying price (§16.5 / §16.7).
  /// Reads (not watches) so it is safe to call from `_save`.
  bool get _canEditBuying => ref
      .read(currentUserPermissionsProvider)
      .contains('products.edit_buying_price');

  /// Empty-crate value in kobo, or null when not tracking empties / left blank.
  int? get _emptyCrateValueKobo {
    if (!(_trackEmpties && _unit.toLowerCase() == 'bottle')) return null;
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
    _qtyToAddCtrl = TextEditingController(text: '0');
    _supplierCtrl = TextEditingController();
    // Manufacturer name is populated in _loadData() via FK lookup.
    _manufacturerCtrl = TextEditingController();
    _imagePath = p.imagePath;

    _unit = p.unit;
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

    if (!mounted) return;
    setState(() {
      _stores = whs;
      _allSuppliers = suppliers;
      _allManufacturers = manufacturers;
      _allCategories = cats;
      _dynamicUnits = <String>{..._units, _unit, ...uniqueUnits}.toList()
        ..sort();

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
    final picker = ImagePicker();
    try {
      final XFile? image = await picker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 800,
        maxHeight: 800,
        imageQuality: 85,
      );

      if (image == null) return;

      final appDir = await getApplicationDocumentsDirectory();
      final fileName =
          'product_${widget.product.id}_${DateTime.now().millisecondsSinceEpoch}${p.extension(image.path)}';
      final savedImage = await File(
        image.path,
      ).copy('${appDir.path}/$fileName');

      setState(() {
        _imagePath = savedImage.path;
      });
    } catch (e) {
      setState(() => _errorMessage = 'Failed to pick image: $e');
    }
  }

  Future<void> _save() async {
    final db = ref.read(databaseProvider);
    final auth = ref.read(authProvider);
    setState(() => _errorMessage = null);

    final canEditBuying = _canEditBuying;
    final name = _nameCtrl.text.trim();
    String? missingField;
    if (name.isEmpty) {
      missingField = 'Product Name';
    } else if (_selectedCategory == null) {
      missingField = 'Category';
    } else if (_retailPriceCtrl.text.trim().isEmpty) {
      missingField = 'Retailer Price';
    } else if (_wholesalePriceCtrl.text.trim().isEmpty) {
      missingField = 'Wholesaler Price';
    } else if (canEditBuying && _buyingPriceCtrl.text.trim().isEmpty) {
      missingField = 'Buying Price';
    } else if (_selectedStore == null) {
      missingField = 'Store';
    }

    if (missingField != null) {
      setState(() => _errorMessage = '$missingField is required.');
      return;
    }

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

      // Auto-handle supplier if typed but not explicitly selected (optional)
      if (_selectedSupplier == null && _supplierCtrl.text.trim().isNotEmpty) {
        _selectedSupplier = await _getOrCreateSupplier(
          _supplierCtrl.text.trim(),
        );
      }

      final retailKobo = (retailPrice * 100).round();
      final wholesaleKobo = (wholesalePrice * 100).round();
      final buyingKobo = (buyingPrice * 100).round();
      final lowStock = int.tryParse(_lowStockCtrl.text) ?? 5;

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
        trackEmpties: _trackEmpties,
        allowFractionalSales: _allowFractionalSales,
        imagePath: _imagePath,
        lowStockThreshold: lowStock,
        subtitle: _subtitleCtrl.text.trim().isEmpty
            ? null
            : _subtitleCtrl.text.trim(),
        colorHex: _colorHex,
        supplierId: _selectedSupplier?.id,
        size: _size,
        expiryDate: _expiryDate,
      );

      // 2. Persist the crate value at the manufacturer level so every product
      //    of this manufacturer shares one value (§16.5).
      if (_selectedManufacturer != null && _emptyCrateValueKobo != null) {
        await db.catalogDao.updateManufacturerEmptyCrateValue(
          _selectedManufacturer!.id,
          _emptyCrateValueKobo!,
        );
      }

      // 3. Add stock if quantity entered
      if (qtyToAdd > 0) {
        await db.inventoryDao.adjustStock(
          widget.product.id,
          _selectedStore!.id,
          qtyToAdd,
          'Restock by ${auth.currentUser?.name ?? 'Unknown'}',
          auth.currentUser?.id,
        );
      }

      // 4. Log the update
      await ref
          .read(activityLogProvider)
          .logAction(
            'update_product',
            '${auth.currentUser?.name ?? 'Unknown'} updated product: $name'
                '${qtyToAdd > 0 ? ', added $qtyToAdd units' : ''}',
            productId: widget.product.id,
          );

      if (mounted) {
        AppNotification.showSuccess(context, '$name updated successfully');
        Navigator.pop(context);
        widget.onProductUpdated?.call();
      }
    } catch (e) {
      debugPrint('UpdateProductSheet._save error: $e');
      setState(() => _errorMessage = 'Could not update product: $e');
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bg = Theme.of(context).colorScheme.surface;
    final card = Theme.of(context).cardColor;
    final textColor = Theme.of(context).colorScheme.onSurface;
    final subtext =
        Theme.of(context).textTheme.bodySmall?.color ??
        Theme.of(context).iconTheme.color!;
    final border = Theme.of(context).dividerColor;

    return Padding(
      padding: EdgeInsets.only(bottom: context.deviceBottomInset),
      child: Container(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.92,
        ),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Drag handle
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
              child: Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: border,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
            ),
            // Header
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
              child: Row(
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: Theme.of(
                        context,
                      ).colorScheme.primary.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(
                      FontAwesomeIcons.penToSquare,
                      color: Theme.of(context).colorScheme.primary,
                      size: 18,
                    ),
                  ),
                  const SizedBox(width: 14),
                  GestureDetector(
                    onTap: _pickImage,
                    child: Stack(
                      children: [
                        Container(
                          width: 44,
                          height: 44,
                          decoration: BoxDecoration(
                            color: Theme.of(
                              context,
                            ).colorScheme.primary.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: Theme.of(
                                context,
                              ).colorScheme.primary.withValues(alpha: 0.2),
                            ),
                          ),
                          child: _imagePath != null
                              ? ClipRRect(
                                  borderRadius: BorderRadius.circular(11),
                                  child: Image.file(
                                    File(_imagePath!),
                                    fit: BoxFit.cover,
                                  ),
                                )
                              : Icon(
                                  FontAwesomeIcons.image,
                                  color: Theme.of(context).colorScheme.primary,
                                  size: 18,
                                ),
                        ),
                        Positioned(
                          right: -2,
                          bottom: -2,
                          child: Container(
                            padding: const EdgeInsets.all(2),
                            decoration: BoxDecoration(
                              color: Theme.of(context).colorScheme.primary,
                              shape: BoxShape.circle,
                              border: Border.all(color: bg, width: 1.5),
                            ),
                            child: const Icon(
                              Icons.edit,
                              color: Colors.white,
                              size: 8,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Update Product',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w800,
                            color: textColor,
                          ),
                        ),
                        Text(
                          'Edit details and add new stock below',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 13, color: subtext),
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
                padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
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

                    // ── PRODUCT NAME ─────────────────────────────────────────
                    AppInput(
                      controller: _nameCtrl,
                      labelText: 'Product Name *',
                      hintText: 'e.g. Heineken 60cl',
                    ),
                    const SizedBox(height: 14),

                    // ── CATEGORY ─────────────────────────────────────────────
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

                    // ── SUBTITLE ─────────────────────────────────────────────
                    AppInput(
                      controller: _subtitleCtrl,
                      labelText: 'Description / Subtitle',
                      hintText: 'e.g. Premium Lager',
                    ),
                    const SizedBox(height: 14),

                    // ── PRICES ───────────────────────────────────────────────
                    Row(
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
                        const SizedBox(width: 12),
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
                    if (_canEditBuying) ...[
                      const SizedBox(height: 14),
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
                    const SizedBox(height: 14),

                    // ── LOW STOCK ALERT ──────────────────────────────────────
                    AppInput(
                      controller: _lowStockCtrl,
                      labelText: 'Low Stock Alert *',
                      hintText: '5',
                      keyboardType: TextInputType.number,
                    ),
                    const SizedBox(height: 16),

                    // ── PRODUCT UNIT ─────────────────────────────────────────
                    _sectionLabel('PRODUCT UNIT *', subtext),
                    const SizedBox(height: 8),
                    AppDropdown<String>(
                      value: _unit,
                      items: _dynamicUnits
                          .map(
                            (u) => DropdownMenuItem(value: u, child: Text(u)),
                          )
                          .toList(),
                      onChanged: (v) {
                        if (v != null) {
                          setState(() {
                            _unit = v;
                            if (v.toLowerCase() == 'bottle') {
                              _trackEmpties = true;
                            } else {
                              _trackEmpties = false;
                            }
                          });
                        }
                      },
                    ),
                    const SizedBox(height: 8),

                    // ── ALLOW FRACTIONAL SALES ───────────────────────────────
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
                    const SizedBox(height: 8),

                    // ── EXPIRY DATE (optional, all business types) ───────────
                    _sectionLabel('EXPIRY DATE', subtext),
                    const SizedBox(height: 4),
                    Text(
                      'Optional — used to flag stock nearing expiry',
                      style: TextStyle(fontSize: 11, color: subtext),
                    ),
                    const SizedBox(height: 8),
                    _expiryField(
                      card: card,
                      border: border,
                      subtext: subtext,
                      textColor: textColor,
                    ),
                    const SizedBox(height: 16),

                    // ── SIZE ─────────────────────────────────────────────────
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
                        DropdownMenuItem(
                          value: 'medium',
                          child: Text('Medium'),
                        ),
                        DropdownMenuItem(value: 'small', child: Text('Small')),
                      ],
                      onChanged: (v) => setState(() => _size = v),
                    ),
                    const SizedBox(height: 16),

                    // ── MANUFACTURER ─────────────────────────────────────────
                    AppInput(
                      controller: _manufacturerCtrl,
                      labelText: 'MANUFACTURER *',
                      hintText: 'Search or type manufacturer name…',
                      prefixIcon: Icon(Icons.search, size: 18, color: subtext),
                      onChanged: _onManufacturerChanged,
                      suffixIcon: _selectedManufacturer != null
                          ? GestureDetector(
                              onTap: _clearManufacturer,
                              child: Icon(
                                Icons.close,
                                size: 16,
                                color: subtext,
                              ),
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
                              label:
                                  'Create "${_manufacturerCtrl.text.trim()}"',
                              icon: Icons.add_circle_outline,
                              textColor: Theme.of(context).colorScheme.primary,
                              card: card,
                              border: border,
                              onTap: () async {
                                final m = await _getOrCreateManufacturer(
                                  _manufacturerCtrl.text.trim(),
                                );
                                if (m != null) _selectManufacturer(m);
                              },
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
                          labelText: 'Empty Crate Value ($activeCurrencySymbol)',
                          hintText: '0.00',
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          inputFormatters: [CurrencyInputFormatter()],
                        ),
                      ],
                      const SizedBox(height: 16),
                    ],

                    // ── SUPPLIER ─────────────────────────────────────────────
                    AppInput(
                      controller: _supplierCtrl,
                      labelText: 'SUPPLIER (optional)',
                      hintText: 'Search supplier name…',
                      prefixIcon: Icon(Icons.search, size: 18, color: subtext),
                      onChanged: _onSupplierChanged,
                      suffixIcon: _selectedSupplier != null
                          ? GestureDetector(
                              onTap: _clearSupplier,
                              child: Icon(
                                Icons.close,
                                size: 16,
                                color: subtext,
                              ),
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
                              onTap: () async {
                                final s = await _getOrCreateSupplier(
                                  _supplierCtrl.text.trim(),
                                );
                                if (s != null) _selectSupplier(s);
                              },
                            ),
                        ],
                        card: card,
                        border: border,
                      ),
                    const SizedBox(height: 16),

                    const Divider(),
                    const SizedBox(height: 16),

                    // ── STOCK SECTION ────────────────────────────────────────
                    Text(
                      'Stock Management',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: textColor,
                        fontSize: 15,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Current total stock: ${widget.totalStock}',
                      style: TextStyle(fontSize: 13, color: subtext),
                    ),
                    const SizedBox(height: 14),
                    AppInput(
                      controller: _qtyToAddCtrl,
                      labelText: 'QUANTITY TO ADD',
                      hintText: '0',
                      keyboardType: TextInputType.number,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'This amount will be added to the existing stock',
                      style: TextStyle(fontSize: 11, color: subtext),
                    ),
                    const SizedBox(height: 14),

                    // ── STORE ────────────────────────────────────────────
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
                                child: Text(
                                  w.name,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            )
                            .toList(),
                        onChanged: (v) =>
                            setState(() => _selectedStore = v),
                      ),
                    const SizedBox(height: 24),
                  ],
                ),
              ),
            ),
            // Save button
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
              child: AppButton(
                text: 'Update Product',
                variant: AppButtonVariant.primary,
                isLoading: _isSaving,
                onPressed: _save,
              ),
            ),
          ],
        ),
      ),
    );
  }

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
