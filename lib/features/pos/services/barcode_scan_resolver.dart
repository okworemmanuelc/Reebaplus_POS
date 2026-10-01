import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/features/customers/data/models/customer.dart';

/// What one POS barcode scan means (#317, PRD #316).
///
/// The scan button only RENDERS an outcome; every decision about a scanned code
/// is made by [resolveBarcodeScan], which is pure (no widgets, no database) so
/// the whole table is unit-tested without a camera.
sealed class ScanOutcome {
  const ScanOutcome();
}

/// Found and sellable: open the "Add to Cart" quantity sheet for [product],
/// capped at the active store's [stock] and priced at [tier]. [inCart] is how
/// many are already in the cart, so the sheet can start on the next unit.
final class ScanAddSheet extends ScanOutcome {
  const ScanAddSheet({
    required this.product,
    required this.stock,
    required this.inCart,
    required this.tier,
  });

  final ProductData product;
  final int stock;
  final double inCart;
  final PriceTier tier;
}

/// Found, but the active store has none of it — either its stock here is 0 or
/// the product isn't stocked in this store at all.
final class ScanOutOfStockHere extends ScanOutcome {
  const ScanOutOfStockHere({required this.product});

  final ProductData product;
}

/// Found, but every unit the active store holds is already in the cart.
final class ScanAllInCart extends ScanOutcome {
  const ScanAllInCart({required this.product, required this.stock});

  final ProductData product;
  final int stock;
}

/// Found, but switched off for sale (`isAvailable == false`). The grid hides
/// these; before #317 a scan still sold them.
final class ScanSwitchedOff extends ScanOutcome {
  const ScanSwitchedOff({required this.product});

  final ProductData product;
}

/// No product in this business carries [code].
final class ScanUnknown extends ScanOutcome {
  const ScanUnknown({required this.code});

  final String code;
}

/// Decides what a scan of [code] means.
///
/// [match] is the product the barcode lookup found (null = none).
/// [storeProducts] is the active store's stock-aware catalogue — the POS
/// controller's store-scoped list — so the cap is the same one a tile tap
/// applies; a product absent from it is not stocked in this store and counts as
/// 0. [cartQty] is how many of [match] are already in the cart. [tier] is the
/// active price tier, carried onto [ScanAddSheet] unchanged.
///
/// `isAvailable` is checked here rather than in the lookup, so a switched-off
/// product gets its own message instead of reading as unknown.
ScanOutcome resolveBarcodeScan({
  required String code,
  required ProductData? match,
  required List<ProductDataWithStock> storeProducts,
  required double cartQty,
  required PriceTier tier,
}) {
  if (match == null) return ScanUnknown(code: code);
  if (!match.isAvailable) return ScanSwitchedOff(product: match);

  final stock = _storeStockOf(match.id, storeProducts);
  if (stock <= 0) return ScanOutOfStockHere(product: match);
  if (cartQty >= stock) return ScanAllInCart(product: match, stock: stock);

  return ScanAddSheet(
    product: match,
    stock: stock,
    inCart: cartQty,
    tier: tier,
  );
}

/// The active store's stock of [productId], or 0 when the store doesn't carry
/// it.
int _storeStockOf(String productId, List<ProductDataWithStock> storeProducts) {
  for (final entry in storeProducts) {
    if (entry.product.id == productId) return entry.totalStock;
  }
  return 0;
}
