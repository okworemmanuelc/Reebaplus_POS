// v6 → v7 migration sanity test for the staff onboarding rev 3 work.
//
// What this verifies:
//   • The seven wizard-collected columns added in v7 (staff_phone,
//     next_of_kin_*, guarantor_*) exist on business_members.
//   • Each column accepts inserts and round-trips text correctly.
//   • Inserting a row with all wizard fields NULL still works (matches
//     CEO + grandfathered membership reality).
//
// What this does NOT verify (limitation worth noting):
//   • The actual onUpgrade(6, 7) code path. Doing that properly requires
//     drift_dev's schema-versioning infrastructure (`dart run drift_dev
//     schema dump` + `verifySelf` helpers), which is not currently set up
//     in this repo. The risk this leaves: a typo in the addColumn call
//     list inside _AppDatabase.onUpgrade that doesn't match the table
//     definition. Fresh installs would catch the typo at onCreate; only
//     mid-flight upgrades on existing devices would silently miss a
//     column. Mitigation: addColumn calls in app_database.dart line up
//     1:1 with the column getters above them; reviewer should grep both.
//
// If we ever add the schema-dump infra, this file is the natural home for
// the proper "boot at v6, migrate, assert" version.

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';

void main() {
  late AppDatabase db;
  late String businessId;
  late String userId;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    businessId = UuidV7.generate();
    userId = UuidV7.generate();
    db.businessIdResolver = () => businessId;

    await db.into(db.businesses).insert(
          BusinessesCompanion.insert(id: Value(businessId), name: 'Test Biz'),
        );
    await db.into(db.users).insert(
          UsersCompanion.insert(
            id: Value(userId),
            businessId: businessId,
            name: 'Test Staff',
            role: 'cashier',
            pin: '0000',
          ),
        );
  });

  tearDown(() async {
    await db.close();
  });

  test('wizard columns exist on business_members and round-trip', () async {
    final memberId = UuidV7.generate();
    await db.into(db.businessMembers).insert(
          BusinessMembersCompanion.insert(
            id: Value(memberId),
            businessId: businessId,
            userId: userId,
            role: 'cashier',
            staffPhone: const Value('+2348012345678'),
            nextOfKinName: const Value('Jane Doe'),
            nextOfKinPhone: const Value('+2348087654321'),
            nextOfKinRelation: const Value('Mother'),
            guarantorName: const Value('John Smith'),
            guarantorPhone: const Value('+2347012345678'),
            guarantorRelation: const Value('Employer'),
          ),
        );

    final row = await (db.select(db.businessMembers)
          ..where((t) => t.id.equals(memberId)))
        .getSingle();

    expect(row.staffPhone, '+2348012345678');
    expect(row.nextOfKinName, 'Jane Doe');
    expect(row.nextOfKinPhone, '+2348087654321');
    expect(row.nextOfKinRelation, 'Mother');
    expect(row.guarantorName, 'John Smith');
    expect(row.guarantorPhone, '+2347012345678');
    expect(row.guarantorRelation, 'Employer');
  });

  test('wizard columns are nullable — CEO/grandfathered shape works',
      () async {
    final memberId = UuidV7.generate();
    await db.into(db.businessMembers).insert(
          BusinessMembersCompanion.insert(
            id: Value(memberId),
            businessId: businessId,
            userId: userId,
            role: 'ceo',
            roleTier: const Value(6),
            verificationStatus: const Value('approved'),
            // No wizard fields — defaults to NULL.
          ),
        );

    final row = await (db.select(db.businessMembers)
          ..where((t) => t.id.equals(memberId)))
        .getSingle();

    expect(row.staffPhone, isNull);
    expect(row.nextOfKinName, isNull);
    expect(row.nextOfKinPhone, isNull);
    expect(row.nextOfKinRelation, isNull);
    expect(row.guarantorName, isNull);
    expect(row.guarantorPhone, isNull);
    expect(row.guarantorRelation, isNull);
  });

  test('partial wizard fields (next-of-kin set, guarantor null) work',
      () async {
    final memberId = UuidV7.generate();
    await db.into(db.businessMembers).insert(
          BusinessMembersCompanion.insert(
            id: Value(memberId),
            businessId: businessId,
            userId: userId,
            role: 'cashier',
            staffPhone: const Value('+2348012345678'),
            nextOfKinName: const Value('Jane Doe'),
            nextOfKinPhone: const Value('+2348087654321'),
            nextOfKinRelation: const Value('Mother'),
            // guarantor_* deliberately omitted.
          ),
        );

    final row = await (db.select(db.businessMembers)
          ..where((t) => t.id.equals(memberId)))
        .getSingle();

    expect(row.nextOfKinName, 'Jane Doe');
    expect(row.guarantorName, isNull);
  });
}
