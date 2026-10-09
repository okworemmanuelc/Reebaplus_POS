// Visual goldens for Home (#374, PRD #346 Wave 1). Compare:
//
//   home_390x844_light.png  ↔ docs/redesign/mockups/phone-home-light.png
//   home_390x844_dark.png   ↔ docs/redesign/mockups/phone-home-dark.png
//   home_844x390_dark.png   ↔ docs/redesign/mockups/phone-landscape-home-dark.png
//   (+ _insets: a 24dp status bar and 3-button navigation on the right)
//   home_800x1280_*.png, home_1280x800_*.png: no mockup; built from the same
//   parts and the column rule (2 upright-tablet columns, 3 wide).
//
// The mockup's sample data, signed in as the CEO: business "Stallion Global",
// store "Abuja HQ", Total Sales ₦225,800, Net Profit ₦7,100, no pending
// orders, no expenses, Stock Value ₦19,382,600, ₦0 credit and debt, 8 unread
// notifications and the Reports attention dot. The mockup shows no Staff
// Sales; the one sale's cashier appears there. At 600dp+ the harness leaves
// the side rail's width blank on the left; only the screen is captured.
// `₦` draws as a box in tests (DM Sans has no Naira glyph).
//
// The PNGs live in test/redesign/goldens/ — never test/golden/, which CI runs
// on Linux. Regenerate with:
//
//     flutter test --update-goldens test/redesign/home_golden_test.dart

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/core/permissions/permissions.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/features/dashboard/get_started_checklist.dart';
import 'package:reebaplus_pos/features/dashboard/reports_attention.dart';
import 'package:reebaplus_pos/features/dashboard/screens/home_screen.dart';

import '../helpers/screen_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const sizes = <String, Size>{
    '390x844': Size(390, 844),
    '844x390': Size(844, 390),
    '800x1280': Size(800, 1280),
    '1280x800': Size(1280, 800),
  };

  late ScreenTestEnvironment env;

  setUp(() async {
    env = await setupScreenTestEnvironment(
      productCount: 1,
      businessName: 'Stallion Global',
    );
    final db = env.db;
    final b = env.businessId;
    await db.customStatement(
      "UPDATE stores SET name = 'Abuja HQ' WHERE id = '${env.storeId}'",
    );
    // 50 in stock × ₦387,652 = ₦19,382,600.
    await db.customStatement(
      'UPDATE products SET retailer_price_kobo = 38765200 '
      "WHERE id = '${env.products.first.id}'",
    );
    for (var i = 0; i < 8; i++) {
      await db.notificationsDao.create('info', 'Notification $i');
    }
    final roleId = UuidV7.generate();
    await db
        .into(db.roles)
        .insert(
          RolesCompanion.insert(
            id: Value(roleId),
            businessId: b,
            name: 'Cashier',
            slug: 'cashier',
          ),
        );
    final staffId = UuidV7.generate();
    await db
        .into(db.users)
        .insert(
          UsersCompanion.insert(
            id: Value(staffId),
            businessId: b,
            name: 'Amaka Obi',
            pin: '123456',
          ),
        );
    await db
        .into(db.userBusinesses)
        .insert(
          UserBusinessesCompanion.insert(
            id: Value(UuidV7.generate()),
            businessId: b,
            userId: staffId,
            roleId: roleId,
            status: const Value('active'),
          ),
        );
    // One sale: ₦225,800 at a cost of ₦218,700 → ₦7,100 profit.
    final at = seedAnchorToday();
    final orderId = UuidV7.generate();
    await db
        .into(db.orders)
        .insert(
          OrdersCompanion.insert(
            id: Value(orderId),
            businessId: b,
            orderNumber: 'ORD-000001-GOLD',
            totalAmountKobo: 22580000,
            netAmountKobo: 22580000,
            amountPaidKobo: const Value(22580000),
            paymentType: 'cash',
            status: 'completed',
            staffId: Value(staffId),
            storeId: Value(env.storeId),
            createdAt: Value(at),
          ),
        );
    await db
        .into(db.orderItems)
        .insert(
          OrderItemsCompanion.insert(
            id: Value(UuidV7.generate()),
            businessId: b,
            orderId: orderId,
            storeId: env.storeId,
            productId: Value(env.products.first.id),
            quantity: 1,
            unitPriceKobo: 22580000,
            buyingPriceKobo: const Value(21870000),
            totalKobo: 22580000,
            createdAt: Value(at),
          ),
        );
  });

  tearDown(() => env.dispose());

  Future<void> pumpGolden(
    WidgetTester tester, {
    required Brightness brightness,
    required Size size,
    required EdgeInsets padding,
    required String goldenName,
  }) async {
    await pumpScreen(
      tester,
      env: env,
      size: size,
      padding: padding,
      screen: const HomeScreen(),
      grantedKeys: const {
        'reports.see_sales',
        'reports.see_profit',
        'reports.see_expenses',
        'stock.view',
        'customers.add',
        'sales.make',
      },
      roleRank: GateTier.ceo,
      theme: brightness == Brightness.light
          ? AppTheme.light()
          : AppTheme.dark(),
      overrides: [
        currentBusinessNameProvider.overrideWithValue('Stallion Global'),
        reportsAttentionDotProvider.overrideWithValue(true),
        getStartedChecklistProvider.overrideWithValue(
          const GetStartedChecklistState(visible: false, steps: []),
        ),
      ],
      settle: false,
    );
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 250));
    }
    expect(tester.takeException(), isNull);

    await expectLater(
      find.byType(HomeScreen),
      matchesGoldenFile('goldens/$goldenName.png'),
    );
    await disposeScreen(tester);
  }

  for (final brightness in Brightness.values) {
    final themeName = brightness == Brightness.light ? 'light' : 'dark';
    sizes.forEach((sizeName, size) {
      testWidgets(
        'home $sizeName $themeName',
        (tester) => pumpGolden(
          tester,
          brightness: brightness,
          size: size,
          padding: EdgeInsets.zero,
          goldenName: 'home_${sizeName}_$themeName',
        ),
      );
    });
    testWidgets('home 844x390 with insets $themeName', (tester) async {
      tester.view.padding = const FakeViewPadding(top: 24, right: 48);
      tester.view.viewPadding = const FakeViewPadding(top: 24, right: 48);
      addTearDown(tester.view.resetPadding);
      addTearDown(tester.view.resetViewPadding);
      await pumpGolden(
        tester,
        brightness: brightness,
        size: const Size(844, 390),
        padding: const EdgeInsets.only(top: 24, right: 48),
        goldenName: 'home_844x390_insets_$themeName',
      );
    });
  }
}
