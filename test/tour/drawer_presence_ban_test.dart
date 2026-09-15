// Static enforcement seam. The first-run rail asks "is the drawer open?" and
// gets its answer from `NavigationService.drawerOpenNotifier`, which is driven
// by `DrawerPresence` mounting and unmounting inside `AppDrawer`.
//
// That signal is easy to lose by accident. MainLayout's Scaffold — the one
// `NavigationService` holds a key to — does not declare a drawer at all; every
// screen declares its own. So `Scaffold.onDrawerChanged` on MainLayout never
// fires and `mainScaffoldKey.currentState.isDrawerOpen` is permanently false.
// Before this seam existed, `nav.isDrawerOpen` was hard-false on every phone,
// and stop one of the rail sat on "Tap the menu to get started" forever with a
// hole cut over a button the open drawer was covering: a blocking dark sheet
// with nothing to tap.
//
// Two rules keep that from coming back:
//   1. Every `drawer:` in lib/ is an `AppDrawer`.
//   2. `AppDrawer` wraps its content in `DrawerPresence`.
//
// Prior art: test/utils/media_query_size_ban_test.dart,
// test/providers/business_scoped_stream_ban_test.dart.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const _appDrawerFile = 'lib/shared/widgets/app_drawer.dart';

/// Matches a `drawer:` / `endDrawer:` argument and captures what follows, so we
/// can check the widget assigned to it.
///
/// Case-insensitive because Flutter spells the second one `endDrawer:` with a
/// capital D — a case-sensitive `(?:end)?drawer:` silently matched neither it
/// nor anything else ending in `Drawer:`, so an `endDrawer` escaped the ban
/// entirely. The leading `\b` still keeps `AppDrawer:`-style identifiers out:
/// there is no word boundary in the middle of a word.
final _drawerArgPattern = RegExp(
  r'\b(?:end)?drawer:\s*(.{0,60})',
  caseSensitive: false,
);

void main() {
  test('every drawer declared in lib/ is an AppDrawer', () {
    final offenders = <String>[];

    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;

      final lines = entity.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i];
        // Skip comments — several files mention a cash drawer in prose.
        if (line.trimLeft().startsWith('//')) continue;

        final match = _drawerArgPattern.firstMatch(line);
        if (match == null) continue;

        final assigned = match.group(1)!;
        if (assigned.contains('AppDrawer') || assigned.contains('null')) {
          continue;
        }
        offenders.add('${entity.path}:${i + 1}: ${line.trim()}');
      }
    }

    expect(
      offenders,
      isEmpty,
      reason:
          'These Scaffolds declare a drawer that is not an AppDrawer, so opening '
          'them will not reach NavigationService.drawerOpenNotifier and the '
          'first-run rail will never notice the drawer opened:\n'
          '${offenders.join('\n')}',
    );
  });

  test('every file declaring a drawer also mounts a DrawerHost', () {
    final offenders = <String>[];

    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;

      final lines = entity.readAsLinesSync();
      // `startsWith`, not `contains`: SharedScaffold assigns
      // `context.isDesktop ? null : AppDrawer(...)`, which really does declare a
      // drawer on phones. Only a flat `drawer: null` declares nothing.
      final declaresDrawer = lines.any(
        (l) =>
            !l.trimLeft().startsWith('//') &&
            _drawerArgPattern.hasMatch(l) &&
            !_drawerArgPattern.firstMatch(l)!.group(1)!.startsWith('null'),
      );
      if (!declaresDrawer) continue;

      if (!lines.any((l) => l.contains('DrawerHost('))) {
        offenders.add(entity.path);
      }
    }

    expect(
      offenders,
      isEmpty,
      reason:
          'These files declare a Scaffold drawer but mount no DrawerHost inside '
          'it, so NavigationService.openDrawer() cannot reach that drawer and '
          'falls back to mainScaffoldKey — whose Scaffold has no drawer, making '
          'the call a silent no-op. Wrap the Scaffold\'s body in a DrawerHost:\n'
          '${offenders.join('\n')}',
    );
  });

  test('AppDrawer reports its own presence via DrawerPresence', () {
    final source = File(_appDrawerFile).readAsStringSync();

    expect(
      source.contains('DrawerPresence('),
      isTrue,
      reason:
          '$_appDrawerFile must wrap its content in DrawerPresence. It is the '
          'only thing telling NavigationService that a drawer is open, because '
          'the drawer belongs to each screen\'s Scaffold rather than to the one '
          'NavigationService holds a key to.',
    );

    expect(
      source.contains('frameSafe(NavigationService().drawerMounted)'),
      isTrue,
      reason:
          'DrawerPresence must report through frameSafe. Writing '
          'drawerOpenNotifier straight from initState marks the rail overlay — '
          'a sibling in MainLayout\'s Stack, never an ancestor — dirty during '
          'build, which Flutter rejects outright. See ADR 0026 section 7.',
    );
  });
}
