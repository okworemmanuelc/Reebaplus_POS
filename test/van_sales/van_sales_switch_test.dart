// The Van Sales on/off switch (`van_sales_switch.dart`).
//
// Van Sales ships switched off until it is fully tested. These tests pin what
// "off" means — every van gate denies, even for an owner holding every key, and
// the Driver role, the van permission keys and vans themselves drop out of the
// staff and settings lists — and that switching it on restores all of it.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/permissions/gate.dart';
import 'package:reebaplus_pos/core/permissions/gate_registry.dart';
import 'package:reebaplus_pos/core/settings/role_permissions_detail_screen.dart';
import 'package:reebaplus_pos/core/van_sales/van_sales_switch.dart';

RoleData _role(String slug) => RoleData(
  id: 'r-$slug',
  businessId: 'biz',
  name: slug,
  slug: slug,
  isSystemDefault: true,
  isDeleted: false,
  createdAt: DateTime(2026, 1, 1),
  lastUpdatedAt: DateTime(2026, 1, 1),
);

StoreData _store(String id, String kind) => StoreData(
  id: id,
  businessId: 'biz',
  name: id,
  kind: kind,
  isDeleted: false,
  createdAt: DateTime(2026, 1, 1),
  lastUpdatedAt: DateTime(2026, 1, 1),
);

/// An owner holding both van keys, and a driver holding theirs.
const _ceo = GateContext(
  grantedKeys: {'van.manage', 'van.sell', 'sales.make'},
  roleRank: GateTier.ceo,
  isReady: true,
);
const _driver = GateContext(
  grantedKeys: {'van.sell'},
  roleRank: GateTier.driver,
  isReady: true,
);

final _roles = [
  _role('ceo'),
  _role('manager'),
  _role('cashier'),
  _role('stock_keeper'),
  _role('driver'),
];

final _stores = [
  _store('warehouse', kStoreKindStore),
  _store('van-1', kStoreKindVan),
];

void main() {
  tearDown(() => debugOverrideVanSalesEnabled(null));

  group('switched off', () {
    setUp(() => debugOverrideVanSalesEnabled(false));

    test('both van gates deny, even for a CEO holding the keys', () {
      expect(Gates.vanManage.evaluate(_ceo), isFalse);
      expect(Gates.vanSell.evaluate(_ceo), isFalse);
      expect(Gates.vanSell.evaluate(_driver), isFalse);
    });

    test('the Driver role is not on offer', () {
      expect(
        rolesOnOffer(_roles).map((r) => r.slug),
        ['ceo', 'manager', 'cashier', 'stock_keeper'],
      );
    });

    test('the van permission keys are hidden; other keys are untouched', () {
      expect(isPermissionKeyHidden('van.manage'), isTrue);
      expect(isPermissionKeyHidden('van.sell'), isTrue);
      expect(isPermissionKeyHidden('sales.make'), isFalse);
      // The existing always-hidden keys stay hidden.
      expect(isPermissionKeyHidden('settings.delete_business'), isTrue);
    });

    test('vans are not offered for staff assignment', () {
      expect(assignableStores(_stores).map((s) => s.id), ['warehouse']);
    });
  });

  group('switched on', () {
    setUp(() => debugOverrideVanSalesEnabled(true));

    test('the van gates follow the keys again', () {
      expect(Gates.vanManage.evaluate(_ceo), isTrue);
      expect(Gates.vanSell.evaluate(_driver), isTrue);
      expect(Gates.vanManage.evaluate(_driver), isFalse);
    });

    test('the Driver role, van keys and vans all come back', () {
      expect(rolesOnOffer(_roles), hasLength(5));
      expect(isPermissionKeyHidden('van.manage'), isFalse);
      expect(isPermissionKeyHidden('van.sell'), isFalse);
      expect(assignableStores(_stores), hasLength(2));
    });
  });
}
