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
}
