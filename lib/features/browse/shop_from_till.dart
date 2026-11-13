// Shop from the till (#437, PRD #421 user stories 3, 49–53).
//
// A phone signed in to a business shops with that same sign-in: the
// business's Supabase session is the Shopper login (ADR 0030), so the
// Shopper RPCs see the same `auth.uid()`. Coming back from Shop returns
// straight to the till: there is no PIN lock any more (#812).
library;

import 'package:flutter/material.dart';

import 'package:reebaplus_pos/features/browse/screens/browse_screen.dart';

/// Opens Browse over the till on [navigator] (the app's root navigator). The
/// Shopper leaves it with the back button or the system back, landing back on
/// the till.
Future<void> openShopFromTill(NavigatorState navigator) async {
  await navigator.push(
    MaterialPageRoute<void>(
      settings: const RouteSettings(name: kShopFromTillRoute),
      builder: (_) => const BrowseScreen(fromTill: true),
    ),
  );
}

/// Route name of Browse opened from the till.
const String kShopFromTillRoute = 'shop-from-till';
