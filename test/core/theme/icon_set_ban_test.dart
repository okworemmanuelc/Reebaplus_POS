import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  const allowedAppIconsPath = 'lib/core/theme/app_icons.dart';

  test('no references to FontAwesome outside app_icons.dart', () {
    final bannedPatterns = [
      RegExp(r'\bFontAwesomeIcons\b'),
      RegExp(r'\bFaIcon\b'),
      RegExp(r'package:font_awesome_flutter'),
    ];

    final violations = <String>[];

    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;

      final normalizedPath = entity.path.replaceAll(r'\', '/');
      if (normalizedPath == allowedAppIconsPath) continue;

      final lines = entity.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i];
        for (final pattern in bannedPatterns) {
          if (pattern.hasMatch(line)) {
            violations.add('$normalizedPath:${i + 1}: ${line.trim()}');
            break;
          }
        }
      }
    }

    expect(
      violations,
      isEmpty,
      reason:
          'FontAwesome icons and packages must not be used directly in lib/ outside of $allowedAppIconsPath.\n'
          'Use AppIcons instead.\n'
          'Violations found:\n${violations.join('\n')}',
    );
  });

  test('no direct imports of material_symbols_icons outside app_icons.dart', () {
    final pattern = RegExp(r'package:material_symbols_icons');
    final violations = <String>[];

    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;

      final normalizedPath = entity.path.replaceAll(r'\', '/');
      if (normalizedPath == allowedAppIconsPath) continue;

      final lines = entity.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i];
        if (pattern.hasMatch(line)) {
          violations.add('$normalizedPath:${i + 1}: ${line.trim()}');
        }
      }
    }

    expect(
      violations,
      isEmpty,
      reason:
          'package:material_symbols_icons must not be imported directly in lib/ outside of $allowedAppIconsPath.\n'
          'Use AppIcons instead.\n'
          'Violations found:\n${violations.join('\n')}',
    );
  });
}
