import 'package:flutter/foundation.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/shared/models/notification.dart';

class NotificationService extends ValueNotifier<List<NotificationModel>> {
  final AppDatabase _db;

  NotificationService(this._db) : super([]) {
    _init();
  }

  void _init() {
    _db.notificationsDao.watchAll().listen((notifsData) {
      value = notifsData.map((data) => NotificationModel.fromDb(data)).toList();
    });
  }

  Future<void> createNotification(
    String type,
    String message, {
    String? linkedRecordId,
  }) async {
    await _db.notificationsDao.create(
      type,
      message,
      linkedRecordId: linkedRecordId,
    );
  }

  Future<void> markAsRead(String id) async {
    await _db.notificationsDao.markRead(id);
  }

  Future<void> markAllAsRead() async {
    await _db.notificationsDao.markAllRead();
  }

  Future<void> deleteNotification(String id) async {
    await _db.notificationsDao.deleteSingle(id);
  }

  Future<void> clearAll() async {
    await _db.notificationsDao.clearAll();
  }

  int get unreadCount => value.where((n) => !n.isRead).length;
}
