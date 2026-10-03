// #349 — the app's fonts come only from the files bundled in
// assets/google_fonts/, registered in pubspec.yaml as real multi-weight
// families (DMSans 400–800, RobotoMono 400). Nothing is fetched at runtime.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';

/// Reads `usWeightClass` from a TrueType file's OS/2 table.
int _weightClass(ByteData font) {
  final numTables = font.getUint16(4);
  for (var i = 0; i < numTables; i++) {
    final record = 12 + i * 16;
    final tag = String.fromCharCodes([
      for (var j = 0; j < 4; j++) font.getUint8(record + j),
    ]);
    if (tag == 'OS/2') {
      final offset = font.getUint32(record + 8);
      return font.getUint16(offset + 4);
    }
  }
  throw StateError('no OS/2 table');
}

/// family -> {asset -> declared weight}, from the bundled FontManifest.json.
Future<Map<String, Map<String, int>>> _fontManifest() async {
  final raw = await rootBundle.loadString('FontManifest.json');
  final families = <String, Map<String, int>>{};
  for (final family in jsonDecode(raw) as List<Object?>) {
    final f = family! as Map<String, Object?>;
    final faces = <String, int>{};
    for (final face in f['fonts']! as List<Object?>) {
      final m = face! as Map<String, Object?>;
      faces[m['asset']! as String] = (m['weight'] as int?) ?? 400;
    }
    families[f['family']! as String] = faces;
  }
  return families;
}

void main() {
  test('DMSans and RobotoMono are registered from the bundled files', () async {
    final manifest = await _fontManifest();
    const dir = 'assets/google_fonts';
    expect(manifest[appFontFamily], {
      '$dir/DMSans-Regular.ttf': 400,
      '$dir/DMSans-Medium.ttf': 500,
      '$dir/DMSans-SemiBold.ttf': 600,
      '$dir/DMSans-Bold.ttf': 700,
      '$dir/DMSans-ExtraBold.ttf': 800,
    });
    expect(manifest[appMonoFontFamily], {'$dir/RobotoMono-Regular.ttf': 400});

    // Each declared weight matches the weight inside the file itself.
    for (final family in [appFontFamily, appMonoFontFamily]) {
      for (final face in manifest[family]!.entries) {
        final bytes = await rootBundle.load(face.key);
        expect(_weightClass(bytes), face.value, reason: face.key);
      }
    }
  });

  testWidgets('screenTitleStyle is DM Sans 800 @18, monoStyle Roboto Mono @13', (
    tester,
  ) async {
    late TextStyle title;
    late TextStyle mono;
    late double expectedTitleSize;
    late double expectedMonoSize;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Builder(
          builder: (context) {
            title = context.screenTitleStyle;
            mono = context.monoStyle;
            expectedTitleSize = context.getRFontSize(18);
            expectedMonoSize = context.getRFontSize(13);
            return const SizedBox();
          },
        ),
      ),
    );
    expect(title.fontFamily, appFontFamily);
    expect(title.fontWeight, FontWeight.w800);
    expect(title.fontSize, expectedTitleSize);
    expect(mono.fontFamily, appMonoFontFamily);
    expect(mono.fontWeight, FontWeight.w400);
    expect(mono.fontSize, expectedMonoSize);
    // Colour inherits from the surroundings.
    expect(title.color, isNull);
    expect(mono.color, isNull);
  });

  testWidgets('the real DM Sans faces resolve by weight (not a synthesised bold)', (
    tester,
  ) async {
    // Widget tests render every family with the test font unless the real
    // files are loaded, so load them here the way the engine would.
    await tester.runAsync(() async {
      final manifest = await _fontManifest();
      final loader = FontLoader(appFontFamily);
      for (final asset in manifest[appFontFamily]!.keys) {
        loader.addFont(rootBundle.load(asset));
      }
      await loader.load();
    });

    double widthOf(FontWeight weight) {
      final painter = TextPainter(
        text: TextSpan(
          text: 'Point of Sale 0123456789',
          style: TextStyle(
            fontFamily: appFontFamily,
            fontSize: 18,
            fontWeight: weight,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      final width = painter.width;
      painter.dispose();
      return width;
    }

    final widths = [
      for (final w in [
        FontWeight.w400,
        FontWeight.w500,
        FontWeight.w600,
        FontWeight.w700,
        FontWeight.w800,
      ])
        widthOf(w),
    ];
    // DM Sans gets wider with each weight; five distinct, rising widths mean
    // five distinct files were picked.
    for (var i = 1; i < widths.length; i++) {
      expect(widths[i], greaterThan(widths[i - 1]), reason: 'weights $widths');
    }
  });
}
