/// The manufacturer crate arithmetic — one **pure function** over plain data
/// (#291, PRD #284 §5).
///
/// This is the ONE read seam for a brand's crate position across its six
/// statuses:
///   1. In the warehouse — the derived Empties Pool (count × crate value)
///   2. Full crates in stock — stock of the brand's tracked-bottle products (count × crate value)
///   3. With customers, on deposit — unsettled money-track crate lines (deposit actually paid in)
///   4. With customers, no deposit — derived customer crate debt (count × crate value)
///   5. Short — the Crate Shortage (open count × crate value; 0 until #293)
///   6. Damaged — damage movements in current month (snapshotted loss or count × crate value)
///
/// Like [computeCrateDepositPosition], this file has NO database imports, no
/// Drift dependencies, and no provider container. It operates exclusively over
/// plain values and returns immutable data structures.
library;

/// The figure for one of the six crate statuses.
class CrateStatusFigure {
  /// User-facing label (e.g. 'In the warehouse').
  final String label;

  /// Quantity of crates in this status.
  final int count;

  /// Monetary value in minor units (kobo).
  final int moneyKobo;

  /// Whether a money amount is meaningful for this status.
  /// Short status has `hasMoney = false` until #293.
  final bool hasMoney;

  const CrateStatusFigure({
    required this.label,
    required this.count,
    required this.moneyKobo,
    this.hasMoney = true,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CrateStatusFigure &&
          runtimeType == other.runtimeType &&
          label == other.label &&
          count == other.count &&
          moneyKobo == other.moneyKobo &&
          hasMoney == other.hasMoney;

  @override
  int get hashCode => Object.hash(label, count, moneyKobo, hasMoney);

  @override
  String toString() =>
      'CrateStatusFigure($label: count=$count, moneyKobo=$moneyKobo, hasMoney=$hasMoney)';
}

/// The complete read-only crate position of ONE brand.
class ManufacturerCratePosition {
  /// The brand ID.
  final String manufacturerId;

  /// The brand's canonical crate value in kobo (`deposit_amount_kobo`).
  final int crateValueKobo;

  /// 1. Empties currently sitting in the warehouse / shop.
  final CrateStatusFigure inWarehouse;

  /// 2. Full crates of drinks in stock (tracked-bottle products).
  final CrateStatusFigure fullCratesInStock;

  /// 3. Crates taken by customers on deposit, not yet settled.
  final CrateStatusFigure withCustomersOnDeposit;

  /// 4. Crates owed by customers with no deposit paid ("crate-track").
  final CrateStatusFigure withCustomersNoDeposit;

  /// 5. Crates missing at counts (shortage). Shows 0 until #293.
  final CrateStatusFigure short;

  /// 6. Empties broken/damaged in the current month.
  final CrateStatusFigure damaged;

  const ManufacturerCratePosition({
    required this.manufacturerId,
    required this.crateValueKobo,
    required this.inWarehouse,
    required this.fullCratesInStock,
    required this.withCustomersOnDeposit,
    required this.withCustomersNoDeposit,
    required this.short,
    required this.damaged,
  });

  /// Factory creating an all-zero position for initial / empty stream states.
  const ManufacturerCratePosition.zero(
    this.manufacturerId, {
    this.crateValueKobo = 0,
  })  : inWarehouse = const CrateStatusFigure(
          label: 'In the warehouse',
          count: 0,
          moneyKobo: 0,
        ),
        fullCratesInStock = const CrateStatusFigure(
          label: 'Full crates in stock',
          count: 0,
          moneyKobo: 0,
        ),
        withCustomersOnDeposit = const CrateStatusFigure(
          label: 'With customers, on deposit',
          count: 0,
          moneyKobo: 0,
        ),
        withCustomersNoDeposit = const CrateStatusFigure(
          label: 'With customers, no deposit',
          count: 0,
          moneyKobo: 0,
        ),
        short = const CrateStatusFigure(
          label: 'Short',
          count: 0,
          moneyKobo: 0,
          hasMoney: false,
        ),
        damaged = const CrateStatusFigure(
          label: 'Damaged',
          count: 0,
          moneyKobo: 0,
        );

  /// Total crates owned or with customers across the brand.
  int get totalCrates =>
      inWarehouse.count +
      fullCratesInStock.count +
      withCustomersOnDeposit.count +
      withCustomersNoDeposit.count;

  /// Total crate value in kobo across the brand.
  int get totalCrateValueKobo =>
      inWarehouse.moneyKobo +
      fullCratesInStock.moneyKobo +
      withCustomersOnDeposit.moneyKobo +
      withCustomersNoDeposit.moneyKobo;

  /// The six statuses in canonical display order.
  List<CrateStatusFigure> get allStatuses => [
        inWarehouse,
        fullCratesInStock,
        withCustomersOnDeposit,
        withCustomersNoDeposit,
        short,
        damaged,
      ];

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ManufacturerCratePosition &&
          runtimeType == other.runtimeType &&
          manufacturerId == other.manufacturerId &&
          crateValueKobo == other.crateValueKobo &&
          inWarehouse == other.inWarehouse &&
          fullCratesInStock == other.fullCratesInStock &&
          withCustomersOnDeposit == other.withCustomersOnDeposit &&
          withCustomersNoDeposit == other.withCustomersNoDeposit &&
          short == other.short &&
          damaged == other.damaged;

  @override
  int get hashCode => Object.hash(
        manufacturerId,
        crateValueKobo,
        inWarehouse,
        fullCratesInStock,
        withCustomersOnDeposit,
        withCustomersNoDeposit,
        short,
        damaged,
      );
}

/// Pure computation function for a manufacturer's crate position.
///
/// Takes plain values representing counts and monetary amounts, with zero
/// database dependencies.
ManufacturerCratePosition computeManufacturerCratePosition({
  required String manufacturerId,
  required int crateValueKobo,
  int warehouseCrates = 0,
  int fullCrates = 0,
  int customerOnDepositCrates = 0,
  int customerOnDepositKobo = 0,
  int customerNoDepositCrates = 0,
  int shortCrates = 0,
  int damagedCrates = 0,
  int? damagedLossKobo,
}) {
  final rate = crateValueKobo > 0 ? crateValueKobo : 0;
  return ManufacturerCratePosition(
    manufacturerId: manufacturerId,
    crateValueKobo: rate,
    inWarehouse: CrateStatusFigure(
      label: 'In the warehouse',
      count: warehouseCrates,
      moneyKobo: warehouseCrates * rate,
    ),
    fullCratesInStock: CrateStatusFigure(
      label: 'Full crates in stock',
      count: fullCrates,
      moneyKobo: fullCrates * rate,
    ),
    withCustomersOnDeposit: CrateStatusFigure(
      label: 'With customers, on deposit',
      count: customerOnDepositCrates,
      moneyKobo: customerOnDepositKobo,
    ),
    withCustomersNoDeposit: CrateStatusFigure(
      label: 'With customers, no deposit',
      count: customerNoDepositCrates,
      moneyKobo: customerNoDepositCrates * rate,
    ),
    short: CrateStatusFigure(
      label: 'Short',
      count: shortCrates,
      moneyKobo: 0,
      hasMoney: false,
    ),
    damaged: CrateStatusFigure(
      label: 'Damaged',
      count: damagedCrates,
      moneyKobo: damagedLossKobo ?? (damagedCrates * rate),
    ),
  );
}

/// Attribution of customer held deposits across brands and any unattributed
/// remainder (#291, PRD #284 §5).
///
/// Guarantees that:
/// `totalAttributedKobo + unattributedKobo == businessWideHeldDepositKobo`.
class CustomerDepositAttribution {
  /// Attributed deposits in kobo, keyed by manufacturer id.
  final Map<String, int> attributedKoboByManufacturer;

  /// Total customer held deposit across the business from the wallet ledger.
  final int businessWideHeldDepositKobo;

  /// Held deposit that cannot be attributed to any known brand.
  final int unattributedKobo;

  const CustomerDepositAttribution({
    required this.attributedKoboByManufacturer,
    required this.businessWideHeldDepositKobo,
    required this.unattributedKobo,
  });

  /// Factory creating an empty attribution for initial stream states.
  const CustomerDepositAttribution.zero()
      : attributedKoboByManufacturer = const {},
        businessWideHeldDepositKobo = 0,
        unattributedKobo = 0;

  /// Sum of all brand-attributed customer deposits in kobo.
  int get totalAttributedKobo =>
      attributedKoboByManufacturer.values.fold(0, (a, b) => a + b);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CustomerDepositAttribution &&
          runtimeType == other.runtimeType &&
          businessWideHeldDepositKobo == other.businessWideHeldDepositKobo &&
          unattributedKobo == other.unattributedKobo &&
          _mapsEqual(
            attributedKoboByManufacturer,
            other.attributedKoboByManufacturer,
          );

  @override
  int get hashCode => Object.hash(
        businessWideHeldDepositKobo,
        unattributedKobo,
        Object.hashAll(attributedKoboByManufacturer.entries),
      );

  static bool _mapsEqual(Map<String, int> a, Map<String, int> b) {
    if (a.length != b.length) return false;
    for (final entry in a.entries) {
      if (b[entry.key] != entry.value) return false;
    }
    return true;
  }
}

/// Pure computation function for Customer Deposit attribution across brands.
///
/// Guarantees that:
/// `sum(attributed) + unattributed == businessWideHeldDepositKobo`.
CustomerDepositAttribution computeCustomerDepositAttribution({
  required int businessWideHeldDepositKobo,
  required Map<String, int> brandDepositsKobo,
}) {
  final totalAttributed = brandDepositsKobo.values.fold(0, (a, b) => a + b);
  final unattributed = businessWideHeldDepositKobo - totalAttributed;
  return CustomerDepositAttribution(
    attributedKoboByManufacturer: Map.unmodifiable(brandDepositsKobo),
    businessWideHeldDepositKobo: businessWideHeldDepositKobo,
    unattributedKobo: unattributed,
  );
}

/// Human-readable label for a crate ledger movement kind.
String labelForCrateMovement(String movementType) {
  switch (movementType) {
    case 'issued':
      return 'Issued to customer';
    case 'returned':
      return 'Returned';
    case 'damaged':
      return 'Damaged';
    case 'adjusted':
      return 'Adjusted';
    case 'count':
      return 'Count';
    case 'opening_count':
      return 'Opening Count';
    case 'received':
      return 'Received from supplier';
    case 'transferred_in':
      return 'Transferred in';
    case 'transferred_out':
      return 'Transferred out';
    case 'purchase':
      return 'Purchased';
    default:
      if (movementType.isEmpty) return 'Movement';
      final words = movementType.replaceAll('_', ' ').split(' ');
      return words
          .map((w) => w.isEmpty
              ? ''
              : '${w[0].toUpperCase()}${w.substring(1).toLowerCase()}')
          .join(' ');
  }
}

/// A single movement row for the Manufacturer screen's History tab.
class CrateMovementHistoryEntry {
  final String id;
  final String movementType;
  final String movementLabel;
  final int quantityDelta;
  final DateTime createdAt;
  final String? performedByName;
  final String? storeName;

  const CrateMovementHistoryEntry({
    required this.id,
    required this.movementType,
    required this.movementLabel,
    required this.quantityDelta,
    required this.createdAt,
    this.performedByName,
    this.storeName,
  });
}
/// Test and widget keys for the Manufacturer screen (#291).
const String kManufacturerCardKeyPrefix = 'manufacturer_card_';
const String kManufacturerScreenKey = 'manufacturer_screen';
const String kManufacturerStatusKeyPrefix = 'manufacturer_status_';
const String kManufacturerProductKeyPrefix = 'manufacturer_product_';
const String kManufacturerHistoryRowKeyPrefix = 'manufacturer_history_';
const String kManufacturerAttributionNoteKey = 'manufacturer_attribution_note';

/// Storage keys for tab scroll state persistence via [TabbedSliverScaffold].
const String kManufacturerCratesStorageKey = 'manufacturer_crates_tab';
const String kManufacturerProductsStorageKey = 'manufacturer_products_tab';
const String kManufacturerHistoryStorageKey = 'manufacturer_history_tab';
