// crate_money_arrangement_section_test.dart
//
// #211 — the surface half of the Crate Money Arrangement (ADR 0023 rule 3).
//
// Three promises the issue makes about the picker, each of which is a rule
// somebody could quietly break later:
//
//   1. Only a crate business sees it — and "crate business" is decided by
//      `businessTracksCrates`, never by comparing `businesses.type` to a
//      string (the type carries non-canonical casing).
//   2. Only a money-permitted role may set it, and a denied role sees NOTHING
//      rather than a disabled control (hard rule #7).
//   3. Switching a brand on says, in shop-owner language, what it changes AND
//      that past figures stay exactly as they are (ADR 0021).
//
// The write itself is covered at the DAO boundary in
// crate_money_arrangement_test.dart; what is pinned here is what an owner is
// shown, and that backing out of the confirmation writes nothing.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/crates/crate_money_arrangement.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/permissions/gate.dart';
import 'package:reebaplus_pos/core/permissions/gate_registry.dart';
import 'package:reebaplus_pos/core/permissions/guarded.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/features/inventory/widgets/crate_money_arrangement_section.dart';

BusinessData _business({
  required String? type,
  bool tracksEmptyCrates = true,
}) => BusinessData(
  id: 'biz-1',
  name: 'Mama Ngozi Drinks',
  type: type,
  phone: null,
  email: null,
  logoUrl: null,
  timezone: 'Africa/Lagos',
  onboardingComplete: true,
  createdAt: DateTime.utc(2026, 1, 1),
  lastUpdatedAt: DateTime.utc(2026, 1, 1),
  ownerId: null,
  tracksEmptyCrates: tracksEmptyCrates,
  subscriptionStatus: 'active',
  subscriptionPlan: null,
  trialEndsAt: null,
  currentPeriodEnd: null,
);

final _manufacturer = ManufacturerData(
  id: 'mfr-star',
  businessId: 'biz-1',
  name: 'Star Lager',
  emptyCrateStock: 0,
  depositAmountKobo: 350000,
  crateMoneyArrangement: kCrateMoneyArrangementNone,
  isDeleted: false,
  createdAt: DateTime.utc(2026, 1, 1),
  lastUpdatedAt: DateTime.utc(2026, 1, 1),
);

GateContext _ctx({required bool canManage}) => GateContext(
  grantedKeys: canManage ? const {'settings.manage'} : const {'stock.add'},
  roleRank: canManage ? GateTier.ceo : GateTier.stockKeeper,
  isReady: true,
);

