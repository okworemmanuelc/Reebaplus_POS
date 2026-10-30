import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reebaplus_pos/core/crates/crate_deposit_position.dart';
import 'package:reebaplus_pos/core/crates/crate_shortage.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/online_order_providers.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/settings/vat_settings.dart';
import 'package:reebaplus_pos/features/dashboard/reconciliation/recon_data.dart';

/// Thin provider-reading adapter for the reconciliation engine: reads the
/// providers, builds [ReconInputs], and hands them to the pure engine
/// ([reconcile]). No arithmetic belongs here (#574).

/// The store-scope predicate shared by every reconciliation read: the §12.1
/// active store (a concrete store), else the viewer's full selectable set
/// ("All Stores" for an all-stores viewer; a confined Manager's assigned stores).
///
/// **Vans are out of scope** (#140, van-sales spec §8.1). Road sales are
/// recognised as revenue when the driver rings them, but they carry no cost
/// against them until the trip closes, so letting them into the All-Stores
/// aggregate would inflate every figure this filter guards. They surface
/// instead as one aggregated "Van Sales" line (#147). Note this is about
/// *revenue and per-store figures* only: van **stock** still counts towards
/// All-Stores inventory value and business worth (§4.1), which is why
/// `inventoryOnHandKobo` below is scoped by the locked store — or unscoped on a
/// [businessWide] compute — rather than by this predicate.
///
/// [businessWide] is the DAY-CLOSE basis (#191, ADR 0022): it ignores both the
/// active lock and the viewer's confinement, so every store in the business
/// counts. A persisted day close is ONE durable record of what the whole
/// business's day looked like, and it is FIRST-WRITER-WINS — whoever opens the
/// finished day first must therefore freeze the same figures, whatever store
/// they happened to be locked to. Vans stay out even here: business-wide is not
/// "vans too".
bool Function(String?) reconStoreFilter(
  WidgetRef ref, {
  bool businessWide = false,
}) {
  final selectableIds = ref
      .watch(selectableStoresProvider)
      .map((s) => s.id)
      .toSet();
  final canAll = ref.watch(canViewAllStoresProvider);
  final active = ref.watch(lockedStoreProvider).value;
  final vans = ref.watch(vanStoresProvider);
  final wide = businessWideStoreFilter(vans);
  return (storeId) {
    if (!wide(storeId)) return false; // vans are out at every scope
    if (businessWide) return true; // the whole business (incl. legacy null-store)
    if (active != null) return storeId == active;
    if (canAll) return true; // All-Stores aggregate (incl. legacy null-store)
    return storeId != null && selectableIds.contains(storeId);
  };
}

/// Full reconciliation roll-up for `[start, endExclusive)` in the active store
/// scope. `isCeo` only gates the supplier-ledger flows (the rest is computed
/// either way; the screen decides which figures to show per the cost wall).
///
/// [businessWide] computes the whole business instead — the basis a persisted
/// day close freezes and compares against (#191, ADR 0022). It ignores the
/// active lock and the viewer's confinement (see [reconStoreFilter]) and reads
/// the UNSCOPED stock totals, so the frozen record never depends on which store
/// the first opener happened to be in. Every other caller wants the default.
///
/// This is the **gather** half only (#195): every `ref.watch` lives here and the
/// arithmetic lives in the pure [reconDataFrom]. Keep it that way — a provider
/// read that sneaks into the math is a figure that can no longer be tested.
ReconData computeReconData(
  WidgetRef ref, {
  DateTime? start,
  DateTime? endExclusive,
  required bool isCeo,
  bool businessWide = false,
}) {
  // Inventory-on-hand must honour the active-store scope like every other
  // figure here (§12.1): pass the locked store so a single-store view doesn't
  // sum every store's stock (null = All Stores). The products list itself is
  // unaffected — only the stock totals are store-filtered — so `productById`
  // (used for damage/shortage/surplus cost lookups) stays complete.
  // A business-wide compute (#191) reads the unscoped totals, matching its
  // store predicate below.
  final storeScope =
      businessWide ? null : ref.watch(lockedStoreProvider).value;
  // Crate reads stay behind the opt-in gate, so a business that tracks no
  // crates opens no crate stream at all (the conditional watch is deliberate).
  final showCrates = businessTracksCrates(ref.watch(currentBusinessProvider));
  return reconDataFrom(
    ReconInputs(
      orders: ref.watch(allOrdersProvider).valueOrNull ?? const [],
      expenses: ref.watch(allExpensesProvider).valueOrNull ?? const [],
      adjustments:
          ref.watch(allStockAdjustmentsProvider).valueOrNull ?? const [],
      supplierLedger:
          ref.watch(allSupplierLedgerEntriesProvider).valueOrNull ?? const [],
      payments:
          ref.watch(allPaymentTransactionsProvider).valueOrNull ?? const [],
      stockTxns:
          ref.watch(allStockTransactionsProvider).valueOrNull ?? const [],
      stockCounts: ref.watch(allStockCountsProvider).valueOrNull ?? const [],
      productsWithStock:
          ref.watch(productsWithStockProvider(storeScope)).valueOrNull ??
          const [],
      creditBalancesKobo:
          ref.watch(creditBalancesKoboProvider).valueOrNull ?? const {},
      manufacturers:
          ref.watch(allManufacturersProvider).valueOrNull ?? const [],
      emptyCrateCounts:
          ref.watch(emptyCratesByManufacturerProvider).valueOrNull ?? const {},
      crateDamages: ref.watch(allCrateDamagesProvider).valueOrNull ?? const [],
      usersById: ref.watch(usersByBusinessProvider).valueOrNull ?? const {},
      inTransitTransfers:
          ref.watch(allInTransitTransfersProvider).valueOrNull ?? const [],
      vanTrips: ref.watch(allVanTripsProvider).valueOrNull ?? const [],
      crateForfeitRows: showCrates
          ? (ref.watch(crateForfeitRowsProvider).valueOrNull ?? const [])
          : const [],
      vat: ref.watch(vatConfigProvider).valueOrNull ?? VatConfig.off,
      showCrates: showCrates,
      heldCrateDepositsKobo: showCrates
          ? (ref.watch(crateDepositSummaryProvider).valueOrNull?.heldKobo ?? 0)
          : 0,
      supplierCrateDebtKobo: showCrates
          ? (ref.watch(supplierCrateDebtValueKoboProvider).valueOrNull ?? 0)
          : 0,
      // #215 — business-wide by design. Note the absence of a store read here:
      // unlike the stock totals above, this is NOT scoped by `storeScope`, and
      // `businessWide` makes no difference to it either. The depot invoices the
      // business, not the branch.
      crateDeposits: showCrates
          ? (ref.watch(businessCrateDepositRollupProvider).valueOrNull ??
                CrateDepositRollup.empty)
          : CrateDepositRollup.empty,
      // #296 — the count-based shortage, in the SAME store scope as the
      // manufacturer screen: shortage belongs to the store whose count found it.
      crateShortages: showCrates
          ? (ref.watch(crateShortageRollupProvider(storeScope)).valueOrNull ??
                CrateShortageRollup.empty)
          : CrateShortageRollup.empty,
      crateShortfallWriteOffs: showCrates
          ? (ref.watch(crateShortfallWriteOffsProvider).valueOrNull ?? const [])
          : const [],
      payOnDelivery:
          ref.watch(payOnDeliveryOrdersProvider).valueOrNull ?? const [],
      isCeo: isCeo,
      inScope: reconStoreFilter(ref, businessWide: businessWide),
      start: start,
      endExclusive: endExclusive,
    ),
  );
}
