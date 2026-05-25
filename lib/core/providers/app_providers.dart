/// Riverpod providers — all services constructed via ref.read().
///
/// Only `database` and `themeController` remain as globals because they
/// must be initialised before `runApp()`. Everything else is constructed
/// here with proper dependency injection.
library;

import 'package:drift/drift.dart' show innerJoin;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/services/biometric_service.dart';
import 'package:reebaplus_pos/core/theme/theme_notifier.dart';
import 'package:reebaplus_pos/features/customers/data/models/customer.dart';
import 'package:reebaplus_pos/features/customers/data/services/customer_service.dart';
import 'package:reebaplus_pos/features/deliveries/data/models/delivery_receipt.dart';
import 'package:reebaplus_pos/features/deliveries/data/services/delivery_service.dart';
import 'package:reebaplus_pos/features/expenses/data/services/expense_service.dart';
import 'package:reebaplus_pos/features/inventory/data/services/supplier_service.dart';
import 'package:reebaplus_pos/features/payments/data/services/payment_service.dart';
import 'package:reebaplus_pos/shared/services/activity_log_service.dart';
import 'package:reebaplus_pos/shared/services/auth_service.dart';
import 'package:reebaplus_pos/shared/services/secure_storage_service.dart';
import 'package:reebaplus_pos/shared/services/cart_service.dart';
import 'package:reebaplus_pos/shared/services/navigation_service.dart';
import 'package:reebaplus_pos/shared/services/notification_service.dart';
import 'package:reebaplus_pos/shared/services/crate_return_approval_service.dart';
import 'package:reebaplus_pos/shared/services/order_service.dart';
import 'package:reebaplus_pos/shared/services/printer_service.dart';
import 'package:reebaplus_pos/shared/services/reorder_alert_service.dart';
import 'package:reebaplus_pos/core/diagnostics/sync_diagnostic.dart';
import 'package:reebaplus_pos/core/services/supabase_sync_service.dart';

// ── Crate Return Approval ──────────────────────────────────────────────────
final crateReturnApprovalServiceProvider =
    Provider<CrateReturnApprovalService>((ref) {
  return CrateReturnApprovalService(ref.read(databaseProvider));
});

// ── Database (global — initialised before runApp) ──────────────────────────
final databaseProvider = Provider<AppDatabase>((_) => database);

// ── Supabase client ────────────────────────────────────────────────────────
final supabaseClientProvider = Provider<SupabaseClient>(
  (_) => Supabase.instance.client,
);

// ── Navigation ─────────────────────────────────────────────────────────────
final navigationProvider = Provider<NavigationService>((ref) {
  return NavigationService();
});
final currentIndexProvider = ChangeNotifierProvider<ValueNotifier<int>>((ref) {
  return ref.watch(navigationProvider).currentIndex;
});
final lockedWarehouseProvider =
    ChangeNotifierProvider<ValueNotifier<String?>>((ref) {
  return ref.watch(navigationProvider).lockedWarehouseId;
});

// ── Secure Storage ─────────────────────────────────────────────────────────
final secureStorageProvider = Provider<SecureStorageService>(
  (_) => SecureStorageService(),
);

// ── Auth ────────────────────────────────────────────────────────────────────
final authProvider = ChangeNotifierProvider<AuthService>((ref) {
  return AuthService(
    ref.read(databaseProvider),
    ref.read(navigationProvider),
    ref.read(secureStorageProvider),
    ref.read(supabaseSyncServiceProvider),
    ref.read(supabaseClientProvider),
  );
});
final deviceUserIdProvider =
    ChangeNotifierProvider<ValueNotifier<String?>>((ref) {
  return ref.watch(authProvider).deviceUserIdNotifier;
});

// ── Theme (global — initialised before runApp) ─────────────────────────────
final themeProvider =
    ChangeNotifierProvider<ThemeController>((_) => themeController);

// ── Cart ────────────────────────────────────────────────────────────────────
final cartProvider = ChangeNotifierProvider<CartService>((ref) {
  return CartService(ref.read(authProvider));
});
final activeCustomerProvider =
    ChangeNotifierProvider<ValueNotifier<Customer?>>((ref) {
  return ref.watch(cartProvider).activeCustomer;
});

// ── Notification ────────────────────────────────────────────────────────────
final notificationProvider =
    ChangeNotifierProvider<NotificationService>((ref) {
  return NotificationService(ref.read(databaseProvider));
});

// ── Activity Log ────────────────────────────────────────────────────────────
final activityLogProvider =
    ChangeNotifierProvider<ActivityLogService>((ref) {
  return ActivityLogService(
      ref.read(databaseProvider), ref.read(authProvider));
});

// ── Order ───────────────────────────────────────────────────────────────────
final orderServiceProvider = Provider<OrderService>((ref) {
  return OrderService(
    ref.read(databaseProvider),
    ref.read(supabaseSyncServiceProvider),
  );
});

// ── Customer ────────────────────────────────────────────────────────────────
final customerServiceProvider =
    ChangeNotifierProvider<CustomerService>((ref) {
  return CustomerService(
      ref.read(databaseProvider), ref.read(activityLogProvider));
});

