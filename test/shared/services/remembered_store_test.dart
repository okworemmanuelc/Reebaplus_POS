// remembered_store_test.dart
//
// #653: the store a user deliberately picked survives the app closing and the
// app locking, until someone picks another. Covers the prefs service and the
// NavigationService restore (the glue MainLayout drives).

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:reebaplus_pos/shared/services/active_store_memory.dart';
import 'package:reebaplus_pos/shared/services/navigation_service.dart';

const _biz = 'biz-1';
const _alice = 'user-alice';
const _bob = 'user-bob';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // NavigationService is a singleton; each test starts clean.
  final nav = NavigationService();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    nav.forgetSavedStore();
    nav.clearStoreLock();
  });

  /// Starts a session and waits for the saved-pick read to finish.
  Future<void> startSession(String userId) async {
    nav.beginStoreRestore(businessId: _biz, userId: userId);
    await pumpEventQueue();
  }

  /// MainLayout's job: apply the waiting pick against the selectable stores.
  bool apply(Set<String> stores, {bool canViewAll = false}) =>
      nav.applySavedStorePick(
        selectableStoreIds: stores,
        canViewAllStores: canViewAll,
      );

  Future<SavedStorePick?> saved(String userId) =>
      ActiveStoreMemory.read(_biz, userId);

  group('ActiveStoreMemory', () {
    test('save / read / clear round-trips a store and All Stores', () async {
      expect(await saved(_alice), isNull);
      await ActiveStoreMemory.save(_biz, _alice, 'store-b');
      expect(await saved(_alice), const SavedStorePick.store('store-b'));
      await ActiveStoreMemory.save(_biz, _alice, null);
      expect(await saved(_alice), const SavedStorePick.allStores());
      expect(
        (await SharedPreferences.getInstance()).getString(
          'active_store.$_biz.$_alice',
        ),
        '__all__',
      );
      await ActiveStoreMemory.clear(_biz, _alice);
      expect(await saved(_alice), isNull);
    });

    test(
      'clearForBusiness removes only that business, clearAll removes all',
      () async {
        await ActiveStoreMemory.save(_biz, _alice, 's1');
        await ActiveStoreMemory.save(_biz, _bob, 's2');
        await ActiveStoreMemory.save('biz-2', _alice, 's3');
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('unrelated', 'keep');

        await ActiveStoreMemory.clearForBusiness(_biz);
        expect(await saved(_alice), isNull);
        expect(await saved(_bob), isNull);
        expect(await ActiveStoreMemory.read('biz-2', _alice), isNotNull);

        await ActiveStoreMemory.clearAll();
        expect(await ActiveStoreMemory.read('biz-2', _alice), isNull);
        expect(prefs.getString('unrelated'), 'keep');
      },
    );
  });

  group('NavigationService restore', () {
    test(
      'only an explicit pick is saved; the silent default never is',
      () async {
        await startSession(_alice);
        nav.setLockedStore('store-a', explicit: false);
        await pumpEventQueue();
        expect(await saved(_alice), isNull);

        nav.setLockedStore('store-b');
        await pumpEventQueue();
        expect(await saved(_alice), const SavedStorePick.store('store-b'));

        nav.setLockedStore(null); // deliberate All Stores
        await pumpEventQueue();
        expect(await saved(_alice), const SavedStorePick.allStores());
      },
    );

    test('pick B, lock, unlock: B is still active and counts as chosen '
        '(POS does not prompt)', () async {
      await startSession(_alice);
      nav.setLockedStore('store-b');
      await pumpEventQueue();

      // lockApp() no longer calls clearStoreLock(): nothing to simulate there.
      // Unlock = setCurrentUser: applyUserStoreLock resets, then restore runs.
      nav.applyUserStoreLock(null);
      await startSession(_alice);
      expect(apply({'store-a', 'store-b'}), isTrue);

      expect(nav.lockedStoreId.value, 'store-b');
      expect(nav.storeExplicitlyChosen.value, isTrue);
      expect(nav.allStoresChosen.value, isFalse);
    });

    test(
      'pick B, restart (fresh session, same prefs): B is restored',
      () async {
        await ActiveStoreMemory.save(_biz, _alice, 'store-b');
        await startSession(_alice);
        expect(apply({'store-a', 'store-b'}), isTrue);
        expect(nav.lockedStoreId.value, 'store-b');
        expect(nav.storeExplicitlyChosen.value, isTrue);
      },
    );

    test('no flash: the restore is pending from the first synchronous moment '
        'until the pick is applied, so the default cannot run first', () async {
      await ActiveStoreMemory.save(_biz, _alice, 'store-b');

      nav.beginStoreRestore(businessId: _biz, userId: _alice);
      // Synchronously after setCurrentUser, before the prefs read returns.
      expect(nav.storeRestorePhase.value, StoreRestorePhase.reading);

      await pumpEventQueue();
      expect(nav.storeRestorePhase.value, StoreRestorePhase.pickReady);
      // Nothing has been put on screen yet: still no active store.
      expect(nav.lockedStoreId.value, isNull);

      apply({'store-a', 'store-b'});
      // The store is set BEFORE the phase returns to idle, so the first build
      // that is allowed to run the default already sees B.
      expect(nav.lockedStoreId.value, 'store-b');
      expect(nav.storeRestorePhase.value, StoreRestorePhase.idle);
    });

    test(
      'nothing saved: the phase drops to idle so the default can run',
      () async {
        await startSession(_alice);
        expect(nav.storeRestorePhase.value, StoreRestorePhase.idle);
        expect(nav.hasSavedStorePick, isFalse);
      },
    );

    test(
      'B deleted or unassigned: ignored, key cleared, default takes over',
      () async {
        await ActiveStoreMemory.save(_biz, _alice, 'store-b');
        await startSession(_alice);

        expect(apply({'store-a', 'store-c'}), isFalse);
        expect(nav.lockedStoreId.value, isNull);
        expect(nav.storeExplicitlyChosen.value, isFalse);
        expect(nav.storeRestorePhase.value, StoreRestorePhase.idle);
        await pumpEventQueue();
        expect(await saved(_alice), isNull);
      },
    );

    test('deliberate All Stores is restored for a CEO', () async {
      await ActiveStoreMemory.save(_biz, _alice, null);
      await startSession(_alice);
      expect(nav.savedPickIsAllStores, isTrue);

      expect(apply({'store-a'}, canViewAll: true), isTrue);
      expect(nav.lockedStoreId.value, isNull);
      expect(nav.allStoresChosen.value, isTrue);
    });

    test(
      'a Manager who lost all-stores access falls back and the key clears',
      () async {
        await ActiveStoreMemory.save(_biz, _alice, null);
        await startSession(_alice);

        expect(apply({'store-a'}, canViewAll: false), isFalse);
        expect(nav.allStoresChosen.value, isFalse);
        await pumpEventQueue();
        expect(await saved(_alice), isNull);
      },
    );

    test('logout forgets the pick; a new session restores nothing', () async {
      await startSession(_alice);
      nav.setLockedStore('store-b');
      await pumpEventQueue();
      expect(await saved(_alice), isNotNull);

      // AuthService.logout(): forgetSavedStore() then clearStoreLock().
      nav.forgetSavedStore();
      nav.clearStoreLock();
      await pumpEventQueue();

      expect(await saved(_alice), isNull);
      await startSession(_alice);
      expect(nav.hasSavedStorePick, isFalse);
      expect(nav.storeRestorePhase.value, StoreRestorePhase.idle);
    });

    test(
      'a different user on the same business does not inherit the pick',
      () async {
        await ActiveStoreMemory.save(_biz, _alice, 'store-b');
        await startSession(_bob);

        expect(nav.hasSavedStorePick, isFalse);
        expect(nav.storeRestorePhase.value, StoreRestorePhase.idle);
        expect(nav.lockedStoreId.value, isNull);
        // ...and Alice's key is untouched.
        expect(await saved(_alice), const SavedStorePick.store('store-b'));
      },
    );

    test(
      'a pick made before the saved one is applied wins and is kept',
      () async {
        await ActiveStoreMemory.save(_biz, _alice, 'store-b');
        await startSession(_alice);

        nav.setLockedStore('store-c'); // user acts first (e.g. a deep link)
        expect(nav.storeRestorePhase.value, StoreRestorePhase.idle);
        expect(apply({'store-b', 'store-c'}), isFalse);
        expect(nav.lockedStoreId.value, 'store-c');
        await pumpEventQueue();
        expect(await saved(_alice), const SavedStorePick.store('store-c'));
      },
    );
  });
}
