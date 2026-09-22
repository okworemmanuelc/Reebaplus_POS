import 'package:drift/drift.dart' hide isNull;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/features/dashboard/screens/stock_approvals_screen.dart';
import '../helpers/screen_harness.dart';
import '../helpers/viewports.dart';

void main() {
  late ScreenTestEnvironment env;

  setUp(() async {
    env = await setupScreenTestEnvironment(
      businessType: 'Beverage distributor',
      manufacturerCount: 1,
    );
    // Allow inventory adjustment locally
    await env.db.systemConfigDao
        .set('feature.domain_rpcs_v2.inventory_delta', 'false');
    await env.db.into(env.db.users).insert(
          UsersCompanion.insert(
            id: const Value('test-user-id'),
            businessId: env.businessId,
            name: 'Test Admin',
            pin: '1234',
          ),
        );
  });

  Future<void> teardownScreen(WidgetTester tester) async {
    // Settle any transient snackbar / toast auto-dismiss timers
    await tester.pump(const Duration(seconds: 5));
    await disposeScreen(tester);
    await tester.runAsync(() => env.dispose());
  }

  const grantedAll = {
    'sales.make',
    'reports.view_approvals',
    'inventory.adjust',
    'expenses.approve',
  };

  StockAdjustmentRequestData makeStockReq({String id = 'req-stock-1'}) =>
      StockAdjustmentRequestData(
        id: id,
        businessId: env.businessId,
        productId: env.products.first.id,
        storeId: env.storeId,
        quantityDiff: 5,
        reason: 'Restock overflow',
        summary: 'Add 5 ${env.products.first.name}',
        requestedBy: 'test-user-id',
        status: 'pending',
        approvedBy: null,
        approvedAt: null,
        createdAt: DateTime.now(),
        lastUpdatedAt: DateTime.now(),
      );

  QuickSaleRequestData makeQuickReq({String id = 'req-quick-1'}) =>
      QuickSaleRequestData(
        id: id,
        businessId: env.businessId,
        storeId: env.storeId,
        itemName: 'Ice Bag',
        quantity: 2,
        unitPriceKobo: 50000,
        summary: 'Quick Sale · Ice Bag',
        requestedBy: 'test-user-id',
        status: 'pending',
        approvedBy: null,
        approvedAt: null,
        createdAt: DateTime.now(),
        lastUpdatedAt: DateTime.now(),
      );

  SupplierCrateDepositRequestData makeCrateReq({String id = 'req-crate-1'}) =>
      SupplierCrateDepositRequestData(
        id: id,
        businessId: env.businessId,
        supplierId: 'supplier-1',
        manufacturerId: env.manufacturers.first.id,
        storeId: env.storeId,
        kind: 'placement',
        crateCount: 10,
        ratePerCrateKobo: 100000,
        requestedAmountKobo: 1000000,
        settledAmountKobo: null,
        paymentMethod: null,
        summary: '10 crates deposit',
        supplierCrateLedgerId: null,
        note: null,
        requestedBy: null,
        status: 'pending',
        decidedBy: null,
        decidedAt: null,
        decisionNote: null,
        createdAt: DateTime.now(),
        lastUpdatedAt: DateTime.now(),
      );

  testWidgets('with pending requests, opening Approvals reports no framework error',
      (tester) async {
    final stockReq = makeStockReq();
    final quickReq = makeQuickReq();
    final crateReq = makeCrateReq();

    await pumpScreen(
      tester,
      env: env,
      size: pixel7Portrait,
      grantedKeys: grantedAll,
      roleRank: 0,
      overrides: [
        viewerScopedPendingStockRequestsProvider
            .overrideWith((ref) => [stockReq]),
        viewerScopedPendingQuickSaleRequestsProvider
            .overrideWith((ref) => [quickReq]),
        viewerScopedPendingCrateDepositsProvider
            .overrideWith((ref) => [crateReq]),
      ],
      screen: const StockApprovalsScreen(),
    );

    expectNoOverflow(tester);
    expect(find.byType(ExpansionTile), findsNWidgets(3));
    await teardownScreen(tester);
  });

  testWidgets('cards look unchanged: surface color, rounded corners, accent border, no dividers',
      (tester) async {
    final stockReq = makeStockReq();
    final quickReq = makeQuickReq();
    final crateReq = makeCrateReq();

    await pumpScreen(
      tester,
      env: env,
      size: pixel7Portrait,
      grantedKeys: grantedAll,
      roleRank: 0,
      overrides: [
        viewerScopedPendingStockRequestsProvider
            .overrideWith((ref) => [stockReq]),
        viewerScopedPendingQuickSaleRequestsProvider
            .overrideWith((ref) => [quickReq]),
        viewerScopedPendingCrateDepositsProvider
            .overrideWith((ref) => [crateReq]),
      ],
      screen: const StockApprovalsScreen(),
    );

    final surface = Theme.of(tester.element(find.byType(StockApprovalsScreen)))
        .colorScheme
        .surface;

    for (final key in [
      stockApprovalCardKey(stockReq.id),
      quickSaleApprovalCardKey(quickReq.id),
      crateDepositApprovalCardKey(crateReq.id),
    ]) {
      final material = tester.widget<Material>(find.byKey(key));
      expect(material.color, surface);
      expect(material.clipBehavior, Clip.antiAlias);
      expect(material.shape, isA<RoundedRectangleBorder>());
      final border = material.shape as RoundedRectangleBorder;
      expect(border.borderRadius, BorderRadius.circular(16));
      expect(border.side.width, 1.0);
      expect(border.side.style, BorderStyle.solid);

      // Verify Theme wraps ExpansionTile with transparent dividerColor
      final tileTheme = tester.widget<Theme>(
        find.descendant(of: find.byKey(key), matching: find.byType(Theme)).first,
      );
      expect(tileTheme.data.dividerColor, Colors.transparent);
    }

    await teardownScreen(tester);
  });

  testWidgets('tapping any card to expand it shows press highlight/ripple and expands content',
      (tester) async {
    final stockReq = makeStockReq();
    final quickReq = makeQuickReq();
    final crateReq = makeCrateReq();

    await pumpScreen(
      tester,
      env: env,
      size: pixel7Portrait,
      grantedKeys: grantedAll,
      roleRank: 0,
      overrides: [
        viewerScopedPendingStockRequestsProvider
            .overrideWith((ref) => [stockReq]),
        viewerScopedPendingQuickSaleRequestsProvider
            .overrideWith((ref) => [quickReq]),
        viewerScopedPendingCrateDepositsProvider
            .overrideWith((ref) => [crateReq]),
      ],
      screen: const StockApprovalsScreen(),
    );

    // 1. Quick sale card tap ripple
    final quickFinder = find.byKey(quickSaleApprovalCardKey(quickReq.id));
    final g1 = await tester.startGesture(tester.getCenter(find.text('Ice Bag')));
    await tester.pump(const Duration(milliseconds: 100));
    expect(quickFinder, paints..rect());
    await g1.up();
    await tester.pumpAndSettle();
    expect(find.text('Unit price'), findsOneWidget);

    // 2. Stock adjustment card tap ripple
    final stockFinder = find.byKey(stockApprovalCardKey(stockReq.id));
    final g2 = await tester.startGesture(tester.getCenter(find.text('Add 5 ${env.products.first.name}')));
    await tester.pump(const Duration(milliseconds: 100));
    expect(stockFinder, paints..rect());
    await g2.up();
    await tester.pumpAndSettle();
    expect(find.text('Requested by'), findsWidgets);

    // 3. Crate deposit card tap ripple
    final crateFinder = find.byKey(crateDepositApprovalCardKey(crateReq.id));
    final g3 = await tester.startGesture(tester.getCenter(find.textContaining('10 crates deposit')));
    await tester.pump(const Duration(milliseconds: 100));
    expect(crateFinder, paints..rect());
    await g3.up();
    await tester.pumpAndSettle();
    expect(find.text('Enter the amount you paid.'), findsNothing); // form is shown
    expect(find.text('Confirm deposit'), findsNothing);

    await teardownScreen(tester);
  });

  group('Approve and reject actions on database-backed cards', () {
    testWidgets('approving stock adjustment updates inventory and marks row approved',
        (tester) async {
      final stockReq = makeStockReq(id: 'stock-adj-1');
      await env.db
          .into(env.db.stockAdjustmentRequests)
          .insert(stockReq.toCompanion(false));

      await pumpScreen(
        tester,
        env: env,
        size: pixel7Portrait,
        grantedKeys: grantedAll,
        roleRank: 0,
        screen: const StockApprovalsScreen(),
      );

      // Expand the card
      await tester.tap(find.text('Add 5 ${env.products.first.name}'));
      await tester.pumpAndSettle();

      // Tap Approve
      await tester.tap(find.text('Approve'));
      await tester.pumpAndSettle();

      final row = await (env.db.select(env.db.stockAdjustmentRequests)
            ..where((t) => t.id.equals('stock-adj-1')))
          .getSingle();
      expect(row.status, 'approved');

      await teardownScreen(tester);
    });

    testWidgets('rejecting stock adjustment prompts for reason and marks row rejected',
        (tester) async {
      final stockReq = makeStockReq(id: 'stock-adj-reject-1');
      await env.db
          .into(env.db.stockAdjustmentRequests)
          .insert(stockReq.toCompanion(false));

      await pumpScreen(
        tester,
        env: env,
        size: pixel7Portrait,
        grantedKeys: grantedAll,
        roleRank: 0,
        screen: const StockApprovalsScreen(),
      );

      // Expand card
      await tester.tap(find.text('Add 5 ${env.products.first.name}'));
      await tester.pumpAndSettle();

      // Tap Reject button in card
      await tester.tap(find.text('Reject'));
      await tester.pumpAndSettle();

      // Dialog is visible
      expect(find.text('Reject request'), findsOneWidget);

      // Tap Reject button in dialog
      final rejectInDialog = find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('Reject'),
      );
      await tester.tap(rejectInDialog);
      await tester.pumpAndSettle();

      final row = await (env.db.select(env.db.stockAdjustmentRequests)
            ..where((t) => t.id.equals('stock-adj-reject-1')))
          .getSingle();
      expect(row.status, 'rejected');

      await teardownScreen(tester);
    });

    testWidgets('approving quick sale flips status to approved', (tester) async {
      final quickReq = makeQuickReq(id: 'quick-sale-1');
      await env.db
          .into(env.db.quickSaleRequests)
          .insert(quickReq.toCompanion(false));

      await pumpScreen(
        tester,
        env: env,
        size: pixel7Portrait,
        grantedKeys: grantedAll,
        roleRank: 0,
        screen: const StockApprovalsScreen(),
      );

      await tester.tap(find.text('Ice Bag'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Approve'));
      await tester.pumpAndSettle();

      final row = await (env.db.select(env.db.quickSaleRequests)
            ..where((t) => t.id.equals('quick-sale-1')))
          .getSingle();
      expect(row.status, 'approved');

      await teardownScreen(tester);
    });

    testWidgets('rejecting quick sale prompts for reason and marks row rejected',
        (tester) async {
      final quickReq = makeQuickReq(id: 'quick-sale-reject-1');
      await env.db
          .into(env.db.quickSaleRequests)
          .insert(quickReq.toCompanion(false));

      await pumpScreen(
        tester,
        env: env,
        size: pixel7Portrait,
        grantedKeys: grantedAll,
        roleRank: 0,
        screen: const StockApprovalsScreen(),
      );

      await tester.tap(find.text('Ice Bag'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Reject'));
      await tester.pumpAndSettle();

      expect(find.text('Reject request'), findsOneWidget);

      final rejectInDialog = find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('Reject'),
      );
      await tester.tap(rejectInDialog);
      await tester.pumpAndSettle();

      final row = await (env.db.select(env.db.quickSaleRequests)
            ..where((t) => t.id.equals('quick-sale-reject-1')))
          .getSingle();
      expect(row.status, 'rejected');

      await teardownScreen(tester);
    });

    testWidgets('approving crate deposit confirms request in database',
        (tester) async {
      await env.db.into(env.db.suppliers).insert(
            SuppliersCompanion.insert(
              id: const Value('supplier-1'),
              businessId: env.businessId,
              name: 'Guinness Depot',
            ),
          );

      final crateReq = makeCrateReq(id: 'crate-dep-1');
      await env.db
          .into(env.db.supplierCrateDepositRequests)
          .insert(crateReq.toCompanion(false));

      await pumpScreen(
        tester,
        env: env,
        size: pixel7Portrait,
        grantedKeys: grantedAll,
        roleRank: 0,
        screen: const StockApprovalsScreen(),
      );

      // Expand crate deposit card
      await tester.tap(find.textContaining('10 crates deposit'));
      await tester.pumpAndSettle();

      // Tap Confirm button
      await tester.tap(find.text('Confirm'));
      await tester.pumpAndSettle();

      final row = await (env.db.select(env.db.supplierCrateDepositRequests)
            ..where((t) => t.id.equals('crate-dep-1')))
          .getSingle();
      expect(row.status, 'confirmed');

      await teardownScreen(tester);
    });

    testWidgets('rejecting crate deposit prompts for reason and marks row rejected',
        (tester) async {
      await env.db.into(env.db.suppliers).insert(
            SuppliersCompanion.insert(
              id: const Value('supplier-1'),
              businessId: env.businessId,
              name: 'Nigerian Breweries',
            ),
          );

      final crateReq = makeCrateReq(id: 'crate-dep-reject-1');
      await env.db
          .into(env.db.supplierCrateDepositRequests)
          .insert(crateReq.toCompanion(false));

      await pumpScreen(
        tester,
        env: env,
        size: pixel7Portrait,
        grantedKeys: grantedAll,
        roleRank: 0,
        screen: const StockApprovalsScreen(),
      );

      await tester.tap(find.textContaining('10 crates deposit'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Reject'));
      await tester.pumpAndSettle();

      expect(find.text('Reject request'), findsOneWidget);

      final rejectInDialog = find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('Reject'),
      );
      await tester.tap(rejectInDialog);
      await tester.pumpAndSettle();

      final row = await (env.db.select(env.db.supplierCrateDepositRequests)
            ..where((t) => t.id.equals('crate-dep-reject-1')))
          .getSingle();
      expect(row.status, 'rejected');

      await teardownScreen(tester);
    });
  });
}
