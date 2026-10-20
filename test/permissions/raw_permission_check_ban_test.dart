// Static enforcement ban (issue #455).
// Scans `lib/` to prevent raw permission checks from regressing:
// 1. `currentUserPermissionsProvider` must never be referenced directly outside
//    the permissions module (`lib/core/permissions/`) and its declaration file
//    (`lib/core/providers/stream_providers.dart`). All feature and UI code must
//    use named gates via `Gates.<gate>.allows(ref)` or `Gates.<gate>.allowsNow(ref)`.
// 2. Raw permission key strings (e.g. `contains('staff.invite')`) must never be
//    checked via `.contains()` outside `lib/core/permissions/`.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

final _userPermissionsProviderRef = RegExp(
  r'\bcurrentUserPermissionsProvider\b',
);

final _rawContainsRegex = RegExp(
  r'''\.contains\(\s*['"]([a-z_]+\.[a-z_]+)['"]\s*\)''',
);

void main() {
  test(
    'no direct currentUserPermissionsProvider reference outside lib/core/permissions/ and stream_providers.dart',
    () {
      final offenders = <String>[];
      for (final entity in Directory('lib').listSync(recursive: true)) {
        if (entity is! File) continue;
        final path = entity.path.replaceAll(r'\', '/');
        if (!path.endsWith('.dart') || path.endsWith('.g.dart')) continue;
        if (path.startsWith('lib/core/permissions/') ||
            path == 'lib/core/providers/stream_providers.dart') {
          continue;
        }

        final content = entity.readAsStringSync();
        final lines = content.split('\n');
        for (var i = 0; i < lines.length; i++) {
          final line = lines[i].trim();
          if (line.startsWith('//') ||
              line.startsWith('///') ||
              line.startsWith('*')) {
            continue;
          }
          if (_userPermissionsProviderRef.hasMatch(line)) {
            offenders.add('$path:${i + 1}: $line');
          }
        }
      }

      expect(
        offenders,
        isEmpty,
        reason:
            'Direct reference to currentUserPermissionsProvider found outside permissions module.'
            ' Cite a named Gate instead (e.g. Gates.<name>.allows(ref) or Gates.<name>.allowsNow(ref)).\n'
            '${offenders.join('\n')}',
      );
    },
  );

  test(
    'no raw permission string checked via .contains() outside lib/core/permissions/',
    () {
      final catalogue = _catalogueKeys();
      expect(
        catalogue,
        isNotEmpty,
        reason: 'Failed to parse catalogue keys from app_database.dart',
      );

      final offenders = <String>[];
      for (final entity in Directory('lib').listSync(recursive: true)) {
        if (entity is! File) continue;
        final path = entity.path.replaceAll(r'\', '/');
        if (!path.endsWith('.dart') || path.endsWith('.g.dart')) continue;
        if (path.startsWith('lib/core/permissions/')) {
          continue;
        }

        final content = entity.readAsStringSync();
        final lines = content.split('\n');
        for (var i = 0; i < lines.length; i++) {
          final line = lines[i].trim();
          if (line.startsWith('//') ||
              line.startsWith('///') ||
              line.startsWith('*')) {
            continue;
          }
          for (final match in _rawContainsRegex.allMatches(line)) {
            final key = match.group(1);
            if (key != null && catalogue.contains(key)) {
              offenders.add(
                '$path:${i + 1}: $line (matched catalogue key: $key)',
              );
            }
          }
        }
      }

      expect(
        offenders,
        isEmpty,
        reason:
            'Raw permission check via .contains() found outside lib/core/permissions/.\n'
            'Use a named Gate instead: Gates.<name>.allows(ref) / .allowsNow(ref).\n'
            '${offenders.join('\n')}',
      );
    },
  );

  test('the scan is strict — planted checks are caught', () {
    const plantedProvider =
        'final perms = ref.watch(currentUserPermissionsProvider);';
    expect(
      _userPermissionsProviderRef.hasMatch(plantedProvider),
      isTrue,
      reason:
          'the provider scanner must catch direct reference to currentUserPermissionsProvider',
    );

    const plantedContainsSingle = "if (perms.contains('staff.invite')) return;";
    expect(
      _rawContainsRegex.hasMatch(plantedContainsSingle),
      isTrue,
      reason: 'the regex scanner must catch raw single-quoted .contains checks',
    );
    final matchSingle = _rawContainsRegex.firstMatch(plantedContainsSingle);
    expect(matchSingle?.group(1), equals('staff.invite'));

    const plantedContainsDouble = 'if (perms.contains("staff.invite")) return;';
    expect(
      _rawContainsRegex.hasMatch(plantedContainsDouble),
      isTrue,
      reason: 'the regex scanner must catch raw double-quoted .contains checks',
    );
    final matchDouble = _rawContainsRegex.firstMatch(plantedContainsDouble);
    expect(matchDouble?.group(1), equals('staff.invite'));

    const migrated = 'if (Gates.inviteStaff.allowsNow(ref)) return;';
    expect(_userPermissionsProviderRef.hasMatch(migrated), isFalse);
    expect(_rawContainsRegex.hasMatch(migrated), isFalse);
  });
}

Set<String> _catalogueKeys() {
  final src = File('lib/core/database/app_database.dart').readAsStringSync();
  final start = src.indexOf('_defaultPermissionRows = [');
  if (start < 0) return const {};
  final end = src.indexOf('\n];', start);
  if (end < 0) return const {};
  final block = src.substring(start, end);
  return RegExp(
    r"\[\s*'([^']+)'",
  ).allMatches(block).map((m) => m.group(1)!).toSet();
}
