// Read-only extra stores after a downgrade (reebaplus-web#90).
//
// CLIENT-SIDE enforcement only, by design: there is no RLS/trigger change, so a
// modified client could still write to a read-only store. That is acceptable
// here (the plans differ by stores + staff, not by security); the server still
// refuses NEW stores past the limit (0224 trg_stores_plan_limit).
//
// What is blocked for a store in `readOnlyStoreIdsProvider`: stock adjustments
// and stock counts against it, editing a product while viewing it, and store
// settings. What is NEVER blocked: selling (the till never locks), and reading.
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:reebaplus_pos/core/utils/notifications.dart';
import 'package:reebaplus_pos/features/subscription/subscription_plan_providers.dart';

const String kReadOnlyStoreMessage =
    'This store is read-only on your plan. Upgrade to Premium to make changes.';

/// Pure predicate: [storeId] is read-only. A null store ("All Stores") never is.
bool isReadOnlyStore(Set<String> readOnlyIds, String? storeId) =>
    storeId != null && readOnlyIds.contains(storeId);

/// The read-only message when a store-scoped WRITE against [storeId] must be
/// blocked, else null. Do NOT call this from the sale / checkout path.
String? readOnlyStoreWriteBlock(Set<String> readOnlyIds, String? storeId) =>
    isReadOnlyStore(readOnlyIds, storeId) ? kReadOnlyStoreMessage : null;

/// Widget-side guard: true (and shows the message) when the write is blocked.
bool blockIfReadOnlyStore(
  BuildContext context,
  WidgetRef ref,
  String? storeId,
) {
  if (!isReadOnlyStore(ref.read(readOnlyStoreIdsProvider), storeId)) {
    return false;
  }
  AppNotification.showError(context, kReadOnlyStoreMessage);
  return true;
}
