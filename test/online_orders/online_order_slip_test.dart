// #430: the order slip matches the accepted order, skips removed lines, notes
// the crate deposit only for crate products, shows its button only on accepted
// / fulfilled orders, and falls back to Share when printing does not happen.

import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/core/online_orders/online_order_slip.dart';
import 'package:reebaplus_pos/features/pos/services/receipt_paper_size.dart';
import 'package:reebaplus_pos/features/orders/screens/online_order_detail_screen.dart';
import 'package:reebaplus_pos/features/orders/widgets/online_order_parts.dart';

import '../helpers/screen_harness.dart';
import 'online_order_fixtures.dart';

const _viewer = {'online_orders.view'};

void main() {
  late ScreenTestEnvironment env;
  late String orderId;
  late String removedLineId;

  setUp(() async {
    env = await setupScreenTestEnvironment();
    orderId = await seedOnlineOrder(
      env.db,
      businessId: env.businessId,
      storeId: env.storeId,
      productId: env.products.first.id,
    );
    removedLineId = UuidV7.generate();
    await env.db.into(env.db.onlineOrderLines).insert(
          OnlineOrderLinesCompanion.insert(
            id: removedLineId,
            businessId: env.businessId,
            onlineOrderId: orderId,
            productId: env.products.last.id,
            productName: 'Removed Item',
            unit: const Value('bottle'),
            unitPriceKobo: 100000,
            requestedQty: 3,
          ),
        );
  });
  tearDown(() => env.dispose());

  Future<OnlineOrderSlip> slip({bool tracksCrates = true}) async {
    final load = await env.db.onlineOrdersDao.slipLoad(orderId);
    return OnlineOrderSlip.from(load!, tracksCrates: tracksCrates);
  }

  Future<void> accept({int removedQty = 0}) async {
    await env.db.onlineOrdersDao.accept(
      onlineOrderId: orderId,
      acceptedQtys: {removedLineId: removedQty},
    );
  }

  test('slip text matches the order and skips removed lines', () async {
    await (env.db.update(env.db.stores)..where((s) => s.id.equals(env.storeId)))
        .write(const StoresCompanion(phone: Value('0803 111 2222')));
    await accept();
    final s = await slip();
    final text = s.toText();
    expect(s.lines.map((l) => l.name), ['Star Lager']);
    expect(text, contains('Order: ON-1A2B3C4D'));
    expect(text, contains('Tel: 0803 111 2222'));
    expect(text, contains('Customer: Ada'));
    expect(text, contains('Phone: 08030000000'));
    expect(text, contains('Deliver to: 1 Road, Keffi, Nasarawa'));
    expect(text, contains('2 x Star Lager'));
    expect(text, isNot(contains('Removed Item')));
    expect(s.totalKobo, 900000);
    expect(text, contains('Estimated total: '));
    expect(await s.toBytes(ReceiptPaperSize.mm58), isNotEmpty);
  });

  test('deposit note appears only with crate products', () async {
    await accept(removedQty: 3);
    // Bottle line kept, product tracks empties, business tracks crates.
    await (env.db.update(env.db.products)
          ..where((p) => p.id.equals(env.products.last.id)))
        .write(const ProductsCompanion(trackEmpties: Value(true)));
    final withCrates = await slip();
    expect(withCrates.hasCrates, isTrue);
    expect(withCrates.toText(), contains(OnlineOrderSlip.depositNote));
    expect((await slip(tracksCrates: false)).toText(),
        isNot(contains(OnlineOrderSlip.depositNote)));
  });

  test('no deposit note when the crate line was removed', () async {
    await (env.db.update(env.db.products)
          ..where((p) => p.id.equals(env.products.last.id)))
        .write(const ProductsCompanion(trackEmpties: Value(true)));
    await accept();
    expect((await slip()).hasCrates, isFalse);
  });

  test('Share fallback when printing fails, none when it prints', () async {
    await accept();
    final s = await slip();
    final shared = <String>[];
    var outcome = await printOrShareOnlineOrderSlip(
      slip: s,
      print: () async => false,
      share: (t) async => shared.add(t),
    );
    expect(outcome, OnlineOrderSlipOutcome.shared);
    expect(shared.single, s.toText());
    outcome = await printOrShareOnlineOrderSlip(
      slip: s,
      print: () async => throw StateError('no bluetooth'),
      share: (t) async => shared.add(t),
    );
    expect(outcome, OnlineOrderSlipOutcome.shared);
    expect(shared, hasLength(2));
    outcome = await printOrShareOnlineOrderSlip(
      slip: s,
      print: () async => true,
      share: (t) async => shared.add(t),
    );
    expect(outcome, OnlineOrderSlipOutcome.printed);
    expect(shared, hasLength(2));
  });

  Future<void> pump(WidgetTester tester, Set<String> keys) => pumpScreen(
    tester,
    env: env,
    size: const Size(390, 844),
    screen: OnlineOrderDetailScreen(onlineOrderId: orderId),
    grantedKeys: keys,
    roleSlug: 'cashier',
    roleName: 'Cashier',
    roleRank: 2,
  );

  Future<void> expectButton(
    WidgetTester tester, {
    String? status,
    bool acceptFirst = false,
    required bool shown,
  }) async {
    if (acceptFirst) await accept();
    if (status != null) {
      await (env.db.update(env.db.onlineOrders)
            ..where((o) => o.id.equals(orderId)))
          .write(OnlineOrdersCompanion(status: Value(status)));
    }
    await pump(tester, _viewer);
    await tester.pumpAndSettle();
    expect(
      find.byKey(OnlineOrderKeys.printSlip),
      shown ? findsOneWidget : findsNothing,
    );
    await disposeScreen(tester);
  }

  testWidgets('no Print slip on a new order', (t) async {
    await expectButton(t, shown: false);
  });
  testWidgets('Print slip on an accepted order', (t) async {
    await expectButton(t, acceptFirst: true, shown: true);
  });
  testWidgets('Print slip on a fulfilled order', (t) async {
    await expectButton(t, status: 'fulfilled', shown: true);
  });
  testWidgets('no Print slip on a declined order', (t) async {
    await expectButton(t, status: 'declined', shown: false);
  });
}
