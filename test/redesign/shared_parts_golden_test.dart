// Gallery goldens for the redesign's shared parts (#352 PR 2): one small
// gallery per part, light and dark (Blue Classic), at a 390dp phone width,
// with the real bundled fonts and icons (test/flutter_test_config.dart).
//
// Wave 1/2 agents open these to see each part before adopting it. The PNGs
// live in test/redesign/goldens/ (never test/golden/, which CI runs on Linux).
// Regenerate with:
//
//     flutter test --update-goldens test/redesign/shared_parts_golden_test.dart

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/theme/app_decorations.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';

import '../shared/redesign/parts_samples.dart';

void main() {
  const width = 390.0;

  for (final name in partGalleries.keys) {
    for (final brightness in Brightness.values) {
      final themeName = brightness == Brightness.light ? 'light' : 'dark';
      testWidgets('parts gallery $name $themeName', (tester) async {
        tester.view.physicalSize = const Size(width, 1600);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);

        await tester.pumpWidget(
          MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: brightness == Brightness.light
                ? AppTheme.light()
                : AppTheme.dark(),
            home: Scaffold(
              body: Align(
                alignment: Alignment.topCenter,
                child: RepaintBoundary(
                  key: const Key('gallery'),
                  child: Builder(
                    builder: (context) => DecoratedBox(
                      decoration: AppDecorations.pageBackground(context),
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            for (final w in partGalleries[name]!(context)) ...[
                              w,
                              const SizedBox(height: 12),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pump();

        await expectLater(
          find.byKey(const Key('gallery')),
          matchesGoldenFile('goldens/parts_${name}_$themeName.png'),
        );
      });
    }
  }
}
