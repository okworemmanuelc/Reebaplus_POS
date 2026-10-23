// Static enforcement seam (#351).
//
// The "Glassy" design language (backdrop blur, translucent surfaces, and
// scroll-reactive top bars) has been replaced with "flat with a soft fade":
// solid surfaces, opaque page gradient fades, hairline borders, and soft
// card/top-bar shadows.
//
// BackdropFilter and ImageFilter.blur are banned across lib/ to prevent
// rasterization overhead, glitches on route transitions, and keep the
// design language unified.
//
// Zero exceptions: BackdropFilter and ImageFilter.blur are banned across lib/.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'no BackdropFilter or ImageFilter.blur appears anywhere in lib/',
    () {
      final offenders = <String>[];

      for (final entity in Directory('lib').listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;

        final normalizedPath = entity.path.replaceAll(r'\', '/');
        final lines = entity.readAsLinesSync();
        for (var i = 0; i < lines.length; i++) {
          final line = lines[i];
          if (line.trimLeft().startsWith('//')) continue;

          if (line.contains('BackdropFilter') ||
              line.contains('ImageFilter.blur')) {
            offenders.add('$normalizedPath:${i + 1}: ${line.trim()}');
          }
        }
      }

      expect(
        offenders,
        isEmpty,
        reason:
            'BackdropFilter and ImageFilter.blur are banned under the flat-with-soft-fade '
            'design standard (#351). Remove blur and use opaque surfaces/scrim instead:\n'
            '${offenders.join('\n')}',
      );
    },
  );
}
