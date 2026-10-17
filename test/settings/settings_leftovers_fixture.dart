// Fixture for the #442 settings-page tests and goldens (Business Info,
// Appearance, Display, Receipt printer, Security, Subscription, Activity Logs
// access, Delete Business). Sample data only.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:print_bluetooth_thermal/print_bluetooth_thermal.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/services/business_logo_service.dart';
import 'package:reebaplus_pos/shared/services/printer_service.dart';

import '../helpers/screen_harness.dart';

/// Never touches storage or the file system.
class FakeLogoService extends BusinessLogoService {
  FakeLogoService() : super(Supabase.instance.client);

  @override
  Future<String?> ensureCached({
    required String businessId,
    required String? logoUrl,
  }) async => null;
}

const kCounterMac = '00:11:22:33:44:55';
const kBackOfficeMac = '66:77:88:99:AA:BB';

/// Never touches the Bluetooth plugin or `permission_handler`.
class FakePrinterService extends PrinterService {
  @override
  Future<bool> requestPermissions() async => true;

  @override
  Future<List<BluetoothInfo>> getPairedDevices() async => [
    BluetoothInfo(name: 'Counter printer', macAdress: kCounterMac),
    BluetoothInfo(name: 'Back office printer', macAdress: kBackOfficeMac),
  ];

  @override
  Future<String?> lastConnectedMac() async => kBackOfficeMac;
}

Future<ScreenTestEnvironment> setupSettingsEnv() async {
  final env = await setupScreenTestEnvironment(
    productCount: 0,
    businessName: 'Stallion Global',
  );
  await env.db.customStatement(
    "UPDATE stores SET name = 'Abuja HQ' WHERE id = '${env.storeId}'",
  );
  return env;
}

/// Pumps a settings page pushed over another route (so its top bar shows the
/// back arrow), as the CEO Settings menu opens it.
Future<BuildContext> pumpSettingsPage(
  WidgetTester tester, {
  required ScreenTestEnvironment env,
  required Widget screen,
  required Size size,
  EdgeInsets padding = EdgeInsets.zero,
  Set<String> grantedKeys = const {'settings.manage'},
  String roleSlug = 'ceo',
  String roleName = 'CEO',
  List<Override> overrides = const [],
  ThemeData? theme,
  TextScaler? textScaler,
  bool followView = false,
}) async {
  final context = await pumpScreen(
    tester,
    env: env,
    size: size,
    padding: padding,
    screen: Navigator(
      onGenerateInitialRoutes: (_, _) => [
        MaterialPageRoute<void>(builder: (_) => const SizedBox.shrink()),
        MaterialPageRoute<void>(builder: (_) => screen),
      ],
    ),
    bottomNavHeight: size.width >= 600 ? kBottomNavBodyHeight : 0,
    grantedKeys: grantedKeys,
    roleSlug: roleSlug,
    roleName: roleName,
    theme: theme,
    textScaler: textScaler,
    followView: followView,
    overrides: [
      businessLogoServiceProvider.overrideWithValue(FakeLogoService()),
      printerServiceProvider.overrideWithValue(FakePrinterService()),
      ...overrides,
    ],
    settle: false,
  );
  await deliverSettingsFrames(tester);
  return context;
}

Future<void> deliverSettingsFrames(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 250));
  }
}
