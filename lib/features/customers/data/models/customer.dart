import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/features/customers/data/models/payment.dart';

enum PriceTier { retailer, wholesaler }

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
  final Map<String, int> emptyCratesBalance;
  final List<Payment> payments;
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
    this.emptyCratesBalance = const {},
    this.payments = const [],
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
    Map<String, int>? emptyCratesBalance,
    List<Payment>? payments,
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
      emptyCratesBalance: emptyCratesBalance ?? this.emptyCratesBalance,
      payments: payments ?? this.payments,
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
      emptyCratesBalance: const {}, // TODO: Fetch from CrateBalances table
      payments: const [], // TODO: Fetch from Payments table
      storeId: data.storeId,
    );
  }

  static Customer walkIn() => Customer(
    id: walkInId,
    name: 'Walk-in Customer',
    addressText: 'N/A',
    googleMapsLocation: 'N/A',
    isWalkIn: true,
    emptyCratesBalance: const {},
    payments: const [],
  );
}
