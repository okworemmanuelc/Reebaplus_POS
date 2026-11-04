// driver_terminal_screen_test.dart
//
// #729 — the redesigned driver terminal: two-tab shell, the "all N are in this
// sale" cap, the empties note, the no-open-trip state, and the outbox-driven
// chip / Waiting-Sent marks. Provider-overridden widget tests: no database
// beyond the in-memory product rows, no network.

import 'dart:async';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/permissions/gate.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/business_scoped_stream.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/van_sales/van_sales_switch.dart';
import 'package:reebaplus_pos/features/van_sales/driver_terminal_data.dart';
import 'package:reebaplus_pos/features/van_sales/screens/driver_terminal_screen.dart';
import 'package:reebaplus_pos/shared/widgets/frame/frame_nav.dart';

import '../helpers/dispatch_test_utils.dart';

BusinessData _business({required String type}) => BusinessData(
  id: 'biz-1',
  name: 'Test Business',
  type: type,
  phone: null,
  email: null,
  logoUrl: null,
  timezone: 'Africa/Lagos',
  onboardingComplete: true,
  createdAt: DateTime.utc(2026, 1, 1),
  lastUpdatedAt: DateTime.utc(2026, 1, 1),
  ownerId: null,
  tracksEmptyCrates: true,
  sellsOnePrice: false,
  subscriptionStatus: 'active',
  subscriptionPlan: null,
  trialEndsAt: null,
  currentPeriodEnd: null,
);

VanTripData _trip() => VanTripData(
  id: 'trip-1',
  businessId: 'biz-1',
  vanStoreId: 'van-1',
  driverUserId: 'driver-1',
  sourceStoreId: 'wh-1',
  status: kVanTripStatusOpen,
  openedAt: DateTime.now(),
  openedBy: 'mgr',
  closedAt: null,
  closedBy: null,
  closedWithBalance: false,
  shellsOut: 0,
  shellsBack: 0,
  restatedAt: null,
  restatedReason: null,
  cogsKobo: 0,
  recoveredKobo: 0,
  unremittedKobo: 0,
  shortageWriteoffKobo: 0,
  damageWriteoffKobo: 0,
  shortageLossKobo: 0,
  damageLossKobo: 0,
  profitKobo: 0,
  createdAt: DateTime.now(),
  lastUpdatedAt: DateTime.now(),
);

const _driverCtx = GateContext(
  grantedKeys: {'van.sell'},
  roleRank: GateTier.driver,
  isReady: true,
);

/// Real product rows (the table has too many required columns to hand-build).
Future<List<ProductData>> _products(WidgetTester tester) async {
  late List<ProductData> out;
  await tester.runAsync(() async {
    final boot = await bootstrapTestDb();
    final db = boot.db;
    Future<void> add(String id, String name, String unit, bool empties) =>
        db.into(db.products).insert(
          ProductsCompanion.insert(
            id: Value(id),
            businessId: boot.businessId,
            name: name,
            retailerPriceKobo: const Value(1000000),
            unit: Value(unit),
            trackEmpties: Value(empties),
          ),
        );
    await add('p-bottle', 'Heineken 60cl', 'Bottle', true);
    await add('p-can', 'Desperados Can', 'Pack', false);
    await add('p-none', 'Tiger Can', 'Pack', false);
    out = await db.select(db.products).get();
    await db.close();
  });
  return out;
}

