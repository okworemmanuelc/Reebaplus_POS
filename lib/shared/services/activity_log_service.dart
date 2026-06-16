import 'package:flutter/widgets.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/shared/models/activity_log.dart';
import 'package:reebaplus_pos/shared/services/auth_service.dart';

class ActivityLogService extends ValueNotifier<List<ActivityLog>> {
  final AppDatabase _db;
  final AuthService _auth;

  ActivityLogService(this._db, this._auth) : super([]) {
    _init();
  }

  void _init() {
    _db.activityLogDao.watchRecent().listen((logsData) {
      value = logsData.map((data) => ActivityLog.fromDb(data)).toList();
    });
  }

  Future<void> logAction(
    String action,
    String description, {
    String? staffId,
    String? storeId,
    String? orderId,
    String? productId,
    String? customerId,
    String? expenseId,
    String? deliveryId,
    String? walletTxnId,
  }) async {
    await _db.activityLogDao.log(
      staffId: staffId ?? _auth.currentUser?.id,
      action: action,
      description: description,
      orderId: orderId,
      productId: productId,
      customerId: customerId,
      expenseId: expenseId,
      deliveryId: deliveryId,
      walletTxnId: walletTxnId,
      storeId: storeId,
    );
  }

  Future<List<ActivityLog>> getForOrder(String orderId) async {
    final data = await _db.activityLogDao.getForOrder(orderId);
    return data.map((d) => ActivityLog.fromDb(d)).toList();
  }

  Future<List<ActivityLog>> getForProduct(String productId) async {
    final data = await _db.activityLogDao.getForProduct(productId);
    return data.map((d) => ActivityLog.fromDb(d)).toList();
  }

  Future<List<ActivityLog>> getForCustomer(String customerId) async {
    final data = await _db.activityLogDao.getForCustomer(customerId);
    return data.map((d) => ActivityLog.fromDb(d)).toList();
  }
}
