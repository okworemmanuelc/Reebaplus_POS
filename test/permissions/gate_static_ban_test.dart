// Static enforcement seam (issue #17, ADR 0002). A source scan that bans the
// bare `hasPermission(ref, …)` check outside the permissions module, carrying a
// **shrinking allowlist** of the sites not yet migrated. Prior art: the
// sync-registry golden/registration tests.
//
// The allowlist is a ratchet:
//   • a bare check in a file above its allowed count fails (cite a Gate);
//   • migrating a site without shrinking the allowlist fails (keep it honest).
// Each migration batch (#18–21) deletes exactly the sites it lifts; the flip
// issue (#22) empties this map and a planted bare check then fails the suite.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Bare-check call sites still permitted, `path → count`. Seeded post the
/// Receive-Stock tracer migration (issue #17). SHRINK this — never grow it.
const _allowlist = <String, int>{
  'lib/core/settings/activity_logs_access_screen.dart': 1,
  'lib/core/settings/appearance_settings_screen.dart': 1,
  'lib/core/settings/business_info_screen.dart': 1,
  'lib/core/settings/delete_business_screen.dart': 1,
  'lib/core/settings/role_permissions_detail_screen.dart': 1,
  'lib/core/settings/roles_permissions_screen.dart': 1,
  'lib/core/settings/security_settings_screen.dart': 1,
  'lib/core/settings/settings_screen.dart': 2,
  'lib/core/settings/stores_settings_screen.dart': 1,
  'lib/core/settings/subscription_screen.dart': 1,
  'lib/core/settings/sync_issues_access_screen.dart': 1,
  'lib/features/customers/screens/customer_detail_screen.dart': 8,
  'lib/features/customers/screens/customers_screen.dart': 1,
  'lib/features/customers/widgets/edit_customer_sheet.dart': 1,
  'lib/features/expenses/screens/expenses_screen.dart': 3,
  'lib/features/inventory/screens/add_product_screen.dart': 2,
  'lib/features/inventory/screens/inventory_screen.dart': 3,
  'lib/features/orders/screens/orders_screen.dart': 2,
  'lib/features/staff/screens/staff_detail_screen.dart': 6,
  'lib/features/staff/screens/staff_permissions_screen.dart': 1,
  'lib/features/stores/screens/store_details_screen.dart': 1,
  'lib/features/stores/screens/stores_screen.dart': 5,
  'lib/features/stores/widgets/store_transfer_hub.dart': 2,
  'lib/shared/widgets/activity_log_screen.dart': 1,
  'lib/shared/widgets/app_drawer.dart': 12,
  'lib/shared/widgets/main_layout.dart': 3,
};

/// Matches a call `hasPermission(ref …` (single- or multi-line) but NOT the
/// helper definition `hasPermission(WidgetRef ref …`, so the helper's own home
/// is never flagged.
final _bareCheck = RegExp(r'hasPermission\s*\(\s*ref');

void main() {
  test('no bare hasPermission(ref, …) survives outside the allowlist', () {
    final actual = <String, int>{};
    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File) continue;
      final path = entity.path;
      if (!path.endsWith('.dart') || path.endsWith('.g.dart')) continue;
      // The permission module is the one place the term may appear (doc
      // comments reference the legacy helper) — never scanned.
      if (path.startsWith('lib/core/permissions/')) continue;
      final count = _bareCheck.allMatches(entity.readAsStringSync()).length;
      if (count > 0) actual[path] = count;
    }

    // Grown or wholly new offenders → cite a named Gate instead.
    final offenders = <String>[];
    actual.forEach((path, count) {
      final allowed = _allowlist[path] ?? 0;
      if (count > allowed) {
        offenders.add('$path: $count bare check(s), allowlist permits $allowed');
      }
    });
    expect(
      offenders,
      isEmpty,
      reason:
          'A bare hasPermission(ref, …) check appeared outside lib/core/permissions/.\n'
          'Cite a named Gate — Gates.x.allows(ref) / .allowsNow(ref) / '
          '.require(ref) — never re-derive the rule inline.\n'
          '${offenders.join('\n')}',
    );

    // Shrunk/removed sites → the allowlist must shrink to match (the ratchet).
    final stale = <String>[];
    _allowlist.forEach((path, allowed) {
      final count = actual[path] ?? 0;
      if (count < allowed) {
        stale.add('$path: allowlist expects $allowed, found $count');
      }
    });
    expect(
      stale,
      isEmpty,
      reason:
          'The static-ban allowlist is stale — a site was migrated without '
          'shrinking it. Update _allowlist to match (it only ever shrinks '
          'toward empty at issue #22).\n${stale.join('\n')}',
    );
  });
}
