import 'package:reebaplus_pos/core/database/app_database.dart';

enum PriceTier { retailer, wholesaler }

/// #202: this model used to carry two never-populated legacy fields —
/// `emptyCratesBalance` (hardcoded `const {}`) and `payments` (hardcoded
/// `const []`), each with a "fetch it from the table one day" TODO. Neither had
/// a reader other than the dead cart crate-credit block, and completing the
/// crate one as written would have discounted crate DEBTORS. Crate balances are
/// derived from `crate_ledger` (ADR 0020) and payment history from
/// `payment_transactions`; read those, never a field on this snapshot.
class Customer {
  // Walk-in sentinel — replaces the legacy `id == -1` integer sentinel.
  static const String walkInId = '__walk_in__';

  final String id;
  final String name;
  final String addressText;
  final String googleMapsLocation;
  final String? phone;
  final int walletLimitKobo;
  final DateTime createdAt;
  final PriceTier priceTier;
  final bool isWalkIn;
  final String? storeId;

  Customer({
    required this.id,
    required this.name,
    required this.addressText,
    required this.googleMapsLocation,
    this.phone,
    this.walletLimitKobo = 0,
    DateTime? createdAt,
    this.priceTier = PriceTier.retailer,
    this.isWalkIn = false,
    this.storeId,
  }) : createdAt = createdAt ?? DateTime.now();

  double get walletLimit => walletLimitKobo / 100.0;

  Customer copyWith({
    String? id,
    String? name,
    String? addressText,
    String? googleMapsLocation,
    String? phone,
    int? walletLimitKobo,
    DateTime? createdAt,
    PriceTier? priceTier,
    bool? isWalkIn,
    String? storeId,
  }) {
    return Customer(
      id: id ?? this.id,
      name: name ?? this.name,
      addressText: addressText ?? this.addressText,
      googleMapsLocation: googleMapsLocation ?? this.googleMapsLocation,
      phone: phone ?? this.phone,
      walletLimitKobo: walletLimitKobo ?? this.walletLimitKobo,
      createdAt: createdAt ?? this.createdAt,
      priceTier: priceTier ?? this.priceTier,
      isWalkIn: isWalkIn ?? this.isWalkIn,
      storeId: storeId ?? this.storeId,
    );
  }

  static Customer fromDb(CustomerData data) {
    PriceTier group = PriceTier.retailer;
    try {
      group = PriceTier.values.firstWhere((e) => e.name == data.priceTier);
    } catch (_) {}

    return Customer(
      id: data.id,
      name: data.name,
      addressText: data.address ?? 'N/A',
      googleMapsLocation: data.googleMapsLocation ?? 'N/A',
      phone: data.phone,
      walletLimitKobo: data.walletLimitKobo,
      createdAt: data.createdAt,
      priceTier: group,
      isWalkIn: data.id == walkInId,
      storeId: data.storeId,
    );
  }

  static Customer walkIn() => Customer(
    id: walkInId,
    name: 'Walk-in Customer',
    addressText: 'N/A',
    googleMapsLocation: 'N/A',
    isWalkIn: true,
  );
}
