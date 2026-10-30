// The Online ordering switch (owner 2026-10-29): off hides every online gate,
// the four permission toggles and Browse-first, even when granted.

import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/permissions/gate.dart';
import 'package:reebaplus_pos/core/permissions/gate_registry.dart';
import 'package:reebaplus_pos/features/settings/screens/role_permissions_detail_screen.dart';
import 'package:reebaplus_pos/core/storefront/browse_switch.dart';
import 'package:reebaplus_pos/core/storefront/online_ordering_switch.dart';

void main() {
  const ceo = GateContext(
    grantedKeys: kOnlineOrderingPermissionKeys,
    roleRank: GateTier.ceo,
    isReady: true,
  );
  final onlineGates = [
    Gates.manageOnlineStore,
    Gates.manageListing,
    Gates.viewOnlineOrders,
    Gates.answerOnlineOrders,
  ];

  tearDown(() {
    debugOverrideOnlineOrderingEnabled(null);
    debugOverrideBrowseFirstEnabled(null);
  });

  test('ships switched off', () {
    expect(kOnlineOrderingEnabled, isFalse);
    expect(isOnlineOrderingEnabled(), isFalse);
  });

  test('off: every online gate denies, even for a CEO holding the keys', () {
    for (final g in onlineGates) {
      expect(g.evaluate(ceo), isFalse, reason: g.name);
    }
  });

  test('on: the gates follow the permission keys again', () {
    debugOverrideOnlineOrderingEnabled(true);
    for (final g in onlineGates) {
      expect(g.evaluate(ceo), isTrue, reason: g.name);
    }
  });

  test('off: the four permission toggles are hidden', () {
    for (final k in kOnlineOrderingPermissionKeys) {
      expect(isPermissionKeyHidden(k), isTrue, reason: k);
    }
    debugOverrideOnlineOrderingEnabled(true);
    for (final k in kOnlineOrderingPermissionKeys) {
      expect(isPermissionKeyHidden(k), isFalse, reason: k);
    }
  });

  test('off: Browse-first stays off even when forced on', () {
    debugOverrideBrowseFirstEnabled(true);
    expect(isBrowseFirstEnabled(), isFalse);
    debugOverrideOnlineOrderingEnabled(true);
    expect(isBrowseFirstEnabled(), isTrue);
  });
}
