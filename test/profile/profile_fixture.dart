// Shared fixture for the Profile / Staff Settings tests and goldens (#442).
// Sample data only: business "Stallion Global", store "Abuja HQ", a made-up
// person.

import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/features/subscription/subscription_access.dart';

import '../helpers/screen_harness.dart';

const kProfileUserId = 'test-user-id';

RoleData profileRole(String slug, String name) => RoleData(
  id: 'role-$slug',
  businessId: 'biz',
  name: name,
  slug: slug,
  isSystemDefault: true,
  isDeleted: false,
  createdAt: DateTime(2026, 1, 1),
  lastUpdatedAt: DateTime(2026, 1, 1),
);

Future<ScreenTestEnvironment> setupProfileEnv() async {
  final env = await setupScreenTestEnvironment(
    productCount: 0,
    businessName: 'Stallion Global',
  );
  await env.db.customStatement(
    "UPDATE stores SET name = 'Abuja HQ' WHERE id = '${env.storeId}'",
  );
  return env;
}

/// Pumps [screen] as a pushed page for the role [slug], with fixed sample
/// data. Returns once the first frames have been delivered.
Future<BuildContext> pumpProfilePage(
  WidgetTester tester, {
  required ScreenTestEnvironment env,
  required Widget screen,
  required Size size,
  EdgeInsets padding = EdgeInsets.zero,
  String slug = 'cashier',
  String roleName = 'Cashier',
  Set<String> grantedKeys = const {},
  ThemeData? theme,
  TextScaler? textScaler,
  bool followView = false,
}) async {
  final role = profileRole(slug, roleName);
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
    roleSlug: slug,
    roleName: roleName,
    theme: theme,
    textScaler: textScaler,
    followView: followView,
    overrides: [
      userRoleProvider.overrideWith((ref, id) => role),
      currentBusinessSubscriptionProvider.overrideWithValue(
        SubscriptionAccess.active,
      ),
    ],
    settle: false,
  );
  final container = ProviderScope.containerOf(context, listen: false);
  final auth = container.read(authProvider);
  auth.value = auth.value!.copyWith(
    name: 'Chinedu Eze',
    email: const Value('chinedu@example.com'),
    createdAt: DateTime(2026, 3, 14),
    storeId: Value(env.storeId),
  );
  await deliverFrames(tester);
  return context;
}

Future<void> deliverFrames(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 250));
  }
}
