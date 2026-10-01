import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/utils/notifications.dart';
import 'package:reebaplus_pos/core/widgets/app_fab.dart';
import 'package:reebaplus_pos/features/customers/data/models/customer.dart';
import 'package:reebaplus_pos/features/inventory/screens/add_product_screen.dart';
import 'package:reebaplus_pos/features/pos/providers/pos_providers.dart';
import 'package:reebaplus_pos/features/pos/services/barcode_scan_resolver.dart';
import 'package:reebaplus_pos/features/pos/widgets/edit_item_modal.dart';
import 'package:reebaplus_pos/shared/widgets/slide_route.dart';

/// The always-visible POS scan control (#118). Rendered as the bottom-right
/// [AppFAB] that replaces the removed cart FAB (ADR 0017); it is never gated on
/// a non-empty cart — tapping it opens the camera one-shot (via
/// [barcodeScannerProvider]).
///
/// What a scanned code means is decided by [resolveBarcodeScan] (#317); this
/// widget only renders the outcome:
///  - found and sellable → the tap-and-hold "Add to Cart" sheet, starting one
///    above what's already in the cart, at the active store's stock cap and
///    the active price tier;
///  - found but not sellable (out of stock here, all already in the cart,
///    switched off) → a message and no sheet;
///  - an unknown barcode toasts and opens Add Product with the code pre-filled
///    so the cashier can catalogue it on the spot.
class PosBarcodeScanButton extends ConsumerWidget {
  const PosBarcodeScanButton({
    super.key,
    required this.tier,
    required this.loadedProducts,
    this.storeName,
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

  /// Test seam: when a scanned barcode matches no product this is invoked with
  /// the code (instead of navigating). Production leaves it null and opens
  /// [AddProductScreen] with the barcode pre-filled.
  final void Function(BuildContext context, String barcode)? onUnknownBarcode;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Rendered as a FAB in the POS scaffold's FAB slot — the spot the old cart
    // FAB used before #118 removed it (owner request). Still always visible: a
    // one-shot scan is never gated on the cart. reserveBottomInset:false because
    // the POS is a bottom-nav tab root whose visible bar already lifts the FAB
    // clear of the system nav (see AppFAB).
    return AppFAB(
      icon: FontAwesomeIcons.barcode.data,
      tooltip: 'Scan barcode',
      onPressed: () => _scan(context, ref),
      reserveBottomInset: false,
    );
  }

  Future<void> _scan(BuildContext context, WidgetRef ref) async {
    final scanner = ref.read(barcodeScannerProvider);
    final code = await scanner.scanOnce(context);
    final trimmed = code?.trim() ?? '';
    if (trimmed.isEmpty) return; // dismissed / nothing scanned — no-op.
    if (!context.mounted) return;

    final match = await ref
        .read(databaseProvider)
        .catalogDao
        .findProductByBarcode(trimmed);
    if (!context.mounted) return;

    final outcome = resolveBarcodeScan(
      code: trimmed,
      match: match,
      storeProducts: loadedProducts,
      cartQty: match == null ? 0 : _cartQtyOf(ref, match.id),
      tier: tier,
    );

    switch (outcome) {
      case ScanAddSheet():
        await _openAddSheet(context, ref, outcome);
      case ScanOutOfStockHere(:final product):
        AppNotification.showError(
          context,
          '${product.name} is out of stock at ${storeName ?? 'this store'}',
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
      case ScanUnknown(:final code):
        // Unchanged in #317; permission-aware routing is a later slice (#316).
        AppNotification.showError(context, 'No product matches that barcode');
        if (onUnknownBarcode != null) {
          onUnknownBarcode!(context, code);
        } else {
          Navigator.of(
            context,
          ).push(slideDownRoute(AddProductScreen(prefilledBarcode: code)));
        }
    }
  }

  /// Opens the tap-and-hold "Add to Cart" sheet for a sellable scan. The sheet
  /// sets the line to the chosen total itself; Cancel / dismiss add nothing.
  Future<void> _openAddSheet(
    BuildContext context,
    WidgetRef ref,
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
    if (result == null || !context.mounted) return;
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
    final qty = _cartQtyOf(ref, product.id);
    if (qty <= 0) return;
    AppNotification.showSuccess(
      context,
      '${product.name} ×${_trimNum(qty)} added',
    );
  }

  /// Total quantity of [productId] across the cart's lines.
  static double _cartQtyOf(WidgetRef ref, String productId) => ref
      .read(cartProvider)
      .value
      .where((i) => i['id'] == productId)
      .fold<double>(0, (s, i) => s + (i['qty'] as num).toDouble());

  /// Formats a quantity without a trailing `.0` (3.0 → "3", 1.5 → "1.5").
  static String _trimNum(double n) =>
      n == n.toInt() ? n.toInt().toString() : n.toString();
}
