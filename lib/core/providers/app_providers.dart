/// Riverpod providers — all services constructed via ref.read().
///
/// Only `database` and `themeController` remain as globals because they
/// must be initialised before `runApp()`. Everything else is constructed
/// here with proper dependency injection.
library;

import 'dart:async';

import 'package:drift/drift.dart' show innerJoin;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:reebaplus_pos/core/data/business_types.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/providers/business_scoped_stream.dart';
import 'package:reebaplus_pos/core/services/biometric_service.dart';
import 'package:reebaplus_pos/core/services/business_logo_service.dart';
import 'package:reebaplus_pos/core/services/product_image_service.dart';
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
import 'package:reebaplus_pos/shared/services/orders/order_service.dart';
import 'package:reebaplus_pos/shared/services/supplier_account_service.dart';
import 'package:reebaplus_pos/shared/services/receive_stock_service.dart';
import 'package:reebaplus_pos/shared/services/supplier_crate_service.dart';
import 'package:reebaplus_pos/shared/services/printer_service.dart';
import 'package:reebaplus_pos/shared/services/reorder_alert_service.dart';
import 'package:reebaplus_pos/core/diagnostics/sync_diagnostic.dart';
import 'package:reebaplus_pos/core/services/supabase_cloud_transport.dart';
import 'package:reebaplus_pos/core/services/supabase_sync_service.dart';
import 'package:reebaplus_pos/main.dart' show googleWebClientId;

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
    googleWebClientId: googleWebClientId,
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

/// Map of customerId → signed credits balance (kobo), computed live from the
/// WalletTransactions ledger. Replaces the cached `customers.wallet_balance_kobo`
/// column that PR 2a removed.
final creditBalancesKoboProvider =
    businessScopedStreamAutoDispose<Map<String, int>>(
  (ref, db, businessId) => db.customersDao.watchAllWalletBalancesKobo(),
  whenAbsent: const {},
);

/// §13.4 Ring 7 — business-wide crate-deposit balancing figures
/// (taken / refunded / kept / held). Held = taken − refunded − kept.
final crateDepositSummaryProvider =
    businessScopedStreamAutoDispose<CrateDepositSummary>(
  (ref, db, businessId) =>
      db.walletTransactionsDao.watchCrateDepositSummary(),
  whenAbsent: const CrateDepositSummary(
    takenKobo: 0,
    refundedKobo: 0,
    keptKobo: 0,
    heldKobo: 0,
  ),
);

/// §13.4 Ring 7 — per-customer held deposit (kobo); only non-zero holders.
final depositsHeldByCustomerProvider =
    businessScopedStreamAutoDispose<Map<String, int>>(
  (ref, db, businessId) =>
      db.walletTransactionsDao.watchDepositsHeldByCustomer(),
  whenAbsent: const {},
);

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
    businessScopedStreamAutoDispose<Map<String, int>>(
  (ref, db, businessId) {
    final storeId = ref.watch(lockedStoreProvider).value;
    return db.supplierLedgerDao.watchAllBalancesKobo(storeId: storeId);
  },
  whenAbsent: const {},
);

/// One supplier row, live (Supplier Details header). Null once soft-deleted.
final supplierByIdProvider =
    businessScopedStreamAutoDisposeFamily<SupplierData?, String>(
  (ref, db, businessId, id) => db.catalogDao.watchSupplierById(id),
  whenAbsent: null,
);

/// One supplier's signed ledger balance (kobo), live. Active-store scoped (§21.11).
final supplierBalanceProvider =
    businessScopedStreamAutoDisposeFamily<int, String>(
  (ref, db, businessId, id) {
    final storeId = ref.watch(lockedStoreProvider).value;
    return db.supplierLedgerDao.watchBalanceKobo(id, storeId: storeId);
  },
  whenAbsent: 0,
);

/// One supplier's full ledger history (invoices + payments + voids), newest
/// first. Active-store scoped (§21.11).
final supplierLedgerHistoryProvider =
    businessScopedStreamAutoDisposeFamily<List<SupplierLedgerEntryData>, String>(
  (ref, db, businessId, id) {
    final storeId = ref.watch(lockedStoreProvider).value;
    return db.supplierLedgerDao.watchHistory(id, storeId: storeId);
  },
  whenAbsent: const [],
);

