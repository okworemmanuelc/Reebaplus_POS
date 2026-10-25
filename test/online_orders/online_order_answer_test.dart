// #427: the shop answers Online Orders (OnlineOrdersDao). Answers are Drift
// writes + full-row outbox upserts; the first order from a Shopper asks staff
// to link a Customer (existing or new Retailer) and never links by phone.

import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/core/online_orders/online_order_answer.dart';
import 'package:reebaplus_pos/core/services/supabase_sync_service.dart';

import '../helpers/dispatch_test_utils.dart';
import 'online_order_fixtures.dart';

void main() {
  late AppDatabase db;
  late String businessId;
  late String storeId;
  const shopper = 'a0000000-0000-7000-8000-000000000001';

  setUp(() async {
    final boot = await bootstrapTestDb();
    db = boot.db;
    businessId = boot.businessId;
    storeId = await seedStore(db, businessId);
  });

  tearDown(() => db.close());

  Future<OnlineOrderData> orderRow(String id) =>
      (db.select(db.onlineOrders)..where((t) => t.id.equals(id))).getSingle();

  Future<List<Map<String, dynamic>>> queued(String table) async {
    final rows = await (db.select(
      db.syncQueue,
    )..where((t) => t.actionType.equals('$table:upsert'))).get();
    return [for (final r in rows) jsonDecode(r.payload) as Map<String, dynamic>];
  }

  Future<String> addCustomer(String name, {String? phone}) =>
      db.customersDao.addCustomer(
        CustomersCompanion.insert(
          businessId: businessId,
          name: name,
          phone: Value(phone),
        ),
      );

  test('first order asks for a customer choice and writes nothing', () async {
    final id = await seedOnlineOrder(
      db,
      businessId: businessId,
      storeId: storeId,
      shopperAccountId: shopper,
    );
    final outcome = await db.onlineOrdersDao.accept(onlineOrderId: id);
    expect(outcome, OnlineOrderAnswerOutcome.needsCustomerChoice);
    expect((await orderRow(id)).status, 'new');
    expect(await queued('online_orders'), isEmpty);
  });

  test('never auto-links by phone: a phone match is only a suggestion',
      () async {
    final match = await addCustomer('Ada O', phone: '+2348030000000');
    final other = await addCustomer('Bola', phone: '0809999999');
    final byName = await addCustomer('ada okafor');
    final id = await seedOnlineOrder(
      db,
      businessId: businessId,
      storeId: storeId,
      shopperAccountId: shopper,
      shopperName: 'Ada',
      phone: '08030000000',
    );
    expect(
      await db.onlineOrdersDao.accept(onlineOrderId: id),
      OnlineOrderAnswerOutcome.needsCustomerChoice,
    );
    final suggestions = await db.onlineOrdersDao.suggestCustomers(
      phone: '08030000000',
      name: 'Ada',
    );
    expect(suggestions.map((c) => c.id), [match, byName],
        reason: 'phone match first, then name; never an unrelated customer');
    expect(suggestions.map((c) => c.id), isNot(contains(other)));
    final c = await db.customersDao.findById(match);
    expect(c!.shopperAccountId, isNull);
  });

  test('linking an existing customer sets the link and attaches the order',
      () async {
    final customer = await addCustomer('Ada', phone: '08030000000');
    final id = await seedOnlineOrder(
      db,
      businessId: businessId,
      storeId: storeId,
      shopperAccountId: shopper,
    );
    final outcome = await db.onlineOrdersDao.accept(
      onlineOrderId: id,
      link: LinkExistingCustomer(customer),
    );
    expect(outcome, OnlineOrderAnswerOutcome.answered);
    final order = await orderRow(id);
    expect(order.status, 'accepted');
    expect(order.customerId, customer);
    expect(order.respondedAt, isNotNull);
    expect((await db.customersDao.findById(customer))!.shopperAccountId,
        shopper);
    final pushedCustomers = await queued('customers');
    expect(pushedCustomers.last['shopper_account_id'], shopper);
    final pushed = (await queued('online_orders')).single;
    expect(pushed['status'], 'accepted');
    expect(pushed['customer_id'], customer);
  });

  test('a later order from a linked Shopper attaches automatically', () async {
    final customer = await addCustomer('Ada');
    final first = await seedOnlineOrder(
      db,
      businessId: businessId,
      storeId: storeId,
      shopperAccountId: shopper,
    );
    await db.onlineOrdersDao.accept(
      onlineOrderId: first,
      link: LinkExistingCustomer(customer),
    );
    final second = await seedOnlineOrder(
      db,
      businessId: businessId,
      storeId: storeId,
      shopperAccountId: shopper,
      reference: 'ON-SECOND',
    );
    expect(
      await db.onlineOrdersDao.accept(onlineOrderId: second),
      OnlineOrderAnswerOutcome.answered,
    );
    expect((await orderRow(second)).customerId, customer);
  });

  test('new customer: one linked Retailer from the order details', () async {
    final id = await seedOnlineOrder(
      db,
      businessId: businessId,
      storeId: storeId,
      shopperAccountId: shopper,
      shopperName: 'Chi',
      phone: '08031111111',
    );
    await db.onlineOrdersDao.accept(
      onlineOrderId: id,
      link: const CreateRetailerCustomer(),
    );
    final customers = await db.select(db.customers).get();
    expect(customers, hasLength(1));
    final c = customers.single;
    expect(c.name, 'Chi');
    expect(c.phone, '08031111111');
    expect(c.priceTier, 'retailer');
    expect(c.shopperAccountId, shopper);
    expect((await orderRow(id)).customerId, c.id);
    expect((await queued('customers')).single['shopper_account_id'], shopper);
  });

  test('one live customer per Shopper per business (unique link)', () async {
    final a = await addCustomer('A');
    final b = await addCustomer('B');
    await (db.update(db.customers)..where((t) => t.id.equals(a))).write(
      const CustomersCompanion(shopperAccountId: Value(shopper)),
    );
    await expectLater(
      (db.update(db.customers)..where((t) => t.id.equals(b))).write(
        const CustomersCompanion(shopperAccountId: Value(shopper)),
      ),
      throwsA(isA<Exception>()),
    );
  });

  test('decline stores the reason; only a `new` order can be answered',
      () async {
    final id = await seedOnlineOrder(
      db,
      businessId: businessId,
      storeId: storeId,
      shopperAccountId: shopper,
    );
    expect(
      await db.onlineOrdersDao.decline(
        onlineOrderId: id,
        reason: OnlineOrderDeclineReason.outOfStock.label,
      ),
      OnlineOrderAnswerOutcome.answered,
    );
    final order = await orderRow(id);
    expect(order.status, 'declined');
    expect(order.declineReason, 'Out of stock');
    expect((await queued('online_orders')).single['decline_reason'],
        'Out of stock');
    expect(
      await db.onlineOrdersDao.accept(
        onlineOrderId: id,
        link: const CreateRetailerCustomer(),
      ),
      OnlineOrderAnswerOutcome.alreadyAnswered,
    );
    expect(() => db.onlineOrdersDao.decline(onlineOrderId: id, reason: '  '),
        throwsArgumentError);
  });

  test('the push keeps cloud-owned placement snapshots off the wire', () {
    final scrubbed = SupabaseSyncService.scrubForTesting('online_orders', {
      'id': UuidV7.generate(),
      'business_id': businessId,
      'status': 'accepted',
      'placed_at': '2026-10-25T09:00:00Z',
      'created_at': '2026-10-25T09:00:00Z',
      'estimated_total_kobo': 1,
      'note': 'x',
      'shopper_account_id': shopper,
    });
    expect(scrubbed.keys, isNot(contains('placed_at')));
    expect(scrubbed.keys, isNot(contains('created_at')));
    expect(scrubbed.keys, isNot(contains('estimated_total_kobo')));
    expect(scrubbed.keys, isNot(contains('shopper_account_id')));
    expect(scrubbed['status'], 'accepted');
  });
}
