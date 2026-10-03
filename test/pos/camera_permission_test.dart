// camera_permission_test.dart
//
// The camera-permission check before the barcode scanner opens: an allowed
// camera opens straight away, an unasked one gets the phone's prompt first,
// and a refused one gets the "Camera is off" sheet with a shortcut to the
// phone's settings. Also the scanner's own "camera is off" view.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/features/pos/services/camera_permission.dart';
import 'package:reebaplus_pos/features/pos/services/mobile_scanner_scan_camera.dart';
import 'package:reebaplus_pos/features/pos/widgets/camera_permission_sheet.dart';

class _FakePermission implements CameraPermission {
  _FakePermission({
    required this.current,
    CameraAccess? afterRequest,
    this.canOpenSettings = true,
    this.throwsOnStatus = false,
  }) : afterRequest = afterRequest ?? current;

  final CameraAccess current;
  final CameraAccess afterRequest;
  final bool canOpenSettings;
  final bool throwsOnStatus;

  int requests = 0;
  int settingsOpened = 0;

  @override
  Future<CameraAccess> status() async {
    if (throwsOnStatus) throw Exception('no permission plugin');
    return current;
  }

  @override
  Future<CameraAccess> request() async {
    requests++;
    return afterRequest;
  }

  @override
  Future<bool> openSettings() async {
    settingsOpened++;
    return canOpenSettings;
  }
}

/// Pumps a button that runs [ensureCameraAccess] and records its answer.
Future<List<bool>> _pumpHost(
  WidgetTester tester,
  CameraPermission permission,
) async {
  final results = <bool>[];
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(),
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () async =>
                results.add(await ensureCameraAccess(context, permission)),
            child: const Text('Scan'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Scan'));
  await tester.pumpAndSettle();
  return results;
}

void main() {
  group('ensureCameraAccess', () {
    testWidgets('allowed camera: opens with no prompt and no sheet', (
      tester,
    ) async {
      final permission = _FakePermission(current: CameraAccess.granted);
      final results = await _pumpHost(tester, permission);

      expect(results, [true]);
      expect(permission.requests, 0);
      expect(find.byType(CameraPermissionSheet), findsNothing);
    });

    testWidgets('never asked: the phone prompts first; allowing opens it', (
      tester,
    ) async {
      final permission = _FakePermission(
        current: CameraAccess.askable,
        afterRequest: CameraAccess.granted,
      );
      final results = await _pumpHost(tester, permission);

      expect(results, [true]);
      expect(permission.requests, 1);
      expect(find.byType(CameraPermissionSheet), findsNothing);
    });

    testWidgets('refused at the prompt: shows the "Camera is off" sheet', (
      tester,
    ) async {
      final permission = _FakePermission(current: CameraAccess.askable);
      final results = await _pumpHost(tester, permission);

      expect(permission.requests, 1);
      expect(find.text('Camera is off'), findsOneWidget);

      await tester.tap(find.byKey(kCameraPermissionNotNowKey));
      await tester.pumpAndSettle();

      expect(results, [false]);
      expect(permission.settingsOpened, 0);
      expect(find.byType(CameraPermissionSheet), findsNothing);
    });

    testWidgets('blocked: no prompt; "Open settings" opens the phone settings', (
      tester,
    ) async {
      final permission = _FakePermission(current: CameraAccess.blocked);
      final results = await _pumpHost(tester, permission);

      expect(permission.requests, 0);
      expect(find.text('Camera is off'), findsOneWidget);

      await tester.tap(find.byKey(kCameraPermissionOpenSettingsKey));
      await tester.pumpAndSettle();

      expect(permission.settingsOpened, 1);
      // The scanner stays closed; the cashier taps Scan again once back.
      expect(results, [false]);
      expect(find.byType(CameraPermissionSheet), findsNothing);
    });

    testWidgets('settings could not open: says where to go instead', (
      tester,
    ) async {
      final permission = _FakePermission(
        current: CameraAccess.blocked,
        canOpenSettings: false,
      );
      final results = await _pumpHost(tester, permission);

      await tester.tap(find.byKey(kCameraPermissionOpenSettingsKey));
      await tester.pump();

      expect(results, [false]);
      expect(find.textContaining("Couldn't open settings"), findsOneWidget);
      await tester.pumpAndSettle(const Duration(seconds: 5));
    });

    testWidgets('permission unreadable: leaves it to the scanner', (
      tester,
    ) async {
      final permission = _FakePermission(
        current: CameraAccess.blocked,
        throwsOnStatus: true,
      );
      final results = await _pumpHost(tester, permission);

      expect(results, [true]);
      expect(find.byType(CameraPermissionSheet), findsNothing);
    });
  });

  group('ScannerErrorView', () {
    Future<void> pumpView(
      WidgetTester tester, {
      required bool isPermissionDenied,
      required VoidCallback onOpenSettings,
    }) {
      return tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            backgroundColor: Colors.black,
            body: ScannerErrorView(
              isPermissionDenied: isPermissionDenied,
              onOpenSettings: onOpenSettings,
            ),
          ),
        ),
      );
    }

    testWidgets('camera permission off: offers "Open settings"', (
      tester,
    ) async {
      var opened = 0;
      await pumpView(
        tester,
        isPermissionDenied: true,
        onOpenSettings: () => opened++,
      );

      expect(find.textContaining('Camera is off for this app'), findsOneWidget);
      await tester.tap(find.text('Open settings'));
      expect(opened, 1);
    });

    testWidgets('other camera errors: no settings shortcut', (tester) async {
      await pumpView(
        tester,
        isPermissionDenied: false,
        onOpenSettings: () {},
      );

      expect(find.textContaining('Camera unavailable'), findsOneWidget);
      expect(find.text('Open settings'), findsNothing);
    });
  });
}