Future<void> _pumpSection(
  WidgetTester tester, {
  required BusinessData? business,
  required bool canManage,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        currentBusinessProvider.overrideWith((ref) => business),
        gateContextProvider.overrideWithValue(_ctx(canManage: canManage)),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: CrateMoneyArrangementSection(manufacturer: _manufacturer),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('who sees it', () {
    testWidgets('a bar that tracks crates, with money permission, sees all '
        'three arrangements', (tester) async {
      await _pumpSection(
        tester,
        business: _business(type: 'Bar'),
        canManage: true,
      );

      for (final option in CrateMoneyArrangement.values) {
        expect(
          find.text(option.label),
          findsOneWidget,
          reason: '${option.wire} must be offerable',
        );
      }
      expect(find.text('CRATE MONEY'), findsOneWidget);
    });

    testWidgets('business type is read through the crate gate, not a string '
        'compare — odd casing still counts', (tester) async {
      // `businesses.type` carries non-canonical casing in the wild; a bar
      // stored as 'BAR' is still a bar.
      await _pumpSection(
        tester,
        business: _business(type: 'BAR'),
        canManage: true,
      );
      expect(find.text(CrateMoneyArrangement.none.label), findsOneWidget);
    });

    testWidgets('a non-crate business sees nothing at all', (tester) async {
      await _pumpSection(
        tester,
        business: _business(type: 'Supermarket'),
        canManage: true,
      );
      expect(find.text('CRATE MONEY'), findsNothing);
      for (final option in CrateMoneyArrangement.values) {
        expect(find.text(option.label), findsNothing);
      }
    });

    testWidgets('a crate-eligible business that turned crate tracking OFF sees '
        'nothing', (tester) async {
      await _pumpSection(
        tester,
        business: _business(type: 'Bar', tracksEmptyCrates: false),
        canManage: true,
      );
      expect(find.text('CRATE MONEY'), findsNothing);
    });

    testWidgets('no business bound yet → nothing (fails closed)',
        (tester) async {
      await _pumpSection(tester, business: null, canManage: true);
      expect(find.text('CRATE MONEY'), findsNothing);
    });

    testWidgets('a role without money permission sees nothing — hidden, not '
        'disabled', (tester) async {
      await _pumpSection(
        tester,
        business: _business(type: 'Bar'),
        canManage: false,
      );
      expect(find.text('CRATE MONEY'), findsNothing);
      for (final option in CrateMoneyArrangement.values) {
        expect(find.text(option.label), findsNothing);
      }
    });

    test('the gate is the registry entry, not an inline rule', () {
      expect(
        Gates.crateMoneyArrangement.rule.evaluate(_ctx(canManage: true)),
        isTrue,
      );
      expect(
        Gates.crateMoneyArrangement.rule.evaluate(_ctx(canManage: false)),
        isFalse,
      );
      expect(Gates.all, contains(Gates.crateMoneyArrangement));
    });
  });

  group('what an owner is told', () {
    testWidgets('the section always carries the "your past figures do not '
        'change" promise', (tester) async {
      await _pumpSection(
        tester,
        business: _business(type: 'Bar'),
        canManage: true,
      );
      expect(find.text(kCrateMoneyHistoryNotice), findsOneWidget);
    });

    testWidgets('switching a brand on explains what changes, and repeats the '
        'history promise, before anything is written', (tester) async {
      await _pumpSection(
        tester,
        business: _business(type: 'Bar'),
        canManage: true,
      );

      await tester.tap(find.text(CrateMoneyArrangement.perDelivery.label));
      await tester.pumpAndSettle();

      expect(
        find.text(CrateMoneyArrangement.perDelivery.onSwitchOn),
        findsOneWidget,
        reason: 'the owner must be told what switching this on will do',
      );
      expect(
        find.text(kCrateMoneyHistoryNotice),
        findsWidgets,
        reason: 'and that days already closed are not rewritten',
      );
      expect(find.text('Yes, use this'), findsOneWidget);
      expect(find.text('Cancel'), findsOneWidget);
    });

    testWidgets('backing out of the confirmation leaves the brand where it was',
        (tester) async {
      await _pumpSection(
        tester,
        business: _business(type: 'Bar'),
        canManage: true,
      );

      await tester.tap(find.text(CrateMoneyArrangement.standingFloat.label));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      // Nothing was written (no databaseProvider override is supplied here, so
      // a write would have thrown), and the selection is still `none`.
      expect(find.text(CrateMoneyArrangement.standingFloat.onSwitchOn),
          findsNothing);
      expect(
        tester
            .widgetList<Icon>(find.byIcon(Icons.radio_button_checked))
            .length,
        1,
        reason: 'exactly one arrangement is selected, and it is still `none`',
      );
    });

    testWidgets('the copy is plain language, not engineer jargon',
        (tester) async {
      // A cheap but real guard: the words an owner reads must not be the words
      // the schema uses. If someone "simplifies" the copy back to the wire
      // values this fails.
      final copy = [
        for (final o in CrateMoneyArrangement.values) ...[
          o.label,
          o.summary,
          o.onSwitchOn,
        ],
        kCrateMoneyHistoryNotice,
      ].join(' ').toLowerCase();

      for (final jargon in [
        'per_delivery',
        'standing_float',
        'kobo',
        'manufacturer_id',
        'ledger',
        'null',
      ]) {
        expect(
          copy.contains(jargon),
          isFalse,
          reason: 'owner-facing copy must not say "$jargon"',
        );
      }
    });
  });
}
