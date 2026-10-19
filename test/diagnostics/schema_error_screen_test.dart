// Schema error screen restyle (#443). It is launched with a bare `runApp`
// before `ProviderScope`, the theme controller or the router exist, so every
// test here pumps it with NO provider scope and nothing but its own
// `MaterialApp`. Every error text and code stays visible: shop owners read them
// to support.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/features/diagnostics/screens/schema_error_screen.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';

import 'schema_error_sample.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pump(
    WidgetTester tester, {
    Size size = const Size(390, 844),
    FakeViewPadding padding = const FakeViewPadding(top: 24, bottom: 24),
    double scale = 1.0,
    bool withReport = true,
    Brightness platformBrightness = Brightness.light,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    tester.view.padding = padding;
    tester.view.viewPadding = padding;
    tester.platformDispatcher.textScaleFactorTestValue = scale;
    tester.platformDispatcher.platformBrightnessTestValue = platformBrightness;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearAllTestValues);
    await tester.pumpWidget(
      SchemaErrorScreen(audit: sampleSchemaAudit(withReport: withReport)),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('renders with no ProviderScope: every error text stays', (
    tester,
  ) async {
    await pump(tester);
    expect(tester.takeException(), isNull);
    expect(find.text('Schema corruption detected'), findsOneWidget);
    expect(
      find.textContaining('The local database is missing columns or tables'),
      findsOneWidget,
    );
    expect(
      find.textContaining('contact support and share the diagnostic file'),
      findsOneWidget,
    );
    // Key / value rows.
    expect(find.text('Schema version'), findsOneWidget);
    expect(find.text('85'), findsOneWidget);
    expect(find.text('Audited at'), findsOneWidget);
    expect(find.text('2026-03-14T09:30:00.000Z'), findsOneWidget);
    expect(find.text('Business ID'), findsOneWidget);
    expect(find.text('0192a9d0-1111-7000-8000-stallion00001'), findsOneWidget);
    expect(find.text('Device user ID'), findsOneWidget);
    expect(find.text('0192a9d0-2222-7000-8000-adaobi000001'), findsOneWidget);
    // Sections, with their heal state and heal error.
    expect(find.text('Missing tables'), findsOneWidget);
    expect(
      find.text('• crate_ledger  — table creation failed: disk I/O error'),
      findsOneWidget,
    );
    expect(find.text('• cost_batches  (healed)'), findsOneWidget);
    expect(find.text('Missing columns'), findsOneWidget);
    expect(
      find.text(
        '• orders.client_ref (TEXT)  — duplicate column name: client_ref',
      ),
      findsOneWidget,
    );
    expect(find.text('• products.barcode (TEXT)  (healed)'), findsOneWidget);
    expect(find.text('Recent migration events'), findsOneWidget);
    expect(
      find.text(
        '• v84 add_crate_ledger_reason [error]  — no such table: '
        'crate_ledger',
      ),
      findsOneWidget,
    );
    expect(
      find.text('• v85 index_orders_client_ref [warning]'),
      findsOneWidget,
    );
    expect(find.text('Diagnostic report'), findsOneWidget);
    expect(
      find.text(
        '/data/user/0/ng.reebaplus.pos/files/schema_audit_20260314.json',
      ),
      findsOneWidget,
    );
    expect(find.text('Copy report path'), findsOneWidget);
    expect(find.text('Close app'), findsOneWidget);
  });

  testWidgets('without a report the report block and button are absent', (
    tester,
  ) async {
    await pump(tester, withReport: false);
    expect(find.text('Diagnostic report'), findsNothing);
    expect(find.text('Copy report path'), findsNothing);
    expect(find.text('Close app'), findsOneWidget);
  });

  testWidgets('stays dark whatever the phone is set to', (tester) async {
    for (final b in Brightness.values) {
      await pump(tester, platformBrightness: b);
      final theme = Theme.of(tester.element(find.text('Close app')));
      expect(theme.brightness, Brightness.dark, reason: '$b');
    }
  });

  testWidgets('Copy report path copies it and says so', (tester) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String?;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await pump(tester);
    await tester.ensureVisible(find.text('Copy report path'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Copy report path'));
    await tester.pump();
    expect(
      copied,
      '/data/user/0/ng.reebaplus.pos/files/schema_audit_20260314.json',
    );
    expect(find.text('Path copied to clipboard'), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('both buttons are at least 48dp tall', (tester) async {
    await pump(tester);
    for (final label in const ['Copy report path', 'Close app']) {
      final button = find.ancestor(
        of: find.text(label),
        matching: find.byType(AppButton),
      );
      expect(
        tester.getSize(button).height,
        greaterThanOrEqualTo(kMinInteractiveDimension),
        reason: label,
      );
    }
  });

  testWidgets('the content caps at 720dp on a wide screen', (tester) async {
    await pump(
      tester,
      size: const Size(1280, 800),
      padding: FakeViewPadding.zero,
    );
    final closeButton = find.ancestor(
      of: find.text('Close app'),
      matching: find.byType(AppButton),
    );
    expect(tester.getSize(closeButton).width, lessThanOrEqualTo(720));
    expect(tester.getSize(closeButton).width, greaterThan(600));
  });

  final sizes = <(String, Size, FakeViewPadding, double)>[
    (
      '360@1.3',
      const Size(360, 640),
      const FakeViewPadding(top: 24, bottom: 48),
      1.3,
    ),
    (
      '390x844',
      const Size(390, 844),
      const FakeViewPadding(top: 24, bottom: 24),
      1.0,
    ),
    (
      '844x390',
      const Size(844, 390),
      const FakeViewPadding(top: 24, right: 48),
      1.0,
    ),
    ('800x1280', const Size(800, 1280), FakeViewPadding.zero, 1.0),
    ('1280x800', const Size(1280, 800), FakeViewPadding.zero, 1.0),
  ];
  for (final (name, size, padding, scale) in sizes) {
    testWidgets('no overflow at $name', (tester) async {
      await pump(tester, size: size, padding: padding, scale: scale);
      expect(tester.takeException(), isNull, reason: 'overflowed at $name');
      // The details scroll: the last block and the Close button are reachable.
      await tester.drag(
        find.byType(SingleChildScrollView).first,
        const Offset(0, -2000),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('Close app'), findsOneWidget);
    });
  }
}
