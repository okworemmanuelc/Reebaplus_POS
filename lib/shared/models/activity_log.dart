import 'package:reebaplus_pos/core/database/app_database.dart';

class ActivityLog {
  final String id;
  final String action;
  final String description;
  final DateTime timestamp;
  final String? storeId;
  final String? userId;

  // Generic entity reference (§24.4) — replaces the six per-entity FK fields.
  // entityType is one of 'order'/'product'/'customer'/'expense'/'delivery'/
  // 'wallet_transaction' (or null); entityId is the referenced row's id.
  final String? entityType;
  final String? entityId;

  // Before/after JSON snapshots for the §24.4 detail view (null when N/A).
  final String? beforeJson;
  final String? afterJson;

  ActivityLog({
    required this.id,
    required this.action,
    required this.description,
    required this.timestamp,
    this.storeId,
    this.userId,
    this.entityType,
    this.entityId,
    this.beforeJson,
    this.afterJson,
  });

  factory ActivityLog.fromDb(ActivityLogData data) {
    return ActivityLog(
      id: data.id,
      action: data.action,
      description: data.description,
      timestamp: data.createdAt,
      storeId: data.storeId,
      userId: data.userId,
      entityType: data.entityType,
      entityId: data.entityId,
      beforeJson: data.beforeJson,
      afterJson: data.afterJson,
    );
  }
}
