// store_selection_gate_test.dart
//
// Unit test for the §12.1 "explicitly chosen" flag behind the POS pick-a-store
// gate. The gate prompts ANY user with more than one store to choose the store
// they're selling from before POS will sell, instead of selling from a silent
// default. `NavigationService.storeExplicitlyChosen` is what distinguishes a
// deliberate user pick from MainLayout's silent confined-user default; the gate
// (UI glue on top) shows whenever there are >1 stores and this flag is false.

import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/shared/services/navigation_service.dart';

void main() {
  // NavigationService is a singleton; start every test from a clean store lock.
  final nav = NavigationService();
  setUp(nav.clearStoreLock);

  test('clean state → no store, not explicitly chosen', () {
    expect(nav.lockedStoreId.value, isNull);
    expect(nav.storeExplicitlyChosen.value, isFalse);
  });

  test('explicit pick of a concrete store → chosen', () {
    nav.setLockedStore('store-a');
    expect(nav.lockedStoreId.value, 'store-a');
    expect(nav.storeExplicitlyChosen.value, isTrue);
  });

  test('MainLayout silent default (explicit: false) → set but NOT chosen', () {
    nav.setLockedStore('store-a', explicit: false);
    expect(nav.lockedStoreId.value, 'store-a');
    expect(nav.storeExplicitlyChosen.value, isFalse);
  });

  test('picking "All Stores" (null) is never a chosen selling store', () {
    nav.setLockedStore('store-a');
    expect(nav.storeExplicitlyChosen.value, isTrue);
    nav.setLockedStore(null);
    expect(nav.lockedStoreId.value, isNull);
    expect(nav.storeExplicitlyChosen.value, isFalse);
  });

  test('confirming the auto-defaulted store flips chosen even if id is unchanged',
      () {
    nav.setLockedStore('store-a', explicit: false);
    expect(nav.storeExplicitlyChosen.value, isFalse);
    // User taps the already-active store in the picker.
    nav.setLockedStore('store-a');
    expect(nav.lockedStoreId.value, 'store-a');
    expect(nav.storeExplicitlyChosen.value, isTrue);
  });

  test('logout / clearStoreLock resets the chosen flag', () {
    nav.setLockedStore('store-a');
    expect(nav.storeExplicitlyChosen.value, isTrue);
    nav.clearStoreLock();
    expect(nav.lockedStoreId.value, isNull);
    expect(nav.storeExplicitlyChosen.value, isFalse);
  });

  test('applyUserStoreLock (login) starts unchosen', () {
    nav.setLockedStore('store-a');
    nav.applyUserStoreLock('store-a');
    expect(nav.lockedStoreId.value, isNull);
    expect(nav.storeExplicitlyChosen.value, isFalse);
  });
}
