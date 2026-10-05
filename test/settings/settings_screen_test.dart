// settings_screen_test.dart
//
// #369 — CEO Settings restyled to the redesign mockup
// (docs/redesign/mockups/phone-ceo-settings-light.png). Pins what the restyle
// must keep (every row, its group, its destination, the search filter, the
// Danger Zone gate and search rule, the no-access guard) and the layout rules
// (no overflow at text scale 1.3 on 360dp, 48dp tap targets, the header,
// search box and rows inside the safe area of a sideways phone with real
// insets, the list scrolling to the Danger Zone, the 720dp content cap).

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/settings/delete_business_screen.dart';
import 'package:reebaplus_pos/core/settings/settings_screen.dart';
import 'package:reebaplus_pos/core/settings/settings_widgets.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/features/subscription/subscription_access.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/redesign.dart';

import '../helpers/screen_harness.dart';

const _allGrants = {'settings.manage', 'settings.delete_business'};

/// Every row, in order, with its group (the brief's grouping).
const _rows = <(String group, String title, String subtitle, IconTileTone)>[
  ('Business', 'Business Info', 'Name, type, and currency', IconTileTone.info),
  (
    'Business',
    'Subscription',
    'Plan, status, and renewal',
    IconTileTone.warning,
  ),
  ('Business', 'Stores', 'Your store locations', IconTileTone.green),
  (
    'Access & Security',
    'Security',
    'Auto-lock and biometric login',
    IconTileTone.danger,
  ),
  (
    'Access & Security',
    'Roles & Permissions',
    'What each role can do',
    IconTileTone.info,
  ),
  (
    'Access & Security',
    'Activity Logs access',
    'Which roles can view activity logs',
    IconTileTone.neutral,
  ),
  (
    'Access & Security',
    'Sync Issues access',
    'Which roles can open Sync Issues',
    IconTileTone.neutral,
  ),
  (
    'Devices & Appearance',
    'Receipt printer',
    'Paper size for each printer (58mm or 80mm)',
    IconTileTone.neutral,
  ),
  (
    'Devices & Appearance',
    'Appearance',
    'Business colour (applies to all devices)',
    IconTileTone.info,
  ),
];

const _groups = ['Business', 'Access & Security', 'Devices & Appearance'];

Finder _row(String title) =>
    find.ancestor(of: find.text(title), matching: find.byType(SettingsRow));

Finder _header(String title) =>
    find.ancestor(of: find.text(title), matching: find.byType(SectionHeader));

