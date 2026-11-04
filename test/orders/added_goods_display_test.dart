// #732 — what the Orders card and the Return and Edit sheets say about goods
// added by an edit: the card's combined quantity, the sheets' max and price.

import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/core/providers/first_run_surface_state.dart';
import 'package:reebaplus_pos/features/orders/screens/orders_screen.dart';
import 'package:reebaplus_pos/features/orders/widgets/edit_sale_sheet.dart';
import 'package:reebaplus_pos/features/orders/widgets/return_sale_dialog.dart';
import 'package:reebaplus_pos/features/orders/widgets/sale_card_rows.dart';

import '../helpers/screen_harness.dart';
import 'orders_fixture.dart';

const _sale = 'order-completed-4'; // Star Lager 1, Eva Water 1

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('wording', () {
    final at = DateTime(2026, 11, 4);

    OrderItemData item(String id, double qty, int total, {String? orderId}) =>
        OrderItemData(
          id: id,
          businessId: 'b',
          orderId: orderId ?? 'sale',
          productId: 'p',
          storeId: 's',
          quantity: qty,
          unitPriceKobo: total ~/ qty.abs(),
          buyingPriceKobo: 0,
          totalKobo: total,
          createdAt: at,
          lastUpdatedAt: at,
        );

    SaleAdjustmentLines adj(List<OrderItemData> lines, {int net = 0}) => (
      adjustment: OrderData(
        id: 'adj',
        businessId: 'b',
        orderNumber: 'ORD-2',
        totalAmountKobo: net,
        discountKobo: 0,
        netAmountKobo: net,
        amountPaidKobo: 0,
        crateDepositPaidKobo: 0,
        driverExtraKobo: 0,
        riderName: 'Pick-up Order',
        paymentType: 'cash',
        status: 'completed',
        kind: 'adjustment',
        createdAt: at,
        lastUpdatedAt: at,
      ),
      lines: [for (final l in lines) OrderItemDataWithProductData(l, null)],
    );

    test('the card row shows the combined quantity and the note', () {
      final rows = saleCardRows(
        [OrderItemDataWithProductData(item('1', 10, 1000000), null)],
        [adj([item('2', 2, 240000, orderId: 'adj')])],
      );
      expect(rows.single.label, '12× Quick Sale (+2 added 4 Nov)');
      expect(rows.single.totalKobo, 1240000);
    });

    test('an untouched sale reads exactly as before', () {
      final rows = saleCardRows(
        [OrderItemDataWithProductData(item('1', 10, 1000000), null)],
        const [],
      );
      expect(rows.single.label, '10× Quick Sale');
    });

    test('the sheet note names the units still standing and their price', () {
      final goods = groupReturnableLines([
        const ReturnableLine(
          lineId: '1',
          productId: 'p',
          storeId: 's',
          sold: 10,
          returned: 0,
          unitPriceKobo: 100000,
          buyingPriceKobo: 0,
        ),
        ReturnableLine(
          lineId: '2',
          productId: 'p',
          storeId: 's',
          sold: 3,
          returned: 1,
          unitPriceKobo: 120000,
          buyingPriceKobo: 0,
          addedAt: at,
        ),
      ]).single;
      final note = addedGoodsNote(goods)!;
      expect(note, startsWith('+2 added 4 Nov at '));
      expect(note, contains('1,200'));
    });

    test('an edit reads + for added and - for taken off', () {
      final s = adjustmentSummary(
        adj([
          item('2', 2, 240000, orderId: 'adj'),
          item('3', -1, -100000, orderId: 'adj'),
        ], net: 140000),
        showMoney: false,
      );
      expect(s, 'Edited: +2 × Quick Sale, -1 × Quick Sale · ORD-2');
    });
  });

  group('sheets', () {
    Future<void> open(
      WidgetTester tester,
      Future<void> Function(BuildContext) show,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => show(context),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    testWidgets('Return lists the combined max and the added note', (
      tester,
    ) async {
      await open(
        tester,
        (context) => showReturnSaleDialog(
          context,
          orderNumber: 'ORD-1',
          refundLabel: 'N1',
          lines: const [
            ReturnLineInput(
              lineId: 'l',
              name: 'Star Lager',
              quantity: 12,
              returnable: 12,
              canBeDamaged: true,
              addedNote: '+2 added 4 Nov at N1,200',
            ),
          ],
        ),
      );
      expect(find.text('Star Lager (up to 12)'), findsOneWidget);
      expect(find.text('+2 added 4 Nov at N1,200'), findsOneWidget);
      expect(
        tester
            .widget<IconButton>(find.byKey(const Key('return-qty-inc-l')))
            .onPressed,
        isNull,
        reason: 'starts at the max',
      );
      await tester.tap(find.byKey(const Key('return-qty-dec-l')));
      await tester.pump();
      expect(find.text('11'), findsOneWidget);
    });
  });

  group('Orders card', () {
    late ScreenTestEnvironment cardEnv;

    setUp(() async {
      cardEnv = await setupScreenTestEnvironment(
        productCount: 3,
        manufacturerCount: 1,
        businessType: 'Bar',
      );
      await seedOrdersSample(cardEnv);
    });
    tearDown(() async => cardEnv.dispose());

    testWidgets('Edit seeds the combined quantity and shows the note', (
      tester,
    ) async {
      await pumpScreen(
        tester,
        env: cardEnv,
        size: const Size(390, 844),
        settle: false,
        screen: Builder(
          builder: (context) => Center(
            child: TextButton(
              onPressed: () => showEditSaleEditor(
                context,
                orderNumber: 'ORD-1',
                storeId: null,
                priceTier: 'retailer',
                lines: const [
                  EditLineSeed(
                    lineId: 'l',
                    name: 'Star Lager',
                    current: 12,
                    unitPriceKobo: 100000,
                    canRaise: true,
                    allowParts: false,
                    addedNote: '+2 added 4 Nov at N1,200',
                  ),
                ],
              ),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.textContaining('+2 added 4 Nov at N1,200'), findsOneWidget);
      expect(find.text('12'), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
      await disposeScreen(tester);
    });

    testWidgets('an added line joins its product row with the note', (
      tester,
    ) async {
      final db = cardEnv.db;
      final sale = await (db.select(db.orders)
            ..where((o) => o.id.equals(_sale)))
          .getSingle();
      final star = (await (db.select(db.orderItems)
                ..where((i) => i.orderId.equals(_sale)))
              .get())
          .first;
      final adjustmentId = UuidV7.generate();
      final today = DateTime.now();
      await db.into(db.orders).insert(OrdersCompanion.insert(
            id: Value(adjustmentId),
            businessId: sale.businessId,
            orderNumber: 'ORD-EDIT',
            totalAmountKobo: 200000,
            netAmountKobo: 200000,
            paymentType: 'cash',
            status: 'completed',
            storeId: Value(sale.storeId),
            kind: const Value('adjustment'),
            adjustsOrderId: const Value(_sale),
            createdAt: Value(today),
          ));
      await db.into(db.orderItems).insert(OrderItemsCompanion.insert(
            businessId: sale.businessId,
            orderId: adjustmentId,
            productId: Value(star.productId),
            storeId: star.storeId,
            quantity: 2,
            unitPriceKobo: 100000,
            totalKobo: 200000,
          ));

      await pumpScreen(
        tester,
        env: cardEnv,
        size: const Size(800, 1280),
        screen: const OrdersScreen(initialIndex: 1),
        grantedKeys: ordersCeoGrants,
        roleSlug: 'ceo',
        roleName: 'ceo',
        roleRank: 0,
        overrides: [
          firstRunSurfaceStateProvider.overrideWithValue(
            FirstRunSurfaceState.hasContent,
          ),
        ],
        settle: false,
      );
      await settleOrders(tester);

      final day = DateFormat('d MMM').format(today);
      expect(
        find.descendant(
          of: find.byKey(orderRowKey(_sale)),
          matching: find.textContaining('(+2 added $day)'),
        ),
        findsOneWidget,
      );
      await tester.pump(const Duration(seconds: 5));
      await disposeScreen(tester);
    });
  });
}