/// Every ledger entry (invoices + payments + voids) across all suppliers,
/// newest first — drives the Transaction history screen. Active-store scoped
/// (§21.11); null lock = "All Stores" aggregate.
final supplierAllHistoryProvider =
    businessScopedStreamAutoDispose<List<SupplierLedgerEntryData>>(
  (ref, db, businessId) {
    final storeId = ref.watch(lockedStoreProvider).value;
    return db.supplierLedgerDao.watchAllHistory(storeId: storeId);
  },
  whenAbsent: const [],
);

// ── Supplier empty-crate tracking (§3.13) ────────────────────────────────────
/// Records crate receipts/returns against a supplier (with deposits).
final supplierCrateServiceProvider = Provider<SupplierCrateService>((ref) {
  return SupplierCrateService(ref.read(databaseProvider));
});

/// One supplier's per-manufacturer crate balances, live. A positive balance =
/// WE owe the supplier that many empties; negative = a crate credit.
/// Business-wide (crate debt is between the store and the supplier, not a store).
final supplierCrateBalancesProvider =
    businessScopedStreamAutoDisposeFamily<
        List<SupplierCrateBalanceWithManufacturer>, String>(
  (ref, db, businessId, id) => db.supplierCrateBalancesDao.watchBySupplier(id),
  whenAbsent: const [],
);

/// One supplier's net refundable deposit still held by them (kobo), live.
final supplierCrateDepositHeldProvider =
    businessScopedStreamAutoDisposeFamily<int, String>(
  (ref, db, businessId, id) =>
      db.supplierCrateLedgerDao.watchDepositHeldKobo(id),
  whenAbsent: 0,
);

/// One supplier's cumulative crates received from / returned (sent back) to
/// them — running totals, not the net balance.
final supplierCrateMovementTotalsProvider =
    businessScopedStreamAutoDisposeFamily<({int received, int returned}),
        String>(
  (ref, db, businessId, id) => db.supplierCrateLedgerDao.watchMovementTotals(id),
  whenAbsent: (received: 0, returned: 0),
);

/// One supplier's empty-crate movement history (receipts + returns), newest
/// first.
final supplierCrateHistoryProvider =
    businessScopedStreamAutoDisposeFamily<List<SupplierCrateLedgerEntryData>,
        String>(
  (ref, db, businessId, id) => db.supplierCrateLedgerDao.watchHistory(id),
  whenAbsent: const [],
);

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
  final service = SupabaseSyncService(
    ref.read(databaseProvider),
    SupabaseCloudTransport(ref.read(supabaseClientProvider)),
    ref.read(secureStorageProvider),
  );
  // On connectivity recovery, upload any product photos saved offline and write
  // their public URLs onto the product rows (which then sync cross-device). #78.
  service.onReconnected = () {
    final db = ref.read(databaseProvider);
    final businessId = db.businessIdResolver.call();
    if (businessId == null) return;
    unawaited(
      ref.read(productImageServiceProvider).flushPending(
            businessId,
            (productId, url) => db.catalogDao.setProductImageUrl(productId, url),
          ),
    );
  };
  return service;
});

// ── Sync diagnostics ────────────────────────────────────────────────────────
final syncDiagnosticProvider = Provider<SyncDiagnostic>((ref) {
  return SyncDiagnostic(ref.read(databaseProvider));
});
// The `sync_queue` feeds filter by the current business (`whereBusiness`), so
// they are business-scoped and go through the factory. The `sync_queue_orphans`
// feeds carry no business_id column (device-local engine state) and stay raw.
final failedQueueItemsProvider =
    businessScopedStreamAutoDispose<List<SyncQueueData>>(
  (ref, db, businessId) => db.syncDao.watchFailedItems(),
  whenAbsent: const [],
);
final failedQueueCountProvider = businessScopedStreamAutoDispose<int>(
  (ref, db, businessId) => db.syncDao.watchFailedCount(),
  whenAbsent: 0,
);
final pendingQueueCountProvider = businessScopedStreamAutoDispose<int>(
  (ref, db, businessId) => db.syncDao.watchPendingCount(),
  whenAbsent: 0,
);
final pendingQueueItemsProvider =
    businessScopedStreamAutoDispose<List<SyncQueueData>>(
  (ref, db, businessId) => db.syncDao.watchPendingItems(),
  whenAbsent: const [],
);
// Device-local sync-engine state (no business_id column) — intentionally raw,
// allowlisted in the ban test. Not tenant-scoped, so it must NOT be forced
// through the factory.
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

