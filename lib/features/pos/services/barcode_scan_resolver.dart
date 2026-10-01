import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/features/customers/data/models/customer.dart';

/// What one POS barcode scan means (#317, PRD #316).
///
/// The scan button only RENDERS an outcome; every decision about a scanned code
/// is made by [resolveBarcodeScan] (and, for one product, [resolveProduct]),
/// which are pure (no widgets, no database) so the whole table is unit-tested
/// without a camera.
sealed class ScanOutcome {
  const ScanOutcome();
}

/// What ONE found product means at the till — the outcomes [resolveProduct]
/// can return. A single barcode match is one of these, and so is a row picked
/// from the "Which one?" list (#318), so both render the same way.
sealed class ScanMatchOutcome extends ScanOutcome {
  const ScanMatchOutcome();

  ProductData get product;
}

/// Found and sellable: open the "Add to Cart" quantity sheet for [product],
/// capped at the active store's [stock] and priced at [tier]. [inCart] is how
/// many are already in the cart, so the sheet can start on the next unit.
final class ScanAddSheet extends ScanMatchOutcome {
  const ScanAddSheet({
    required this.product,
    required this.stock,
    required this.inCart,
    required this.tier,
  });

  @override
  final ProductData product;
  final int stock;
  final double inCart;
  final PriceTier tier;
}

/// Found, but the active store has none of it — either its stock here is 0 or
/// the product isn't stocked in this store at all.
final class ScanOutOfStockHere extends ScanMatchOutcome {
  const ScanOutOfStockHere({required this.product});

  @override
  final ProductData product;
}

/// Found, but every unit the active store holds is already in the cart.
final class ScanAllInCart extends ScanMatchOutcome {
  const ScanAllInCart({required this.product, required this.stock});

  @override
  final ProductData product;
  final int stock;
}

/// Found, but switched off for sale (`isAvailable == false`). The grid hides
/// these; before #317 a scan still sold them.
final class ScanSwitchedOff extends ScanMatchOutcome {
  const ScanSwitchedOff({required this.product});

  @override
  final ProductData product;
}

/// More than one product in this business carries the scanned code (#318).
/// Barcodes are only softly unique (ADR 0017), so instead of taking the first
/// row the cashier picks one from a "Which one?" list. [choices] keep the
/// lookup's order (by name).
final class ScanChooseAmong extends ScanOutcome {
  const ScanChooseAmong({required this.choices});

  final List<ScanChoice> choices;
}

/// One row of the "Which one?" list (#318): the product, its price at the
/// active tier, its stock in the active store, and what picking it right now
/// would mean ([outcome]) — so an unsellable row can be shown dimmed with its
/// reason. The caller still re-runs [resolveProduct] after a pick, so the
/// result reflects the cart at that moment.
final class ScanChoice {
  const ScanChoice({
    required this.product,
    required this.unitPriceKobo,
    required this.stock,
    required this.outcome,
  });

  final ProductData product;
  final int unitPriceKobo;
  final int stock;
  final ScanMatchOutcome outcome;

  bool get isSellable => outcome is ScanAddSheet;
}

/// No product in this business carries [code].
final class ScanUnknown extends ScanOutcome {
  const ScanUnknown({required this.code});

  final String code;
}

/// Decides what a scan of [code] means.
///
/// [matches] are the products the barcode lookup found (#318: all of them, not
/// just the first). None → [ScanUnknown]; two or more → [ScanChooseAmong]; one
/// → exactly the single-product checks of [resolveProduct].
///
/// [storeProducts] is the active store's stock-aware catalogue — the POS
/// controller's store-scoped list — so the cap is the same one a tile tap
/// applies; a product absent from it is not stocked in this store and counts as
/// 0. [cartQtyOf] gives how many of a product are already in the cart. [tier]
/// is the active price tier.
ScanOutcome resolveBarcodeScan({
  required String code,
  required List<ProductData> matches,
  required List<ProductDataWithStock> storeProducts,
  required double Function(String productId) cartQtyOf,
  required PriceTier tier,
}) {
  if (matches.isEmpty) return ScanUnknown(code: code);
  if (matches.length == 1) {
    final match = matches.single;
    return resolveProduct(
      product: match,
      storeProducts: storeProducts,
      cartQty: cartQtyOf(match.id),
      tier: tier,
    );
  }
  return ScanChooseAmong(
    choices: [
      for (final match in matches)
        ScanChoice(
          product: match,
          unitPriceKobo: tier == PriceTier.wholesaler
              ? match.wholesalerPriceKobo
              : match.retailerPriceKobo,
          stock: _storeStockOf(match.id, storeProducts),
          outcome: resolveProduct(
            product: match,
            storeProducts: storeProducts,
            cartQty: cartQtyOf(match.id),
            tier: tier,
          ),
        ),
    ],
  );
}

/// The single-product checks (#317): what [product] means at the till given
/// the active store's [storeProducts], the [cartQty] already in the cart and
/// the active [tier]. Used for a single barcode match and re-run for the row
/// picked from the "Which one?" list (#318), with that product's own cart qty
/// and stock.
///
/// Check order: switched off → stock ≤ 0 here → cart ≥ stock → sheet.
/// `isAvailable` is checked here rather than in the lookup, so a switched-off
/// product gets its own message instead of reading as unknown.
ScanMatchOutcome resolveProduct({
  required ProductData product,
  required List<ProductDataWithStock> storeProducts,
  required double cartQty,
  required PriceTier tier,
}) {
  if (!product.isAvailable) return ScanSwitchedOff(product: product);

  final stock = _storeStockOf(product.id, storeProducts);
  if (stock <= 0) return ScanOutOfStockHere(product: product);
  if (cartQty >= stock) return ScanAllInCart(product: product, stock: stock);

  return ScanAddSheet(
    product: product,
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
