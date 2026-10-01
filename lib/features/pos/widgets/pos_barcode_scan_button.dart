import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/permissions/gate_registry.dart';
import 'package:reebaplus_pos/core/permissions/guarded.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/utils/notifications.dart';
import 'package:reebaplus_pos/core/widgets/app_fab.dart';
import 'package:reebaplus_pos/features/customers/data/models/customer.dart';
import 'package:reebaplus_pos/features/inventory/screens/add_product_screen.dart';
import 'package:reebaplus_pos/features/pos/providers/pos_providers.dart';
import 'package:reebaplus_pos/features/pos/services/barcode_scan_resolver.dart';
import 'package:reebaplus_pos/features/pos/widgets/edit_item_modal.dart';
import 'package:reebaplus_pos/features/pos/widgets/scan_which_one_sheet.dart';
import 'package:reebaplus_pos/shared/widgets/slide_route.dart';

/// The always-visible POS scan control (#118). Rendered as the bottom-right
/// [AppFAB] that replaces the removed cart FAB (ADR 0017); it is never gated on
/// a non-empty cart — tapping it opens a scan session (via
/// [barcodeScannerProvider]) that stays open until the cashier closes it
/// (#319).
///
/// What a scanned code means is decided by [resolveBarcodeScan] (#317); this
/// widget only renders the outcome, over the scanner page (#319) so closing any
/// of it lands back on the live camera:
///  - found and sellable → the tap-and-hold "Add to Cart" sheet, starting one
///    above what's already in the cart, at the active store's stock cap and
///    the active price tier;
///  - found but not sellable (out of stock here, all already in the cart,
///    switched off) → a message and no sheet;
///  - more than one product carries the code (#318) → the "Which one?" list;
///    the picked product then goes through the two cases above;
///  - an unknown barcode (#320) depends on [Gates.addProduct]: without it the
///    cashier is told to ask a manager; with it Add Product opens with the code
///    pre-filled, and a product saved there goes through the found cases above
///    (its stock is read fresh from the active store, not the grid's stream).
class PosBarcodeScanButton extends ConsumerStatefulWidget {
  const PosBarcodeScanButton({
    super.key,
    required this.tier,
    required this.loadedProducts,
    this.storeName,
    this.storeId,
    this.onUnknownBarcode,
  });

  /// The active price tier (§12.2). A scanned line is priced exactly as a tap.
  final PriceTier tier;

  /// The store-scoped, stock-aware catalogue the grid is currently showing. A
  /// scanned product is resolved against this so the cart's stock cap is the
  /// same one a tap would apply (the normal add path).
  final List<ProductDataWithStock> loadedProducts;

  /// The active store's name, for "out of stock at ‹store›" (#317). Null while
  /// it is still loading or when no single store is active.
  final String? storeName;

  /// The active store's id (the POS controller's `lockedStoreId ??
  /// fallbackStoreId`). A product saved from Add Product after an unknown scan
  /// (#320) has its stock read here, directly, because [loadedProducts] may not
  /// have caught up with the new row yet. Null ⇒ treated as no stock.
  final String? storeId;

  /// Test seam: when a permitted user scans a barcode that matches no product
  /// this is invoked with the code instead of navigating, and returns what
  /// Add Product would have handed back — the saved product, or null when the
  /// user backed out (#320). Production leaves it null and opens
  /// [AddProductScreen] with the barcode pre-filled.
  final Future<ProductData?> Function(BuildContext context, String barcode)?
  onUnknownBarcode;

  @override
  ConsumerState<PosBarcodeScanButton> createState() =>
      _PosBarcodeScanButtonState();
}

// Stateful (#319) so a long scan session reads the LATEST tier, catalogue and
// store name through `widget` on every code, not the ones captured at the tap.
class _PosBarcodeScanButtonState extends ConsumerState<PosBarcodeScanButton> {
  @override
  Widget build(BuildContext context) {
    // Rendered as a FAB in the POS scaffold's FAB slot — the spot the old cart
    // FAB used before #118 removed it (owner request). Still always visible: a
    // scan is never gated on the cart. reserveBottomInset:false because the POS
    // is a bottom-nav tab root whose visible bar already lifts the FAB clear of
    // the system nav (see AppFAB).
    return AppFAB(
      icon: FontAwesomeIcons.barcode.data,
      tooltip: 'Scan barcode',
      onPressed: _scan,
      reserveBottomInset: false,
    );
  }

  /// Opens a scan session (#319); it ends when the cashier closes the scanner.
  Future<void> _scan() async {
    await ref
        .read(barcodeScannerProvider)
        .scanSession(context, onCode: _onCode);
  }

  /// One scanned code, shown over the scanner page ([context] is the scanner's,
  /// #319). The scanner keeps the camera frozen until this completes.
  Future<void> _onCode(BuildContext context, String code) async {
    final trimmed = code.trim();
    if (trimmed.isEmpty || !mounted) return;

    // All matches, not just the first (#318): a soft-unique collision shows
    // the "Which one?" list.
    final matches = await ref
        .read(databaseProvider)
        .catalogDao
        .findProductsByBarcode(trimmed);
    if (!context.mounted || !mounted) return;

    final outcome = resolveBarcodeScan(
      code: trimmed,
      matches: matches,
      storeProducts: widget.loadedProducts,
      cartQtyOf: _cartQtyOf,
      tier: widget.tier,
    );

    switch (outcome) {
      case ScanMatchOutcome():
        await _renderMatch(context, outcome);
      case ScanChooseAmong(:final choices):
        await _chooseAmong(context, choices);
      case ScanUnknown(:final code):
        await _onUnknown(context, code);
    }
  }

