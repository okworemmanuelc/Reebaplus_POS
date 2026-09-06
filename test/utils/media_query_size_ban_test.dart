// Static enforcement seam. A source scan that bans reading MediaQuery size
// directly anywhere in `lib/` outside `lib/core/utils/responsive.dart`.
//
// Screens and widgets must route through `context.screenWidth`,
// `context.screenHeight`, or `context.screenShortestSide` from
// `lib/core/utils/responsive.dart` rather than calling `MediaQuery.of(context).size`,
// `MediaQuery.maybeOf(context)?.size`, or `MediaQuery.sizeOf(context)`.
//
// Other MediaQuery properties (`viewInsets`, `padding`, `viewPadding`,
// `textScaler`, `orientation`) are legitimate and remain un-flagged.
//
// Prior art: test/providers/mirror_notifier_ban_test.dart,
// test/providers/business_scoped_stream_ban_test.dart, and
// test/permissions/gate_static_ban_test.dart.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The responsive utility itself defines the extension getters and helper
/// functions that read MediaQuery size. Never scanned.
const _sanctionedFile = 'lib/core/utils/responsive.dart';

/// Explicitly deferred call sites audited and scheduled for Phase 2 review on the emulator:
/// - `lib/features/pos/widgets/product_grid.dart`: computes grid columns from raw width (line ~98)
///   and calculates bottom nav cart fling target (line ~231).
/// - `lib/features/receiving/widgets/receive_product_grid.dart`: computes grid columns from raw width (line ~44).
/// - `lib/shared/widgets/app_dropdown.dart`: calculates overlay positioning space above/below (line ~91).
const _deferredFiles = {
  'lib/features/pos/widgets/product_grid.dart',
  'lib/features/receiving/widgets/receive_product_grid.dart',
  'lib/shared/widgets/app_dropdown.dart',
};

/// Matches direct access to MediaQuery size:
/// - `MediaQuery.of(context).size`
/// - `MediaQuery.maybeOf(context)?.size`
/// - `MediaQuery.sizeOf(context)`
final _mediaQuerySizePattern = RegExp(
  r'MediaQuery\s*\.\s*(?:(?:of|maybeOf)\s*\([^)]*\)\s*(?:\?\.|\.)\s*size|sizeOf\s*\([^)]*\))',
);

void main() {
  test(
    'no code in lib/ reads MediaQuery size directly (use context.screenWidth / screenHeight / screenShortestSide)',
    () {
      final offenders = <String>[];

      for (final entity in Directory('lib').listSync(recursive: true)) {
        if (entity is! File) continue;
        final path = entity.path;
        if (!path.endsWith('.dart') || path.endsWith('.g.dart')) continue;
        if (path == _sanctionedFile) continue;
        if (_deferredFiles.contains(path)) continue;

        final lines = entity.readAsLinesSync();
        for (var i = 0; i < lines.length; i++) {
          final line = lines[i];
          if (_mediaQuerySizePattern.hasMatch(line)) {
            offenders.add('$path:${i + 1}: ${line.trim()}');
          }
        }
      }

      expect(
        offenders,
        isEmpty,
        reason:
            'use context.getRHeight(fraction) / getRWidth(fraction) for proportions, '
            'and context.getRSize / getRFontSize for scaled dimensions — never compute '
            'a scale from raw screen dimensions outside responsive.dart.\n'
            'Offenders:\n${offenders.join('\n')}',
      );
    },
    // Retained skipped honestly: 4 non-sheet occurrences remain outside the 4 deferred sites
    // (who_is_working_screen.dart, cart_screen.dart:1494, activity_log_screen.dart:190, view_selector_sheet.dart:21).
    skip:
        'TODO: migrate remaining non-sheet MediaQuery size call sites in lib/ to responsive.dart getters (see plan §6)',
  );

  test(
      'the scan is strict — direct size reads are caught; legitimate MediaQuery properties are ignored',
      () {
    // Direct size reads are caught…
    const plantedOfSize = 'final w = MediaQuery.of(context).size.width;';
    expect(_mediaQuerySizePattern.hasMatch(plantedOfSize), isTrue,
        reason: 'MediaQuery.of(context).size must be caught');

    const plantedMaybeOfSize =
        'final s = MediaQuery.maybeOf(context)?.size;';
    expect(_mediaQuerySizePattern.hasMatch(plantedMaybeOfSize), isTrue,
        reason: 'MediaQuery.maybeOf(context)?.size must be caught');

    const plantedSizeOf = 'final s = MediaQuery.sizeOf(context);';
    expect(_mediaQuerySizePattern.hasMatch(plantedSizeOf), isTrue,
        reason: 'MediaQuery.sizeOf(context) must be caught');

    const plantedWhitespace =
        'final h = MediaQuery . of ( ctx ) . size . height;';
    expect(_mediaQuerySizePattern.hasMatch(plantedWhitespace), isTrue,
        reason: 'whitespace variants of MediaQuery size must be caught');

    // Legitimate MediaQuery properties are NOT caught…
    const legitimateViewInsets =
        'final bottom = MediaQuery.of(context).viewInsets.bottom;';
    expect(_mediaQuerySizePattern.hasMatch(legitimateViewInsets), isFalse,
        reason: 'viewInsets must remain allowed');

    const legitimatePadding =
        'final top = MediaQuery.of(context).padding.top;';
    expect(_mediaQuerySizePattern.hasMatch(legitimatePadding), isFalse,
        reason: 'padding must remain allowed');

    const legitimateViewPadding =
        'final safe = MediaQuery.of(context).viewPadding.bottom;';
    expect(_mediaQuerySizePattern.hasMatch(legitimateViewPadding), isFalse,
        reason: 'viewPadding must remain allowed');

    const legitimateTextScaler =
        'final scaler = MediaQuery.textScalerOf(context);';
    expect(_mediaQuerySizePattern.hasMatch(legitimateTextScaler), isFalse,
        reason: 'textScaler must remain allowed');

    const legitimateOrientation =
        'final isPortrait = MediaQuery.of(context).orientation == Orientation.portrait;';
    expect(_mediaQuerySizePattern.hasMatch(legitimateOrientation), isFalse,
        reason: 'orientation must remain allowed');

    // Sanctioned responsive extension getters are NOT caught…
    const sanctionedScreenWidth = 'final w = context.screenWidth;';
    expect(_mediaQuerySizePattern.hasMatch(sanctionedScreenWidth), isFalse,
        reason: 'context.screenWidth is the sanctioned form');

    const sanctionedScreenHeight = 'final h = context.screenHeight;';
    expect(_mediaQuerySizePattern.hasMatch(sanctionedScreenHeight), isFalse,
        reason: 'context.screenHeight is the sanctioned form');

    const sanctionedShortestSide = 'final s = context.screenShortestSide;';
    expect(_mediaQuerySizePattern.hasMatch(sanctionedShortestSide), isFalse,
        reason: 'context.screenShortestSide is the sanctioned form');
  });
}
