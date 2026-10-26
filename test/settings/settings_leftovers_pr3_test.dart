// Security, Subscription, Activity Logs (access + log) and Delete Business
// after the #442 restyle (PR 3 of 3, PRD #346 Wave 2 C): every control still
// renders, the permission-hidden ones stay hidden, the main actions still work
// and nothing overflows at the reference sizes.

import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/settings/activity_logs_access_screen.dart';
import 'package:reebaplus_pos/core/settings/delete_business_screen.dart';
import 'package:reebaplus_pos/core/settings/security_settings_screen.dart';
import 'package:reebaplus_pos/core/settings/subscription_screen.dart';
import 'package:reebaplus_pos/features/subscription/billing/play_billing_providers.dart';
import 'package:reebaplus_pos/features/subscription/billing/plans_paywall.dart';
import 'package:reebaplus_pos/features/subscription/subscription_access.dart';
import 'package:reebaplus_pos/shared/widgets/activity_log_screen.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/tag_pill.dart';

import '../helpers/screen_harness.dart';
import 'settings_leftovers_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late ScreenTestEnvironment env;
  setUp(() async => env = await setupSettingsEnv());
  tearDown(() => env.dispose());

  group('Security', () {
    testWidgets('renders every control and a preset saves', (tester) async {
      await pumpSettingsPage(
        tester,
        env: env,
        screen: const SecuritySettingsScreen(),
        size: const Size(390, 844),
      );
      expect(find.text('Auto-lock'), findsOneWidget);
      expect(find.text('Biometric login'), findsOneWidget);
      for (final m in ['1', '3', '5', '10', '15', '30']) {
        expect(find.text('$m min'), findsOneWidget, reason: m);
      }
      await tester.tap(find.text('3 min'));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)),
      );
      await tester.pump(const Duration(milliseconds: 300));
      expect(await env.db.settingsDao.get('auto_lock_interval_seconds'), '180');
      await tester.pumpAndSettle(const Duration(seconds: 5));
      await disposeScreen(tester);
    });

    testWidgets('hidden without settings.manage', (tester) async {
      await pumpSettingsPage(
        tester,
        env: env,
        screen: const SecuritySettingsScreen(),
        size: const Size(390, 844),
        grantedKeys: const {},
        roleSlug: 'cashier',
        roleName: 'Cashier',
      );
      expect(find.text("You don't have access to settings."), findsOneWidget);
      expect(find.text('Auto-lock'), findsNothing);
      await disposeScreen(tester);
    });
  });

  group('Subscription page', () {
    testWidgets('shows the plan, status and renewal; paywall is non-Android here', (
      tester,
    ) async {
      await seedSubscription(
        env,
        plan: 'local',
        periodEnd: DateTime(2026, 4, 14),
      );
      await pumpSettingsPage(
        tester,
        env: env,
        screen: const SubscriptionScreen(),
        size: const Size(390, 844),
        overrides: [
          billingSupportedProvider.overrideWithValue(false),
          currentBusinessSubscriptionProvider.overrideWithValue(
            SubscriptionAccess.active,
          ),
        ],
      );
      expect(find.text('Monthly subscription'), findsOneWidget);
      expect(find.text('ACTIVE'), findsOneWidget);
      expect(find.text('Renews'), findsOneWidget);
      expect(find.text('14 Apr 2026'), findsOneWidget);
      expect(find.byKey(const Key('paywall-non-android')), findsOneWidget);
      // Read-only: the cloud-owned columns are untouched.
      final b = await (env.db.select(
        env.db.businesses,
      )..where((t) => t.id.equals(env.businessId))).getSingle();
      expect(b.currentPeriodEnd, DateTime(2026, 4, 14));
      expect(b.subscriptionPlan, 'local');
      await disposeScreen(tester);
    });

    testWidgets('an ended trial shows TRIAL ENDED', (tester) async {
      await seedSubscription(env, trialEnds: DateTime(2026, 2, 1));
      await pumpSettingsPage(
        tester,
        env: env,
        screen: const SubscriptionScreen(),
        size: const Size(390, 844),
        overrides: [
          currentBusinessSubscriptionProvider.overrideWithValue(
            SubscriptionAccess.trialExpired,
          ),
        ],
      );
      expect(find.text('TRIAL ENDED'), findsOneWidget);
      expect(find.text('Trial ends'), findsOneWidget);
      expect(find.text('Ended 1 Feb 2026'), findsOneWidget);
      await disposeScreen(tester);
    });

    testWidgets('hidden without settings.manage', (tester) async {
      await pumpSettingsPage(
        tester,
        env: env,
        screen: const SubscriptionScreen(),
        size: const Size(390, 844),
        grantedKeys: const {},
        roleSlug: 'cashier',
        roleName: 'Cashier',
      );
      expect(find.byType(PlansPaywall), findsNothing);
      await disposeScreen(tester);
    });
  });

  group('Activity Logs access', () {
    testWidgets('lists the roles; the CEO is locked on', (tester) async {
      await seedSampleRoles(env);
      await pumpSettingsPage(
        tester,
        env: env,
        screen: const ActivityLogsAccessScreen(),
        size: const Size(390, 844),
      );
      expect(find.text('CEO'), findsOneWidget);
      expect(find.text('Always on'), findsOneWidget);
      expect(find.text('Cashier'), findsOneWidget);
      final ceoSwitch = tester.widget<Switch>(find.byType(Switch).first);
      expect(ceoSwitch.onChanged, isNull);
      await disposeScreen(tester);
    });

    testWidgets('hidden without settings.manage', (tester) async {
      await pumpSettingsPage(
        tester,
        env: env,
        screen: const ActivityLogsAccessScreen(),
        size: const Size(390, 844),
        grantedKeys: const {},
        roleSlug: 'cashier',
        roleName: 'Cashier',
      );
      expect(find.byType(Switch), findsNothing);
      await disposeScreen(tester);
    });
  });

  group('Activity Logs', () {
    testWidgets('lists the log rows', (tester) async {
      await seedSampleActivityLogs(env);
      await pumpSettingsPage(
        tester,
        env: env,
        screen: const ActivityLogScreen(),
        size: const Size(390, 844),
        pushed: false,
        grantedKeys: const {'activity_logs.view'},
      );
      expect(find.text('Activity Logs'), findsOneWidget);
      expect(find.text('Sale completed'), findsOneWidget);
      expect(find.text('Stock received'), findsOneWidget);
      expect(find.text('Customer added'), findsOneWidget);
      await disposeScreen(tester);
    });

    testWidgets(
      'store pill resolves name for active and soft-deleted stores, falling back to N/A for unknown stores',
      (tester) async {
        await env.db
            .into(env.db.stores)
            .insert(
              StoresCompanion.insert(
                id: const Value('store-soft-deleted'),
                businessId: env.businessId,
                name: 'Old Lagos Branch',
                location: const Value('Lagos'),
                isDeleted: const Value(true),
              ),
            );

        final now = DateTime(2026, 3, 14, 12, 0);
        await env.db
            .into(env.db.activityLogs)
            .insert(
              ActivityLogsCompanion.insert(
                id: const Value('log-active'),
                businessId: env.businessId,
                action: 'Active store action',
                description: 'Active store event',
                createdAt: Value(now),
                storeId: Value(env.storeId),
                lastUpdatedAt: Value(now),
              ),
            );
        await env.db
            .into(env.db.activityLogs)
            .insert(
              ActivityLogsCompanion.insert(
                id: const Value('log-soft-deleted'),
                businessId: env.businessId,
                action: 'Archived store action',
                description: 'Archived store event',
                createdAt: Value(now.subtract(const Duration(minutes: 5))),
                storeId: const Value('store-soft-deleted'),
                lastUpdatedAt: Value(now),
              ),
            );
        await env.db.customStatement('PRAGMA foreign_keys = OFF;');
        await env.db
            .into(env.db.activityLogs)
            .insert(
              ActivityLogsCompanion.insert(
                id: const Value('log-unknown'),
                businessId: env.businessId,
                action: 'Unknown store action',
                description: 'Unknown store event',
                createdAt: Value(now.subtract(const Duration(minutes: 10))),
                storeId: const Value('store-nonexistent'),
                lastUpdatedAt: Value(now),
              ),
            );
        await env.db.customStatement('PRAGMA foreign_keys = ON;');

        await pumpSettingsPage(
          tester,
          env: env,
          screen: const ActivityLogScreen(),
          size: const Size(390, 844),
          pushed: false,
          grantedKeys: const {'activity_logs.view'},
          overrides: [
            lockedStoreProvider.overrideWith(
              (ref) => ValueNotifier<String?>(null),
            ),
          ],
        );

        expect(find.widgetWithText(TagPill, 'Abuja HQ'), findsOneWidget);
        expect(
          find.widgetWithText(TagPill, 'Old Lagos Branch'),
          findsOneWidget,
        );
        expect(find.widgetWithText(TagPill, 'N/A'), findsOneWidget);

        await disposeScreen(tester);
      },
    );
    testWidgets('empty state says so', (tester) async {
      await pumpSettingsPage(
        tester,
        env: env,
        screen: const ActivityLogScreen(),
        size: const Size(390, 844),
        pushed: false,
        grantedKeys: const {'activity_logs.view'},
      );
      expect(find.text('No Activity Found'), findsOneWidget);
      await disposeScreen(tester);
    });

    testWidgets('hidden without activity_logs.view', (tester) async {
      await seedSampleActivityLogs(env);
      await pumpSettingsPage(
        tester,
        env: env,
        screen: const ActivityLogScreen(),
        size: const Size(390, 844),
        pushed: false,
        grantedKeys: const {},
        roleSlug: 'cashier',
        roleName: 'Cashier',
      );
      expect(
        find.text("You don't have access to Activity Logs."),
        findsOneWidget,
      );
      expect(find.text('Sale completed'), findsNothing);
      await disposeScreen(tester);
    });
  });

  group('Delete Business', () {
    testWidgets('shows the warning; the button asks for the PIN', (
      tester,
    ) async {
      await pumpSettingsPage(
        tester,
        env: env,
        screen: const DeleteBusinessScreen(),
        size: const Size(390, 844),
        grantedKeys: const {'settings.delete_business'},
      );
      expect(
        find.text('This is permanent and cannot be undone'),
        findsOneWidget,
      );
      expect(find.textContaining('Stallion Global'), findsWidgets);
      expect(
        find.text('You will be asked for your PIN to confirm.'),
        findsOneWidget,
      );
      await tester.tap(find.widgetWithText(AppButton, 'Delete Business'));
      await tester.pumpAndSettle();
      expect(find.text('Re-enter your PIN to delete'), findsOneWidget);
      await disposeScreen(tester);
    });

    testWidgets('hidden without settings.delete_business', (tester) async {
      await pumpSettingsPage(
        tester,
        env: env,
        screen: const DeleteBusinessScreen(),
        size: const Size(390, 844),
        grantedKeys: const {},
        roleSlug: 'manager',
        roleName: 'Manager',
      );
      expect(find.text("You don't have access to settings."), findsOneWidget);
      expect(find.text('This is permanent and cannot be undone'), findsNothing);
      await disposeScreen(tester);
    });
  });

  group('no overflow', () {
    const cases = <(String, Size, EdgeInsets, double)>[
      ('360x640 @1.3', Size(360, 640), EdgeInsets.zero, 1.3),
      ('390x844', Size(390, 844), EdgeInsets.only(top: 24, bottom: 24), 1),
      ('844x390', Size(844, 390), EdgeInsets.only(top: 24, right: 48), 1),
      ('800x1280', Size(800, 1280), EdgeInsets.zero, 1),
      ('1280x800', Size(1280, 800), EdgeInsets.zero, 1),
    ];
    for (final (name, size, insets, scale) in cases) {
      for (final (label, screen, pushed) in <(String, Widget, bool)>[
        ('security', const SecuritySettingsScreen(), true),
        ('subscription', const SubscriptionScreen(), true),
        ('activity logs access', const ActivityLogsAccessScreen(), true),
        ('activity logs', const ActivityLogScreen(), false),
        ('delete business', const DeleteBusinessScreen(), true),
      ]) {
        testWidgets('$label $name', (tester) async {
          final fake = FakeViewPadding(
            top: insets.top,
            right: insets.right,
            bottom: insets.bottom,
          );
          tester.view.padding = fake;
          tester.view.viewPadding = fake;
          addTearDown(tester.view.resetPadding);
          addTearDown(tester.view.resetViewPadding);
          await seedSampleRoles(env);
          await seedSampleActivityLogs(env);
          await seedSubscription(
            env,
            plan: 'local',
            periodEnd: DateTime(2026, 4, 14),
          );
          await pumpSettingsPage(
            tester,
            env: env,
            screen: screen,
            size: size,
            padding: insets,
            pushed: pushed,
            grantedKeys: const {
              'settings.manage',
              'settings.delete_business',
              'activity_logs.view',
            },
            textScaler: TextScaler.linear(scale),
            overrides: [
              currentBusinessSubscriptionProvider.overrideWithValue(
                SubscriptionAccess.active,
              ),
            ],
          );
          expectNoOverflow(tester);
          await disposeScreen(tester);
        });
      }
    }
  });
}
