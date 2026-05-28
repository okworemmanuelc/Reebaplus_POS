import 'package:reebaplus_pos/core/database/app_database.dart';

class ActivityLog {
  final String id;
  final String action;
  final String description;
  final DateTime timestamp;
  final String? storeId;
  final String? userId;

  // Typed FKs (PR 4)
  final String? orderId;
  final String? productId;
  final String? customerId;
  final String? expenseId;
  final String? deliveryId;
  final String? walletTxnId;

  ActivityLog({
    required this.id,
    required this.action,
    required this.description,
    required this.timestamp,
    this.storeId,
    this.userId,
    this.orderId,
    this.productId,
    this.customerId,
    this.expenseId,
    this.deliveryId,
    this.walletTxnId,
  });

  factory ActivityLog.fromDb(ActivityLogData data) {
    return ActivityLog(
      id: data.id,
      action: data.action,
      description: data.description,
      timestamp: data.createdAt,
      storeId: data.storeId,
      userId: data.userId,
      orderId: data.orderId,
      productId: data.productId,
      customerId: data.customerId,
      expenseId: data.expenseId,
      deliveryId: data.deliveryId,
      walletTxnId: data.walletTxnId,
    );
  }
}