/// Map of customerId → signed wallet balance (kobo), computed live from the
/// WalletTransactions ledger. Replaces the cached `customers.wallet_balance_kobo`
/// column that PR 2a removed.
final walletBalancesKoboProvider =
    StreamProvider.autoDispose<Map<String, int>>((ref) {
  return ref.read(databaseProvider).customersDao.watchAllWalletBalancesKobo();
});

// ── Supplier ────────────────────────────────────────────────────────────────
final supplierServiceProvider =
    ChangeNotifierProvider<SupplierService>((ref) {
  return SupplierService(ref.read(databaseProvider));
});

// ── Delivery ────────────────────────────────────────────────────────────────
final deliveryServiceProvider =
    ChangeNotifierProvider<DeliveryService>((ref) {
  return DeliveryService(ref.read(notificationProvider));
});
final deliveryReceiptServiceProvider =
    ChangeNotifierProvider<DeliveryReceiptService>((ref) {
  return DeliveryReceiptService();
});

// ── Expense ─────────────────────────────────────────────────────────────────
final expenseServiceProvider =
    ChangeNotifierProvider<ExpenseService>((ref) {
  return ExpenseService(ref.read(notificationProvider));
});

// ── Payment ─────────────────────────────────────────────────────────────────
final paymentServiceProvider =
    ChangeNotifierProvider<PaymentService>((ref) {
  return PaymentService();
});

// ── Stateless services ─────────────────────────────────────────────────────
final printerServiceProvider = Provider<PrinterService>((ref) {
  return PrinterService();
});
final biometricServiceProvider = Provider<BiometricService>((ref) {
  return BiometricService();
});
final reorderAlertServiceProvider = Provider<ReorderAlertService>((ref) {
  return ReorderAlertService(ref.read(databaseProvider).stockLedgerDao);
});

final supabaseSyncServiceProvider = Provider<SupabaseSyncService>((ref) {
  return SupabaseSyncService(
    ref.read(databaseProvider),
    ref.read(supabaseClientProvider),
  );
});

// ── Sync diagnostics ────────────────────────────────────────────────────────
final syncDiagnosticProvider = Provider<SyncDiagnostic>((ref) {
  return SyncDiagnostic(ref.read(databaseProvider));
});
final failedQueueItemsProvider = StreamProvider.autoDispose((ref) {
  return ref.read(databaseProvider).syncDao.watchFailedItems();
});
final failedQueueCountProvider = StreamProvider.autoDispose<int>((ref) {
  return ref.read(databaseProvider).syncDao.watchFailedCount();
});
final pendingQueueCountProvider = StreamProvider.autoDispose<int>((ref) {
  return ref.read(databaseProvider).syncDao.watchPendingCount();
});
final pendingQueueItemsProvider = StreamProvider.autoDispose((ref) {
  return ref.read(databaseProvider).syncDao.watchPendingItems();
});
final orphanQueueItemsProvider = StreamProvider.autoDispose((ref) {
  return ref.read(databaseProvider).syncDao.watchOrphans();
});
final orphanQueueCountProvider = StreamProvider.autoDispose<int>((ref) {
  return ref.read(databaseProvider).syncDao.watchOrphanCount();
});

final pendingCrateReturnsProvider =
    StreamProvider.autoDispose<List<PendingCrateReturnData>>((ref) {
  final db = ref.read(databaseProvider);
  return (db.select(db.pendingCrateReturns)
        ..where((t) => t.status.equals('pending')))
      .watch();
});

class PendingReturnWithDetails {
  final PendingCrateReturnData returnRow;
  final CustomerData customer;
  final CrateGroupData crateGroup;
  PendingReturnWithDetails({
    required this.returnRow,
    required this.customer,
    required this.crateGroup,
  });
}

final pendingReturnsWithDetailsProvider =
    StreamProvider.autoDispose<List<PendingReturnWithDetails>>((ref) {
  final db = ref.read(databaseProvider);
  final query = db.select(db.pendingCrateReturns).join([
    innerJoin(db.customers,
        db.customers.id.equalsExp(db.pendingCrateReturns.customerId)),
    innerJoin(db.crateGroups,
        db.crateGroups.id.equalsExp(db.pendingCrateReturns.crateGroupId)),
  ])
    ..where(db.pendingCrateReturns.status.equals('pending'));

  return query.watch().map((rows) => rows
      .map((r) => PendingReturnWithDetails(
            returnRow: r.readTable(db.pendingCrateReturns),
            customer: r.readTable(db.customers),
            crateGroup: r.readTable(db.crateGroups),
          ))
      .toList());
});

final localBusinessesProvider = StreamProvider.autoDispose<List<BusinessData>>((ref) {
  final db = ref.read(databaseProvider);
  return db.select(db.businesses).watch();
});

/// Lifts the `SupabaseSyncService.pullStatus` ValueNotifier into Riverpod
/// so the MainLayout catch-up banner (and SyncIssues) can `ref.watch` it.
/// Mirrors the pattern used for the `isOnline` ValueNotifier (read directly
/// from the service in `app_drawer.dart`).
final pullStatusProvider =
    ChangeNotifierProvider<ValueNotifier<PullStatus>>((ref) {
  return ref.watch(supabaseSyncServiceProvider).pullStatus;
});
