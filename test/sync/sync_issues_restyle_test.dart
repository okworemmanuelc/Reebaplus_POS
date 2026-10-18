// Sync Issues restyle (#443, PRD #346 Wave 2 batch C). Restyle only: retry,
// discard and resolve keep the same calls, order, confirmations and wording.
//
// Covers: every control renders; Retry now / Discard / Retry (orphan) do what
// they did; the cancel-rejected-sale confirmation; a viewer without sync.view
// sees no controls; the 720 cap; no overflow at 360 @1.3, 390x844, 844x390 with
// insets, 800x1280 and 1280x800; the dev-only audit fields with the keyboard up.

import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/features/sync/screens/sync_issues_screen.dart';
import 'package:reebaplus_pos/features/sync/widgets/sync_parts.dart';

import '../helpers/screen_harness.dart';
import 'sync_issues_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ScreenTestEnvironment env;
  late SyncSample sample;

  setUp(() async {
    env = await setupScreenTestEnvironment(
      productCount: 0,
      businessName: 'Stallion Global',
    );
    sample = await seedSyncSample(env);
  });
  tearDown(() => env.dispose());

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 250));
    }
  }

  Future<void> pumpSync(
    WidgetTester tester, {
    Size size = const Size(390, 844),
    EdgeInsets? padding,
    TextScaler? textScaler,
    bool followView = false,
    Set<String> grants = const {'sync.view'},
    int roleRank = 0,
    bool deferred = false,
  }) async {
    await pumpScreen(
      tester,
      env: env,
      size: size,
      padding: padding,
      textScaler: textScaler,
      followView: followView,
      screen: const SyncIssuesScreen(),
      grantedKeys: grants,
      roleRank: roleRank,
      roleSlug: roleRank == 0 ? 'ceo' : 'cashier',
      roleName: roleRank == 0 ? 'CEO' : 'Cashier',
      bottomNavHeight: size.width >= 600 ? kBottomNavBodyHeight : 0,
      sharedPreferences: deferred ? deferredTablesPrefs(env) : const {},
      settle: false,
    );
    await settle(tester);
  }

  /// Waits (real time, bounded) for a write the tap started to land: the
  /// Drift work runs off the fake clock, so a fixed pump count can be too short
  /// on a loaded machine.
  Future<void> until(WidgetTester tester, Future<bool> Function() done) async {
    for (var i = 0; i < 100; i++) {
      if ((await tester.runAsync(done))!) break;
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
    }
    await settle(tester);
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 5));
    await disposeScreen(tester);
  }

  /// The list builds lazily, so reach the bottom by dragging, as a thumb would.
  Future<void> scrollToBottom(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.drag(find.byKey(SyncKeys.list), const Offset(0, -2000));
      await tester.pumpAndSettle();
    }
  }

  testWidgets('renders the top bar, sections, items and their controls', (
    tester,
  ) async {
    await pumpSync(tester, deferred: true, size: const Size(390, 4000));
    expect(find.byKey(SyncKeys.topBar), findsOneWidget);
    expect(find.byKey(SyncKeys.back), findsOneWidget);
    expect(find.text('Sync Issues'), findsOneWidget);
    for (final title in const [
      'Health',
      'Catching up',
      'Pending items',
      'Failed items',
      'Orphaned items',
      'Row-count audit',
    ]) {
      expect(find.text(title), findsOneWidget, reason: title);
    }
    // Health facts, every label and the failing probe text.
    for (final label in const [
      'Local businessId',
      'Cloud profile',
      'JWT claim',
      'Pending in queue',
      'Failed in queue',
      'Orphaned (auto-archived)',
    ]) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
    expect(find.text('Probe failed: no session'), findsOneWidget);
    expect(find.text('No active Supabase session'), findsOneWidget);
    // Catching up.
    expect(find.text('Some history is still catching up'), findsOneWidget);
    expect(find.text('order_items'), findsOneWidget);
    expect(find.byKey(SyncKeys.retryPull), findsOneWidget);
    // Items: action types, error texts and the pills they classify to.
    expect(
      find.byKey(SyncKeys.pendingItem(sample.pendingPlainId)),
      findsOneWidget,
    );
    expect(find.text('orders:upsert'), findsOneWidget);
    expect(find.text('Pending'), findsOneWidget);
    expect(find.text('RLS rejection'), findsOneWidget);
    expect(find.text('Network'), findsOneWidget);
    expect(find.text('FK violation'), findsOneWidget);
    expect(find.text('Duplicate key'), findsOneWidget);
    expect(find.text('Orphan'), findsNWidgets(2));
    expect(find.textContaining('row-level security policy'), findsOneWidget);
    expect(find.textContaining('inventory_product_id_fkey'), findsOneWidget);
    expect(find.text('insufficient_stock (P0001)'), findsOneWidget);
    expect(find.text('insufficient_privilege (42501)'), findsOneWidget);
    expect(find.text('Next try: ASAP'), findsNWidgets(3));
    expect(find.text('attempts: 3'), findsOneWidget);
    // Controls: Retry now + Discard on each queue row, Retry + Discard on each
    // orphan, Cancel this sale only on the rejected sale, Retry all.
    expect(find.text('Retry now'), findsNWidgets(5));
    expect(find.text('Discard'), findsNWidgets(7));
    expect(find.text('Cancel this sale'), findsOneWidget);
    expect(find.byKey(SyncKeys.retryAllOrphans), findsOneWidget);
    expect(find.byKey(SyncKeys.auditToggle), findsOneWidget);
    expect(tester.takeException(), isNull);
    await close(tester);
  });

  testWidgets('every action button is at least 48dp tall', (tester) async {
    await pumpSync(tester, size: const Size(390, 4000));
    for (final key in [
      SyncKeys.retryItem(sample.pendingPlainId),
      SyncKeys.discardItem(sample.pendingPlainId),
      SyncKeys.retryItem(sample.orphanPlainId),
      SyncKeys.retryAllOrphans,
      SyncKeys.auditToggle,
      SyncKeys.back,
    ]) {
      final size = tester.getSize(find.byKey(key));
      expect(
        size.height,
        greaterThanOrEqualTo(kMinInteractiveDimension),
        reason: '$key is ${size.height} tall',
      );
    }
    await close(tester);
  });

  testWidgets('Retry now clears the backoff and keeps the row pending', (
    tester,
  ) async {
    await tester.runAsync(() async {
      await (env.db.update(
        env.db.syncQueue,
      )..where((t) => t.id.equals(sample.pendingRlsId))).write(
        SyncQueueCompanion(nextAttemptAt: Value(DateTime.utc(2026, 3, 15))),
      );
    });
    await pumpSync(tester, size: const Size(390, 4000));
    await tester.tap(find.byKey(SyncKeys.retryItem(sample.pendingRlsId)));
    await until(
      tester,
      () async =>
          (await (env.db.select(
                env.db.syncQueue,
              )..where((t) => t.id.equals(sample.pendingRlsId))).getSingle())
              .nextAttemptAt ==
          null,
    );
    final row = await tester.runAsync(
      () => (env.db.select(
        env.db.syncQueue,
      )..where((t) => t.id.equals(sample.pendingRlsId))).getSingle(),
    );
    expect(row!.nextAttemptAt, isNull);
    expect(row.status, 'pending');
    expect(tester.takeException(), isNull);
    await close(tester);
  });

  testWidgets('Discard drops the queue row', (tester) async {
    await pumpSync(tester, size: const Size(390, 4000));
    await tester.tap(find.byKey(SyncKeys.discardItem(sample.pendingPlainId)));
    await until(
      tester,
      () async => (await (env.db.select(
        env.db.syncQueue,
      )..where((t) => t.id.equals(sample.pendingPlainId))).get()).isEmpty,
    );
    final rows = await tester.runAsync(
      () => (env.db.select(
        env.db.syncQueue,
      )..where((t) => t.id.equals(sample.pendingPlainId))).get(),
    );
    expect(rows, isEmpty);
    expect(
      find.byKey(SyncKeys.pendingItem(sample.pendingPlainId)),
      findsNothing,
    );
    await close(tester);
  });

  testWidgets('orphan Retry re-enqueues it; orphan Discard removes it', (
    tester,
  ) async {
    await pumpSync(tester, size: const Size(390, 4000));
    await tester.tap(find.byKey(SyncKeys.retryItem(sample.orphanPlainId)));
    await until(
      tester,
      () async => (await env.db.select(env.db.syncQueueOrphans).get()).every(
        (o) => o.id != sample.orphanPlainId,
      ),
    );
    final orphans = await tester.runAsync(
      () => env.db.select(env.db.syncQueueOrphans).get(),
    );
    expect(orphans!.map((o) => o.id), isNot(contains(sample.orphanPlainId)));
    expect(find.text('Re-enqueued.'), findsOneWidget);

    await tester.tap(find.byKey(SyncKeys.discardItem(sample.orphanSaleId)));
    await until(
      tester,
      () async => (await env.db.select(env.db.syncQueueOrphans).get()).isEmpty,
    );
    final left = await tester.runAsync(
      () => env.db.select(env.db.syncQueueOrphans).get(),
    );
    expect(left, isEmpty);
    expect(find.text('No orphaned items.'), findsOneWidget);
    await close(tester);
  });

  testWidgets('Cancel this sale asks first and Keep changes nothing', (
    tester,
  ) async {
    await pumpSync(tester, size: const Size(390, 4000));
    await tester.tap(find.text('Cancel this sale'));
    await tester.pumpAndSettle();
    expect(find.text('Cancel this rejected sale?'), findsOneWidget);
    expect(find.text('Keep'), findsOneWidget);
    expect(find.text('Cancel the sale'), findsOneWidget);
    await tester.tap(find.text('Keep'));
    await tester.pumpAndSettle();
    expect(find.text('Cancel this rejected sale?'), findsNothing);
    final orphans = await tester.runAsync(
      () => env.db.select(env.db.syncQueueOrphans).get(),
    );
    expect(orphans, hasLength(2));
    await close(tester);
  });

  testWidgets('the audit card opens; the dev-only fields show in debug', (
    tester,
  ) async {
    await pumpSync(tester, size: const Size(390, 4000));
    await tester.tap(find.byKey(SyncKeys.auditToggle));
    await tester.pumpAndSettle();
    expect(find.byKey(SyncKeys.runAudit), findsOneWidget);
    expect(find.text('Run audit'), findsOneWidget);
    expect(find.text('Project URL (optional)'), findsOneWidget);
    expect(find.text('Service role key (optional, dev only)'), findsOneWidget);
    final key = tester.widget<EditableText>(
      find.descendant(
        of: find.byKey(SyncKeys.serviceKey),
        matching: find.byType(EditableText),
      ),
    );
    expect(key.obscureText, isTrue, reason: 'the service key stays hidden');
    await close(tester);
  });

  testWidgets('a viewer without sync.view sees no controls', (tester) async {
    await pumpSync(tester, grants: const {}, roleRank: 2);
    expect(find.byKey(SyncKeys.topBar), findsOneWidget);
    expect(find.byKey(SyncKeys.back), findsOneWidget);
    expect(find.text('You don\'t have access to Sync Issues.'), findsOneWidget);
    expect(find.byKey(SyncKeys.list), findsNothing);
    expect(find.text('Retry now'), findsNothing);
    expect(find.text('Discard'), findsNothing);
    expect(find.byKey(SyncKeys.retryAllOrphans), findsNothing);
    expect(find.byKey(SyncKeys.auditToggle), findsNothing);
    await close(tester);
  });

  testWidgets('a role granted sync.view sees the screen', (tester) async {
    await pumpSync(tester, grants: const {'sync.view'}, roleRank: 2);
    expect(find.byKey(SyncKeys.list), findsOneWidget);
    expect(find.text('Retry now'), findsWidgets);
    await close(tester);
  });

  testWidgets('the list caps at 720dp on a wide screen', (tester) async {
    await pumpSync(tester, size: const Size(1280, 800));
    final width = tester.getSize(find.byKey(SyncKeys.healthCard)).width;
    expect(width, lessThanOrEqualTo(720));
    expect(width, greaterThan(600));
    await close(tester);
  });

  final sizes = <(String, Size, EdgeInsets, double)>[
    (
      '360@1.3',
      const Size(360, 640),
      const EdgeInsets.only(top: 24, bottom: 48),
      1.3,
    ),
    (
      '390x844',
      const Size(390, 844),
      const EdgeInsets.only(top: 24, bottom: 24),
      1.0,
    ),
    (
      '844x390',
      const Size(844, 390),
      const EdgeInsets.only(top: 24, right: 48),
      1.0,
    ),
    ('800x1280', const Size(800, 1280), EdgeInsets.zero, 1.0),
    ('1280x800', const Size(1280, 800), EdgeInsets.zero, 1.0),
  ];
  for (final (name, size, pad, scale) in sizes) {
    testWidgets('Sync Issues has no overflow at $name', (tester) async {
      await pumpSync(
        tester,
        size: size,
        padding: pad,
        textScaler: TextScaler.linear(scale),
        deferred: true,
      );
      expectNoOverflow(tester, reason: 'overflowed at $name');
      // Scroll to the bottom with the audit open: every section lays out.
      await scrollToBottom(tester);
      await tester.tap(find.byKey(SyncKeys.auditToggle));
      await tester.pumpAndSettle();
      expectNoOverflow(tester, reason: 'audit open overflowed at $name');
      await close(tester);
    });

    testWidgets('no access state has no overflow at $name', (tester) async {
      await pumpSync(
        tester,
        size: size,
        padding: pad,
        textScaler: TextScaler.linear(scale),
        grants: const {},
        roleRank: 2,
      );
      expectNoOverflow(tester, reason: 'no-access overflowed at $name');
      await close(tester);
    });
  }

  for (final (name, size, keyboard) in const [
    ('390x844', Size(390, 844), 340.0),
    ('360x640', Size(360, 640), 280.0),
  ]) {
    testWidgets('the audit fields survive the keyboard $name', (tester) async {
      await pumpSync(
        tester,
        size: size,
        followView: true,
        textScaler: const TextScaler.linear(1.15),
      );
      await scrollToBottom(tester);
      await tester.tap(find.byKey(SyncKeys.auditToggle));
      await tester.pumpAndSettle();
      await scrollToBottom(tester);
      await tester.tap(find.byKey(SyncKeys.serviceKey));
      tester.view.viewInsets = FakeViewPadding(bottom: keyboard);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.descendant(
          of: find.byKey(SyncKeys.serviceKey),
          matching: find.byType(EditableText),
        ),
        'secret',
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      tester.view.resetViewInsets();
      await close(tester);
    });
  }
}
