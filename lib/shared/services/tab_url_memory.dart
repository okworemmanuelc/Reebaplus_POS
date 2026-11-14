import 'package:reebaplus_pos/shared/services/navigation_service.dart';
import 'package:reebaplus_pos/shared/services/tab_url_memory_stub.dart'
    if (dart.library.js_interop) 'package:reebaplus_pos/shared/services/tab_url_memory_web.dart'
    as impl;

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

/// Fragment for [tab], e.g. `#/orders`; null for an index with no name.
String? fragmentForTab(int tab) {
  final name = NavigationService.indexToRoute[tab];
  return name == null ? null : '#/$name';
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

/// Current URL fragment in the browser; '' on every other platform.
String readUrlFragment() => impl.readUrlFragment();

/// Replaces (never pushes) the URL fragment. No-op off the browser.
void replaceUrlFragment(String fragment) => impl.replaceUrlFragment(fragment);
