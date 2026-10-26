// The Browse-first on/off switch (#425, PRD #421 "Ship order").
//
// Browse is built, but the front door must not reach shops' phones until a
// Shopper can order end to end (#426 place order, #427 shop Online tab), or new
// installs would land on a feed with nothing to order. Until then a phone with
// no business user keeps opening on today's Welcome screen. Flip
// [kBrowseFirstEnabled] to `true` (and release) when #426/#427 ship — nothing
// else needs to change.
//
// What the switch decides: the signed-out entry screen in `_HomeRouter`
// (Browse vs Welcome), and whether the till's side menu shows **Shop** (#437).
// A phone signed in to a business always opens on the PIN screen and till,
// switch on or off.
library;

import 'package:flutter/foundation.dart';

/// Whether the app opens on Browse for phones with no business user.
const bool kBrowseFirstEnabled = false;

bool? _override;

/// [kBrowseFirstEnabled], unless a test has overridden it.
bool isBrowseFirstEnabled() => _override ?? kBrowseFirstEnabled;

/// Forces the switch for a test; `null` restores [kBrowseFirstEnabled].
@visibleForTesting
void debugOverrideBrowseFirstEnabled(bool? enabled) => _override = enabled;