void _phone(WidgetTester tester) {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

void _tablet(WidgetTester tester) {
  tester.view.physicalSize = const Size(1280, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

Future<void> _pump(
  WidgetTester tester, {
  required List<ProductData> products,
  required String businessType,
  VanTripData? trip,
  int pending = 0,
  bool online = true,
  Map<String, SaleEnvelopeState> states = const {},
}) async {
  final byId = {for (final p in products) p.id: p};
  final stock = [
    ProductDataWithStock(product: byId['p-bottle']!, totalStock: 18),
    ProductDataWithStock(product: byId['p-can']!, totalStock: 2),
    ProductDataWithStock(product: byId['p-none']!, totalStock: 0),
  ];
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        gateContextProvider.overrideWithValue(_driverCtx),
        currentBusinessIdProvider.overrideWithValue(null),
        currentBusinessProvider.overrideWith(
          (ref) => _business(type: businessType),
        ),
        driverDisplayNameProvider.overrideWithValue('Musa Bello'),
        currentUserIdProvider.overrideWithValue('driver-1'),
        driverOnlineListenableProvider.overrideWithValue(
          ValueNotifier<bool>(online),
        ),
        pendingQueueCountProvider.overrideWith((ref) => Stream.value(pending)),
        currentDriverTripProvider.overrideWith((ref) => Stream.value(trip)),
        if (trip != null) ...[
          vanTripProvider(trip.id).overrideWith((ref) => Stream.value(trip)),
          vanTripLoadPricesProvider(trip.id).overrideWith(
            (ref) => Stream.value(const {
              'p-bottle': 1750000,
              'p-can': 2160000,
              'p-none': 1920000,
            }),
          ),
          productsWithStockProvider(
            trip.vanStoreId,
          ).overrideWith((ref) => Stream.value(stock)),
          driverTripSaleStatesProvider(
            trip.id,
          ).overrideWith((ref) => Stream.value(states)),
          vanTripPendingSalesProvider(trip.id).overrideWith(
            (ref) => Stream.value(
              states.values.where((s) => s == SaleEnvelopeState.pending).length,
            ),
          ),
        ],
      ],
      child: MaterialApp(
        theme: AppTheme.light(),
        home: const DriverTerminalScreen(),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
}

void main() {
  setUpAll(() => debugOverrideVanSalesEnabled(true));

  group('pure helpers', () {
    test('empties count only crate-tracked bottles, and only when tracked', () {
      const lines = <DriverSaleLine>[
        (name: 'Heineken 60cl', units: 3, unit: 'bottle', trackEmpties: true),
        (name: 'Tiger 50cl', units: 2, unit: 'Bottle', trackEmpties: true),
        (name: 'Desperados Can', units: 2, unit: 'pack', trackEmpties: false),
        (name: 'Loose bottle', units: 4, unit: 'bottle', trackEmpties: false),
      ];
      final on = driverCrateEmpties(businessTracksCrates: true, lines: lines);
      expect(on.count, 5);
      expect(on.names, '3 Heineken 60cl and 2 Tiger 50cl');
      final off = driverCrateEmpties(businessTracksCrates: false, lines: lines);
      expect(off.count, 0);
      expect(off.names, isNull);
    });

    test('all-in-sale holds only when units reach what is on the van', () {
      expect(driverAllInSale(units: 2, onVan: 2), isTrue);
      expect(driverAllInSale(units: 1, onVan: 2), isFalse);
      expect(driverAllInSale(units: 0, onVan: 0), isFalse);
    });

    test('sync chip reads the outbox state', () {
      expect(
        driverSyncChipLabel(online: false, pending: 3),
        'Offline · 3 waiting',
      );
      expect(driverSyncChipLabel(online: true, pending: 0), isNull);
      expect(driverSyncChipLabel(online: true, pending: 2), '2 waiting');
    });
  });

  group('no open trip', () {
    testWidgets('says the driver cannot sell yet, with Check Again', (
      tester,
    ) async {
      _phone(tester);
      final products = await _products(tester);
      await _pump(tester, products: products, businessType: 'Bar');

      expect(find.text('No open trip'), findsOneWidget);
      expect(find.textContaining("You can't sell yet"), findsOneWidget);
      expect(find.text('Check Again'), findsOneWidget);
      expect(find.text('YOUR VAN'), findsOneWidget);
      expect(find.text('Checkout'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  group('Sell and My Trip tabs', () {
    testWidgets('the bottom bar switches between Sell and My Trip', (
      tester,
    ) async {
      _phone(tester);
      final products = await _products(tester);
      await _pump(
        tester,
        products: products,
        businessType: 'Bar',
        trip: _trip(),
      );

      expect(find.text('Search products on your van'), findsOneWidget);
      expect(find.text('Sold this trip'), findsNothing);

      await tester.tap(find.byKey(frameNavItemKey(1)));
      await tester.pump();
      await tester.pump();

      expect(find.text('You owe'), findsOneWidget);
      expect(find.text('Sold this trip'), findsOneWidget);
      expect(find.text('Left on your van'), findsOneWidget);
      expect(find.text('My Trip'), findsWidgets);
      expect(find.text('My run'), findsNothing);

      await tester.tap(find.byKey(frameNavItemKey(0)));
      await tester.pump();
      expect(find.text('Search products on your van'), findsOneWidget);
    });

    testWidgets('a tablet shows the side rail with both tabs', (tester) async {
      _tablet(tester);
      final products = await _products(tester);
      await _pump(
        tester,
        products: products,
        businessType: 'Bar',
        trip: _trip(),
      );

      expect(find.byType(FrameNavRail), findsOneWidget);
      expect(find.byType(FrameBottomBar), findsNothing);
      expect(
        find.textContaining('This sale', findRichText: true),
        findsOneWidget,
      );
      await tester.tap(find.byKey(frameNavItemKey(1)));
      await tester.pump();
      await tester.pump();
      expect(find.text('Sold this trip'), findsOneWidget);
    });
  });

  group('Sell', () {
    testWidgets('all N in this sale disables +, and none-left stays listed', (
      tester,
    ) async {
      _phone(tester);
      final products = await _products(tester);
      await _pump(
        tester,
        products: products,
        businessType: 'Bar',
        trip: _trip(),
      );

      // The sold-out product stays in the list, labelled.
      expect(find.text('Tiger Can'), findsOneWidget);
      expect(find.text('None left'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('van-add-p-can')));
      await tester.pump();
      expect(find.text('All 2 on your van are in this sale.'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('van-plus-p-can')));
      await tester.pump();

      expect(find.text('All 2 on your van are in this sale.'), findsOneWidget);
      // The + is now inert: tapping it cannot push the count past what is on
      // the van.
      await tester.tap(find.byKey(const ValueKey('van-plus-p-can')));
      await tester.pump();
      expect(find.text('3'), findsNothing);
      // 2 packs at the load price of 21,600 each.
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('van-sell-total'))).data,
        contains('43,200'),
      );
    });

    testWidgets('the empties note counts crate-tracked units in the sale', (
      tester,
    ) async {
      _phone(tester);
      final products = await _products(tester);
      await _pump(
        tester,
        products: products,
        businessType: 'Bar',
        trip: _trip(),
      );

      // 3 crates of Heineken + 1 pack (a pack needs no empties).
      await tester.tap(find.byKey(const ValueKey('van-add-p-bottle')));
      await tester.pump();
      for (var i = 0; i < 2; i++) {
        await tester.tap(find.byKey(const ValueKey('van-plus-p-bottle')));
        await tester.pump();
      }
      await tester.tap(find.byKey(const ValueKey('van-add-p-can')));
      await tester.pump();

      await tester.tap(find.byKey(const ValueKey('van-checkout')));
      await tester.pump();

      expect(find.text('Cash sale · Walk-in customer'), findsOneWidget);
      expect(find.text('Collect 3 empty crates'), findsOneWidget);
      expect(
        find.textContaining('3 Heineken 60cl. Take one empty back'),
        findsOneWidget,
      );
      expect(find.textContaining('Complete Sale'), findsOneWidget);
    });

    testWidgets('no empties note for a business that does not track crates', (
      tester,
    ) async {
      _phone(tester);
      final products = await _products(tester);
      await _pump(
        tester,
        products: products,
        businessType: 'Pharmacy',
        trip: _trip(),
      );

      await tester.tap(find.byKey(const ValueKey('van-add-p-bottle')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('van-checkout')));
      await tester.pump();

      expect(find.byKey(const ValueKey('van-crates-note')), findsNothing);
    });
  });

  group('outbox', () {
    testWidgets('the chip reads offline + the real waiting count', (
      tester,
    ) async {
      _phone(tester);
      final products = await _products(tester);
      await _pump(
        tester,
        products: products,
        businessType: 'Bar',
        trip: _trip(),
        pending: 3,
        online: false,
      );
      expect(find.text('Offline · 3 waiting'), findsOneWidget);
    });

    testWidgets('no chip when online with nothing queued', (tester) async {
      _phone(tester);
      final products = await _products(tester);
      await _pump(
        tester,
        products: products,
        businessType: 'Bar',
        trip: _trip(),
      );
      expect(find.byKey(const ValueKey('van-sync-chip')), findsNothing);
    });

    testWidgets('My Trip shows the waiting banner from the outbox', (
      tester,
    ) async {
      _phone(tester);
      final products = await _products(tester);
      await _pump(
        tester,
        products: products,
        businessType: 'Bar',
        trip: _trip(),
        pending: 2,
        states: const {
          'o1': SaleEnvelopeState.pending,
          'o2': SaleEnvelopeState.pending,
        },
      );
      await tester.tap(find.byKey(frameNavItemKey(1)));
      await tester.pump();
      await tester.pump();
      expect(find.text('2 sales waiting to send'), findsOneWidget);
    });
  });
}
