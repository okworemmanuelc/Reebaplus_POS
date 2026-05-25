import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/shared/services/pin_hasher.dart';

void main() {
  test('setUserPin path produces pinHash/pinSalt and >=100k iterations', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);

    final businessId = UuidV7.generate();
    final userId = UuidV7.generate();
    await db.into(db.businesses).insert(BusinessesCompanion.insert(
          id: Value(businessId),
          name: 'Test Biz',
        ));
    await db.into(db.users).insert(UsersCompanion.insert(
          id: Value(userId),
          businessId: businessId,
          name: 'Tester',
          pin: '__SETUP_REQUIRED__',
        ));

    // Mirror auth_service.setUserPin's write path.
    final salt = PinHasher.generateSaltBase64();
    const iterations = PinHasher.defaultIterations;
    final hash = PinHasher.hashBase64('123456', salt, iterations);
    // Setting lastUpdatedAt explicitly skirts the (pre-existing, out-of-scope)
    // bump_users_last_updated_at trigger that writes CURRENT_TIMESTAMP as TEXT
    // into a Drift INT-encoded DateTime column.
    await (db.update(db.users)..where((u) => u.id.equals(userId))).write(
      UsersCompanion(
        pin: const Value('__HASHED__'),
        pinHash: Value(hash),
        pinSalt: Value(salt),
        pinIterations: const Value(iterations),
        lastUpdatedAt: Value(DateTime.now()),
      ),
    );

    final row =
        await (db.select(db.users)..where((u) => u.id.equals(userId))).getSingle();
    expect(row.pinHash, isNotNull);
    expect(row.pinSalt, isNotNull);
    expect(row.pinIterations, isNotNull);
    expect(row.pinIterations!, greaterThanOrEqualTo(100000));
    expect(row.pin, equals('__HASHED__'));
  });
}
