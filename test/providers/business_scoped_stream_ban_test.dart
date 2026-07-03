// Static enforcement seam (issue #24/#25, ADR 0003). A source scan that bans a
// raw `StreamProvider` declaration anywhere in `lib/`: every business-scoped
// live-query stream must be declared through the guarded factory
// (`businessScopedStream` / `businessScopedStreamFamily` and their autoDispose
// variants), so the build-time-poison bug (a tenant-scoped `watch*()` baking a
// missing businessId at first build and sticking the whole session) cannot be
// re-introduced. Prior art: test/permissions/gate_static_ban_test.dart and the
// sync-registry golden/registration tests.
//
// The allowlist is SMALL and NON-EMPTY: it names the genuinely-NON-tenant-scoped
// streams that legitimately stay raw (the ADR's "global/unscoped streams stay
// off the factory"). It is a shrink-only ratchet — never add a business-scoped
// provider to it; route the provider through the factory instead.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Provider names permitted to remain a raw `StreamProvider`. Each is NOT scoped
/// to the current session's business, so forcing it through the factory would be
/// wrong (it would break pre-bind resolution or change device-local semantics).
///
/// Grouped by why it is exempt:
const _allowlist = <String>{
  // Genuinely global catalogue / unscoped-by-design (role ids are globally
  // unique, so the role is resolvable before a business binds).
  'allPermissionsProvider',
  '_allRolesUnscopedProvider',
  // Keyed by an explicit id (not the session businessId) and resolved BEFORE a
  // business binds — routing these through the factory would emit `whenAbsent`
  // during the shared-PIN / Who's-Working picker and break role resolution.
  '_userMembershipsProvider', // watchForUser(userId) — no whereBusiness
  'myUserStoresProvider', // watchForUser(userId) — no whereBusiness
  'activeStaffProvider', // watchActiveStaffForBusiness(explicit businessId)
  'deviceStaffProvider', // watchDeviceStaffForBusiness(explicit businessId)
  // Device-local sync-engine state — `sync_queue_orphans` carries no business_id
  // column, so it is not tenant-scoped.
  'orphanQueueItemsProvider',
  'orphanQueueCountProvider',
  // Intentionally unscoped — a device may hold more than one business's rows.
  'localBusinessesProvider', // all businesses on the device
  'pendingCrateReturnsProvider', // raw select, no session filter
  'pendingReturnsWithDetailsProvider', // raw join, no session filter
};

/// Matches a top-level raw stream provider declaration —
/// `final xProvider = StreamProvider…` in any of its forms (`.family`,
/// `.autoDispose`, `.autoDispose.family`). Dart's `\s` matches newlines, so a
/// declaration split across lines is still caught. A factory-built provider
/// reads `= businessScopedStream…` and never matches.
final _rawStreamDecl = RegExp(r'final\s+(\w+)\s*=\s*StreamProvider');

/// The factory itself contains `return StreamProvider…` bodies — never scanned
/// (it is the one place raw `StreamProvider` is the correct primitive).
const _factoryFile = 'lib/core/providers/business_scoped_stream.dart';

void main() {
  test('no raw business-scoped StreamProvider is declared outside the factory',
      () {
    final found = <String, String>{}; // provider name → file path
    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File) continue;
      final path = entity.path;
      if (!path.endsWith('.dart') || path.endsWith('.g.dart')) continue;
      if (path == _factoryFile) continue;
      for (final m in _rawStreamDecl.allMatches(entity.readAsStringSync())) {
        found[m.group(1)!] = path;
      }
    }

    final offenders = <String>[];
    found.forEach((name, path) {
      if (!_allowlist.contains(name)) {
        offenders.add('$name  ($path)');
      }
    });

    expect(
      offenders,
      isEmpty,
      reason:
          'A raw StreamProvider was declared for a business-scoped read. Declare '
          'it through the factory instead: businessScopedStream / '
          'businessScopedStreamFamily (+ autoDispose variants), which guard the '
          'null-businessId window (ADR 0003). If it is genuinely NOT '
          'tenant-scoped, add its name to the allowlist with a reason.\n'
          '${offenders.join('\n')}',
    );

    // Shrink-only ratchet: an allowlist entry with no matching raw provider is
    // stale (the provider was migrated or renamed) — remove it.
    final stale =
        _allowlist.where((name) => !found.containsKey(name)).toList();
    expect(
      stale,
      isEmpty,
      reason:
          'Stale allowlist entries — these no longer name a raw StreamProvider. '
          'The allowlist may only shrink; remove them.\n${stale.join('\n')}',
    );
  });

  test('the scan is strict — a planted raw provider is caught, the migrated '
      'form is not', () {
    // A re-introduced raw business-scoped stream is caught…
    const planted =
        "final xProvider = StreamProvider<int>((ref) => ref.watch(dbP).x());";
    expect(_rawStreamDecl.hasMatch(planted), isTrue,
        reason: 'the scanner must catch a re-introduced raw StreamProvider');

    // …a multi-line declaration is caught (Dart \s spans newlines)…
    const plantedMultiline =
        'final xProvider =\n    StreamProvider.autoDispose.family<int, String>(';
    expect(_rawStreamDecl.hasMatch(plantedMultiline), isTrue,
        reason: 'a declaration split across lines must still be caught');

    // …and none of the migrated (factory) forms trip the ban.
    for (final migrated in [
      'final xProvider = businessScopedStream<int>((ref, db, id) => db.x());',
      'final xProvider = businessScopedStreamFamily<int, String>(',
      'final xProvider = businessScopedStreamAutoDispose<int>(',
      'final xProvider = businessScopedStreamAutoDisposeFamily<int, String>(',
    ]) {
      expect(_rawStreamDecl.hasMatch(migrated), isFalse,
          reason: 'a factory-built provider must not trip the ban: $migrated');
    }
  });
}
