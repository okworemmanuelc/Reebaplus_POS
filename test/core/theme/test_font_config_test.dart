// #352: test/flutter_test_config.dart loads the bundled fonts for every test.
// Pins that it really did: under the FlutterTest font every glyph is exactly
// 1em wide, so a run of real DM Sans / Roboto Mono letters is not.

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

double _width(String text, String family) {
  final painter = TextPainter(
    text: TextSpan(
      text: text,
      style: TextStyle(fontFamily: family, fontSize: 20),
    ),
    textDirection: TextDirection.ltr,
  )..layout();
  final width = painter.width;
  painter.dispose();
  return width;
}

void main() {
  test('DM Sans is the real font, not 1em test squares', () {
    // 10 glyphs at 20px would be exactly 200 wide in the test font.
    expect(_width('iiiiiiiiii', 'DMSans'), lessThan(150));
  });

  test('Roboto Mono is the real font, not 1em test squares', () {
    // Monospace, but each glyph is ~0.6em, not 1em.
    expect(_width('0000000000', 'RobotoMono'), lessThan(150));
  });

  test('DM Sans weights resolve to different files', () {
    final regular = _width('Point of Sale', 'DMSans');
    final painter = TextPainter(
      text: const TextSpan(
        text: 'Point of Sale',
        style: TextStyle(
          fontFamily: 'DMSans',
          fontSize: 20,
          fontWeight: FontWeight.w800,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    expect(painter.width, greaterThan(regular));
    painter.dispose();
  });
}
