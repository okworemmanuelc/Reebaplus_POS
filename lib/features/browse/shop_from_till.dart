// Shop from the till (#437, PRD #421 user stories 3, 49–53).
//
// A phone signed in to a business shops with that same sign-in: the
// business's Supabase session is the Shopper login (ADR 0030), so the
// Shopper RPCs see the same `auth.uid()`. Coming back from Shop locks the
// till, so the existing PIN screen stands between the shopper side and the
// business — whoever is holding the phone needs the PIN to get back in.
library;

import 'package:flutter/material.dart';

import 'package:reebaplus_pos/features/browse/screens/browse_screen.dart';

/// Opens Browse over the till on [navigator] (the app's root navigator), and
/// once the Shopper leaves it — the back button or the system back — runs
/// [lockTill], which drops the till to the PIN screen.
///
/// [lockTill] also runs if the route is torn down another way (an auto-lock
/// already reset the stack); locking an already-locked till is harmless.
Future<void> openShopFromTill(
  NavigatorState navigator, {
  required Future<void> Function() lockTill,
}) async {
  await navigator.push(
    MaterialPageRoute<void>(
      settings: const RouteSettings(name: kShopFromTillRoute),
      builder: (_) => const BrowseScreen(fromTill: true),
    ),
  );
  await lockTill();
}

/// Route name of Browse opened from the till.
const String kShopFromTillRoute = 'shop-from-till';
