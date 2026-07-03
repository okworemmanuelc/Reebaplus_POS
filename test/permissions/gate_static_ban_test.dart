// Static enforcement seam (issue #17, ADR 0002). A source scan that bans the
// bare `hasPermission(ref, …)` check outside the permissions module. Prior art:
// the sync-registry golden/registration tests.
//
// The finish-line flip (issue #22) is now in force: **the allowlist is empty**.
// Every gated action cites a named `Gates.x` entry, and the bare single-key
// helper (`hasPermission`) plus the tier helper (`isManagerOrAbove`) have been
// removed from the app. A bare `hasPermission(ref, …)` reappearing anywhere in
// `lib/` outside `lib/core/permissions/` fails this suite — cite a named Gate.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// EMPTY — the flip landed (issue #22). No bare-check site is permitted outside
/// `lib/core/permissions/`. This map only ever stayed at empty; do not add to it
/// (that would re-open the leak class the registry retired). Cite a named Gate.
const _allowlist = <String, int>{};

/// Matches a call `hasPermission(ref …` (single- or multi-line). The bare helper
/// no longer exists, so any match is a re-introduced inline permission check.
final _bareCheck = RegExp(r'hasPermission\s*\(\s*ref');

void main() {
  test('no bare hasPermission(ref, …) survives outside lib/core/permissions/',
      () {
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

    // With an empty allowlist, ANY bare check is an offender → cite a named Gate.
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
          'The allowlist is empty (issue #22 flip) — cite a named Gate instead: '
          'Gates.x.allows(ref) / .allowsNow(ref) / .require(ref). Never re-derive '
          'the rule inline.\n${offenders.join('\n')}',
    );

    // Ratchet backstop: the allowlist may only ever shrink toward empty. If a
    // path is listed above its actual count the map is stale — but it is empty
    // now, so this only fires if someone re-adds an entry without a matching
    // (undesired) bare check.
    final stale = <String>[];
    _allowlist.forEach((path, allowed) {
      final count = actual[path] ?? 0;
      if (count < allowed) {
        stale.add('$path: allowlist expects $allowed, found $count');
      }
    });
    expect(stale, isEmpty,
        reason: 'The static-ban allowlist is empty and must stay empty '
            '(issue #22). Remove the stale entry.\n${stale.join('\n')}');
  });

  test('the scan is strict — a planted bare check would be caught', () {
    // Durable proof that emptying the allowlist gave the ban teeth (the AC's
    // "a deliberately-planted bare check fails the suite"): a synthetic bare
    // check matches the scanner, so a real one anywhere in lib/ outside the
    // permissions module would land in `offenders` above and fail the test.
    const planted = "final ok = hasPermission(ref, 'sales.make');";
    expect(_bareCheck.hasMatch(planted), isTrue,
        reason: 'the scanner must catch a re-introduced bare check');

    // …and the migrated form is never flagged, so gate citations are safe.
    const migrated = 'final ok = Gates.makeSale.allows(ref);';
    expect(_bareCheck.hasMatch(migrated), isFalse,
        reason: 'a named-gate citation must not trip the ban');
  });
}
