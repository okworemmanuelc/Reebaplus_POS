// #349 — DM Sans ExtraBold (800) and Roboto Mono resolve from the fonts
// bundled in assets/google_fonts/, with runtime fetching off (as main.dart
// sets it), so no style can ever reach for fonts.gstatic.com.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
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

void main() {
  setUp(() => GoogleFonts.config.allowRuntimeFetching = false);

  test('the new font files are bundled with the right weights', () async {
    final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
    final assets = manifest.listAssets();
    expect(assets, contains('assets/google_fonts/DMSans-ExtraBold.ttf'));
    expect(assets, contains('assets/google_fonts/RobotoMono-Regular.ttf'));

    final extraBold = await rootBundle.load(
      'assets/google_fonts/DMSans-ExtraBold.ttf',
    );
    final mono = await rootBundle.load(
      'assets/google_fonts/RobotoMono-Regular.ttf',
    );
    expect(_weightClass(extraBold), 800);
    expect(_weightClass(mono), 400);
  });

  testWidgets(
    'screenTitleStyle (DM Sans 800 @18) and monoStyle (Roboto Mono @13) '
    'load from bundled assets with no runtime fetch',
    (tester) async {
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
              return Column(
                children: [
                  Text('Point of Sale', style: title),
                  Text('Terminal 01', style: mono),
                ],
              );
            },
          ),
        ),
      );

      // Throws if either font is missing from the assets: with runtime
      // fetching off, google_fonts has nowhere else to get it.
      await tester.runAsync(GoogleFonts.pendingFonts);

      expect(title.fontWeight, FontWeight.w800);
      expect(title.fontFamily, 'DMSans_800');
      expect(title.fontSize, expectedTitleSize);
      expect(mono.fontWeight, FontWeight.w400);
      expect(mono.fontFamily, 'RobotoMono_regular');
      expect(mono.fontSize, expectedMonoSize);
      // Colour inherits from the surroundings.
      expect(title.color, isNull);
      expect(mono.color, isNull);
    },
  );

  testWidgets(
    'control: a weight that is NOT bundled fails instead of fetching',
    (tester) async {
      // Proves the test above is meaningful: DM Sans Black (900) is not in
      // assets/google_fonts/, so loading it must error rather than download.
      final errors = <Object>[];
      await tester.runAsync(() async {
        final done = Completer<void>();
        runZonedGuarded(() async {
          GoogleFonts.dmSans(fontWeight: FontWeight.w900);
          try {
            await GoogleFonts.pendingFonts();
          } catch (e) {
            errors.add(e);
          }
          done.complete();
        }, (error, _) => errors.add(error));
        await done.future;
        // Let the zone report the duplicate error from google_fonts' own
        // bookkeeping future.
        await Future<void>.delayed(Duration.zero);
      });
      expect(errors, isNotEmpty);
      expect(errors.first.toString(), contains('allowRuntimeFetching is false'));
    },
  );
}