void main() {
  late ScreenTestEnvironment env;

  setUp(() async {
    env = await setupScreenTestEnvironment(productCount: 0);
  });

  tearDown(() => env.dispose());

  Future<BuildContext> pump(
    WidgetTester tester, {
    Size size = const Size(390, 844),
    EdgeInsets padding = kRealisticPhoneInsets,
    Set<String> grants = _allGrants,
    SubscriptionAccess access = SubscriptionAccess.active,
    TextScaler? textScaler,
    double bottomNavHeight = 0,
    Widget screen = const SettingsScreen(),
  }) async {
    final ctx = await pumpScreen(
      tester,
      env: env,
      size: size,
      padding: padding,
      screen: screen,
      bottomNavHeight: bottomNavHeight,
      grantedKeys: grants,
      textScaler: textScaler,
      theme: AppTheme.light(),
      overrides: [
        currentBusinessNameProvider.overrideWithValue('Stallion Global'),
        currentBusinessSubscriptionProvider.overrideWithValue(access),
        currentBusinessLogoPathProvider.overrideWith((ref) async => null),
      ],
      settle: false,
    );
    for (var i = 0; i < 4; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 300));
    }
    return ctx;
  }

  Future<void> search(WidgetTester tester, String text) async {
    await tester.enterText(find.byKey(const Key('settings-search')), text);
    await tester.pump();
  }

  group('content kept', () {
    testWidgets('every row in its group, in order, with its fixed tint', (
      tester,
    ) async {
      await pump(tester, size: const Size(390, 3000), padding: EdgeInsets.zero);

      final rows = tester.widgetList<SettingsRow>(find.byType(SettingsRow));
      expect(
        [for (final r in rows) r.title],
        [..._rows.map((r) => r.$2), 'Delete Business'],
      );
      for (final r in _rows) {
        final row = tester.widget<SettingsRow>(_row(r.$2));
        expect(row.subtitle, r.$3, reason: r.$2);
        expect(row.tone, r.$4, reason: r.$2);
      }

      // Group headers sit above their rows and below the previous group.
      for (final r in _rows) {
        final headerY = tester.getTopLeft(_header(r.$1)).dy;
        expect(tester.getTopLeft(_row(r.$2)).dy, greaterThan(headerY));
      }
      for (var i = 1; i < _groups.length; i++) {
        expect(
          tester.getTopLeft(_header(_groups[i])).dy,
          greaterThan(tester.getTopLeft(_header(_groups[i - 1])).dy),
        );
      }
      expect(_header('Danger zone'), findsOneWidget);
      expect(
        tester.widget<SettingsRow>(_row('Delete Business')).tone,
        IconTileTone.danger,
      );
      await disposeScreen(tester);
    });

    testWidgets('header: title, active store, bell; profile card + tags', (
      tester,
    ) async {
      await pump(tester);
      final header = tester.widget<ScreenHeader>(find.byType(ScreenHeader));
      expect(header.title, 'CEO Settings');
      expect(header.subtitle, 'Main Store');
      expect(find.byType(HeaderBell), findsOneWidget);

      final card = tester.widget<ProfileCard>(find.byType(ProfileCard));
      expect(card.title, 'Stallion Global');
      expect(card.subtitle, 'Test Admin');
      expect(card.onTap, isNull, reason: 'display only');
      expect(card.tags, [
        (label: 'PRO', tone: TagPillTone.solidInfo),
        (label: 'CEO', tone: TagPillTone.info),
      ]);
      await disposeScreen(tester);
    });

    testWidgets('PRO tag follows the drawer rule (badgeLabel)', (tester) async {
      await pump(tester, access: SubscriptionAccess.trialActive);
      expect(tester.widget<ProfileCard>(find.byType(ProfileCard)).tags, [
        (label: 'FREE TRIAL', tone: TagPillTone.warning),
        (label: 'CEO', tone: TagPillTone.info),
      ]);
      await disposeScreen(tester);

      await pump(tester, access: SubscriptionAccess.grace);
      expect(tester.widget<ProfileCard>(find.byType(ProfileCard)).tags, [
        (label: 'CEO', tone: TagPillTone.info),
      ]);
      await disposeScreen(tester);
    });

    testWidgets('no back arrow at a root; one when pushed, and it pops', (
      tester,
    ) async {
      await pump(tester);
      expect(find.byKey(const Key('settings-back')), findsNothing);
      await disposeScreen(tester);

      await pump(
        tester,
        screen: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const SettingsScreen()),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('settings-back')), findsOneWidget);
      await tester.tap(find.byKey(const Key('settings-back')));
      await tester.pumpAndSettle();
      expect(find.byType(SettingsScreen), findsNothing);
      await disposeScreen(tester);
    });

    testWidgets('without settings.manage: the no-access guard only', (
      tester,
    ) async {
      await pump(tester, grants: const {});
      expect(find.byType(SettingsNoAccess), findsOneWidget);
      expect(find.byType(SettingsRow), findsNothing);
      await disposeScreen(tester);
    });

    testWidgets('Danger Zone hidden without settings.delete_business', (
      tester,
    ) async {
      await pump(
        tester,
        size: const Size(390, 3000),
        padding: EdgeInsets.zero,
        grants: const {'settings.manage'},
      );
      expect(find.text('Delete Business'), findsNothing);
      expect(find.text('Danger zone'), findsNothing);
      expect(find.byType(SettingsRow), findsNWidgets(_rows.length));
      await disposeScreen(tester);
    });

    testWidgets('Delete Business opens its confirmation screen', (
      tester,
    ) async {
      await pump(tester, size: const Size(390, 3000), padding: EdgeInsets.zero);
      await tester.tap(find.byKey(const Key('settings-delete-business')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(DeleteBusinessScreen), findsOneWidget);
      // The destination's own providers are not this test's concern.
      tester.takeException();
      await disposeScreen(tester);
    });
  });

  group('search', () {
    testWidgets('filters rows and hides headers of empty groups', (
      tester,
    ) async {
      await pump(tester, size: const Size(390, 3000), padding: EdgeInsets.zero);

      await search(tester, 'stores');
      expect(
        [
          for (final r in tester.widgetList<SettingsRow>(
            find.byType(SettingsRow),
          ))
            r.title,
        ],
        ['Stores'],
      );
      expect(_header('Business'), findsOneWidget);
      expect(find.text('Access & Security'), findsNothing);
      expect(find.text('Devices & Appearance'), findsNothing);
      expect(find.text('Danger zone'), findsNothing);

      // Subtitle match, across a group.
      await search(tester, 'roles');
      expect(
        [
          for (final r in tester.widgetList<SettingsRow>(
            find.byType(SettingsRow),
          ))
            r.title,
        ],
        ['Roles & Permissions', 'Activity Logs access', 'Sync Issues access'],
      );
      expect(find.text('Business'), findsNothing);
      expect(_header('Access & Security'), findsOneWidget);

      // The clear button restores everything.
      await tester.tap(find.byTooltip('Clear'));
      await tester.pump();
      expect(find.byType(SettingsRow), findsNWidgets(_rows.length + 1));
      expect(find.byTooltip('Clear'), findsNothing);
      await disposeScreen(tester);
    });

    testWidgets('no match: the empty message; Danger Zone keyword rule', (
      tester,
    ) async {
      await pump(tester, size: const Size(390, 3000), padding: EdgeInsets.zero);

      await search(tester, 'zzz');
      expect(find.text('No settings match "zzz".'), findsOneWidget);
      expect(find.byType(SettingsRow), findsNothing);
      expect(find.byType(SectionHeader), findsNothing);

      await search(tester, 'delete');
      expect(find.text('No settings match "delete".'), findsOneWidget);
      expect(find.text('Delete Business'), findsOneWidget);
      expect(_header('Danger zone'), findsOneWidget);
      await disposeScreen(tester);
    });
  });

  group('layout', () {
    testWidgets('360dp at text scale 1.3: no overflow, targets >= 48dp', (
      tester,
    ) async {
      await pump(
        tester,
        size: const Size(360, 3000),
        textScaler: const TextScaler.linear(1.3),
      );
      expect(tester.takeException(), isNull);
      await search(tester, 'e');
      expect(tester.takeException(), isNull);
      _expectTapTargets(tester);
      final field = tester.getSize(find.byKey(const Key('settings-search')));
      expect(field.height, greaterThanOrEqualTo(kMinInteractiveDimension));
      await disposeScreen(tester);
    });

    for (final size in const [Size(844, 390), Size(915, 412)]) {
      testWidgets(
        'sideways ${size.width.toInt()}x${size.height.toInt()} with insets '
        '(top 24, right 48): header, search and rows inside the safe area; '
        'scrolls to the Danger Zone',
        (tester) async {
          const insets = EdgeInsets.only(top: 24, right: 48);
          tester.view.padding = const FakeViewPadding(top: 24, right: 48);
          tester.view.viewPadding = const FakeViewPadding(top: 24, right: 48);
          addTearDown(tester.view.resetPadding);
          addTearDown(tester.view.resetViewPadding);
          await pump(
            tester,
            size: size,
            padding: insets,
            // 600dp+ wide: the harness draws the rail's width on the left.
            bottomNavHeight: kBottomNavBodyHeight,
          );
          expect(tester.takeException(), isNull);
          final safe = Rect.fromLTRB(
            0,
            insets.top,
            size.width - insets.right,
            size.height,
          );
          void inside(Finder f, String what) {
            final r = tester.getRect(f);
            expect(
              r.left >= safe.left - 0.5 &&
                  r.top >= safe.top - 0.5 &&
                  r.right <= safe.right + 0.5,
              isTrue,
              reason: '$what $r is outside the safe area $safe',
            );
          }

          inside(find.byType(ScreenHeader), 'header');
          inside(find.byType(HeaderBell), 'bell');
          inside(find.byKey(const Key('settings-search')), 'search box');
          inside(find.byType(ProfileCard), 'profile card');

          final list = find.byKey(const Key('settings-list'));
          final viewport = tester.getRect(list);
          final titles = [..._rows.map((r) => r.$2), 'Delete Business'];
          for (final title in titles) {
            await tester.scrollUntilVisible(
              find.text(title),
              120,
              scrollable: find
                  .descendant(of: list, matching: find.byType(Scrollable))
                  .first,
            );
            await tester.pump();
            await tester.ensureVisible(_row(title));
            await tester.pump();
            final r = tester.getRect(_row(title));
            inside(_row(title), title);
            // Unclipped: the whole card is inside the list's viewport.
            expect(
              r.top >= viewport.top - 0.5 && r.bottom <= viewport.bottom + 0.5,
              isTrue,
              reason: '$title $r clipped by the list $viewport',
            );
            expect(r.height, greaterThanOrEqualTo(kMinInteractiveDimension));
          }
          expect(find.text('Delete Business').hitTestable(), findsOneWidget);
          _expectTapTargets(tester);
          await disposeScreen(tester);
        },
      );
    }

    testWidgets('upright with a 48dp gesture bar: the Danger Zone clears it', (
      tester,
    ) async {
      const insets = EdgeInsets.only(top: 24, bottom: 48);
      tester.view.padding = const FakeViewPadding(top: 24, bottom: 48);
      tester.view.viewPadding = const FakeViewPadding(top: 24, bottom: 48);
      addTearDown(tester.view.resetPadding);
      addTearDown(tester.view.resetViewPadding);
      const size = Size(390, 844);
      await pump(tester, size: size, padding: insets);
      expect(tester.takeException(), isNull);
      final list = find.byKey(const Key('settings-list'));
      final position = tester
          .state<ScrollableState>(
            find.descendant(of: list, matching: find.byType(Scrollable)).first,
          )
          .position;
      position.jumpTo(position.maxScrollExtent);
      await tester.pump();
      final r = tester.getRect(
        find.byKey(const Key('settings-delete-business')),
      );
      expect(r.bottom, lessThanOrEqualTo(size.height - insets.bottom));
      expect(r.top, greaterThan(tester.getRect(find.byType(AppBar)).bottom));
      await disposeScreen(tester);
    });

    testWidgets('1280 wide: content capped at 720dp and centred', (
      tester,
    ) async {
      const size = Size(1280, 800);
      await pump(
        tester,
        size: size,
        padding: EdgeInsets.zero,
        bottomNavHeight: kBottomNavBodyHeight,
      );
      final list = tester.getRect(find.byKey(const Key('settings-list')));
      for (final f in [
        find.byType(ProfileCard),
        find.byKey(const Key('settings-search')),
        _row('Business Info'),
      ]) {
        final r = tester.getRect(f);
        expect(r.width, lessThanOrEqualTo(kSettingsMaxContentWidth + 0.5));
        expect(
          (r.center.dx - list.center.dx).abs(),
          lessThan(1),
          reason: 'centred in the content area',
        );
      }
      await disposeScreen(tester);
    });
  });
}

/// Every live tap target on screen is at least 48dp both ways.
void _expectTapTargets(WidgetTester tester) {
  final live = find.byWidgetPredicate(
    (w) =>
        (w is InkResponse && (w.onTap != null || w.onLongPress != null)) ||
        (w is IconButton && w.onPressed != null),
  );
  expect(live, findsWidgets);
  for (final e in live.evaluate()) {
    final box = e.renderObject! as RenderBox;
    expect(
      box.size.width,
      greaterThanOrEqualTo(kMinInteractiveDimension),
      reason: '${e.widget.runtimeType} width ${box.size.width}',
    );
    expect(
      box.size.height,
      greaterThanOrEqualTo(kMinInteractiveDimension),
      reason: '${e.widget.runtimeType} height ${box.size.height}',
    );
  }
}
