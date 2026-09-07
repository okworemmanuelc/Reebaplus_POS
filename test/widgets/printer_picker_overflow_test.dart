// printer_picker_overflow_test.dart
//
// Regression net for the landscape overflow reported 2026-09-06: opening the
// receipt printer picker on a landscape phone painted "BOTTOM OVERFLOWED BY 59
// PIXELS" over the sheet.
//
// Root cause was two faults compounding:
//
//   1. All four call sites capped the sheet at `getRHeight(0.5)` — a blind
//      fraction of screen height. On a 915x412 landscape phone that is a 206dp
//      ceiling.
//   2. `PrinterPicker`'s loading and empty branches were fixed-height
//      `Padding`s (with an UNSCALED `EdgeInsets.all(32)`), so the content could
//      not shrink or scroll below its ~265dp intrinsic height. Only the
//      device-list branch was `Flexible`.
//
// A sheet's chrome does not compress with the viewport — the refresh
// `IconButton` and the paper-size `SegmentedButton` are both pinned at the 48dp
// tap-target minimum — so the fix is both: `sheetMaxHeight` floors a short
// viewport's cap at 90%, and every branch of the picker is now Flexible +
// scrollable so it can never overflow whatever cap it is given.
//
// The `tightCap` cases below are the important ones: they pin the picker at the
// OLD 206dp ceiling and prove the widget alone no longer overflows, so the
// regression cannot come back through a call site that forgets `sheetMaxHeight`.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:print_bluetooth_thermal/print_bluetooth_thermal.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/features/pos/services/receipt_paper_size.dart';
import 'package:reebaplus_pos/shared/services/printer_service.dart';
import 'package:reebaplus_pos/shared/widgets/printer_picker.dart';

import '../helpers/viewports.dart';

/// Stands in for the real service so the picker never reaches the Bluetooth
/// plugin or `permission_handler`. `PrinterService` has a default constructor
/// and no final state, so a subclass is enough — no mocking package needed.
class _FakePrinterService extends PrinterService {
  _FakePrinterService(this.devices);

  final List<BluetoothInfo> devices;

  @override
  Future<bool> requestPermissions() async => true;

  @override
  Future<List<BluetoothInfo>> getPairedDevices() async => devices;

  @override
  Future<ReceiptPaperSize> getPaperSize() async => ReceiptPaperSize.mm58;

  @override
  Future<void> savePaperSize(ReceiptPaperSize size) async {}
}

/// Pumps [PrinterPicker] inside the same `BoxConstraints` the four production
/// call sites impose, at [size], and settles the two async loads in `initState`.
///
/// [maxHeight] defaults to what `sheetMaxHeight(0.5)` resolves to at [size];
/// pass a value to pin a specific ceiling.
Future<void> _pumpPicker(
  WidgetTester tester, {
  required Size size,
  List<BluetoothInfo> devices = const [],
  double? maxHeight,
  TextScaler textScaler = TextScaler.noScaling,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        printerServiceProvider.overrideWithValue(_FakePrinterService(devices)),
      ],
      child: MaterialApp(
        theme: AppTheme.dark(),
        home: Builder(
          builder: (context) {
            final cap = maxHeight ?? context.sheetMaxHeight(0.5);
            return MediaQuery(
              data: MediaQuery.of(context).copyWith(textScaler: textScaler),
              child: Scaffold(
                // Mirrors showModalBottomSheet: the sheet is bottom-anchored
                // under a hard maxHeight and sized to its content.
                body: Align(
                  alignment: Alignment.bottomCenter,
                  child: ConstrainedBox(
                    constraints: BoxConstraints(maxHeight: cap),
                    child: Material(
                      child: PrinterPicker(onSelected: (_) {}),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    ),
  );
  // initState kicks off _loadPaperSize + _loadDevices; settle both.
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('sheetMaxHeight', () {
    testWidgets('floors a short viewport at 90% instead of the raw fraction',
        (tester) async {
      final context = await pumpWithViewport(tester, size: pixel7Landscape);

      // The old behaviour, still available as the raw fraction.
      expect(context.getRHeight(0.5), closeTo(206.0, 0.01));
      // The new cap: 412 * 0.90.
      expect(context.sheetMaxHeight(0.5), closeTo(370.8, 0.01));
      expect(context.isShortViewport, isTrue);
    });

    testWidgets('leaves a comfortable viewport untouched', (tester) async {
      final context = await pumpWithViewport(tester, size: pixel7Portrait);

      expect(context.isShortViewport, isFalse);
      expect(context.sheetMaxHeight(0.5), context.getRHeight(0.5));
      expect(context.sheetMaxHeight(0.5), closeTo(457.5, 0.01));
    });

    testWidgets('never shrinks a fraction already above the floor',
        (tester) async {
      final context = await pumpWithViewport(tester, size: pixel7Landscape);

      // 0.92 > 0.90, so the floor must not pull it down.
      expect(context.sheetMaxHeight(0.92), closeTo(412 * 0.92, 0.01));
    });
  });

  group('PrinterPicker does not overflow', () {
    for (final (name, size) in const [
      ('pixel7Landscape', pixel7Landscape),
      ('androidCompactLandscape', androidCompactLandscape),
      ('phoneSe1Landscape', Size(568, 320)),
      ('pixel7Portrait', pixel7Portrait),
    ]) {
      testWidgets('$name — empty state', (tester) async {
        await _pumpPicker(tester, size: size);

        expect(find.text('Select Receipt Printer'), findsOneWidget);
        expect(find.text('Paper size'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });

      testWidgets('$name — populated list', (tester) async {
        await _pumpPicker(
          tester,
          size: size,
          devices: [
            BluetoothInfo(name: 'Thermal 58', macAdress: '00:11:22:33:44:55'),
            BluetoothInfo(name: 'Thermal 80', macAdress: '00:11:22:33:44:66'),
            BluetoothInfo(name: 'Spare', macAdress: '00:11:22:33:44:77'),
          ],
        );

        expect(find.text('Thermal 58'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets(
        'survives the OLD 206dp cap that produced the 59px overflow',
        (tester) async {
      // The exact ceiling getRHeight(0.5) imposed at pixel7Landscape. Before
      // the fix this overflowed by 59px; the widget must now absorb it on its
      // own, independent of sheetMaxHeight.
      await _pumpPicker(tester, size: pixel7Landscape, maxHeight: 206.0);

      expect(tester.takeException(), isNull);
      expect(find.text('Select Receipt Printer'), findsOneWidget);
    });

    testWidgets('survives the old cap under textScaler 1.3', (tester) async {
      await _pumpPicker(
        tester,
        size: pixel7Landscape,
        maxHeight: 206.0,
        textScaler: const TextScaler.linear(1.3),
      );

      expect(tester.takeException(), isNull);
    });

    testWidgets('the sheet stays within its cap at pixel7Landscape',
        (tester) async {
      await _pumpPicker(tester, size: pixel7Landscape);

      final rect = tester.getRect(find.byType(PrinterPicker));
      // 412 * 0.90 — the sheet may be shorter (content-sized) but never taller.
      expect(rect.height, lessThanOrEqualTo(370.8 + 0.01));
      expect(rect.bottom, lessThanOrEqualTo(412.0 + 0.01));
    });
  });
}
