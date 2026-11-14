import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/services.dart' show SystemNavigator;
import 'package:reebaplus_pos/shared/services/navigation_service.dart';

/// Browser reload keeps the tab (#828). Pure rules first, URL glue below.

/// Tab index named by a URL fragment such as `#/orders`, or null when the
/// fragment is empty, unknown, or names something that is not a tab.
int? tabIndexFromFragment(String? fragment) {
  if (fragment == null) return null;
  var f = fragment.trim();
  if (f.startsWith('#')) f = f.substring(1);
  if (f.startsWith('/')) f = f.substring(1);
  if (f.endsWith('/')) f = f.substring(0, f.length - 1);
  if (f.isEmpty) return null;
  f = f.toLowerCase();
  for (final e in NavigationService.indexToRoute.entries) {
    if (e.value == f) return e.key;
  }
  return null;
}

/// Route for [tab], e.g. `/orders` (shown as `#/orders` in the browser's
/// address bar); null for an index with no name.
String? fragmentForTab(int tab) {
  final name = NavigationService.indexToRoute[tab];
  return name == null ? null : '/$name';
}

/// The tab a fresh session opens on: the remembered [saved] tab when this user
/// may see it, otherwise the role's [roleLanding].
int resolveStartTab({
  required int? saved,
  required int roleLanding,
  required bool Function(int tab) isAllowed,
}) {
  if (saved != null && isAllowed(saved)) return saved;
  return roleLanding;
}

/// The route the browser opened on (e.g. `/orders` from `#/orders`).
///
/// Captured by [captureStartRoute] in `main()` before `runApp`, because the
/// root Navigator rewrites the address bar to `#/` on its first frame.
String? _startRoute;
String? get startRoute => _startRoute;

/// Call once in `main()`, before `runApp`. Browser only.
void captureStartRoute() {
  _startRoute = PlatformDispatcher.instance.defaultRouteName;
}

/// Shows [route] in the address bar, replacing (never pushing) the history
/// entry. Goes through the engine so its own back-button bookkeeping stays
/// intact. Browser only.
void replaceUrlRoute(String route) {
  SystemNavigator.routeInformationUpdated(uri: Uri.parse(route), replace: true);
}
