import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';

import '../helpers/dispatch_test_utils.dart';

/// `UserPermissionOverridesDao.clearAllForUser` — the "Restore defaults" button
/// on the per-staff permission screen (§10.2.1). Clearing must remove ONLY that
/// staff member's overrides and tombstone each one so other devices drop it too
/// (the live-revert path fixed by migration 0090).
void main() {
  late AppDatabase db;
  late String businessId;
  const userA = 'user-aaaa';
  const userB = 'user-bbbb';

  setUp(() async {
    final boot = await bootstrapTestDb();
    db = boot.db;
    businessId = boot.businessId;
    for (final u in const [(userA, 'Ada'), (userB, 'Bob')]) {
      await db.into(db.users).insert(
            UsersCompanion.insert(
              id: Value(u.$1),
              businessId: businessId,
              name: u.$2,
              pin: '0000',
            ),
          );
    }
  });

  tearDown(() async => db.close());

  // Seed overrides directly (as if pulled from the cloud / already synced), so
  // the clear produces clean delete tombstones with no pending upsert to
  // coalesce away.
  Future<void> seedOverride(String userId, String key, bool granted) async {
    await db.into(db.userPermissionOverrides).insert(
          UserPermissionOverridesCompanion.insert(
            id: Value(UuidV7.generate()),
            businessId: businessId,
            userId: userId,
            permissionKey: key,
            isGranted: granted,
          ),
        );
  }

  test('clears only that user\'s overrides, returns the count, tombstones each',
      () async {
    final dao = db.userPermissionOverridesDao;
    await seedOverride(userA, 'activity_logs.view', true);
    await seedOverride(userA, 'settings.manage', false);
    await seedOverride(userB, 'sync.view', true);

    final cleared = await dao.clearAllForUser(userA);

    expect(cleared, 2, reason: 'returns the number of overrides removed');
    expect(await dao.getForUser(userA), isEmpty);
    expect((await dao.getForUser(userB)).length, 1,
        reason: 'another staff member\'s overrides are untouched');

    final deletes = (await getPendingQueue(db))
        .where((q) => q.actionType == 'user_permission_overrides:delete')
        .toList();
    expect(deletes.length, 2,
        reason: 'each cleared override enqueues a hard-delete so the removal '
            'propagates live to other devices (0090)');
  });

  test('on a user with no overrides is a no-op returning 0', () async {
    final dao = db.userPermissionOverridesDao;
    expect(await dao.clearAllForUser(userA), 0);
    expect(await dao.getForUser(userA), isEmpty);
  });
}
