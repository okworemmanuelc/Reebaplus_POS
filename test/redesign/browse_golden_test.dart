// Visual goldens for Browse (#425): feed, offline and store page at 390x844
// and 844x390 (24dp status bar + 48dp side inset). No Claude Design files
// exist for these screens; they follow ui-context tokens and shared parts.
// Regenerate with:
//
//     flutter test --update-goldens test/redesign/browse_golden_test.dart

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/features/browse/screens/browse_screen.dart';
import 'package:reebaplus_pos/features/browse/screens/storefront_store_screen.dart';

import '../browse/browse_fixtures.dart';

void main() {
  const sizes = <String, (Size, EdgeInsets)>{
    '390x844': (Size(390, 844), EdgeInsets.zero),
    '844x390': (Size(844, 390), EdgeInsets.only(top: 24, right: 48)),
  };
  final screens = <String, (Widget, FakeStorefront Function())>{
    'feed': (const BrowseScreen(), FakeStorefront.new),
    'offline': (const BrowseScreen(), () => FakeStorefront(online: false)),
    'store': (const StorefrontStoreScreen(storeId: 'store-9'), FakeStorefront.new),
  };

  for (final screen in screens.entries) {
    for (final size in sizes.entries) {
      for (final brightness in Brightness.values) {
        final name = 'browse_${screen.key}_${size.key}_${brightness.name}';
        testWidgets(name, (tester) async {
          await pumpBrowse(
            tester,
            screen: screen.value.$1,
            backend: screen.value.$2(),
            size: size.value.$1,
            padding: size.value.$2,
            brightness: brightness,
          );
          expect(tester.takeException(), isNull);
          await expectLater(
            find.byType(MaterialApp),
            matchesGoldenFile('goldens/$name.png'),
          );
        });
      }
    }
  }

  for (final size in sizes.entries) {
    final brightness = size.key == '390x844' ? Brightness.light : Brightness.dark;
    final name = 'browse_product_sheet_${size.key}_${brightness.name}';
    testWidgets(name, (tester) async {
      await pumpBrowse(tester, screen: const BrowseScreen(), backend: FakeStorefront(),
          size: size.value.$1, padding: size.value.$2, brightness: brightness);
      await tester.tap(find.text('Star Lager'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/$name.png'));
    });
  }
}
