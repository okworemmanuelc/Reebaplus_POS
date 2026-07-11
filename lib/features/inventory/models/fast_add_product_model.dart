/// Fast-Add form model — the pure, widget-free heart of the Add Product screen
/// (Seam 1, issue #30 / ADR 0006). It owns the save-time decisions that used to
/// live inside the screen: required-field validation, field defaulting, the
/// wholesaler mirror, the business-type-aware unit default, the
/// manufacturer-required-for-crate rule, target-store resolution, and shaping
/// the write intent. It takes raw field strings plus a small business-context
/// value object and returns either a validation error naming a **visible**
/// field or a resolved [FastAddIntent] the caller persists through the existing
/// catalog/inventory DAOs. No widgets, no database, no `BuildContext`.
library;

import 'package:reebaplus_pos/core/utils/currency_input_formatter.dart';

/// The business context the Fast-Add model needs, decoupled from widgets and
/// the database. Built by the screen from the current business + role + stores.
class FastAddContext {
  const FastAddContext({
    required this.tracksCrates,
    required this.canEditBuying,
    required this.storeIds,
  });

  /// `businessTracksCrates(business)` — a crate business surfaces + requires a
  /// Manufacturer and defaults the unit to Bottle.
  final bool tracksCrates;

  /// Whether the current role may see/set the buying price
  /// (`products.edit_buying_price`). When false the buying price is ignored and
  /// the product is saved Uncosted.
  final bool canEditBuying;

  /// The ids of the business's active stores. A single-store business resolves
  /// its store silently; a multi-store business must be given a selection.
  final List<String> storeIds;

  /// A business with exactly one store never asks which store to stock into.
  bool get isSingleStore => storeIds.length == 1;
}

/// Raw, unparsed field values from the Fast-Add form — the strings behind the
/// text controllers plus the two toggles the model reasons about. The model
/// owns all parsing, defaulting, and validation; the screen never pre-computes.
class FastAddInput {
  const FastAddInput({
    required this.name,
    required this.sellingPrice,
    required this.quantity,
    this.buyingPrice = '',
    this.wholesalePrice = '',
    this.lowStock = '',
    this.unit,
    this.trackEmpties = true,
    this.emptyCrateValue = '',
    this.hasManufacturer = false,
    this.selectedStoreId,
    this.barcode = '',
  });

  /// Product name (required). Trimmed by the model.
  final String name;

  /// Selling (Retailer) price (required).
  final String sellingPrice;

  /// Opening quantity (required, must be > 0).
  final String quantity;

  /// Buying price — blank ⇒ Uncosted (accepted, never blocks the save).
  final String buyingPrice;

  /// Wholesaler price — blank ⇒ mirrored from the selling price at save (a
  /// stored value, not a read-time fallback).
  final String wholesalePrice;

  /// Low-stock alert threshold — blank ⇒ default 5.
  final String lowStock;

  /// The chosen unit, or null to take the business-type default.
  final String? unit;

  /// The track-empty-crate-returns toggle. Only effective for a crate business.
  final bool trackEmpties;

  /// Empty-crate deposit value — only shaped when effectively tracking empties
  /// on a bottle unit.
  final String emptyCrateValue;

  /// Whether a manufacturer was selected or typed. Required for crate
  /// businesses (the deposit rate lives on the manufacturer).
  final bool hasManufacturer;

  /// The chosen store for a multi-store business. Ignored (resolved silently)
  /// for a single-store business.
  final String? selectedStoreId;

  /// Optional product barcode (#113). Blank ⇒ no barcode (null). Never blocks
  /// the save; a soft collision warning is surfaced by the screen, not here (a
  /// lookup is a DB call, which this pure model does not do).
  final String barcode;
}

/// The outcome of validating + shaping a Fast-Add submission.
sealed class FastAddResult {
  const FastAddResult();
}

/// A validation failure. [field] is always a field the user can currently see
/// (the fast section, or the "More details" section the caller expands before
/// surfacing the error) — never a silently-collapsed field.
final class FastAddInvalid extends FastAddResult {
  const FastAddInvalid({required this.field, required this.message});

  /// The human name of the offending field, matching its on-screen label.
  final String field;

  /// The user-facing error message.
  final String message;
}

/// A resolved write intent: the shaped, DB-ready scalar values for the new
/// product and its opening stock. Foreign keys (manufacturer/category/supplier)
/// are get-or-created by the caller around this intent; everything the model
/// owns — prices in kobo, the mirrored wholesaler price, the resolved unit,
/// effective crate tracking, the low-stock default, the initial stock, and the
/// target store — is final here.
final class FastAddIntent extends FastAddResult {
  const FastAddIntent({
    required this.name,
    required this.retailerPriceKobo,
    required this.wholesalerPriceKobo,
    required this.buyingPriceKobo,
    required this.unit,
    required this.trackEmpties,
    required this.emptyCrateValueKobo,
    required this.lowStockThreshold,
    required this.initialStock,
    required this.storeId,
    this.barcode,
  });

  final String name;
  final int retailerPriceKobo;

  /// Mirrored from [retailerPriceKobo] when the wholesaler field was blank.
  final int wholesalerPriceKobo;

