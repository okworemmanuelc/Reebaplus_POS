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
import 'package:reebaplus_pos/shared/widgets/slide_route.dart';

/// The always-visible POS scan control (#118). It is never gated on a non-empty
/// cart — tapping it opens the camera one-shot (via [barcodeScannerProvider]).
///
/// On a successful scan:
///  - a matching product is added to the cart through the SAME add path a tap
///    uses, so per-store stock and the active price tier apply identically;
///  - an unknown barcode toasts and opens Add Product with the code pre-filled
///    so the cashier can catalogue it on the spot.
class PosBarcodeScanButton extends ConsumerWidget {
  const PosBarcodeScanButton({
    super.key,
    required this.tier,
    required this.loadedProducts,
    this.onUnknownBarcode,
  });

  /// The active price tier (§12.2). A scanned line is priced exactly as a tap.
  final PriceTier tier;

  /// The store-scoped, stock-aware catalogue the grid is currently showing. A
  /// scanned product is resolved against this so the cart's stock cap is the
  /// same one a tap would apply (the normal add path).
  final List<ProductDataWithStock> loadedProducts;

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
      label: 'Scan',
      icon: FontAwesomeIcons.barcode.data,
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

    if (match == null) {
      AppNotification.showError(context, 'No product matches that barcode');
      if (onUnknownBarcode != null) {
        onUnknownBarcode!(context, trimmed);
      } else {
        Navigator.of(
          context,
        ).push(slideDownRoute(AddProductScreen(prefilledBarcode: trimmed)));
      }
      return;
    }

    // FOUND — add through the normal path so stock + tier rules apply exactly
    // as they would for a tap on the product tile.
    final item = _resolveStock(match);
    final accepted = ref
        .read(cartProvider)
        .addItem(
          item.product,
          qty: 1.0,
          maxStock: item.totalStock,
          tier: tier,
        );
    if (!context.mounted) return;
    if (accepted) {
      AppNotification.showSuccess(context, '${match.name} added to cart');
    } else {
      AppNotification.showError(
        context,
        'Stock limit reached for ${match.name}',
      );
    }
  }

  /// Resolve the scanned product to its store-scoped stock from the loaded grid
  /// list, so the cart's stock cap matches a tap. A product not in the current
  /// grid (e.g. unstocked in this store) resolves to 0 stock — the normal add
  /// path then reports the stock limit rather than overselling.
  ProductDataWithStock _resolveStock(ProductData match) {
    for (final entry in loadedProducts) {
      if (entry.product.id == match.id) return entry;
    }
    return ProductDataWithStock(product: match, totalStock: 0);
  }
}
