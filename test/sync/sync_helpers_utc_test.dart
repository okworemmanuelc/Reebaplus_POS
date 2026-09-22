// sync_helpers_utc_test.dart
//
// Regression test for issue #286: Whole-row uploads send times without a time
// zone, so records land in the cloud an hour late on non-UTC devices (e.g. WAT /
// UTC+1 in Nigeria).
//
// Root cause: serializeInsertable (sync_helpers.dart) previously used Drift's
// default ValueSerializer, which calls value.toIso8601String() on local
// DateTimes without .toUtc(). This produced zone-less strings (e.g.
// "2026-09-13T23:22:03.000") that Postgres interprets as UTC, shifting
// timestamps forward by the device's UTC offset.

import 'package:drift/drift.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/sync_helpers.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';

import '../helpers/dispatch_test_utils.dart';

void main() {
  group('Issue #286: Whole-row DataClass UTC timestamp serialization', () {
    test(
      'serializing UserData whose DateTime is a local value yields strings ending in Z and preserves instant',
      () {
        // Construct local DateTimes (isUtc == false).
        final localCreated = DateTime(2026, 9, 21, 14, 30, 0);
        final localUpdated = DateTime(2026, 9, 21, 14, 35, 22);
        expect(localCreated.isUtc, isFalse);
        expect(localUpdated.isUtc, isFalse);

        final user = UserData(
          id: UuidV7.generate(),
          businessId: 'biz-1',
          name: 'Chimezie Okwor',
          email: 'chimezie@example.com',
          pin: '123456',
          avatarColor: 'amber',
          biometricEnabled: false,
          createdAt: localCreated,
          lastUpdatedAt: localUpdated,
        );

        final payload = serializeInsertable(user);

        // created_at must end with 'Z'.
        expect(
          payload['created_at'],
          isA<String>(),
          reason: 'created_at must be serialized as a string',
        );
        final createdAtStr = payload['created_at'] as String;
        expect(
          createdAtStr.endsWith('Z'),
          isTrue,
          reason:
              'created_at must carry UTC zone designator "Z", got: $createdAtStr',
        );
        final parsedCreated = DateTime.parse(createdAtStr);
        expect(
          parsedCreated.toUtc().isAtSameMomentAs(localCreated.toUtc()),
          isTrue,
          reason: 'created_at parsed instant must match localCreated instant',
        );

        // last_updated_at must end with 'Z'.
        expect(
          payload['last_updated_at'],
          isA<String>(),
          reason: 'last_updated_at must be serialized as a string',
        );
        final lastUpdatedStr = payload['last_updated_at'] as String;
        expect(
          lastUpdatedStr.endsWith('Z'),
          isTrue,
          reason:
              'last_updated_at must carry UTC zone designator "Z", got: $lastUpdatedStr',
        );
        final parsedUpdated = DateTime.parse(lastUpdatedStr);
        expect(
          parsedUpdated.toUtc().isAtSameMomentAs(localUpdated.toUtc()),
          isTrue,
          reason:
              'last_updated_at parsed instant must match localUpdated instant',
        );
      },
    );

    test(
      'serializing CostBatchData whose receivedAt is a local value yields string ending in Z',
      () {
        final localReceived = DateTime(2026, 9, 13, 23, 22, 3);
        final localCreated = DateTime(2026, 9, 13, 23, 22, 3);
        final localUpdated = DateTime(2026, 9, 13, 23, 22, 3);

        final costBatch = CostBatchData(
          id: UuidV7.generate(),
          businessId: 'biz-1',
          productId: 'prod-1',
          storeId: 'store-1',
          qtyRemaining: 50,
          qtyOriginal: 50,
          costKobo: 120000,
          receivedAt: localReceived,
          createdAt: localCreated,
          lastUpdatedAt: localUpdated,
        );

        final payload = serializeInsertable(costBatch);

        final receivedAtStr = payload['received_at'] as String;
        expect(
          receivedAtStr.endsWith('Z'),
          isTrue,
          reason:
              'cost_batches.received_at must carry UTC "Z" designator so FIFO sorting '
              'is not corrupted across time zones. Got: $receivedAtStr',
        );
        expect(
          DateTime.parse(receivedAtStr).toUtc().isAtSameMomentAs(
                localReceived.toUtc(),
              ),
          isTrue,
        );

        final createdAtStr = payload['created_at'] as String;
        expect(createdAtStr.endsWith('Z'), isTrue);

        final lastUpdatedAtStr = payload['last_updated_at'] as String;
        expect(lastUpdatedAtStr.endsWith('Z'), isTrue);
      },
    );

    test(
      'Companion path output is unchanged and also produces strings ending in Z',
      () {
        final localTime = DateTime(2026, 9, 21, 16, 45, 12);
        final companion = UsersCompanion.insert(
          id: Value(UuidV7.generate()),
          businessId: 'biz-1',
          name: 'Test Staff',
          pin: '000000',
          createdAt: Value(localTime),
          lastUpdatedAt: Value(localTime),
        );

        final payload = serializeInsertable(companion);

        final createdAtStr = payload['created_at'] as String;
        expect(createdAtStr.endsWith('Z'), isTrue);
        expect(
          DateTime.parse(createdAtStr).toUtc().isAtSameMomentAs(
                localTime.toUtc(),
              ),
          isTrue,
        );

        final lastUpdatedAtStr = payload['last_updated_at'] as String;
        expect(lastUpdatedAtStr.endsWith('Z'), isTrue);
        expect(
          DateTime.parse(lastUpdatedAtStr).toUtc().isAtSameMomentAs(
                localTime.toUtc(),
              ),
          isTrue,
        );
      },
    );

    test(
      'guard test: representative DataClass per synced table serializes all DateTime columns with Z',
      () {
        final localNow = DateTime(2026, 9, 21, 10, 15, 30);
        final localDate = DateTime(2026, 9, 21);

        final List<Insertable> sampleRows = [
          // businesses
          BusinessData(
            id: UuidV7.generate(),
            name: 'Sample Biz',
            timezone: 'Africa/Lagos',
            onboardingComplete: true,
            createdAt: localNow,
            lastUpdatedAt: localNow,
            tracksEmptyCrates: true,
            subscriptionStatus: 'trial',
            trialEndsAt: localNow.add(const Duration(days: 14)),
            currentPeriodEnd: localNow.add(const Duration(days: 30)),
          ),
          // stores
          StoreData(
            id: UuidV7.generate(),
            businessId: 'biz-1',
            name: 'Main Store',
            createdAt: localNow,
            lastUpdatedAt: localNow,
            kind: 'store',
            isDeleted: false,
          ),
          // categories
          CategoryData(
            id: UuidV7.generate(),
            businessId: 'biz-1',
            name: 'Beer',
            createdAt: localNow,
            lastUpdatedAt: localNow,
            isDeleted: false,
          ),
          // suppliers
          SupplierData(
            id: UuidV7.generate(),
            businessId: 'biz-1',
            name: 'Breweries Plc',
            createdAt: localNow,
            lastUpdatedAt: localNow,
            isDeleted: false,
          ),
          // products
          ProductData(
            id: UuidV7.generate(),
            businessId: 'biz-1',
            name: 'Lager Beer',
            retailerPriceKobo: 50000,
            wholesalerPriceKobo: 48000,
            buyingPriceKobo: 40000,
            isAvailable: true,
            isDeleted: false,
            lowStockThreshold: 10,
            avgDailySales: 5,
            leadTimeDays: 2,
            safetyStockQty: 15,
            monthlyTargetUnits: 150,
            emptyCrateValueKobo: 50000,
            trackEmpties: false,
            allowFractionalSales: false,
            version: 1,
            expiryDate: localDate,
            createdAt: localNow,
            lastUpdatedAt: localNow,
          ),
          // inventory
          InventoryData(
            id: UuidV7.generate(),
            businessId: 'biz-1',
            productId: 'prod-1',
            storeId: 'store-1',
            quantity: 50,
            createdAt: localNow,
            lastUpdatedAt: localNow,
          ),
          // customers
          CustomerData(
            id: UuidV7.generate(),
            businessId: 'biz-1',
            name: 'Retail Customer',
            priceTier: 'retailer',
            walletLimitKobo: 0,
            isDeleted: false,
            createdAt: localNow,
            lastUpdatedAt: localNow,
          ),
          // orders
          OrderData(
            id: UuidV7.generate(),
            businessId: 'biz-1',
            orderNumber: 'ORD-001',
            totalAmountKobo: 100000,
            discountKobo: 0,
            netAmountKobo: 100000,
            amountPaidKobo: 100000,
            paymentType: 'cash',
            status: 'completed',
            riderName: 'None',
            crateDepositPaidKobo: 0,
            createdAt: localNow,
            lastUpdatedAt: localNow,
            completedAt: localNow,
          ),
          // expenses
          ExpenseData(
            id: UuidV7.generate(),
            businessId: 'biz-1',
            amountKobo: 15000,
            description: 'Fuel',
            status: 'approved',
            expenseDate: localNow,
            isDeleted: false,
            createdAt: localNow,
            lastUpdatedAt: localNow,
          ),
          // settings
          SettingData(
            id: UuidV7.generate(),
            businessId: 'biz-1',
            key: 'theme',
            value: 'dark',
            createdAt: localNow,
            lastUpdatedAt: localNow,
          ),
          // sessions
          SessionData(
            id: UuidV7.generate(),
            businessId: 'biz-1',
            userId: 'user-1',
            token: 'tok-1',
            expiresAt: localNow.add(const Duration(days: 30)),
            createdAt: localNow,
            lastUpdatedAt: localNow,
          ),
        ];

        for (final row in sampleRows) {
          final payload = serializeInsertable(row);
          for (final entry in payload.entries) {
            final key = entry.key;
            final val = entry.value;

            // Check any timestamp column by name convention.
            final isTimestampKey = key.endsWith('_at') ||
                key.endsWith('_date') ||
                key == 'created_at' ||
                key == 'last_updated_at' ||
                key == 'expires_at' ||
                key == 'received_at';

            if (isTimestampKey && val != null) {
              expect(
                val,
                isA<String>(),
                reason: '${row.runtimeType}.$key should be a String',
              );
              final strVal = val as String;
              expect(
                strVal.endsWith('Z'),
                isTrue,
                reason:
                    '${row.runtimeType}.$key must carry UTC "Z" designator, but was: "$strVal"',
              );
              // Must parse to a valid ISO-8601 instant.
              expect(
                () => DateTime.parse(strVal),
                returnsNormally,
                reason: '${row.runtimeType}.$key must be valid ISO-8601',
              );
            }
          }
        }
      },
    );

    test(
      'UUIDv7 instant parity: created_at matches UUIDv7 embedded creation instant within seconds',
      () {
        final nowLocal = DateTime.now();
        final id = UuidV7.generate();
        final user = UserData(
          id: id,
          businessId: 'biz-1',
          name: 'Jane Doe',
          pin: '123456',
          avatarColor: 'blue',
          biometricEnabled: false,
          createdAt: nowLocal,
          lastUpdatedAt: nowLocal,
        );

        final payload = serializeInsertable(user);
        final createdAtStr = payload['created_at'] as String;
        final createdAtUtc = DateTime.parse(createdAtStr).toUtc();

        // Extract instant from UUIDv7 ID:
        // UUIDv7 first 48 bits encode milliseconds since Unix epoch in UTC.
        final hex = id.replaceAll('-', '');
        final epochMs = int.parse(hex.substring(0, 12), radix: 16);
        final uuidInstantUtc =
            DateTime.fromMillisecondsSinceEpoch(epochMs, isUtc: true);

        final difference =
            createdAtUtc.difference(uuidInstantUtc).inSeconds.abs();
        expect(
          difference,
          lessThan(5),
          reason:
              'created_at instant ($createdAtUtc) must match UUIDv7 instant ($uuidInstantUtc) '
              'within seconds. A +1h shift would produce ~3600 seconds difference. Got: $difference s',
        );
      },
    );

    test(
      'enqueueUpsert with UserData re-read from Drift enqueues payload with UTC Z timestamps matching UUIDv7',
      () async {
        final boot = await bootstrapTestDb();
        try {
          final userId = UuidV7.generate();
          final localNow = DateTime(2026, 9, 21, 14, 0, 0);

          // Insert into Drift table
          await boot.db.into(boot.db.users).insert(
                UsersCompanion.insert(
                  id: Value(userId),
                  businessId: boot.businessId,
                  name: 'Original Name',
                  pin: '123456',
                  createdAt: Value(localNow),
                  lastUpdatedAt: Value(localNow),
                ),
              );

          // Re-read whole row as DataClass (Drift reads back as local DateTime)
          final userRow = await (boot.db.select(boot.db.users)
                ..where((u) => u.id.equals(userId)))
              .getSingle();

          // Enqueue upsert (as done during user profile edits)
          await boot.db.syncDao.enqueueUpsert('users', userRow);

          final pending = await getPendingQueue(boot.db);
          final userPush = pending.firstWhere((r) => r.actionType == 'users:upsert');
          final payload = decodePayload(userPush);

          final createdAtStr = payload['created_at'] as String;
          final lastUpdatedAtStr = payload['last_updated_at'] as String;

          expect(createdAtStr.endsWith('Z'), isTrue,
              reason: 'users:upsert created_at must end in Z, got: $createdAtStr');
          expect(lastUpdatedAtStr.endsWith('Z'), isTrue,
              reason: 'users:upsert last_updated_at must end in Z, got: $lastUpdatedAtStr');

          final parsedUtc = DateTime.parse(createdAtStr).toUtc();
          expect(parsedUtc.isAtSameMomentAs(localNow.toUtc()), isTrue);
        } finally {
          await boot.db.close();
        }
      },
    );

    test(
      'enqueueUpsert with CostBatchData re-read from Drift enqueues payload with UTC Z timestamps matching UUIDv7 instant',
      () async {
        final boot = await bootstrapTestDb();
        try {
          final storeId = UuidV7.generate();
          final productId = UuidV7.generate();
          final localReceived = DateTime(2026, 9, 13, 23, 22, 3);

          // Deterministic UUIDv7 whose embedded 48-bit timestamp matches localReceived instant
          final epochMs = localReceived.toUtc().millisecondsSinceEpoch;
          final msHex = epochMs.toRadixString(16).padLeft(12, '0');
          final batchId =
              '${msHex.substring(0, 8)}-${msHex.substring(8, 12)}-7000-8000-000000000001';
          final uuidInstantUtc = DateTime.fromMillisecondsSinceEpoch(
            int.parse(batchId.replaceAll('-', '').substring(0, 12), radix: 16),
            isUtc: true,
          );

          await boot.db.into(boot.db.stores).insert(
                StoresCompanion.insert(
                  id: Value(storeId),
                  businessId: boot.businessId,
                  name: 'Main Store',
                  kind: const Value('store'),
                ),
              );

          await boot.db.into(boot.db.products).insert(
                ProductsCompanion.insert(
                  id: Value(productId),
                  businessId: boot.businessId,
                  name: 'Stout',
                ),
              );

          await boot.db.into(boot.db.costBatches).insert(
                CostBatchesCompanion.insert(
                  id: Value(batchId),
                  businessId: boot.businessId,
                  productId: productId,
                  storeId: storeId,
                  qtyRemaining: 20,
                  qtyOriginal: 20,
                  receivedAt: Value(localReceived),
                  createdAt: Value(localReceived),
                  lastUpdatedAt: Value(localReceived),
                ),
              );

          // Re-read whole row as DataClass
          final batchRow = await (boot.db.select(boot.db.costBatches)
                ..where((b) => b.id.equals(batchId)))
              .getSingle();

          await boot.db.syncDao.enqueueUpsert('cost_batches', batchRow);

          final pending = await getPendingQueue(boot.db);
          final batchPush =
              pending.firstWhere((r) => r.actionType == 'cost_batches:upsert');
          final payload = decodePayload(batchPush);

          final receivedAtStr = payload['received_at'] as String;
          expect(receivedAtStr.endsWith('Z'), isTrue,
              reason: 'cost_batches:upsert received_at must end in Z, got: $receivedAtStr');

          final parsedUtc = DateTime.parse(receivedAtStr).toUtc();
          expect(parsedUtc.isAtSameMomentAs(localReceived.toUtc()), isTrue);
          expect(parsedUtc, equals(uuidInstantUtc),
              reason: 'serialized received_at ($parsedUtc) must equal UUIDv7 embedded instant ($uuidInstantUtc)');
          expect(receivedAtStr, equals(uuidInstantUtc.toIso8601String()),
              reason: 'serialized received_at string must equal ISO-8601 representation of UUIDv7 instant');
        } finally {
          await boot.db.close();
        }
      },
    );
  });
}
