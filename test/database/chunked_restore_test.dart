// chunked_restore_test.dart
//
// #761 — a downloaded table is saved a chunk at a time (one batch per chunk)
// and a chunk that fails is replayed row by row. These tests pin that the
// result is the same as the row-by-row path: a bad row is skipped on its own,
// FK orphans are reported through fkSkipped, Last-Write-Wins still applies.

import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/core/services/supabase_cloud_transport.dart';
import 'package:reebaplus_pos/core/services/supabase_sync_service.dart';

void main() {
  late AppDatabase db;
  late SupabaseClient supabase;
  late SupabaseSyncService sync;
  late String businessId;

  final older = DateTime.utc(2026, 5, 28, 12).toIso8601String();
  final newer = DateTime.utc(2026, 5, 29, 12).toIso8601String();

  Future<void> seedBusiness(AppDatabase d, String id) => d
      .into(d.businesses)
      .insert(BusinessesCompanion.insert(id: Value(id), name: 'Biz'));

  Map<String, dynamic> role(
    String id,
    String name,
    String biz, {
    String? lua,
  }) => {
    'id': id,
    'business_id': biz,
    'name': name,
    'slug': name.toLowerCase(),
    'is_system_default': false,
    'is_deleted': false,
    'created_at': older,
    'last_updated_at': lua ?? older,
  };

  Future<Map<String, String>> roleNames(AppDatabase d) async {
    final rows = await d.select(d.roles).get();
    return {for (final r in rows) r.id: r.name};
  }

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    supabase = SupabaseClient('https://placeholder.supabase.co', 'placeholder');
    sync = SupabaseSyncService(db, SupabaseCloudTransport(supabase));
    businessId = UuidV7.generate();
    await seedBusiness(db, businessId);
  });

  tearDown(() async {
    await supabase.dispose();
    await db.close();
  });

  test('a bad row in the middle is skipped, every other row saves', () async {
    final ids = List.generate(5, (_) => UuidV7.generate());
    final orphanBiz = UuidV7.generate(); // no such business -> FK violation
    final fkSkipped = <String>{};
    await db.transaction(
      () => sync.restoreTableDataForTesting('roles', [
        role(ids[0], 'A', businessId),
        role(ids[1], 'B', businessId),
        role(ids[2], 'Orphan', orphanBiz),
        role(ids[3], 'D', businessId),
        role(ids[4], 'E', businessId),
      ], fkSkipped: fkSkipped),
    );
    final saved = await roleNames(db);
    expect(saved.keys.toSet(), {ids[0], ids[1], ids[3], ids[4]});
    expect(fkSkipped, {'roles'});
  });

  test('FK orphans are collected for the targeted parent fetch', () async {
    final good = UuidV7.generate();
    final bad = UuidV7.generate();
    final collected = <String, List<Map<String, dynamic>>>{};
    final ex = SyncRestoreExecutor(db, fkOrphanedRows: collected);
    final fkSkipped = <String>{};
    final entry = syncedTableForName('roles')!;
    await db.transaction(
      () => entry.restore(
        ex,
        'roles',
        [
          role(bad, 'Bad', UuidV7.generate()),
          role(good, 'Good', businessId),
        ].map(_camel).toList(),
        fkSkipped,
      ),
    );
    expect((await roleNames(db)).keys.toSet(), {good});
    expect(fkSkipped, {'roles'});
    expect(collected['roles']!.single['id'], bad);
  });

  test('Last-Write-Wins: older does not overwrite, newer does', () async {
    final keep = UuidV7.generate();
    final bump = UuidV7.generate();
    await sync.restoreTableDataForTesting('roles', [
      role(keep, 'KeepNew', businessId, lua: newer),
      role(bump, 'WasOld', businessId, lua: older),
    ]);
    await db.transaction(
      () => sync.restoreTableDataForTesting('roles', [
        role(keep, 'StaleIncoming', businessId, lua: older),
        role(bump, 'FreshIncoming', businessId, lua: newer),
      ]),
    );
    final saved = await roleNames(db);
    expect(saved[keep], 'KeepNew');
    expect(saved[bump], 'FreshIncoming');
  });

  test('chunked result equals the row-by-row result (across chunks)', () async {
    const n = SyncRestoreExecutor.restoreChunkSize * 2 + 37;
    final orphanBiz = UuidV7.generate();
    final input = [
      for (var i = 0; i < n; i++)
        role(
          UuidV7.generate(),
          'R$i',
          // a few orphans spread over different chunks
          (i == 3 || i == 600 || i == n - 1) ? orphanBiz : businessId,
        ),
    ];

    final fkChunked = <String>{};
    await db.transaction(
      () => sync.restoreTableDataForTesting(
        'roles',
        input.map((m) => Map<String, dynamic>.of(m)).toList(),
        fkSkipped: fkChunked,
      ),
    );

    // Reference: the old shape, one insertResilient per row.
    final ref = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(ref.close);
    await seedBusiness(ref, businessId);
    final ex = SyncRestoreExecutor(ref);
    final fkRef = <String>{};
    await ref.transaction(() async {
      for (final m in input) {
        final c = _camel(Map<String, dynamic>.of(m));
        final data = RoleData.fromJson(c);
        await ex.insertResilient(
          'roles',
          c,
          fkRef,
          () => ref.into(ref.roles).insertOnConflictUpdate(data),
        );
      }
    });

    expect(await roleNames(db), await roleNames(ref));
    expect(fkChunked, fkRef);
    expect((await roleNames(db)).length, n - 3);
  });
}

Map<String, dynamic> _camel(Map<String, dynamic> m) => m.map((k, v) {
  final parts = k.split('_');
  final key =
      parts.first +
      parts.skip(1).map((p) => p[0].toUpperCase() + p.substring(1)).join();
  return MapEntry(key, v);
});
