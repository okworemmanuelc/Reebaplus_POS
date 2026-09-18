import 'package:drift/drift.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/features/inventory/screens/supplier_detail_screen.dart';
import 'package:reebaplus_pos/shared/widgets/app_dropdown.dart';
import 'package:reebaplus_pos/shared/widgets/tabbed_sliver_scaffold.dart';

import '../helpers/screen_harness.dart';
import '../helpers/viewports.dart';

/// Issue #246 / PRD #239 — the Supplier Detail screen must hold its ledger at
/// every supported viewport.
///
/// The screen has two shapes. A business that tracks empty crates gets two tabs
/// (Ledger, Empty Crates) under a pinned tab bar; every other business gets the
/// ledger alone under an "Activity Ledger" heading. Before the fix both shapes
/// were a `NestedScrollView` whose body was a `Column` with the Total In / Total
/// Out strip above an `Expanded` list — the fixed band above a flexible
/// remainder that PRD #239 names. The owner's device walk measured the tabbed
/// shape overflowing by 1.2px; the harness sweep had missed it.
///
/// Acceptance criteria covered here:
///   1. Built on the shared [TabbedSliverScaffold] from #243.
///   2. No tab body holds a fixed-height band above a flexible remainder.
///   3. Pumped at the smallest supported portrait phone (320x568), the shortest
///      supported landscape phone (800x360), a landscape phone (915x412) and a
///      comfortable portrait control (412x915).
///   4. Every test asserts **both** no overflow *and* one complete ledger row
///      laid out and hit-testable.
///   5. Both an empty and a populated data state, in both screen shapes.
///   6. Tab swiping and per-tab scroll retention survive the restructure.
///   7. Tap targets stay at or above the minimum interactive dimension.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ScreenTestEnvironment env;
  late String supplierId;
  late BusinessData business;

  const supplierGrants = {'suppliers.manage', 'sales.make'};

  /// The scroll surface that holds the ledger. In the tabbed shape
  /// [TabSliverBody] keys its scroll view with the tab's storage key; the
  /// single-ledger shape uses the same key on its own scroll view, so one
  /// finder addresses both.
  Finder ledgerSurface() =>
      find.byKey(const PageStorageKey<String>(kSupplierLedgerStorageKey));

  /// What a thumb actually drags: the whole screen. In the tabbed shape that is
  /// the `NestedScrollView`, which scrolls the header away before handing the
  /// gesture to the tab. Dragging the Ledger tab's own view is not an option on
  /// a short phone: a fully filled-in supplier header is taller than the whole
  /// screen there, so at rest the tab bar and the ledger start below the fold.
  Finder screenSurface() {
    final nested = find.byType(NestedScrollView);
    return nested.evaluate().isNotEmpty ? nested : ledgerSurface();
  }

  /// Scrolls the screen a little at a time, asserting no overflow after each
  /// step. The owner's device walk saw the 1.2px band only once the header had
  /// scrolled part of the way, not at rest, so checking the two ends is not
  /// enough.
  Future<void> scrollInStepsWithoutOverflow(
    WidgetTester tester,
    String name,
  ) async {
    for (var step = 1; step <= 8; step++) {
      await tester.drag(screenSurface(), const Offset(0, -40));
      await tester.pump(const Duration(milliseconds: 16));
      expectNoOverflow(
        tester,
        reason: 'Supplier Detail overflowed ${step * 40}dp into a scroll at $name',
      );
    }
    await tester.pumpAndSettle();
  }

  /// Scrolls the header away so the pinned tab bar is on screen.
  Future<void> scrollHeaderAway(WidgetTester tester) async {
    await tester.drag(screenSurface(), const Offset(0, -600));
    await tester.pumpAndSettle();
  }

  /// Asserts [target] sits wholly inside [surface] — scrolled into view and
  /// readable, not merely built. A finder count alone passes a message that
  /// is clipped to a sliver at the fold.
  void expectFullyInside(
    WidgetTester tester,
    Finder target,
    Finder surface, {
    required String reason,
  }) {
    final inner = tester.getRect(target);
    final outer = tester.getRect(surface);
    expect(
      inner.top >= outer.top - 0.5 &&
          inner.bottom <= outer.bottom + 0.5 &&
          inner.left >= outer.left - 0.5 &&
          inner.right <= outer.right + 0.5,
      isTrue,
      reason: '$reason (target $inner, surface $outer)',
    );
  }

  Finder ledgerRows() => find.byWidgetPredicate(
        (w) =>
            w.key is ValueKey<String> &&
            (w.key! as ValueKey<String>)
                .value
                .startsWith(kSupplierLedgerRowKeyPrefix),
        description: 'supplier ledger row',
      );

  /// Drift's stream plumbing resolves in real async time; the screen paints its
  /// ledger only after those settle. `pumpAndSettle` alone spins forever on the
  /// loading spinner, so step the clock by hand as the Expenses suite does.
  Future<void> settleScreen(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 250));
    }
  }

  /// Unmounts the screen and closes the database **inside `runAsync`**. Supplier
  /// Detail reads everything through long-lived Drift streams, and a `tearDown`
  /// close runs outside the tester's fake-async zone and blocks until the
  /// 10-minute test timeout (see the Expenses suite, #256).
  Future<void> teardownScreen(WidgetTester tester) async {
    await disposeScreen(tester);
    await tester.runAsync(() => env.dispose());
  }

  /// Seeds a supplier with every optional header field filled, which makes the
  /// scroll-away header as tall as it gets — the honest worst case.
  Future<void> seedSupplier({required int entryCount}) async {
    final db = env.db;
    supplierId = await db.catalogDao.insertSupplier(
      SuppliersCompanion.insert(
        businessId: env.businessId,
        name: 'Nigerian Breweries Depot',
        phone: const Value('08012345678'),
        email: const Value('orders@depot.example'),
        address: const Value('12 Industrial Avenue, Ikeja, Lagos'),
        bankName: const Value('First Bank'),
        bankAccountNumber: const Value('0123456789'),
        bankAccountName: const Value('NB Depot Ltd'),
        notes: const Value('Delivers Tuesdays and Fridays'),
      ),
    );

    final now = DateTime.now();
    for (var i = 1; i <= entryCount; i++) {
      final isInvoice = i.isOdd;
      await db.into(db.supplierLedgerEntries).insert(
            SupplierLedgerEntriesCompanion.insert(
              id: Value(UuidV7.generate()),
              businessId: env.businessId,
              supplierId: supplierId,
              storeId: Value(env.storeId),
              type: isInvoice ? 'debit' : 'credit',
              amountKobo: 150000 * i,
              signedAmountKobo: isInvoice ? -150000 * i : 150000 * i,
              referenceType: isInvoice ? 'invoice' : 'payment_cash',
              // Inside "This Month", the screen's default period.
              activityDate: now.subtract(Duration(seconds: i)),
            ),
          );
    }

    business = await (db.select(db.businesses)
          ..where((t) => t.id.equals(env.businessId)))
        .getSingle();
  }

  Future<void> pumpSupplierDetail(WidgetTester tester, Size size) async {
    await pumpScreen(
      tester,
      env: env,
      size: size,
      screen: SupplierDetailScreen(supplierId: supplierId),
      grantedKeys: supplierGrants,
      overrides: [currentBusinessProvider.overrideWith((ref) => business)],
      settle: false,
    );
    await settleScreen(tester);
  }

  const viewports = <String, Size>{
    'phoneSe1Portrait (320x568, smallest supported portrait)': phoneSe1Portrait,
    'androidCompactLandscape (800x360, shortest supported landscape)':
        androidCompactLandscape,
    'pixel7Landscape (915x412, landscape phone)': pixel7Landscape,
    'pixel7Portrait (412x915, comfortable control)': pixel7Portrait,
  };

  /// `Bar` is crate-eligible and `tracksEmptyCrates` defaults on, so it gets
  /// the tabbed shape; a business with no type gets the single ledger.
  const shapes = <String, String?>{
    'tabbed (tracks crates)': 'Bar',
    'single ledger (no crates)': null,
  };

  shapes.forEach((shape, businessType) {
    group('Supplier Detail holds its ledger — $shape, populated', () {
      setUp(() async {
        env = await setupScreenTestEnvironment(businessType: businessType);
        await seedSupplier(entryCount: 12);
      });

      viewports.forEach((name, size) {
        testWidgets('$name shows a complete ledger row without overflowing',
            (tester) async {
          await pumpSupplierDetail(tester, size);

          expectNoOverflow(tester, reason: 'Supplier Detail overflowed at $name');
          await scrollInStepsWithoutOverflow(tester, name);
          await expectContentRowVisible(
            tester,
            ledgerRows(),
            scrollable: screenSurface(),
            reason: 'Supplier Detail showed no complete ledger row at $name',
          );
          expectNoOverflow(tester, reason: 'Scrolling overflowed at $name');

          await teardownScreen(tester);
        });
      });
    });

    group('Supplier Detail holds its ledger — $shape, empty', () {
      setUp(() async {
        env = await setupScreenTestEnvironment(businessType: businessType);
        await seedSupplier(entryCount: 0);
      });

      viewports.forEach((name, size) {
        testWidgets('$name renders the empty ledger without overflowing',
            (tester) async {
          await pumpSupplierDetail(tester, size);

          expectNoOverflow(
            tester,
            reason: 'Supplier Detail overflowed empty at $name',
          );

          // The message may sit below the scroll-away header on a short
          // viewport; one scroll must reach it.
          await tester.drag(screenSurface(), const Offset(0, -400));
          await tester.pump(const Duration(milliseconds: 250));

          final emptyMessage = find.text('No activity in this period');
          expect(
            emptyMessage,
            findsOneWidget,
            reason: 'An empty ledger must still show its message at $name',
          );
          expectFullyInside(
            tester,
            emptyMessage,
            ledgerSurface(),
            reason: 'One scroll must bring the whole empty-ledger message '
                'into view at $name',
          );
          expectNoOverflow(tester, reason: 'Scrolling overflowed at $name');

          await teardownScreen(tester);
        });
      });
    });
  });

  group('Supplier Detail keeps the behaviour the restructure could have cost',
      () {
    setUp(() async {
      env = await setupScreenTestEnvironment(businessType: 'Bar');
      await seedSupplier(entryCount: 30);
    });

    testWidgets('each tab remembers its scroll position across tab switches',
        (tester) async {
      await pumpSupplierDetail(tester, pixel7Portrait);

      ScrollPosition ledgerPosition() => tester
          .state<ScrollableState>(
            find
                .descendant(
                  of: ledgerSurface(),
                  matching: find.byType(Scrollable),
                )
                .first,
          )
          .position;

      await tester.drag(ledgerSurface(), const Offset(0, -800));
      await tester.pumpAndSettle();
      final scrolledTo = ledgerPosition().pixels;
      expect(scrolledTo, greaterThan(0), reason: 'The Ledger tab must scroll');

      await tester.tap(find.widgetWithText(Tab, 'Empty Crates'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(Tab, 'Ledger'));
      await tester.pumpAndSettle();

      expect(
        ledgerPosition().pixels,
        closeTo(scrolledTo, 1.0),
        reason: "Switching away and back must not lose the reader's place",
      );

      await teardownScreen(tester);
    });

    testWidgets('swiping sideways still moves between tabs', (tester) async {
      await pumpSupplierDetail(tester, pixel7Portrait);

      final pager = tester.state<ScrollableState>(
        find
            .descendant(
              of: find.byType(TabBarView),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      final onePage = pager.position.viewportDimension;

      final swipe = await tester.startGesture(tester.getCenter(ledgerSurface()));
      for (var step = 0; step < 8; step++) {
        await swipe.moveBy(Offset(-onePage * 0.08, 0));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await swipe.up();
      await tester.pumpAndSettle();

      expect(
        pager.position.pixels,
        closeTo(onePage, 1.0),
        reason: 'A sideways swipe must snap the pager to the Empty Crates tab',
      );

      await teardownScreen(tester);
    });

    for (final entry in {
      'phoneSe1Portrait': phoneSe1Portrait,
      'androidCompactLandscape': androidCompactLandscape,
    }.entries) {
      testWidgets(
          'the Empty Crates tab holds its content at ${entry.key} '
          'without overflowing', (tester) async {
        await pumpSupplierDetail(tester, entry.value);

        await scrollHeaderAway(tester);
        await tester.tap(find.widgetWithText(Tab, 'Empty Crates'));
        await tester.pumpAndSettle();
        expectNoOverflow(tester, reason: 'Empty Crates overflowed at ${entry.key}');

        final cratesSurface =
            find.byKey(const PageStorageKey<String>(kSupplierCratesStorageKey));
        expect(
          cratesSurface,
          findsOneWidget,
          reason: 'The Empty Crates tab must be its own scroll view',
        );
        await tester.drag(cratesSurface, const Offset(0, -600));
        await tester.pumpAndSettle();

        final byManufacturer = find.text('By manufacturer');
        expect(
          byManufacturer,
          findsOneWidget,
          reason: 'One scroll must reach the per-manufacturer list',
        );
        expectFullyInside(
          tester,
          byManufacturer,
          cratesSurface,
          reason: 'One scroll must bring the whole per-manufacturer heading '
              'into view at ${entry.key}',
        );
        expectNoOverflow(
          tester,
          reason: 'Scrolling Empty Crates overflowed at ${entry.key}',
        );

        await teardownScreen(tester);
      });

      testWidgets('tap targets keep their full height at ${entry.key}',
          (tester) async {
        await pumpSupplierDetail(tester, entry.value);

        // Measured by layout, not hit-testing, so it holds even when the
        // scroll-away header has left the screen.
        final periodSelector = find
            .byType(AppDropdown<String>, skipOffstage: false)
            .first;
        expect(
          tester.getSize(periodSelector).height,
          greaterThanOrEqualTo(kMinInteractiveDimension),
          reason: 'The period selector must not shrink below a full tap target',
        );

        await scrollHeaderAway(tester);
        for (final label in ['Ledger', 'Empty Crates']) {
          // The tap target is the InkWell TabBar wraps each tab in, which spans
          // the bar's full height; the Tab label inside it sits above the
          // indicator line and is 2dp shorter by design.
          final tapTarget = find
              .ancestor(
                of: find.widgetWithText(Tab, label),
                matching: find.byType(InkWell),
              )
              .first;
          expect(
            tester.getSize(tapTarget).height,
            greaterThanOrEqualTo(kMinInteractiveDimension),
            reason: 'The $label tab must keep a full tap target',
          );
        }

        await teardownScreen(tester);
      });
    }
  });
}
