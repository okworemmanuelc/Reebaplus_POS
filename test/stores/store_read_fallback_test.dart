import 'package:drift/drift.dart' hide isNull;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/business_scoped_stream.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/shared/services/navigation_service.dart';

import '../helpers/screen_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ScreenTestEnvironment env;
  late String storeAId;
  late String storeBId;
  late ProviderContainer container;
  late NavigationService nav;

  setUp(() async {
    env = await setupScreenTestEnvironment(
      productCount: 0,
      businessName: 'Read Fallback Biz',
    );
    storeAId = env.storeId;
    storeBId = UuidV7.generate();

    await env.db
        .into(env.db.stores)
        .insert(
          StoresCompanion.insert(
            id: Value(storeBId),
            businessId: env.businessId,
            name: 'Store B',
          ),
        );

    nav = NavigationService();
    nav.clearStoreLock();

    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(env.db),
        currentBusinessIdProvider.overrideWithValue(env.businessId),
      ],
    );
    // Keep allStoresProvider alive and subscribed
    container.listen(allStoresProvider, (_, __) {});
  });

  tearDown(() async {
    nav.clearStoreLock();
    container.dispose();
    await env.dispose();
  });

  test(
    'when locked store is null, activeStoreIdProvider is null and activeStoreLabelProvider is All Stores',
    () async {
      nav.clearStoreLock();

      await container.read(allStoresProvider.future);

      expect(container.read(activeStoreIdProvider), isNull);
      expect(container.read(activeStoreLabelProvider), 'All Stores');
    },
  );

  test(
    'when locked store is active, activeStoreIdProvider and label reflect the locked store',
    () async {
      nav.setLockedStore(storeAId);

      await container.read(allStoresProvider.future);

      expect(container.read(activeStoreIdProvider), storeAId);
      expect(container.read(activeStoreLabelProvider), 'Main Store');
      expect(container.read(activeWriteStoreProvider).id, storeAId);
      expect(container.read(activeWriteStoreProvider).label, 'Main Store');
    },
  );

  test(
    'when locked store is not an active store, activeStoreIdProvider falls back to null and label to All Stores',
    () async {
      final nonExistentId = UuidV7.generate();
      nav.setLockedStore(nonExistentId);

      await container.read(allStoresProvider.future);

      expect(container.read(activeStoreIdProvider), isNull);
      expect(container.read(activeStoreLabelProvider), 'All Stores');
    },
  );

  test(
    'when locked store is soft-deleted, reactive stream updates activeStoreIdProvider to null',
    () async {
      nav.setLockedStore(storeBId);

      final stores = await container.read(allStoresProvider.future);
      expect(stores.any((s) => s.id == storeBId), isTrue);
      expect(container.read(activeStoreIdProvider), storeBId);
      expect(container.read(activeStoreLabelProvider), 'Store B');

      // Soft delete Store B
      await env.db.storesDao.softDeleteStore(storeBId);

      // Allow stream to pump
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(container.read(activeStoreIdProvider), isNull);
      expect(container.read(activeStoreLabelProvider), 'All Stores');
    },
  );
}
