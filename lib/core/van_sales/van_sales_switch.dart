// The Van Sales on/off switch — the one place that decides whether anybody can
// see or use van sales (PRD #139 / ADR 0019).
//
// Van Sales v1 is built and its cloud migrations (0161–0165) are live, but it
// is SWITCHED OFF until it has been fully tested. Flip [kVanSalesEnabled] to
// `true` and release to turn it back on — nothing else needs to change.
//
// What the switch hides (the user-facing surface):
//  * both van gates — `Gates.vanManage` and `Gates.vanSell` deny for everyone,
//    which takes out the Van Sales drawer entry and every hub screen, the
//    driver terminal takeover, the Vans section of Settings → Stores, and a
//    driver's ability to select their van;
//  * the Driver role wherever a role can be picked or configured (Invite
//    Staff, Change Role, Roles & Permissions, the Activity Logs and Sync Issues
//    access lists) — a Driver invited while the feature is off would sign in to
//    a shell with nothing they are allowed to do;
//  * the `van.manage` / `van.sell` permission toggles;
//  * vans in the staff store-assignment sheet.
//
// What it deliberately does NOT touch: the van exclusions in store pickers and
// reports, the road-sale checks in `createOrder`, the costing fences, the van
// tables' sync and the late-sale restatement sweep, the driver offboarding
// guard, and the Drift / cloud schema. Those are inert while no van exists and
// protect money the moment one does, so they stay on either way.
library;

import 'package:flutter/foundation.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/stores/van_store.dart';

/// Whether Van Sales ships switched on. `false` until it has been fully tested.
const bool kVanSalesEnabled = false;

/// The permission keys that belong to Van Sales. Hidden from every permission
/// editor while the feature is off.
const Set<String> kVanSalesPermissionKeys = {'van.manage', 'van.sell'};

/// The seeded role that only exists for Van Sales.
const String kDriverRoleSlug = 'driver';

bool? _override;

/// Whether Van Sales is on right now: [kVanSalesEnabled], unless a test has
/// overridden it.
///
/// A plain top-level function (not a getter) so the gate registry can hold a
/// `const` tear-off of it — see `Gate.when`.
bool isVanSalesEnabled() => _override ?? kVanSalesEnabled;

/// Forces the switch for a test; `null` restores [kVanSalesEnabled]. The van
/// suites set it `true` so they keep guarding the feature while it ships off.
@visibleForTesting
void debugOverrideVanSalesEnabled(bool? enabled) => _override = enabled;

/// [roles] minus the ones that belong to a switched-off feature — today, the
/// Driver role while Van Sales is off. For any list a user picks a role from or
/// configures a role in; lookups by id must keep using the full list.
List<RoleData> rolesOnOffer(List<RoleData> roles) {
  if (isVanSalesEnabled()) return roles;
  return [for (final r in roles) if (r.slug != kDriverRoleSlug) r];
}

/// True when [key] is a van permission and Van Sales is switched off.
bool isSwitchedOffPermissionKey(String key) =>
    !isVanSalesEnabled() && kVanSalesPermissionKeys.contains(key);

/// [stores] for a staff store-assignment list: every location while Van Sales
/// is on, vans dropped while it is off.
List<StoreData> assignableStores(List<StoreData> stores) =>
    isVanSalesEnabled() ? stores : withoutVans(stores);
