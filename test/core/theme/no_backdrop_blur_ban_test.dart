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
// Single exception: `lib/features/auth/widgets/auth_background.dart`, which
// blurs a background photo on the sign-in screens pending the Wave 2 Auth redesign.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const _allowedException = 'lib/features/auth/widgets/auth_background.dart';

void main() {
  test('no BackdropFilter or ImageFilter.blur appears in lib/ outside auth_background.dart', () {
    final offenders = <String>[];

    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;

      final normalizedPath = entity.path.replaceAll(r'\', '/');
      if (normalizedPath == _allowedException ||
          normalizedPath.endsWith('/auth_background.dart')) {
        continue;
      }

      final lines = entity.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i];
        if (line.trimLeft().startsWith('//')) continue;

        if (line.contains('BackdropFilter') || line.contains('ImageFilter.blur')) {
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
  });
}
