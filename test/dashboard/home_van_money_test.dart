// home_van_money_test.dart
//
// #805 — Home's Total Sales includes the money drivers handed in during the
// period (non-voided `van_remittance` payments), with no line of its own.
// Net Profit stays on shop sales, and the Total Sales breakdown names the
// driver payments in one chip because no order row carries them.

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/core/permissions/permissions.dart';
import 'package:reebaplus_pos/core/providers/first_run_surface_state.dart';
import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/features/dashboard/get_started_checklist.dart';
import 'package:reebaplus_pos/features/dashboard/reports_attention.dart';
import 'package:reebaplus_pos/features/dashboard/screens/home_screen.dart';
import 'package:reebaplus_pos/features/dashboard/widgets/home_parts.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/redesign.dart';

import '../helpers/screen_harness.dart';

const _ceoKeys = {
  'reports.see_sales',
  'reports.see_profit',
  'reports.see_expenses',
  'stock.view',
  'customers.add',
  'sales.make',
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ScreenTestEnvironment env;

  setUp(() async {
    env = await setupScreenTestEnvironment(
      productCount: 1,
      manufacturerCount: 1,
    );
  });

  tearDown(() => env.dispose());

  Future<void> deliver(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 250));
    }
  }

  Future<void> pumpHome(WidgetTester tester) async {
    await pumpScreen(
      tester,
      env: env,
      size: const Size(1280, 800),
      padding: EdgeInsets.zero,
      screen: const HomeScreen(),
      grantedKeys: _ceoKeys,
      roleSlug: 'ceo',
      roleName: 'CEO',
      roleRank: GateTier.ceo,
      overrides: [
        reportsAttentionDotProvider.overrideWithValue(false),
        zeroStoresEmptySurfaceProvider.overrideWithValue(false),
        getStartedChecklistProvider.overrideWithValue(
          const GetStartedChecklistState(visible: false, steps: []),
        ),
      ],
      settle: false,
    );
    await deliver(tester);
  }

  /// One shop sale today: ₦2,258 at cost ₦2,187 → ₦71 profit.
  Future<void> seedShopSale() async {
    final db = env.db;
    final at = seedAnchorToday();
    final orderId = UuidV7.generate();
    await db
        .into(db.orders)
        .insert(
          OrdersCompanion.insert(
            id: Value(orderId),
            businessId: env.businessId,
            orderNumber: 'ORD-000001-VANH',
            totalAmountKobo: 225800,
            netAmountKobo: 225800,
            amountPaidKobo: const Value(225800),
            paymentType: 'cash',
            status: 'completed',
            storeId: Value(env.storeId),
            createdAt: Value(at),
          ),
        );
    await db
        .into(db.orderItems)
        .insert(
          OrderItemsCompanion.insert(
            id: Value(UuidV7.generate()),
            businessId: env.businessId,
            orderId: orderId,
            storeId: env.storeId,
            productId: Value(env.products.first.id),
            quantity: 1,
            unitPriceKobo: 225800,
            buyingPriceKobo: const Value(218700),
            totalKobo: 225800,
            createdAt: Value(at),
          ),
        );
  }

  /// A driver payment booked to the shop today; [voided] marks it voided.
  Future<void> seedDriverPayment(int kobo, {bool voided = false}) async {
    final db = env.db;
    final at = seedAnchorToday();
    final driverId = UuidV7.generate();
    await db
        .into(db.vanDrivers)
        .insert(
          VanDriversCompanion.insert(
            id: Value(driverId),
            businessId: env.businessId,
            name: 'Driver Dan',
          ),
        );
    await db
        .into(db.paymentTransactions)
        .insert(
          PaymentTransactionsCompanion.insert(
            id: Value(UuidV7.generate()),
            businessId: env.businessId,
            storeId: Value(env.storeId),
            amountKobo: kobo,
            method: 'cash',
            type: kPaymentTypeVanRemittance,
            vanDriverId: Value(driverId),
            voidedAt: Value(voided ? at : null),
            createdAt: Value(at),
            lastUpdatedAt: Value(at),
          ),
        );
  }

  String valueOf(WidgetTester tester, Key card) =>
      tester.widget<StatCard>(find.byKey(card)).value;

  testWidgets('Total Sales adds the money drivers handed in; Net Profit '
      'stays on shop sales; voided payments never count', (tester) async {
    await seedShopSale();
    await seedDriverPayment(100000);
    await seedDriverPayment(500000, voided: true);
    await pumpHome(tester);

    expect(valueOf(tester, HomeKeys.sales), formatCurrency(3258));
    expect(valueOf(tester, HomeKeys.profit), formatCurrency(71));
    // No separate van line or split on the card.
    expect(find.textContaining('Van sales'), findsNothing);
    await disposeScreen(tester);
  });

  testWidgets('the Total Sales breakdown names the driver payments in one '
      'chip, since no order row carries them', (tester) async {
    await seedShopSale();
    await seedDriverPayment(100000);
    await pumpHome(tester);

    await tester.tap(find.byKey(HomeKeys.sales));
    await deliver(tester);
    expect(find.text('Total Sales Breakdown'), findsOneWidget);
    expect(
      find.text('Plus driver payments: ${formatCurrency(1000)}'),
      findsOneWidget,
    );
    await disposeScreen(tester);
  });
}
