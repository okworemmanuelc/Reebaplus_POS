import 'package:reebaplus_pos/core/database/app_database.dart';

class NotificationModel {
  final String id;
  final String type;
  final String message;
  final DateTime timestamp;
  final bool isRead;
  final String? linkedRecordId;
  final String severity;

  NotificationModel({
    required this.id,
    required this.type,
    required this.message,
    required this.timestamp,
    this.isRead = false,
    this.linkedRecordId,
    this.severity = 'info',
  });

  factory NotificationModel.fromDb(NotificationData data) {
    return NotificationModel(
      id: data.id,
      type: data.type,
      message: data.message,
      timestamp: data.createdAt,
      isRead: data.isRead,
      linkedRecordId: data.linkedRecordId,
      severity: data.severity,
    );
  }

  NotificationModel copyWith({
    String? id,
    String? type,
    String? message,
    DateTime? timestamp,
    bool? isRead,
    String? linkedRecordId,
    String? severity,
  }) {
    return NotificationModel(
      id: id ?? this.id,
      type: type ?? this.type,
      message: message ?? this.message,
      timestamp: timestamp ?? this.timestamp,
      isRead: isRead ?? this.isRead,
      linkedRecordId: linkedRecordId ?? this.linkedRecordId,
      severity: severity ?? this.severity,
    );
  }
}

