// Test print preview goldens (#702): 58mm Compact and 80mm Full, light and
// dark. PNGs live in test/redesign/goldens/. Regenerate with:
//
//     flutter test --update-goldens test/redesign/test_print_preview_golden_test.dart

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/features/settings/screens/test_print_preview_screen.dart';
import 'package:reebaplus_pos/shared/services/printer_service.dart';

const _id = '00:11:22:33:44:55';

void main() {
  setUpAll(() => WidgetsApp.debugAllowBannerOverride = false);
  tearDownAll(() => WidgetsApp.debugAllowBannerOverride = true);

  const cases = <String, Map<String, Object>>{
    '58_compact': {
      'printer_paper_size:$_id': 'mm58',
      'printer_receipt_size:$_id': 'compact',
    },
    '80_full': {
      'printer_paper_size:$_id': 'mm80',
      'printer_receipt_size:$_id': 'full',
    },
  };

  for (final brightness in Brightness.values) {
    final themeName = brightness == Brightness.light ? 'light' : 'dark';
    cases.forEach((name, prefs) {
      testWidgets('test print preview $name $themeName', (tester) async {
        SharedPreferences.setMockInitialValues(prefs);
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              printerServiceProvider.overrideWithValue(PrinterService()),
              currentBusinessNameProvider.overrideWithValue('Ada Bar'),
            ],
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: brightness == Brightness.light
                  ? AppTheme.light()
                  : AppTheme.dark(),
              home: TestPrintPreviewScreen(
                printerId: _id,
                printerName: 'Counter printer',
                send: (_, _, _) async => true,
                saleDate: DateTime(2026, 11, 3, 10, 30),
              ),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 100));
        await tester.pump(const Duration(milliseconds: 100));
        await expectLater(
          find.byType(TestPrintPreviewScreen),
          matchesGoldenFile(
            'goldens/test_print_preview_${name}_$themeName.png',
          ),
        );
      });
    });
  }
}
