import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:reebaplus_pos/core/crates/crate_bearing_sale.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/business_scoped_stream.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';

/// Data behind the redesigned driver screens (#729). Read-only: every figure
/// here is derived from rows the app already syncs; nothing writes.

/// Each of a trip's sales → is its `pos_record_sale_v2` envelope still in this
/// device's outbox? Re-read whenever the outbox moves, so Waiting flips to Sent
/// the moment the sale goes up. Reuses `SyncDao.saleEnvelopeState` so "is this
/// sale up?" keeps ONE definition in the codebase.
final driverTripSaleStatesProvider =
    businessScopedStreamFamily<Map<String, SaleEnvelopeState>, String>(
      (ref, db, businessId, tripId) {
        final orders =
            ref.watch(vanTripSalesProvider(tripId)).valueOrNull ??
            const <OrderData>[];
        return db.syncDao.watchPendingCount().asyncMap((_) async {
          return {
            for (final o in orders)
              o.id: await db.syncDao.saleEnvelopeState(o.id),
          };
        });
      },
      whenAbsent: const {},
    );

/// The sync service's online flag, behind a provider so tests can override it.
final driverOnlineListenableProvider = Provider<ValueListenable<bool>>(
  (ref) => ref.read(supabaseSyncServiceProvider).isOnline,
);

/// The signed-in driver's name for the header subtitle (a provider so tests
/// need not build an `AuthService`).
final driverDisplayNameProvider = Provider<String>(
  (ref) => ref.watch(authProvider).currentUser?.name ?? '',
);

/// "Offline · 3 waiting" chip text, or null when there is nothing to say
/// (online and nothing queued).
String? driverSyncChipLabel({required bool online, required int pending}) {
  if (!online) return pending > 0 ? 'Offline · $pending waiting' : 'Offline';
  if (pending > 0) return '$pending waiting';
  return null;
}

/// One line of a sale being built, as far as the empties note cares.
typedef DriverSaleLine = ({
  String name,
  int units,
  String? unit,
  bool trackEmpties,
});

/// The "Collect N empty crates" figures: how many crate-tracked units are in
/// the sale, and the "3 Heineken 60cl and 2 Tiger 50cl" sentence naming them.
/// Zero / null unless the business tracks crates and a line is a crate-tracked
/// bottle (cans and packs need no empties).
({int count, String? names}) driverCrateEmpties({
  required bool businessTracksCrates,
  required Iterable<DriverSaleLine> lines,
}) {
  if (!businessTracksCrates) return (count: 0, names: null);
  final crate = [
    for (final l in lines)
      if (l.units > 0 &&
          isCrateTrackedBottle((unit: l.unit, trackEmpties: l.trackEmpties)))
        l,
  ];
  final count = crate.fold<int>(0, (s, l) => s + l.units);
  if (count == 0) return (count: 0, names: null);
  final parts = [for (final l in crate) '${l.units} ${l.name}'];
  final names = parts.length == 1
      ? parts.first
      : '${parts.sublist(0, parts.length - 1).join(', ')} and ${parts.last}';
  return (count: count, names: names);
}

/// The My Trip "You owe" breakdown, from the trip's own ledger rows plus the
/// driver's older rows. A READ of existing ledger types: no new money rule.
class DriverTripFigures {
  final int loadedKobo;
  final int loadCount;

  /// Positive = still owed from before this trip.
  final int carriedKobo;
  final int returnedKobo;
  final int handedInKobo;

  const DriverTripFigures({
    required this.loadedKobo,
    required this.loadCount,
    required this.carriedKobo,
    required this.returnedKobo,
    required this.handedInKobo,
  });
}

DriverTripFigures driverTripFigures({
  required String tripId,
  required List<DriverLedgerEntryData> driverHistory,
  required List<VanTripLotData> lots,
}) {
  var loaded = 0, returned = 0, handedIn = 0, carried = 0;
  for (final e in driverHistory) {
    if (e.tripId != tripId) {
      carried -= e.signedAmountKobo;
      continue;
    }
    switch (e.type) {
      case kDriverLedgerTypeLoad:
      case kDriverLedgerTypeRestock:
        loaded += e.amountKobo;
      case kDriverLedgerTypeReturnGood:
        returned += e.amountKobo;
      case kDriverLedgerTypePaymentCash:
      case kDriverLedgerTypePaymentTransfer:
        handedIn += e.amountKobo;
    }
  }
  final loads = {for (final l in lots) l.dispatchedAt}.length;
  return DriverTripFigures(
    loadedKobo: loaded,
    loadCount: loads,
    carriedKobo: carried,
    returnedKobo: returned,
    handedInKobo: handedIn,
  );
}

/// Pure sale-line facts for tests and the screens: "All N on your van are in
/// this sale" holds when the sale already takes every unit that is on the van.
bool driverAllInSale({required int units, required int onVan}) =>
    onVan > 0 && units >= onVan;

/// #730 — one sale line at checkout: units, the LOAD price, and the price the
/// driver chose to sell at (never below the load price).
typedef DriverPricedLine = ({int units, int loadPriceKobo, int sellPriceKobo});

/// The three checkout money figures. The shop only ever sees [loadValueKobo];
/// [extraKobo] is the driver's, recorded apart (ADR 0019).
typedef DriverCheckoutFigures = ({
  int customerPaysKobo,
  int loadValueKobo,
  int extraKobo,
});

/// A selling price clamped up to the load price: the box cannot go below it.
int driverSellPriceKobo({required int loadPriceKobo, int? typedKobo}) =>
    (typedKobo == null || typedKobo < loadPriceKobo)
    ? loadPriceKobo
    : typedKobo;

/// customer pays = Σ sell × units; load value = Σ load × units (what the driver
/// hands in); extra = the difference.
DriverCheckoutFigures driverCheckoutFigures(List<DriverPricedLine> lines) {
  var pays = 0;
  var load = 0;
  for (final l in lines) {
    pays += l.sellPriceKobo * l.units;
    load += l.loadPriceKobo * l.units;
  }
  return (customerPaysKobo: pays, loadValueKobo: load, extraKobo: pays - load);
}
