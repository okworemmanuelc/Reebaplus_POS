import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:reebaplus_pos/core/data/area_selection.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/daos.dart';
import 'package:reebaplus_pos/core/permissions/gate.dart';
import 'package:reebaplus_pos/core/permissions/gate_registry.dart';
import 'package:reebaplus_pos/core/services/store_online_service.dart';
import 'package:reebaplus_pos/core/services/supabase_cloud_transport.dart';
import 'package:reebaplus_pos/core/services/supabase_sync_service.dart';

import '../helpers/dispatch_test_utils.dart';

void main() {
  late AppDatabase db;
  late String businessId;
  late StoreOnlineService service;
  const ceo = GateContext(
      grantedKeys: {'stores.online_ordering'}, roleRank: GateTier.ceo, isReady: true);
  const manager = GateContext(
      grantedKeys: {'stores.manage', 'settings.manage'},
      roleRank: GateTier.manager, isReady: true);
  const ikeja = AreaSelection(country: 'Nigeria', state: 'Lagos', lga: 'Ikeja');

  setUp(() async {
    final boot = await bootstrapTestDb();
    db = boot.db;
    businessId = boot.businessId;
    service = StoreOnlineService(db.storesDao);
  });
  tearDown(() => db.close());

  Future<StoreData> store(String id) =>
      (db.select(db.stores)..where((s) => s.id.equals(id))).getSingle();

  Future<List<Map<String, dynamic>>> queued(String table) async =>
      (await getPendingQueue(db))
          .where((q) => q.actionType == '$table:upsert')
          .map(decodePayload)
          .toList();

  test('the switch has its own key; other roles cannot without it', () {
    expect(Gates.manageOnlineStore.evaluate(ceo), isTrue);
    expect(Gates.manageOnlineStore.evaluate(manager), isFalse);
  });

  test('a new store is offline and cannot switch on until it has state + LGA',
      () async {
    final id = await db.storesDao.createStore(name: 'Main');
    expect((await store(id)).onlineOrderingEnabled, isFalse);
    final r = await service.setOnlineOrdering(
        storeId: id, enabled: true, gateContext: ceo);
    expect(r.isErr, isTrue);
    expect((await store(id)).onlineOrderingEnabled, isFalse);
    expect(await db.storesDao.onlineBlocker(await store(id)),
        StoreOnlineBlockedReason.needsArea);
  });

  test('setting the area pre-fills its LGA as the first delivery area, then the '
      'switch works and syncs', () async {
    final id = await db.storesDao.createStore(name: 'Main');
    expect((await service.setArea(storeId: id, area: ikeja, gateContext: ceo)).isOk,
        isTrue);
    final areas = await db.storesDao.getDeliveryAreas(id);
    expect(areas.single.lga, 'Ikeja');
    expect(areas.single.state, 'Lagos');
    expect((await service.setOnlineOrdering(
            storeId: id, enabled: true, gateContext: ceo)).isOk, isTrue);
    final s = await store(id);
    expect(s.onlineOrderingEnabled, isTrue);
    expect(s.lga, 'Ikeja');
    final payload = (await queued('stores')).last;
    expect(payload['online_ordering_enabled'], isTrue);
    expect(payload['lga'], 'Ikeja');
    expect(payload['state'], 'Lagos');
    expect(payload['business_id'], businessId);
    expect((await queued('store_delivery_areas')).single['store_id'], id);
    expect(
      SupabaseSyncService.scrubForTesting('stores', payload)['online_ordering_enabled'],
      isTrue,
    );
  });

  test('creating a store with its area (first-run sheet) makes it ready to go online',
      () async {
    final id = await db.storesDao.createStore(
        name: 'Main', country: 'Nigeria', state: 'Lagos', lga: 'Ikeja');
    final s = await store(id);
    expect(s.state, 'Lagos');
    expect(s.lga, 'Ikeja');
    expect((await db.storesDao.getDeliveryAreas(id)).single.lga, 'Ikeja');
    expect(await db.storesDao.onlineBlocker(s), isNull);
  });

  test('vans can never be switched online', () async {
    final id = await db.storesDao.createStore(name: 'Van 1', kind: kStoreKindVan);
    final r = await service.setArea(storeId: id, area: ikeja, gateContext: ceo);
    expect(r.isErr, isTrue);
    final on = await service.setOnlineOrdering(
        storeId: id, enabled: true, gateContext: ceo);
    expect(on.isErr, isTrue);
    expect((await store(id)).onlineOrderingEnabled, isFalse);
  });

  test('denied grant leaves the store and outbox untouched', () async {
    final id = await db.storesDao.createStore(name: 'Main');
    final before = (await getPendingQueue(db)).length;
    final r = await service.setArea(storeId: id, area: ikeja, gateContext: manager);
    expect(r.isErr, isTrue);
    expect((await store(id)).state, isNull);
    expect((await getPendingQueue(db)).length, before);
  });

  test('whole-state delivery area, dedup by deterministic id, last area kept '
      'while online', () async {
    final id = await db.storesDao.createStore(
        name: 'Main', country: 'Nigeria', state: 'Lagos', lga: 'Ikeja');
    const allLagos = AreaSelection(country: 'Nigeria', state: 'Lagos');
    expect((await service.addDeliveryArea(
            storeId: id, area: allLagos, gateContext: ceo)).isOk, isTrue);
    expect((await service.addDeliveryArea(
            storeId: id, area: allLagos, gateContext: ceo)).isOk, isTrue);
    var areas = await db.storesDao.getDeliveryAreas(id);
    expect(areas.length, 2);
    expect(areas.where((a) => a.lga == null).length, 1);

    await service.setOnlineOrdering(storeId: id, enabled: true, gateContext: ceo);
    final whole = areas.firstWhere((a) => a.lga == null);
    expect((await service.removeDeliveryArea(
            storeId: id, areaId: whole.id, gateContext: ceo)).isOk, isTrue);
    areas = await db.storesDao.getDeliveryAreas(id);
    final last = areas.single;
    final r = await service.removeDeliveryArea(
        storeId: id, areaId: last.id, gateContext: ceo);
    expect(r.isErr, isTrue);
    expect((await db.storesDao.getDeliveryAreas(id)).length, 1);

    // Re-adding a removed area revives the same row (same id).
    await service.addDeliveryArea(storeId: id, area: allLagos, gateContext: ceo);
    expect((await db.storesDao.getDeliveryAreas(id))
        .any((a) => a.id == whole.id), isTrue);
  });

  test('invalid Nigerian LGA is rejected; foreign free text is accepted', () async {
    final id = await db.storesDao.createStore(name: 'Main');
    expect((await service.setArea(storeId: id,
        area: const AreaSelection(country: 'Nigeria', state: 'Lagos', lga: 'Nowhere'),
        gateContext: ceo)).isErr, isTrue);
    expect((await service.setArea(storeId: id,
        area: const AreaSelection(country: 'Ghana', state: 'Greater Accra', lga: 'Tema'),
        gateContext: ceo)).isOk, isTrue);
    expect((await store(id)).country, 'Ghana');
  });

  test('switching off always works and keeps the area and delivery list', () async {
    final id = await db.storesDao.createStore(
        name: 'Main', country: 'Nigeria', state: 'Lagos', lga: 'Ikeja');
    await service.setOnlineOrdering(storeId: id, enabled: true, gateContext: ceo);
    expect((await service.setOnlineOrdering(
            storeId: id, enabled: false, gateContext: ceo)).isOk, isTrue);
    final s = await store(id);
    expect(s.onlineOrderingEnabled, isFalse);
    expect(s.lga, 'Ikeja');
    expect((await db.storesDao.getDeliveryAreas(id)).length, 1);
  });

  test('phone and note save, clear to null, and the note is capped at 280', () async {
    final id = await db.storesDao.createStore(name: 'Main');
    expect((await service.setContact(storeId: id, phone: ' 0803 000 0000 ',
        onlineNote: 'Delivery ₦500, Mon–Sat', gateContext: ceo)).isOk, isTrue);
    var s = await store(id);
    expect(s.phone, '0803 000 0000');
    expect(s.onlineNote, 'Delivery ₦500, Mon–Sat');
    expect((await service.setContact(storeId: id, phone: 'x',
        onlineNote: 'a' * 281, gateContext: ceo)).isErr, isTrue);
    await service.setContact(storeId: id, phone: '', onlineNote: '', gateContext: ceo);
    s = await store(id);
    expect(s.phone, isNull);
    expect(s.onlineNote, isNull);
    final payload = (await queued('stores')).last;
    expect(payload.containsKey('phone'), isTrue);
    expect(payload['phone'], isNull);
  });

  test('pulled store rows restore old snapshots off and keep remote changes',
      () async {
    final supabase = SupabaseClient('https://placeholder.supabase.co', 'anon-key');
    addTearDown(supabase.dispose);
    final sync = SupabaseSyncService(db, SupabaseCloudTransport(supabase));
    final id = await db.storesDao.createStore(name: 'Main');
    await (db.delete(db.syncQueue)).go();
    final now = DateTime.now().toUtc().add(const Duration(minutes: 1));
    await sync.restoreTableDataForTesting('stores', [
      {
        'id': id, 'business_id': businessId, 'name': 'Main', 'kind': 'store',
        'is_deleted': false, 'state': 'Lagos', 'lga': 'Ikeja', 'country': 'Nigeria',
        'online_ordering_enabled': true,
        'created_at': now.toIso8601String(), 'last_updated_at': now.toIso8601String(),
      },
    ]);
    expect((await store(id)).onlineOrderingEnabled, isTrue);
    const legacyId = '00000000-0000-7000-8000-000000000001';
    await sync.restoreTableDataForTesting('stores', [
      {
        'id': legacyId, 'business_id': businessId, 'name': 'Old', 'is_deleted': false,
        'created_at': now.toIso8601String(), 'last_updated_at': now.toIso8601String(),
      },
    ]);
    expect((await store(legacyId)).onlineOrderingEnabled, isFalse);
    await sync.restoreTableDataForTesting('store_delivery_areas', [
      {
        'id': '00000000-0000-7000-8000-000000000002', 'business_id': businessId,
        'store_id': id, 'country': 'Nigeria', 'state': 'Lagos', 'lga': null,
        'is_deleted': false,
        'created_at': now.toIso8601String(), 'last_updated_at': now.toIso8601String(),
      },
    ]);
    expect((await db.storesDao.getDeliveryAreas(id)).single.lga, isNull);
  });
}
