// van_wide_layout_test.dart
//
// #820 — Van Sales screens fit every screen size: lists capped at 720, the
// hub's van cards in a grid of at most 540-wide cards. Layout only.

import 'package:drift/drift.dart' hide isNull;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/core/van_sales/van_sales_switch.dart';
import 'package:reebaplus_pos/features/van_sales/screens/drivers_list_screen.dart';
import 'package:reebaplus_pos/features/van_sales/screens/van_sales_hub_screen.dart';
import 'package:reebaplus_pos/features/van_sales/widgets/van_ui.dart';

import '../helpers/screen_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('cardGridColumns / cardGridMaxWidth', () {
    test('columns follow the measured width, items and cap', () {
      expect(cardGridColumns(360, itemCount: 5), 1);
      expect(cardGridColumns(764, itemCount: 5), 2);
      expect(cardGridColumns(1920, itemCount: 2), 2);
      expect(cardGridColumns(1920, itemCount: 5), 3);
      expect(cardGridColumns(1920, itemCount: 1), 1);
      expect(cardGridColumns(1920, itemCount: 0), 1);
      expect(cardGridColumns(1920, itemCount: 9, maxColumns: 2), 2);
    });

    test('max width is columns of kCardMaxWidth plus gaps', () {
      expect(cardGridMaxWidth(1), kCardMaxWidth);
      expect(cardGridMaxWidth(2), 2 * kCardMaxWidth + 16);
      expect(cardGridMaxWidth(3), 3 * kCardMaxWidth + 32);
    });
  });

  testWidgets('contentGutter centres the column, never under 16', (
    tester,
  ) async {
    late double wide;
    late double narrow;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            wide = contentGutter(context, 1920);
            narrow = contentGutter(context, 360);
            return const SizedBox();
          },
        ),
      ),
    );
    expect(wide, (1920 - kContentMaxWidth) / 2);
    expect(narrow, greaterThanOrEqualTo(16 * 0.84));
    expect(narrow, lessThan(30));
  });

  group('screens', () {
    late ScreenTestEnvironment env;
    late String driverId;
    const grants = {'van.manage'};

    Future<void> settleFrames(WidgetTester tester) async {
      for (var i = 0; i < 8; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump(const Duration(milliseconds: 250));
      }
    }

    setUp(() async {
      debugOverrideVanSalesEnabled(true);
      env = await setupScreenTestEnvironment(businessType: 'drinks');
      final db = env.db;
      driverId = UuidV7.generate();
      await db
          .into(db.vanDrivers)
          .insert(
            VanDriversCompanion.insert(
              id: Value(driverId),
              businessId: env.businessId,
              name: 'Johnson Kim',
            ),
          );
      final vanIds = [UuidV7.generate(), UuidV7.generate()];
      for (var i = 0; i < 2; i++) {
        await db
            .into(db.stores)
            .insert(
              StoresCompanion.insert(
                id: Value(vanIds[i]),
                businessId: env.businessId,
                name: 'Van ${i + 1}',
                kind: const Value(kStoreKindVan),
              ),
            );
      }
      // Van 2 is out on a trip.
      await db
          .into(db.vanTrips)
          .insert(
            VanTripsCompanion.insert(
              id: Value(UuidV7.generate()),
              businessId: env.businessId,
              vanStoreId: vanIds[1],
              vanDriverId: Value(driverId),
              sourceStoreId: env.storeId,
            ),
          );
    });

    tearDown(() async {
      debugOverrideVanSalesEnabled(null);
      await env.dispose();
    });

    for (final size in const [
      Size(360, 800),
      Size(844, 390),
      Size(800, 1280),
      Size(1280, 800),
      Size(1920, 1080),
    ]) {
      testWidgets('hub pumps clean at ${size.width.toInt()}x'
          '${size.height.toInt()}', (tester) async {
        await pumpScreen(
          tester,
          env: env,
          size: size,
          screen: const VanSalesHubScreen(),
          grantedKeys: grants,
          settle: false,
        );
        await settleFrames(tester);
        expect(find.byType(VanCard), findsNWidgets(2));
        expect(tester.takeException(), isNull);
        await tester.pump(const Duration(seconds: 10));
        await disposeScreen(tester);
      });
    }

    testWidgets('hub at 1920x1080: one centred column, capped at 720', (
      tester,
    ) async {
      await pumpScreen(
        tester,
        env: env,
        size: const Size(1920, 1080),
        screen: const VanSalesHubScreen(),
        grantedKeys: grants,
        settle: false,
      );
      await settleFrames(tester);
      final a = find.byType(VanCard).at(0);
      final b = find.byType(VanCard).at(1);
      expect(tester.getTopLeft(b).dy, greaterThan(tester.getTopLeft(a).dy));
      expect(tester.getSize(a).width, lessThanOrEqualTo(kContentMaxWidth));
      expect(tester.getSize(b).width, lessThanOrEqualTo(kContentMaxWidth));
      // Centred: the same margin on both sides of the column.
      final left = tester.getTopLeft(a).dx;
      final right = 1920 - tester.getTopRight(a).dx;
      expect((left - right).abs(), lessThan(100));
      expect(tester.takeException(), isNull);
      await tester.pump(const Duration(seconds: 10));
      await disposeScreen(tester);
    });

    testWidgets('hub at 360x800: the second card sits below the first', (
      tester,
    ) async {
      await pumpScreen(
        tester,
        env: env,
        size: const Size(360, 800),
        screen: const VanSalesHubScreen(),
        grantedKeys: grants,
        settle: false,
      );
      await settleFrames(tester);
      final a = find.byType(VanCard).at(0);
      final b = find.byType(VanCard).at(1);
      expect(tester.getTopLeft(b).dy, greaterThan(tester.getTopLeft(a).dy));
      await tester.pump(const Duration(seconds: 10));
      await disposeScreen(tester);
    });

    testWidgets('drivers list at 1920x1080: rows stay within 720', (
      tester,
    ) async {
      await pumpScreen(
        tester,
        env: env,
        size: const Size(1920, 1080),
        screen: const DriversListScreen(),
        grantedKeys: grants,
        settle: false,
      );
      await settleFrames(tester);
      final row = find
          .ancestor(
            of: find.text('Johnson Kim'),
            matching: find.byType(GestureDetector),
          )
          .first;
      expect(tester.getSize(row).width, lessThanOrEqualTo(kContentMaxWidth));
      expect(tester.takeException(), isNull);
      await tester.pump(const Duration(seconds: 10));
      await disposeScreen(tester);
    });
  });
}
