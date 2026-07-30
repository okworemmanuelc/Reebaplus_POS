// recon_van_exclusion_test.dart
//
// #140 (PRD #139 / ADR 0019, van-sales spec §8.1) — `reconStoreFilter` is the
// store-scope predicate EVERY reconciliation read runs each row through (sales,
// discounts, refunds, expenses, damages, stock counts). Whatever it lets past
// is what the Daily Reconciliation and its detail screen report.
//
// Van orders must not get past it. Road revenue is recognised when the driver
// rings it, but it carries no cost against it until the trip closes, so an
// All-Stores aggregate that counted it would report road sales at 100% margin
// and inflate every downstream figure. It surfaces instead as one aggregated
// "Van Sales" line (#147).
//
// The filter is built from four provider reads, so these drive it through a
// real ProviderScope with those four overridden — the same seam
// `guarded_test.dart` uses for gates.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/stores/van_store.dart';
import 'package:reebaplus_pos/features/dashboard/reconciliation/recon_data.dart';

StoreData _store(String id, {String kind = kStoreKindStore}) => StoreData(
      id: id,
      businessId: 'biz',
      name: 'Location $id',
      location: null,
      kind: kind,
      isDeleted: false,
      createdAt: DateTime.utc(2026, 1, 1),
      lastUpdatedAt: DateTime.utc(2026, 1, 1),
    );

/// Pumps a throwaway consumer and hands back the built predicate.
Future<bool Function(String?)> buildFilter(
  WidgetTester tester, {
  required List<StoreData> allStores,
  required bool canViewAll,
  String? lockedStoreId,
}) async {
  late bool Function(String?) filter;
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        // The picker feed is already van-free (selectableStoresProvider filters
        // them), which is exactly why the predicate needs its own van check for
        // the All-Stores branch — that branch returns true for everything.
        selectableStoresProvider.overrideWithValue(withoutVans(allStores)),
        canViewAllStoresProvider.overrideWithValue(canViewAll),
        lockedStoreProvider
            .overrideWith((ref) => ValueNotifier<String?>(lockedStoreId)),
        vanStoresProvider.overrideWithValue(VanStores.of(allStores)),
      ],
      child: Consumer(
        builder: (_, ref, _) {
          filter = reconStoreFilter(ref);
          return const SizedBox.shrink();
        },
      ),
    ),
  );
  return filter;
}

void main() {
  const warehouse = 'wh';
  const branch = 'br';
  const van = 'van';

  final locations = [
    _store(warehouse),
    _store(branch),
    _store(van, kind: kStoreKindVan),
  ];

  testWidgets('All Stores: every store passes, the van never does',
      (tester) async {
    final inScope = await buildFilter(
      tester,
      allStores: locations,
      canViewAll: true,
    );

    expect(inScope(warehouse), isTrue);
    expect(inScope(branch), isTrue);
    expect(inScope(van), isFalse,
        reason: 'road revenue would otherwise inflate the All-Stores '
            'aggregate at zero cost against it');
    // A legacy, pre-store row still aggregates on All Stores (unchanged).
    expect(inScope(null), isTrue);
  });

  testWidgets('a locked concrete store: only that store', (tester) async {
    final inScope = await buildFilter(
      tester,
      allStores: locations,
      canViewAll: true,
      lockedStoreId: warehouse,
    );

    expect(inScope(warehouse), isTrue);
    expect(inScope(branch), isFalse);
    expect(inScope(van), isFalse);
    expect(inScope(null), isFalse);
  });

  testWidgets('a confined Manager: their stores only, never the van',
      (tester) async {
    final inScope = await buildFilter(
      tester,
      allStores: [_store(branch), _store(van, kind: kStoreKindVan)],
      canViewAll: false,
    );

    expect(inScope(branch), isTrue);
    expect(inScope(van), isFalse);
    expect(inScope(warehouse), isFalse);
    expect(inScope(null), isFalse);
  });

  testWidgets('the van is excluded even if it somehow became the locked store',
      (tester) async {
    // Defence in depth: `selectableStoresProvider` already stops a non-driver
    // locking a van, but the van check runs FIRST so a stale/hand-set lock can
    // never leak road figures into a per-store report either.
    final inScope = await buildFilter(
      tester,
      allStores: locations,
      canViewAll: true,
      lockedStoreId: van,
    );

    expect(inScope(van), isFalse);
  });

  testWidgets('a business with no vans behaves exactly as before',
      (tester) async {
    final inScope = await buildFilter(
      tester,
      allStores: [_store(warehouse), _store(branch)],
      canViewAll: true,
    );

    expect(inScope(warehouse), isTrue);
    expect(inScope(branch), isTrue);
    expect(inScope(null), isTrue);
  });
}
