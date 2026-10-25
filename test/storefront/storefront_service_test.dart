import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:reebaplus_pos/core/storefront/storefront_models.dart';
import 'package:reebaplus_pos/core/storefront/storefront_service.dart';
import 'package:reebaplus_pos/core/utils/number_format.dart';

import '../browse/browse_fixtures.dart';

void main() {
  group('ShopperArea', () {
    test('labels and RPC params', () {
      expect(kTestArea.label, 'Keffi, Nasarawa');
      expect(const ShopperArea(state: 'Lagos').label, 'All of Lagos');
      expect(const ShopperArea.allNigeria().label, 'All of Nigeria');
      expect(const ShopperArea.allNigeria().toRpcParams(),
          {'p_country': 'Nigeria', 'p_state': null, 'p_lga': null});
    });

    test('JSON round trip and corrupt values', () {
      expect(ShopperArea.fromJson(kTestArea.toJson()), kTestArea);
      expect(ShopperArea.fromJson({'country': 'Ghana', 'state': ' Accra ', 'lga': ''}),
          const ShopperArea(country: 'Ghana', state: 'Accra'));
      // An LGA without a state is meaningless: dropped.
      expect(ShopperArea.fromJson({'country': 'Nigeria', 'state': '', 'lga': 'Keffi'}),
          const ShopperArea.allNigeria());
      expect(ShopperArea.fromJson('nope'), isNull);
      expect(ShopperArea.fromJson({'country': 3}), isNull);
    });
  });

  group('StorefrontCard', () {
    test('parses public fields, stock words and seller label', () {
      final card = StorefrontCard.fromRow(cardRow(
        id: 'p3', name: 'Coke', stock: 'only_few_left', onlyLeft: 2, deposit: 150000));
      expect(card.stock, StorefrontStock.onlyFewLeft);
      expect(card.stockText, 'Only 2 left');
      expect(card.orderable, isTrue);
      expect(card.sellerLabel, 'Stallion Global · Nasarawa');
      expect(card.crateDepositKobo, 150000);
      final out = StorefrontCard.fromRow(cardRow(id: 'x', name: 'X', stock: 'out_of_stock'));
      expect(out.orderable, isFalse);
      expect(out.stockText, 'Out of stock');
      // An unknown label is never shown as orderable.
      expect(StorefrontStock.fromWire('bogus'), StorefrontStock.outOfStock);
    });

    test('listing content and order rule (#473)', () {
      final card = StorefrontCard.fromRow(cardRow(id: 'a', name: 'A',
          brand: 'Guinness', description: 'Stout', minQty: 6, step: 6));
      expect(card.brand, 'Guinness');
      expect(card.onlineDescription, 'Stout');
      expect(card.orderRuleText, 'Order at least 6, in steps of 6');
      expect(StorefrontCard.fromRow(cardRow(id: 'b', name: 'B')).orderRuleText, isNull);
    });

    test('store currency formatting', () {
      expect(formatCurrencyIn(4500, 'NGN'), '₦4,500');
      expect(formatCurrencyIn(12, 'KES'), 'KSh 12');
    });
  });

  group('StorefrontService', () {
    test('feed sends the area and paginates with the last cursor', () async {
      final calls = <(String, Map<String, Object?>)>[];
      final full = [
        for (var i = 0; i < StorefrontService.pageSize; i++)
          cardRow(id: 'p$i', name: 'P$i'),
      ];
      final service = StorefrontService.withRpc(rpc: (fn, params) async {
        calls.add((fn, params));
        return full;
      });
      final page = await service.feed(area: kTestArea, category: 'beer');
      expect(calls.single.$1, 'storefront_feed');
      expect(calls.single.$2, {
        'p_country': 'Nigeria', 'p_state': 'Nasarawa', 'p_lga': 'Keffi',
        'p_category': 'beer', 'p_after': null, 'p_limit': StorefrontService.pageSize,
      });
      expect(page.cards, hasLength(StorefrontService.pageSize));
      expect(page.nextCursor, full.last['cursor']);

      final short = StorefrontService.withRpc(rpc: (_, __) async => [cardRow(id: 'a', name: 'A')]);
      expect((await short.feed(area: kTestArea)).nextCursor, isNull);
    });

    test('search trims, store page sends no blank query', () async {
      final calls = <(String, Map<String, Object?>)>[];
      final service = StorefrontService.withRpc(rpc: (fn, params) async {
        calls.add((fn, params));
        return <Object?>[];
      });
      await service.search(area: kTestArea, query: '  star ');
      await service.storeProducts(storeId: 's1', query: '   ');
      expect(calls[0].$2['p_query'], 'star');
      expect(calls[1].$1, 'storefront_store_products');
      expect(calls[1].$2['p_query'], isNull);
      expect(calls[1].$2.containsKey('p_country'), isFalse);
    });

    test('store header: null when not listed', () async {
      final empty = StorefrontService.withRpc(rpc: (_, __) async => <Object?>[]);
      expect(await empty.store(storeId: 's', area: kTestArea), isNull);
      final listed = StorefrontService.withRpc(rpc: (_, __) async => [kStoreRow]);
      final store = await listed.store(storeId: 's', area: kTestArea);
      expect(store!.deliversToArea, isFalse);
      expect(store.sellerLabel, 'Far Away Ventures · Ikeja');
    });

    test('offline, network, timeout and server failures', () async {
      Future<StorefrontFailure> failureOf(StorefrontService s) async {
        try {
          await s.feed(area: kTestArea);
        } on StorefrontException catch (e) {
          return e.failure;
        }
        fail('expected a StorefrontException');
      }

      var called = false;
      final offline = StorefrontService.withRpc(
        isOnline: () async => false,
        rpc: (_, __) async { called = true; return <Object?>[]; },
      );
      expect(await failureOf(offline), StorefrontFailure.offline);
      expect(called, isFalse, reason: 'no request while offline');

      expect(await failureOf(StorefrontService.withRpc(
        rpc: (_, __) => Future.error(const SocketException('down')))),
        StorefrontFailure.offline);
      expect(await failureOf(StorefrontService.withRpc(
        timeout: const Duration(milliseconds: 10),
        rpc: (_, __) => Completer<Object?>().future)),
        StorefrontFailure.offline);
      expect(await failureOf(StorefrontService.withRpc(
        rpc: (_, __) => Future.error(const PostgrestException(message: 'bad', code: '22023')))),
        StorefrontFailure.failed);
      expect(await failureOf(StorefrontService.withRpc(rpc: (_, __) async => 'x')),
        StorefrontFailure.failed);
    });
  });
}
