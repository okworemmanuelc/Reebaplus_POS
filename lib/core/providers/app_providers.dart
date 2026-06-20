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
import 'package:reebaplus_pos/shared/services/supplier_account_service.dart';
import 'package:reebaplus_pos/shared/services/receive_stock_service.dart';
import 'package:reebaplus_pos/shared/services/supplier_crate_service.dart';
import 'package:reebaplus_pos/shared/services/printer_service.dart';
import 'package:reebaplus_pos/shared/services/reorder_alert_service.dart';
import 'package:reebaplus_pos/core/diagnostics/sync_diagnostic.dart';
import 'package:reebaplus_pos/core/services/supabase_sync_service.dart';

// ── Crate Return Approval ──────────────────────────────────────────────────
final crateReturnApprovalServiceProvider = Provider<CrateReturnApprovalService>(
  (ref) {
    return CrateReturnApprovalService(ref.read(databaseProvider));
  },
);

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
  final original = ref.watch(navigationProvider).currentIndex;
  final proxy = ValueNotifier<int>(original.value);
  void originalListener() {
    if (proxy.value != original.value) proxy.value = original.value;
  }

  void proxyListener() {
    if (original.value != proxy.value) original.value = proxy.value;
  }

  original.addListener(originalListener);
  proxy.addListener(proxyListener);
  ref.onDispose(() {
    original.removeListener(originalListener);
  });
  return proxy;
});
final lockedStoreProvider = ChangeNotifierProvider<ValueNotifier<String?>>((
  ref,
) {
  final original = ref.watch(navigationProvider).lockedStoreId;
  final proxy = ValueNotifier<String?>(original.value);
  void originalListener() {
    if (proxy.value != original.value) proxy.value = original.value;
  }

  void proxyListener() {
    if (original.value != proxy.value) original.value = proxy.value;
  }

  original.addListener(originalListener);
  proxy.addListener(proxyListener);
  ref.onDispose(() {
    original.removeListener(originalListener);
  });
  return proxy;
});
// §12.1: true once the user explicitly picked a concrete active store this
// session (vs MainLayout's silent confined-user default). Drives the POS
// "pick a store" gate for every user with more than one store.
final storeExplicitlyChosenProvider =
    ChangeNotifierProvider<ValueNotifier<bool>>((ref) {
      final original = ref.watch(navigationProvider).storeExplicitlyChosen;
      final proxy = ValueNotifier<bool>(original.value);
      void originalListener() {
        if (proxy.value != original.value) proxy.value = original.value;
      }

      void proxyListener() {
        if (original.value != proxy.value) original.value = proxy.value;
      }

      original.addListener(originalListener);
      proxy.addListener(proxyListener);
      ref.onDispose(() {
        original.removeListener(originalListener);
      });
      return proxy;
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
final deviceUserIdProvider = ChangeNotifierProvider<ValueNotifier<String?>>((
  ref,
) {
  return ref.watch(authProvider).deviceUserIdNotifier;
});

// ── Theme (global — initialised before runApp) ─────────────────────────────
final themeProvider = ChangeNotifierProvider<ThemeController>(
  (_) => themeController,
);

// ── Cart ────────────────────────────────────────────────────────────────────
final cartProvider = ChangeNotifierProvider<CartService>((ref) {
  return CartService(ref.read(authProvider), ref.read(navigationProvider));
});
final activeCustomerProvider = ChangeNotifierProvider<ValueNotifier<Customer?>>(
  (ref) {
    return ref.watch(cartProvider).activeCustomer;
  },
);

// ── Notification ────────────────────────────────────────────────────────────
final notificationProvider = ChangeNotifierProvider<NotificationService>((ref) {
  return NotificationService(ref.read(databaseProvider));
});

// ── Activity Log ────────────────────────────────────────────────────────────
final activityLogProvider = ChangeNotifierProvider<ActivityLogService>((ref) {
  return ActivityLogService(ref.read(databaseProvider), ref.read(authProvider));
});

// ── Order ───────────────────────────────────────────────────────────────────
final orderServiceProvider = Provider<OrderService>((ref) {
  return OrderService(
    ref.read(databaseProvider),
    ref.read(supabaseSyncServiceProvider),
    // Device id → per-device order-number tag (§30.8.1, collision-proof
    // numbering across offline tills).
    ref.read(secureStorageProvider),
  );
});

// ── Customer ────────────────────────────────────────────────────────────────
final customerServiceProvider = ChangeNotifierProvider<CustomerService>((ref) {
  return CustomerService(
    ref.read(databaseProvider),
    ref.read(activityLogProvider),
  );
});

/// Map of customerId → signed wallet balance (kobo), computed live from the
/// WalletTransactions ledger. Replaces the cached `customers.wallet_balance_kobo`
/// column that PR 2a removed.
final walletBalancesKoboProvider = StreamProvider.autoDispose<Map<String, int>>(
  (ref) {
    return ref.read(databaseProvider).customersDao.watchAllWalletBalancesKobo();
  },
);

/// §13.4 Ring 7 — business-wide crate-deposit balancing figures
/// (taken / refunded / kept / held). Held = taken − refunded − kept.
final crateDepositSummaryProvider =
    StreamProvider.autoDispose<CrateDepositSummary>((ref) {
      return ref
          .read(databaseProvider)
          .walletTransactionsDao
          .watchCrateDepositSummary();
    });

/// §13.4 Ring 7 — per-customer held deposit (kobo); only non-zero holders.
final depositsHeldByCustomerProvider =
    StreamProvider.autoDispose<Map<String, int>>((ref) {
      return ref
          .read(databaseProvider)
          .walletTransactionsDao
          .watchDepositsHeldByCustomer();
    });

// ── Supplier ────────────────────────────────────────────────────────────────
final supplierServiceProvider = ChangeNotifierProvider<SupplierService>((ref) {
  return SupplierService(ref.read(databaseProvider));
});

/// §21.10 — records Invoice Total / Payment activity on a supplier's ledger.
final supplierAccountServiceProvider = Provider<SupplierAccountService>((ref) {
  return SupplierAccountService(ref.read(databaseProvider));
});

/// Atomic "Receive Stock" commit: supplier invoice + stock increment + crate
/// movements + activity log, all in one transaction. See [ReceiveStockService].
final receiveStockServiceProvider = Provider<ReceiveStockService>((ref) {
  return ReceiveStockService(
    ref.read(databaseProvider),
    ref.read(supplierAccountServiceProvider),
  );
});

/// supplierId → signed ledger balance (kobo), live. Negative = we owe the
/// supplier. Drives the per-supplier balance chip on the Suppliers list.
/// Scoped to the active store (§21.11); null lock = "All Stores" aggregate.
final supplierBalancesKoboProvider =
    StreamProvider.autoDispose<Map<String, int>>((ref) {
      final storeId = ref.watch(lockedStoreProvider).value;
      return ref
          .read(databaseProvider)
          .supplierLedgerDao
          .watchAllBalancesKobo(storeId: storeId);
    });

/// One supplier row, live (Supplier Details header). Null once soft-deleted.
final supplierByIdProvider = StreamProvider.autoDispose
    .family<SupplierData?, String>((ref, id) {
      return ref.read(databaseProvider).catalogDao.watchSupplierById(id);
    });

/// One supplier's signed ledger balance (kobo), live. Active-store scoped (§21.11).
final supplierBalanceProvider = StreamProvider.autoDispose.family<int, String>((
  ref,
  id,
) {
  final storeId = ref.watch(lockedStoreProvider).value;
  return ref
      .read(databaseProvider)
      .supplierLedgerDao
      .watchBalanceKobo(id, storeId: storeId);
});

/// One supplier's full ledger history (invoices + payments + voids), newest
/// first. Active-store scoped (§21.11).
final supplierLedgerHistoryProvider = StreamProvider.autoDispose
    .family<List<SupplierLedgerEntryData>, String>((ref, id) {
      final storeId = ref.watch(lockedStoreProvider).value;
      return ref
          .read(databaseProvider)
          .supplierLedgerDao
          .watchHistory(id, storeId: storeId);
    });

/// Every ledger entry (invoices + payments + voids) across all suppliers,
/// newest first — drives the Transaction history screen. Active-store scoped
/// (§21.11); null lock = "All Stores" aggregate.
final supplierAllHistoryProvider =
    StreamProvider.autoDispose<List<SupplierLedgerEntryData>>((ref) {
      final storeId = ref.watch(lockedStoreProvider).value;
      return ref
          .read(databaseProvider)
          .supplierLedgerDao
          .watchAllHistory(storeId: storeId);
    });

// ── Supplier empty-crate tracking (§3.13) ────────────────────────────────────
/// Records crate receipts/returns against a supplier (with deposits).
final supplierCrateServiceProvider = Provider<SupplierCrateService>((ref) {
  return SupplierCrateService(ref.read(databaseProvider));
});

/// One supplier's per-manufacturer crate balances, live. A positive balance =
/// WE owe the supplier that many empties; negative = a crate credit.
/// Business-wide (crate debt is between the store and the supplier, not a store).
final supplierCrateBalancesProvider = StreamProvider.autoDispose
    .family<List<SupplierCrateBalanceWithManufacturer>, String>((ref, id) {
      return ref
          .read(databaseProvider)
          .supplierCrateBalancesDao
          .watchBySupplier(id);
    });

/// One supplier's net refundable deposit still held by them (kobo), live.
final supplierCrateDepositHeldProvider = StreamProvider.autoDispose
    .family<int, String>((ref, id) {
      return ref
          .read(databaseProvider)
          .supplierCrateLedgerDao
          .watchDepositHeldKobo(id);
    });

/// One supplier's cumulative crates received from / returned (sent back) to
/// them — running totals, not the net balance.
final supplierCrateMovementTotalsProvider = StreamProvider.autoDispose
    .family<({int received, int returned}), String>((ref, id) {
      return ref
          .read(databaseProvider)
          .supplierCrateLedgerDao
          .watchMovementTotals(id);
    });

/// One supplier's empty-crate movement history (receipts + returns), newest
/// first.
final supplierCrateHistoryProvider = StreamProvider.autoDispose
    .family<List<SupplierCrateLedgerEntryData>, String>((ref, id) {
      return ref
          .read(databaseProvider)
          .supplierCrateLedgerDao
          .watchHistory(id);
    });

// ── Delivery receipts (rider hand-off on customer orders, §orders) ───────────
final deliveryReceiptServiceProvider =
    ChangeNotifierProvider<DeliveryReceiptService>((ref) {
      return DeliveryReceiptService();
    });

// Expenses are persisted/synced via ExpensesDao (§20); the old in-memory
// ExpenseService stub was removed in Session 59.

// ── Payment ─────────────────────────────────────────────────────────────────
final paymentServiceProvider = ChangeNotifierProvider<PaymentService>((ref) {
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
    ref.read(secureStorageProvider),
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
      return (db.select(
        db.pendingCrateReturns,
      )..where((t) => t.status.equals('pending'))).watch();
    });

class PendingReturnWithDetails {
  final PendingCrateReturnData returnRow;
  final CustomerData customer;
  // v29: crate returns are keyed by manufacturer (§13.4).
  final ManufacturerData manufacturer;
  PendingReturnWithDetails({
    required this.returnRow,
    required this.customer,
    required this.manufacturer,
  });
}

final pendingReturnsWithDetailsProvider =
    StreamProvider.autoDispose<List<PendingReturnWithDetails>>((ref) {
      final db = ref.read(databaseProvider);
      final query = db.select(db.pendingCrateReturns).join([
        innerJoin(
          db.customers,
          db.customers.id.equalsExp(db.pendingCrateReturns.customerId),
        ),
        innerJoin(
          db.manufacturers,
          db.manufacturers.id.equalsExp(db.pendingCrateReturns.manufacturerId),
        ),
      ])..where(db.pendingCrateReturns.status.equals('pending'));

      return query.watch().map(
        (rows) => rows
            .map(
              (r) => PendingReturnWithDetails(
                returnRow: r.readTable(db.pendingCrateReturns),
                customer: r.readTable(db.customers),
                manufacturer: r.readTable(db.manufacturers),
              ),
            )
            .toList(),
      );
    });

final localBusinessesProvider = StreamProvider.autoDispose<List<BusinessData>>((
  ref,
) {
  final db = ref.read(databaseProvider);
  return db.select(db.businesses).watch();
});

/// The active business row, live. Resolves [localBusinessesProvider] against
/// the bound `currentBusinessId` (a device can hold more than one business's
/// data). Used wherever the business name must reflect a Business Info rename
/// (§10.1) immediately — receipts (§15.1), onboarding welcome, etc.
final currentBusinessProvider = Provider.autoDispose<BusinessData?>((ref) {
  final id = ref.watch(databaseProvider).currentBusinessId;
  final list = ref.watch(localBusinessesProvider).valueOrNull ?? const [];
  if (list.isEmpty) return null;
  if (id != null) {
    for (final b in list) {
      if (b.id == id) return b;
    }
  }
  // No bound id, or it didn't match a local row: only guess when there's
  // exactly ONE business (unambiguous). With more than one business on the
  // device, returning null avoids surfacing the WRONG business's name (§7.2a).
  return list.length == 1 ? list.first : null;
});

/// The active business name, live (see [currentBusinessProvider]). Empty when
/// no business is bound yet.
final currentBusinessNameProvider = Provider.autoDispose<String>((ref) {
  return ref.watch(currentBusinessProvider)?.name ?? '';
});

/// Lifts the `SupabaseSyncService.pullStatus` ValueNotifier into Riverpod
/// so the MainLayout catch-up banner (and SyncIssues) can `ref.watch` it.
/// Mirrors the pattern used for the `isOnline` ValueNotifier (read directly
/// from the service in `app_drawer.dart`).
final pullStatusProvider = ChangeNotifierProvider<ValueNotifier<PullStatus>>((
  ref,
) {
  return ref.watch(supabaseSyncServiceProvider).pullStatus;
});