  /// An unknown barcode (#320). Without [Gates.addProduct] (e.g. a Cashier)
  /// it is only a message — no navigation, scanning carries on. With it, Add
  /// Product opens pre-filled over the scanner; a product saved there goes
  /// straight on to the quantity sheet (or its message). Backing out adds
  /// nothing. (#321 puts the "Add as new / Link to existing" choice here.)
  Future<void> _onUnknown(BuildContext context, String code) async {
    // allowsNow: a one-shot read inside a callback, not a build.
    if (!Gates.addProduct.allowsNow(ref)) {
      AppNotification.showError(
        context,
        'No product has this barcode. Ask a manager to add it.',
      );
      return;
    }

    ProductData? saved;
    final onUnknown = widget.onUnknownBarcode;
    if (onUnknown != null) {
      saved = await onUnknown(context, code);
    } else {
      // Awaited (#319) so the camera stays frozen while Add Product is open
      // over the scanner. Add Product pops itself before calling
      // onProductAdded, so `saved` is set by the time the push completes.
      await Navigator.of(context).push(
        slideDownRoute(
          AddProductScreen(
            prefilledBarcode: code,
            onProductAdded: (product) => saved = product,
          ),
        ),
      );
    }
    final product = saved;
    if (product == null || !context.mounted || !mounted) return;
    await _renderSaved(context, product);
  }

  /// Renders a product just saved from Add Product (#320) like a found scan.
  /// Its stock is read from the active store directly (a business-scoped DAO
  /// read) rather than from [PosBarcodeScanButton.loadedProducts], which may
  /// not include a row saved a moment ago.
  Future<void> _renderSaved(BuildContext context, ProductData product) async {
    final storeId = widget.storeId;
    final stock = storeId == null
        ? 0
        : await ref
              .read(databaseProvider)
              .stockLedgerDao
              .getCurrentStock(product.id, storeId);
    if (!context.mounted || !mounted) return;

    final outcome = resolveProduct(
      product: product,
      storeProducts: [ProductDataWithStock(product: product, totalStock: stock)],
      cartQty: _cartQtyOf(product.id),
      tier: widget.tier,
    );
    if (outcome is ScanOutOfStockHere) {
      final store = widget.storeName ?? 'this store';
      AppNotification.showError(
        context,
        "Saved. ${product.name} has no stock at $store yet, so it can't be "
        'added to the cart.',
      );
      return;
    }
    await _renderMatch(context, outcome);
  }

  /// Shows the "Which one?" list (#318). A pick continues as a single match:
  /// the single-product checks are re-run for that product with its own cart
  /// qty and store stock. Dismissing adds nothing.
  Future<void> _chooseAmong(
    BuildContext context,
    List<ScanChoice> choices,
  ) async {
    final picked = await ScanWhichOneSheet.show(context, choices: choices);
    if (picked == null || !context.mounted || !mounted) return;
    final outcome = resolveProduct(
      product: picked,
      storeProducts: widget.loadedProducts,
      cartQty: _cartQtyOf(picked.id),
      tier: widget.tier,
    );
    await _renderMatch(context, outcome);
  }

  /// Renders what one found product means: the quantity sheet when it can be
  /// sold, otherwise its message (#317).
  Future<void> _renderMatch(
    BuildContext context,
    ScanMatchOutcome outcome,
  ) async {
    switch (outcome) {
      case ScanAddSheet():
        await _openAddSheet(context, outcome);
      case ScanOutOfStockHere(:final product):
        final store = widget.storeName ?? 'this store';
        AppNotification.showError(
          context,
          '${product.name} is out of stock at $store',
        );
      case ScanAllInCart(:final product, :final stock):
        AppNotification.showError(
          context,
          'All $stock ${product.name} in stock are already in the cart',
        );
      case ScanSwitchedOff(:final product):
        AppNotification.showError(
          context,
          '${product.name} is switched off for sale',
        );
    }
  }

  /// Opens the tap-and-hold "Add to Cart" sheet for a sellable scan. The sheet
  /// sets the line to the chosen total itself; Cancel / dismiss add nothing.
  Future<void> _openAddSheet(
    BuildContext context,
    ScanAddSheet outcome,
  ) async {
    final product = outcome.product;
    final result = await EditItemModal.showForProduct(
      context,
      product: product,
      maxStock: outcome.stock,
      tier: outcome.tier,
      shouldStartOnNextUnit: true,
    );
    if (result == null || !context.mounted || !mounted) return;
    // false = the sheet's add was clamped or rejected by stock: say so, as the
    // tap-and-hold path does, rather than reporting a success.
    if (!result) {
      AppNotification.showError(
        context,
        'Stock limit reached for ${product.name}',
      );
      return;
    }
    // Report what the cart now holds for the line (the sheet's field is the
    // total).
    final qty = _cartQtyOf(product.id);
    if (qty <= 0) return;
    AppNotification.showSuccess(
      context,
      '${product.name} ×${_trimNum(qty)} added',
    );
  }

  /// Total quantity of [productId] across the cart's lines.
  double _cartQtyOf(String productId) => ref
      .read(cartProvider)
      .value
      .where((i) => i['id'] == productId)
      .fold<double>(0, (s, i) => s + (i['qty'] as num).toDouble());

  /// Formats a quantity without a trailing `.0` (3.0 → "3", 1.5 → "1.5").
  static String _trimNum(double n) =>
      n == n.toInt() ? n.toInt().toString() : n.toString();
}
