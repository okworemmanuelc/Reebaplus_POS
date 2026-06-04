// pin_email_scoping_test.dart
//
// Guards the shared-PIN collision fix behind the Who Is Working picker
// (master plan §8): when two staff on the same till happen to choose the
// same PIN, AuthService.getUsersByPin scoped to the identified user's email
// must resolve to that one user only — never the other PIN-twin.

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';

void main() {
  late AppDatabase db;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(
      url: 'https://placeholder.supabase.co',
      anonKey: 'placeholder',
    );
  });

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() => db.close());

  test('getUsersByPin scopes to the given email when two users share a PIN',
      () async {
    final container = ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(db)],
    );
    addTearDown(container.dispose);
    final auth = container.read(authProvider);

    final biz = UuidV7.generate();
    await db.into(db.businesses).insert(
        BusinessesCompanion.insert(id: Value(biz), name: 'Biz'));

    final aliceId = UuidV7.generate();
    final bobId = UuidV7.generate();
    await db.into(db.users).insert(UsersCompanion.insert(
          id: Value(aliceId),
          businessId: biz,
          name: 'Alice',
          email: const Value('alice@x.com'),
          pin: '__INIT__',
        ));
    await db.into(db.users).insert(UsersCompanion.insert(
          id: Value(bobId),
          businessId: biz,
          name: 'Bob',
          email: const Value('bob@x.com'),
          pin: '__INIT__',
        ));

    // Both pick the same plaintext PIN — distinct salts, so distinct hashes,
    // but getUsersByPin recomputes per-candidate and both match the plaintext.
    await auth.setUserPin(aliceId, '123456');
    await auth.setUserPin(bobId, '123456');

    // Unscoped: the PIN belongs to both.
    final unscoped = await auth.getUsersByPin('123456');
    expect(unscoped.map((u) => u.id).toSet(), {aliceId, bobId});

    // Scoped to Alice's email: only Alice.
    final scoped = await auth.getUsersByPin('123456', email: 'alice@x.com');
    expect(scoped.map((u) => u.id).toList(), [aliceId]);
  });

  test(
      'getUsersByPin scopes to userId — only the exact identified user, even '
      'when another business shares the same email AND PIN (issue #5)',
      () async {
    final container = ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(db)],
    );
    addTearDown(container.dispose);
    final auth = container.read(authProvider);

    // Two businesses on the same till. UNIQUE(business_id, email) allows the
    // SAME email to exist once per business — the multi-business account case.
    final bizA = UuidV7.generate();
    final bizB = UuidV7.generate();
    await db.into(db.businesses).insert(
        BusinessesCompanion.insert(id: Value(bizA), name: 'Biz A'));
    await db.into(db.businesses).insert(
        BusinessesCompanion.insert(id: Value(bizB), name: 'Biz B'));

    final userA = UuidV7.generate();
    final userB = UuidV7.generate();
    await db.into(db.users).insert(UsersCompanion.insert(
          id: Value(userA),
          businessId: bizA,
          name: 'Manager',
          email: const Value('shared@x.com'),
          pin: '__INIT__',
        ));
    await db.into(db.users).insert(UsersCompanion.insert(
          id: Value(userB),
          businessId: bizB,
          name: 'Stock keeper',
          email: const Value('shared@x.com'),
          pin: '__INIT__',
        ));
    await auth.setUserPin(userA, '123456');
    await auth.setUserPin(userB, '123456');

    // Email scoping ALONE is not enough: a shared email across businesses
    // returns BOTH rows — this is exactly why the PIN screen must scope by id.
    final byEmail = await auth.getUsersByPin('123456', email: 'shared@x.com');
    expect(byEmail.map((u) => u.id).toSet(), {userA, userB});

    // userId scoping pins it to the one identity that was authenticated. The
    // other business's row — same email, same PIN — can never unlock.
    final byIdA =
        await auth.getUsersByPin('123456', userId: userA, email: 'shared@x.com');
    expect(byIdA.map((u) => u.id).toList(), [userA]);

    final byIdB =
        await auth.getUsersByPin('123456', userId: userB, email: 'shared@x.com');
    expect(byIdB.map((u) => u.id).toList(), [userB]);
  });

  test(
      'clearUserPin kills the old PIN (Log Out) but keeps the user row + other '
      "staff's PINs — the lighter, non-wipe logout (§7.6)", () async {
    final container = ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(db)],
    );
    addTearDown(container.dispose);
    final auth = container.read(authProvider);

    final biz = UuidV7.generate();
    await db.into(db.businesses).insert(
        BusinessesCompanion.insert(id: Value(biz), name: 'Biz'));

    final leaving = UuidV7.generate();
    final other = UuidV7.generate();
    await db.into(db.users).insert(UsersCompanion.insert(
          id: Value(leaving),
          businessId: biz,
          name: 'Manager',
          email: const Value('mgr@x.com'),
          pin: '__INIT__',
        ));
    await db.into(db.users).insert(UsersCompanion.insert(
          id: Value(other),
          businessId: biz,
          name: 'Cashier',
          email: const Value('cashier@x.com'),
          pin: '__INIT__',
        ));
    await auth.setUserPin(leaving, '111111');
    await auth.setUserPin(other, '222222');

    // Log Out clears only the leaving user's PIN.
    await auth.clearUserPin(leaving);

    // The leaving user's OLD PIN no longer unlocks anything.
    expect(await auth.getUsersByPin('111111'), isEmpty);

    // Their row SURVIVES (orders reference it) and is now setup-required, so
    // re-login routes to Create-PIN.
    final row = await db.storesDao.getUserById(leaving);
    expect(row != null, true);
    expect(row!.pin, kSetupRequiredPin);
    expect(row.pinHash, null);

    // The OTHER staffer's PIN is untouched — the till stays usable for them.
    expect(
      (await auth.getUsersByPin('222222', userId: other)).map((u) => u.id),
      [other],
    );
  });
}
