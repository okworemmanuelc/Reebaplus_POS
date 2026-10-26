// Shared fixtures for the #427 Online Order tests.

import 'package:drift/drift.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';

Future<String> seedStore(AppDatabase db, String businessId) async {
  final id = UuidV7.generate();
  await db.into(db.stores).insert(
        StoresCompanion.insert(id: Value(id), businessId: businessId, name: 'Main'),
      );
  return id;
}

/// A `new` Online Order with one line, as the pull would write it.
Future<String> seedOnlineOrder(
  AppDatabase db, {
  required String businessId,
  required String storeId,
  String? shopperAccountId,
  String status = 'new',
  String shopperName = 'Ada',
  String phone = '08030000000',
  String reference = 'ON-1A2B3C4D',
  String? productId,
}) async {
  final id = UuidV7.generate();
  final at = DateTime.utc(2026, 10, 25, 9);
  await db.into(db.onlineOrders).insert(
        OnlineOrdersCompanion.insert(
          id: id,
          businessId: businessId,
          storeId: storeId,
          shopperAccountId: Value(shopperAccountId),
          status: Value(status),
          reference: reference,
          estimatedTotalKobo: const Value(900000),
          shopperName: shopperName,
          deliveryPhone: phone,
          deliveryState: 'Nasarawa',
          deliveryLga: 'Keffi',
          deliveryStreet: '1 Road',
          placedAt: Value(at),
          createdAt: Value(at),
          lastUpdatedAt: Value(at),
        ),
      );
  if (productId != null) {
    await db.into(db.onlineOrderLines).insert(
          OnlineOrderLinesCompanion.insert(
            id: UuidV7.generate(),
            businessId: businessId,
            onlineOrderId: id,
            productId: productId,
            productName: 'Star Lager',
            unitPriceKobo: 450000,
            requestedQty: 2,
          ),
        );
  }
  return id;
}

/// The cloud's copy of a seeded order (snake_case), for the transport store.
Map<String, dynamic> cloudOnlineOrder(OnlineOrderData o, {String? status}) => {
      'id': o.id,
      'business_id': o.businessId,
      'store_id': o.storeId,
      'shopper_account_id': o.shopperAccountId,
      'customer_id': o.customerId,
      'status': status ?? o.status,
      'reference': o.reference,
      'currency': o.currency,
      'estimated_total_kobo': o.estimatedTotalKobo,
      'shopper_name': o.shopperName,
      'delivery_phone': o.deliveryPhone,
      'delivery_country': o.deliveryCountry,
      'delivery_state': o.deliveryState,
      'delivery_lga': o.deliveryLga,
      'delivery_street': o.deliveryStreet,
      'note': o.note,
      'decline_reason': o.declineReason,
      'cancel_reason': o.cancelReason,
      'linked_order_id': o.linkedOrderId,
      'placed_at': o.placedAt.toUtc().toIso8601String(),
      'responded_at': null,
      'created_at': o.createdAt.toUtc().toIso8601String(),
      'last_updated_at': o.lastUpdatedAt.toUtc().toIso8601String(),
    };
