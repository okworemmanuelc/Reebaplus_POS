// The Online ordering on/off switch — the one place that decides whether
// anybody can see or use online ordering (PRD #421).
//
// Online ordering is built and its cloud migrations are live, but the owner
// SWITCHED IT OFF (2026-10-29) to focus on other work. Flip
// [kOnlineOrderingEnabled] to `true` and release to turn it back on — nothing
// else needs to change.
//
// What the switch hides (the user-facing surface):
//  * the four online gates — `Gates.manageOnlineStore`, `Gates.manageListing`,
//    `Gates.viewOnlineOrders` and `Gates.answerOnlineOrders` deny for everyone,
//    which takes out the Online store settings, the Store Details online card,
//    the product page's online listing (switch, description, gallery), the
//    Orders screen's Online tab and its badges, and online-order pushes' taps;
//  * the Settings → Online store row;
//  * the four permission toggles in Roles & Permissions;
//  * Browse-first (`isBrowseFirstEnabled` needs this switch too), so a phone
//    with no business user opens on Welcome and the side menu has no Shop.
//
// What it deliberately does NOT touch: the Drift / cloud schema, the online
// tables' sync, the cloud storefront RPCs and the reebaplus.com/shop pages.
// While no store is switched online they list nothing.
library;

import 'package:flutter/foundation.dart';

/// Whether online ordering ships switched on. Off by owner choice.
const bool kOnlineOrderingEnabled = false;

/// The permission keys that belong to online ordering. Hidden from every
/// permission editor while the feature is off.
const Set<String> kOnlineOrderingPermissionKeys = {
  'stores.online_ordering',
  'products.manage_listing',
  'online_orders.view',
  'online_orders.answer',
};

bool? _override;

/// Whether online ordering is on right now: [kOnlineOrderingEnabled], unless a
/// test has overridden it. A plain function so a gate can hold a `const`
/// tear-off of it — see `Gate.when`.
bool isOnlineOrderingEnabled() => _override ?? kOnlineOrderingEnabled;

/// Forces the switch for a test; `null` restores [kOnlineOrderingEnabled].
@visibleForTesting
void debugOverrideOnlineOrderingEnabled(bool? enabled) => _override = enabled;
