import 'package:flutter/foundation.dart';
import 'package:reebaplus_pos/features/deliveries/data/models/delivery.dart';
import 'package:reebaplus_pos/shared/services/notification_service.dart';

class DeliveryService extends ValueNotifier<List<Delivery>> {
  final NotificationService _notifications;

  DeliveryService(this._notifications) : super(_initialDeliveries);

  static final List<Delivery> _initialDeliveries = [];

  Future<void> addDelivery(Delivery delivery) async {
    value = [...value, delivery];
    await _notifications.createNotification(
      'new_delivery',
      'New delivery received from ${delivery.supplierName}',
      linkedRecordId: delivery.id,
    );
  }

  List<Delivery> getAll() {
    final list = List<Delivery>.from(value);
    list.sort((a, b) => b.deliveredAt.compareTo(a.deliveredAt));
    return list;
  }
}
