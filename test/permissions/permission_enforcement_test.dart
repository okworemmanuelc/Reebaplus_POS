import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Permission-enforcement guardrail (CLAUDE.md hard rules #6/#7, §10.2.1).
///
/// The per-staff override editor turns every non-hidden catalogue permission
/// into an on/off toggle. A toggle is only meaningful if *some* feature gates on
/// the EFFECTIVE permission — `hasPermission(ref, '<key>')` or
/// `currentUserPermissionsProvider…contains('<key>')`. A key that no feature
/// checks is a dead toggle (the CEO flips it and nothing changes); a feature
/// gated only on `role.slug` is override-blind. Both were the "toggles don't
/// work" bug this test exists to prevent regressing.
///
/// Rule: every catalogue key NOT in `kHiddenPermissionKeys` must appear as a
/// quoted string literal somewhere in `lib/` OUTSIDE the catalogue definition
/// (`app_database.dart`) and the dependency map (`permission_dependencies.dart`)
/// — i.e. in an actual enforcement reference. Hidden keys are exempt: their
/// feature isn't built, so hiding the inert toggle is the documented choice.
///
/// This is the permission analogue of the Layer-C sync raw-write leak scanner
/// (`test/sync/sync_raw_write_leak_test.dart`): a pure source scan, no Flutter
/// binding. If it goes red, either wire the key with `hasPermission` or add it
/// to `kHiddenPermissionKeys` (with a comment) until its feature ships.
void main() {
  test('every non-hidden permission key is enforced via hasPermission in lib/',
      () {
    final catalogue = _catalogueKeys();
    expect(catalogue, isNotEmpty,
        reason: 'Failed to parse _defaultPermissionRows from app_database.dart');

    final hidden = _hiddenKeys();
    expect(hidden, contains('sales.discount.give'),
        reason: 'Failed to parse kHiddenPermissionKeys '
            '(expected the known hidden key to be present)');

    // Concatenate every scanned lib source once. Exclude the two files where a
    // key literal is NOT an enforcement reference (the catalogue + the
    // dependency map) and generated code.
    final buf = StringBuffer();
    for (final f in _dartFilesUnder('lib')) {
      final path = f.path.replaceAll(r'\', '/');
      if (path.endsWith('.g.dart')) continue;
      if (path.endsWith('/core/database/app_database.dart')) continue;
      if (path.endsWith('/core/permissions/permission_dependencies.dart')) {
        continue;
      }
      buf.write(f.readAsStringSync());
      buf.write('\n');
    }
    final scanned = buf.toString();

    final unenforced = <String>[
      for (final key in catalogue)
        if (!hidden.contains(key) && !scanned.contains("'$key'")) key,
    ]..sort();

    expect(
      unenforced,
      isEmpty,
      reason: 'Catalogue permission key(s) with NO enforcement reference in '
          'lib/ — the per-staff toggle for each does nothing (CLAUDE.md hard '
          'rule #6):\n  ${unenforced.join('\n  ')}\n\nFix by gating the feature '
          "on hasPermission(ref, '<key>') / "
          "currentUserPermissionsProvider.contains('<key>'), or — if the "
          'feature is not built yet — add the key to kHiddenPermissionKeys in '
          'role_permissions_detail_screen.dart with a comment.',
    );
  });
}

/// First string of each row in the `_defaultPermissionRows` literal in
/// `app_database.dart` — the canonical permission catalogue.
Set<String> _catalogueKeys() {
  final src = File('lib/core/database/app_database.dart').readAsStringSync();
  final start = src.indexOf('_defaultPermissionRows = [');
  if (start < 0) return const {};
  final end = src.indexOf('\n];', start);
  if (end < 0) return const {};
  final block = src.substring(start, end);
  // Each row opens with `[` then (optionally across newlines) the key literal.
  return RegExp(r"\[\s*'([^']+)'")
      .allMatches(block)
      .map((m) => m.group(1)!)
      .toSet();
}

/// The quoted entries of the `kHiddenPermissionKeys` set literal in
/// `role_permissions_detail_screen.dart`.
Set<String> _hiddenKeys() {
  final src = File('lib/core/settings/role_permissions_detail_screen.dart')
      .readAsStringSync();
  final start = src.indexOf('kHiddenPermissionKeys = {');
  if (start < 0) return const {};
  final end = src.indexOf('}', start);
  if (end < 0) return const {};
  final block = src.substring(start, end);
  return RegExp(r"'([^']+)'")
      .allMatches(block)
      .map((m) => m.group(1)!)
      .toSet();
}

List<File> _dartFilesUnder(String dir) {
  final root = Directory(dir);
  if (!root.existsSync()) return const [];
  return root
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart'))
      .toList();
}
