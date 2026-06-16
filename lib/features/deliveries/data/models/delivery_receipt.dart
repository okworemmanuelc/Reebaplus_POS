import 'package:flutter/foundation.dart';

class DeliveryReceipt {
  final String id;
  final String orderId;
  final String referenceNumber;
  final String riderName;
  final double outstandingAmount;
  final double paidAmount;
  final DateTime createdAt;

  DeliveryReceipt({
    required this.id,
    required this.orderId,
    required this.referenceNumber,
    required this.riderName,
    required this.outstandingAmount,
    required this.paidAmount,
    required this.createdAt,
  });

  bool get isFullyPaid => outstandingAmount <= 0;

  DeliveryReceipt copyWith({
    String? id,
    String? orderId,
    String? referenceNumber,
    String? riderName,
    double? outstandingAmount,
    double? paidAmount,
    DateTime? createdAt,
  }) {
    return DeliveryReceipt(
      id: id ?? this.id,
      orderId: orderId ?? this.orderId,
      referenceNumber: referenceNumber ?? this.referenceNumber,
      riderName: riderName ?? this.riderName,
      outstandingAmount: outstandingAmount ?? this.outstandingAmount,
      paidAmount: paidAmount ?? this.paidAmount,
      createdAt: createdAt ?? this.createdAt,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'orderId': orderId,
      'referenceNumber': referenceNumber,
      'riderName': riderName,
      'outstandingAmount': outstandingAmount,
      'paidAmount': paidAmount,
      'createdAt': createdAt.toIso8601String(),
    };
  }

  factory DeliveryReceipt.fromJson(Map<String, dynamic> json) {
    return DeliveryReceipt(
      id: json['id'],
      orderId: json['orderId'],
      referenceNumber: json['referenceNumber'],
      riderName: json['riderName'],
      outstandingAmount: (json['outstandingAmount'] as num).toDouble(),
      paidAmount: (json['paidAmount'] as num).toDouble(),
      createdAt: DateTime.parse(json['createdAt']),
    );
  }
}

class DeliveryReceiptService extends ValueNotifier<List<DeliveryReceipt>> {
  DeliveryReceiptService() : super([]);

  void addReceipt(DeliveryReceipt receipt) {
    value = [...value, receipt];
  }

  String generateReference() {
    const prefix = 'DEL-';
    final timestamp = DateTime.now().millisecondsSinceEpoch
        .toString()
        .substring(7);
    final random = (1000 + (DateTime.now().microsecond % 9000)).toString();
    return '$prefix$timestamp$random';
  }

  DeliveryReceipt? getByOrderId(String orderId) {
    try {
      return value.firstWhere((r) => r.orderId == orderId);
    } catch (_) {
      return null;
    }
  }

  void updateReceipt(DeliveryReceipt updated) {
    final idx = value.indexWhere((r) => r.id == updated.id);
    if (idx != -1) {
      final newList = List<DeliveryReceipt>.from(value);
      newList[idx] = updated;
      value = newList;
    }
  }
}