// Intentionally UNSCOPED — a device may hold more than one business's row and
// [currentBusinessProvider] resolves the active one against the session id.
// Not a business-scoped stream; stays raw (allowlisted in the ban test).
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

/// Combined visibility gate for all empty-crate surfaces. True only when:
///  1. The business type is crate-eligible (Bar / Beverage distributor), AND
///  2. The CEO opted in to crate tracking at onboarding (tracksEmptyCrates=true).
///
/// Use this everywhere instead of calling [isCrateBusiness] directly. Pass the
/// [BusinessData] row from [currentBusinessProvider]. Returns false when null.
bool businessTracksCrates(BusinessData? business) {
  if (business == null) return false;
  if (!isCrateBusiness(business.type)) return false;
  return business.tracksEmptyCrates;
}

/// The active business name, live (see [currentBusinessProvider]). Empty when
/// no business is bound yet.
final currentBusinessNameProvider = Provider.autoDispose<String>((ref) {
  return ref.watch(currentBusinessProvider)?.name ?? '';
});

// ── Business Logo ──────────────────────────────────────────────────────────

final businessLogoServiceProvider = Provider<BusinessLogoService>((ref) {
  return BusinessLogoService(ref.read(supabaseClientProvider));
});

/// The local file path to the business logo, or null when no logo is set or
/// the cache is still being populated. Watches [currentBusinessProvider] so
/// it rebuilds when the business row updates (e.g. after a logo upload).
/// Calls [BusinessLogoService.ensureCached] once per businessId — downloads
/// from Storage on first use, then serves from the local file thereafter.
final currentBusinessLogoPathProvider =
    FutureProvider.autoDispose<String?>((ref) async {
      final business = ref.watch(currentBusinessProvider);
      if (business == null) return null;
      final svc = ref.read(businessLogoServiceProvider);
      return svc.ensureCached(
        businessId: business.id,
        logoUrl: business.logoUrl,
      );
    });

// ── Product Image (#78) ─────────────────────────────────────────────────────

final productImageServiceProvider = Provider<ProductImageService>((ref) {
  return ProductImageService(ref.read(supabaseClientProvider));
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

/// True while a user-initiated pull-to-refresh is in flight. The
/// `AppRefreshWrapper` orb is the sole animation for a manual pull, so
/// `SyncPullBanner` suppresses its top progress bar while this is set (the
/// banner's bar still drives automatic/background pulls, where there is no orb).
final manualPullActiveProvider = StateProvider<bool>((ref) => false);

/// True once the local Drift database has at least one product row — used as
/// the fresh-device gate signal. Distinct-filtered so it only notifies when
/// the boolean flips (empty → non-empty), keeping rebuilds cheap.
final hasLocalProductsProvider = businessScopedStream<bool>(
  (ref, db, businessId) => db.inventoryDao
      .watchAllProductDatasWithStock()
      .map((list) => list.isNotEmpty)
      .distinct(),
  whenAbsent: false,
);

/// True once the local Drift database has at least one order row for the
/// current business — the "Make a sale" milestone for the Get-started checklist
/// (issue #31 / Seam 3). Distinct-filtered in the DAO so it only notifies on the
/// empty → non-empty flip. Any order counts (see
/// [OrdersDao.watchAnyOrderExists]).
final hasAnyOrderProvider = businessScopedStream<bool>(
  (ref, db, businessId) => db.ordersDao.watchAnyOrderExists(),
  whenAbsent: false,
);