  /// 0 when the buying price was skipped or the role cannot edit it — an
  /// Uncosted product.
  final int buyingPriceKobo;

  /// The resolved unit, or null (#108) when the clearable unit field was left
  /// blank — a product with no unit, hidden everywhere it would render.
  final String? unit;

  /// Effective track-empties (crate business AND the toggle on).
  final bool trackEmpties;

  /// Null when not tracking empties on a bottle unit, or when left blank.
  final int? emptyCrateValueKobo;
  final int lowStockThreshold;
  final int initialStock;
  final String storeId;

  /// Optional product barcode (#113); null when the field was left blank.
  final String? barcode;

  /// A product saved with no buying price is Uncosted (ADR 0006 / CONTEXT.md
  /// §Inventory & Costing): reports exclude it from COGS and count it
  /// transparently rather than guessing a cost.
  bool get isUncosted => buyingPriceKobo == 0;
}

/// Validate and shape a Fast-Add submission. Pure: same inputs ⇒ same result.
///
/// Required fields are checked in visible-first order so a single missing field
/// names itself. Crate businesses additionally require a Manufacturer (surfaced
/// in the fast section). A multi-store business requires a store selection; a
/// single-store business resolves its one store silently.
FastAddResult resolveFastAdd(FastAddInput input, FastAddContext context) {
  final name = input.name.trim();
  if (name.isEmpty) {
    return const FastAddInvalid(
      field: 'Product Name',
      message: 'Product Name is required.',
    );
  }

  final sellingRaw = input.sellingPrice.trim();
  if (sellingRaw.isEmpty) {
    return const FastAddInvalid(
      field: 'Selling Price',
      message: 'Selling Price is required.',
    );
  }

  final quantity = int.tryParse(input.quantity.trim()) ?? 0;
  if (quantity <= 0) {
    return const FastAddInvalid(
      field: 'Quantity',
      message: 'Quantity must be greater than 0.',
    );
  }

  // Crate businesses surface Manufacturer in the fast section and require it —
  // the crate deposit rate lives on the manufacturer, so omitting it would
  // silently disable the flagship crate feature.
  if (context.tracksCrates && !input.hasManufacturer) {
    return const FastAddInvalid(
      field: 'Manufacturer',
      message: 'Manufacturer is required.',
    );
  }

  // Target store: a single-store business resolves silently; a multi-store one
  // must be given a selection.
  final String storeId;
  if (context.isSingleStore) {
    storeId = context.storeIds.single;
  } else {
    final selected = input.selectedStoreId;
    if (selected == null || selected.isEmpty) {
      return const FastAddInvalid(
        field: 'Store',
        message: 'Store is required.',
      );
    }
    storeId = selected;
  }

  final retailerPriceKobo = _toKobo(sellingRaw);

  // Buying price is optional; a blank (or a role that cannot edit it) yields an
  // Uncosted product rather than blocking the save.
  final buyingPriceKobo =
      context.canEditBuying ? _toKobo(input.buyingPrice) : 0;
  if (context.canEditBuying &&
      input.buyingPrice.trim().isNotEmpty &&
      buyingPriceKobo > retailerPriceKobo) {
    return const FastAddInvalid(
      field: 'Buying Price',
      message: 'Buying price cannot be higher than selling price.',
    );
  }

  // Wholesaler mirror: blank ⇒ copy the selling price into the stored value.
  final wholesaleRaw = input.wholesalePrice.trim();
  final wholesalerPriceKobo =
      wholesaleRaw.isEmpty ? retailerPriceKobo : _toKobo(wholesaleRaw);

  // Unit + effective crate tracking. A blank/cleared unit (#108) resolves to
  // null — no unit — not a trade default; the form pre-fills the trade's
  // Lexicon unit as a clearable suggestion, so a non-blank value here is the
  // user's kept choice and a blank one is a deliberate clear.
  final unitRaw = input.unit?.trim() ?? '';
  final String? unit = unitRaw.isEmpty ? null : unitRaw;
  final trackEmpties = context.tracksCrates && input.trackEmpties;
  final crateRaw = input.emptyCrateValue.trim();
  final int? emptyCrateValueKobo =
      (trackEmpties && unit?.toLowerCase() == 'bottle' && crateRaw.isNotEmpty)
      ? _toKobo(crateRaw)
      : null;

  final lowStockThreshold = int.tryParse(input.lowStock.trim()) ?? 5;

  // Optional barcode: a blank field is no barcode (null), never a save blocker.
  final barcodeRaw = input.barcode.trim();
  final barcode = barcodeRaw.isEmpty ? null : barcodeRaw;

  return FastAddIntent(
    name: name,
    retailerPriceKobo: retailerPriceKobo,
    wholesalerPriceKobo: wholesalerPriceKobo,
    buyingPriceKobo: buyingPriceKobo,
    unit: unit,
    trackEmpties: trackEmpties,
    emptyCrateValueKobo: emptyCrateValueKobo,
    lowStockThreshold: lowStockThreshold,
    initialStock: quantity,
    storeId: storeId,
    barcode: barcode,
  );
}

/// Parse a currency field string to integer kobo (minor units).
int _toKobo(String raw) => (parseCurrency(raw) * 100).round();
