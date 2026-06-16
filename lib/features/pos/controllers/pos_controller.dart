import 'package:flutter/material.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/shared/services/cart_service.dart';
import 'package:reebaplus_pos/shared/services/navigation_service.dart';
import 'package:reebaplus_pos/features/customers/data/models/customer.dart';
import 'dart:async';

class PosController extends ChangeNotifier {
  final AppDatabase _database;
  final NavigationService _navigationService;
  final CartService _cartService;

  List<ProductDataWithStock> allProducts = [];
  List<CategoryData> categories = [];
  List<ManufacturerData> manufacturers = [];
  String? selectedCategoryId;
  String selectedManufacturerId = 'All';
  PriceTier selectedGroup = PriceTier.retailer;
  String searchQuery = '';
  bool isSearching = false;
  String? currentStoreName;

  /// The concrete store POS sells from when the global active store is "All
  /// Stores" (`lockedStoreId == null`, an all-stores viewer). Set by the POS
  /// screen from the user's first selectable store (§12.1). POS always needs one
  /// real store for the grid + checkout even when the view filter is "All".
  String? fallbackStoreId;

  bool isLoading = true;
  bool _disposed = false;
  StreamSubscription? _productsSub;
  StreamSubscription<List<CategoryData>>? _categoriesSub;
  StreamSubscription<List<ManufacturerData>>? _manufacturersSub;
  Timer? _debounce;

  PosController({
    required AppDatabase database,
    required NavigationService navigationService,
    required CartService cartService,
  }) : _database = database,
       _navigationService = navigationService,
       _cartService = cartService {
    _init();
  }

  void _init() {
    _loadCategories();
    _loadManufacturers();
    _subscribeToProducts();
    _cartService.activeCustomer.addListener(_onCustomerSelected);
    _navigationService.lockedStoreId.addListener(_subscribeToProducts);
  }

  @override
  void dispose() {
    _disposed = true;
    _productsSub?.cancel();
    _categoriesSub?.cancel();
    _manufacturersSub?.cancel();
    _debounce?.cancel();
    _cartService.activeCustomer.removeListener(_onCustomerSelected);
    _navigationService.lockedStoreId.removeListener(_subscribeToProducts);
    super.dispose();
  }

  void _loadCategories() {
    // Stream-based: a remote add/rename of a category propagates to the
    // POS chip row without needing a screen rebuild.
    _categoriesSub = _database.inventoryDao.watchAllCategories().listen((list) {
      if (_disposed) return;
      categories = list;
      notifyListeners();
    });
  }

  void _loadManufacturers() {
    _manufacturersSub = _database.inventoryDao.watchAllManufacturers().listen((
      list,
    ) {
      if (_disposed) return;
      manufacturers = list;
      notifyListeners();
    });
  }

  void _subscribeToProducts() {
    _productsSub?.cancel();

    // The lockedStoreId listener fires during lockApp/logout. If the
    // ordering ever regresses (or another teardown path nulls businessId
    // before clearing the store), bail rather than throw. Mirrors the
    // currentUser==null guard in auto_lock_wrapper.dart.
    if (_database.currentBusinessId == null) {
      return;
    }

    final storeId = _navigationService.lockedStoreId.value ?? fallbackStoreId;

    if (storeId != null) {
      // Fetch store name
      _database.storesDao.getStore(storeId).then((w) {
        if (_disposed) return;
        currentStoreName = w?.name;
        notifyListeners();
      });

      _productsSub = _database.inventoryDao
          .watchProductDatasWithStockByStore(storeId)
          .listen((data) {
            if (_disposed) return;
            allProducts = data;
            isLoading = false;
            notifyListeners();
          });
    } else {
      currentStoreName = null;
      _productsSub = _database.inventoryDao
          .watchProductsByCategory(selectedCategoryId)
          .listen((data) {
            if (_disposed) return;
            allProducts = data;
            isLoading = false;
            notifyListeners();
          });
    }
  }

  void _onCustomerSelected() {
    final customer = _cartService.activeCustomer.value;
    if (customer != null) {
      selectedGroup = customer.priceTier;
      notifyListeners();
    }
  }

  /// Sets the "All Stores" fallback selling store (§12.1) and re-subscribes the
  /// product grid if it changed and is currently the effective store.
  void setFallbackStore(String? id) {
    if (fallbackStoreId == id) return;
    fallbackStoreId = id;
    if (_navigationService.lockedStoreId.value == null) _subscribeToProducts();
  }

  void selectCategory(String? categoryId) {
    selectedCategoryId = categoryId;
    _subscribeToProducts();
    notifyListeners();
  }

  void selectManufacturer(String manufacturerId) {
    selectedManufacturerId = manufacturerId;
    notifyListeners();
  }

  void selectGroup(PriceTier group) {
    selectedGroup = group;
    notifyListeners();
  }

  void toggleSearch() {
    isSearching = !isSearching;
    if (!isSearching) {
      searchQuery = '';
    }
    notifyListeners();
  }

  void updateSearch(String query) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () {
      searchQuery = query;
      notifyListeners();
    });
  }

  List<ProductDataWithStock> get filteredProducts {
    var items = allProducts
        .where((item) => item.product.isAvailable && !item.product.isDeleted)
        .where((item) {
          if (selectedManufacturerId == 'All') return true;
          return item.product.manufacturerId?.toString() ==
              selectedManufacturerId;
        })
        .where((item) {
          if (selectedCategoryId == null) return true;
          return item.product.categoryId == selectedCategoryId;
        })
        .toList();

    if (searchQuery.isNotEmpty) {
      final q = searchQuery.toLowerCase();
      items = items
          .where(
            (item) =>
                item.product.name.toLowerCase().contains(q) ||
                (item.product.subtitle?.toLowerCase().contains(q) ?? false),
          )
          .toList();
    }
    return items;
  }
}
