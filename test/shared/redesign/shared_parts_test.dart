import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/theme/fixed_colors.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/redesign.dart';

import 'parts_samples.dart';

/// #352 PR 2 — the shared parts. Each part renders its gallery without an
/// overflow at text scale 1.3 on a narrow phone, every live tap target is at
/// least kMinInteractiveDimension, and the behaviour each part owns works.
void main() {
  Future<void> pump(
    WidgetTester tester,
    Widget Function(BuildContext) body, {
    double width = 360,
    double textScale = 1.0,
    ThemeData? theme,
  }) async {
    tester.view.physicalSize = Size(width, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: theme ?? AppTheme.light(),
        home: Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(textScale)),
            child: Scaffold(
              body: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: Builder(builder: body),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  Widget gallery(String name) => Builder(
    builder: (context) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final w in partGalleries[name]!(context)) ...[
          w,
          const SizedBox(height: 12),
        ],
      ],
    ),
  );

  group('every part at text scale 1.3 on a 360dp phone', () {
    for (final name in partGalleries.keys) {
      testWidgets('$name: no overflow, tap targets >= 48dp', (tester) async {
        await pump(tester, (_) => gallery(name), textScale: 1.3);
        expect(tester.takeException(), isNull, reason: '$name overflowed');

        final live = find.byWidgetPredicate(
          (w) =>
              (w is InkResponse &&
                  (w.onTap != null || w.onLongPress != null)) ||
              (w is IconButton && w.onPressed != null),
        );
        for (final e in live.evaluate()) {
          final box = e.renderObject! as RenderBox;
          expect(
            box.size.width,
            greaterThanOrEqualTo(kMinInteractiveDimension),
            reason: '$name: ${e.widget.runtimeType} width ${box.size.width}',
          );
          expect(
            box.size.height,
            greaterThanOrEqualTo(kMinInteractiveDimension),
            reason: '$name: ${e.widget.runtimeType} height ${box.size.height}',
          );
        }
      });
    }
  });

  testWidgets('CartLine stepper: + and − call back; at one unit − is delete', (
    tester,
  ) async {
    var inc = 0, dec = 0;
    await pump(
      tester,
      (_) => Column(
        children: [
          CartLine(
            key: const Key('two'),
            name: 'Star Lager',
            icon: AppIcons.beerMug,
            quantityLabel: '2',
            unitPriceLabel: '₦9,600',
            totalLabel: '₦19,200',
            isLastUnit: false,
            onIncrement: () => inc++,
            onDecrement: () => dec++,
          ),
          CartLine(
            key: const Key('one'),
            name: 'Hero Lager',
            icon: AppIcons.beerMug,
            quantityLabel: '1',
            unitPriceLabel: '₦8,400',
            totalLabel: '₦8,400',
            isLastUnit: true,
            onIncrement: () {},
            onDecrement: () {},
          ),
        ],
      ),
    );
    final two = find.byKey(const Key('two'));
    await tester.tap(
      find.descendant(
        of: two,
        matching: find.byKey(const Key('stepper-increment')),
      ),
    );
    await tester.tap(
      find.descendant(
        of: two,
        matching: find.byKey(const Key('stepper-decrement')),
      ),
    );
    expect((inc, dec), (1, 1));
    expect(find.text('2 × ₦9,600'), findsOneWidget);

    AppIcon iconIn(String key) => tester.widget<AppIcon>(
      find.descendant(
        of: find.descendant(
          of: find.byKey(Key(key)),
          matching: find.byKey(const Key('stepper-decrement')),
        ),
        matching: find.byType(AppIcon),
      ),
    );
    expect(iconIn('two').icon, AppIcons.minus);
    expect(iconIn('one').icon, AppIcons.delete);
  });

  testWidgets('ProductTile: badge for cart qty; out of stock ignores taps; '
      'no photo falls back to the category icon', (tester) async {
    var taps = 0;
    await pump(
      tester,
      (_) => Row(
        children: [
          Expanded(
            child: SizedBox(
              height: 260,
              child: ProductTile(
                key: const Key('beer'),
                name: 'Star Lager',
                priceLabel: '₦9,600',
                stockLabel: '38',
                categoryName: 'Beer',
                inCartQty: 2,
                onTap: () => taps++,
              ),
            ),
          ),
          Expanded(
            child: SizedBox(
              height: 260,
              child: ProductTile(
                key: const Key('out'),
                name: 'Power Horse',
                priceLabel: '₦16,800',
                stockLabel: '0',
                stockLevel: StockLevel.out,
                categoryName: 'Energy',
                photoPath: '/no/such/photo.jpg',
                onTap: () => taps++,
              ),
            ),
          ),
        ],
      ),
    );
    await tester.pump();
    expect(find.text('2'), findsOneWidget);
    await tester.tap(find.byKey(const Key('beer')));
    await tester.tap(find.byKey(const Key('out')), warnIfMissed: false);
    expect(taps, 1);
    expect(find.text('Out of stock'), findsOneWidget);
    final beerIcon = tester.widget<AppIcon>(
      find
          .descendant(
            of: find.byKey(const Key('beer')),
            matching: find.byType(AppIcon),
          )
          .first,
    );
    expect(beerIcon.icon, AppIcons.beerMug);
  });

  testWidgets('CategoryChip: the dot follows the product-tile colour rule', (
    tester,
  ) async {
    var tapped = false;
    await pump(
      tester,
      (_) => CategoryChip(
        label: 'Water',
        categoryName: 'Water',
        selected: false,
        onTap: () => tapped = true,
      ),
    );
    final f = AppFixedColors.light;
    final dot = find.byWidgetPredicate(
      (w) =>
          w is Container &&
          w.decoration is BoxDecoration &&
          (w.decoration! as BoxDecoration).shape == BoxShape.circle,
    );
    final color =
        (tester.widget<Container>(dot).decoration! as BoxDecoration).color;
    expect(color, categoryVisual('Water', f).iconColor);
    await tester.tap(find.text('Water'));
    expect(tapped, isTrue);
  });

  testWidgets('SettingsRow and ProfileCard call back on tap', (tester) async {
    var rows = 0, profile = 0;
    await pump(
      tester,
      (_) => Column(
        children: [
          SettingsRow(
            icon: AppIcons.business,
            tone: IconTileTone.info,
            title: 'Business Info',
            subtitle: 'Name, type, and currency',
            onTap: () => rows++,
          ),
          ProfileCard(
            title: 'Stallion Global',
            subtitle: 'Emmanuel Okwor',
            tags: const [(label: 'PRO', tone: TagPillTone.solidInfo)],
            onTap: () => profile++,
          ),
        ],
      ),
    );
    await tester.tap(find.text('Business Info'));
    await tester.tap(find.text('Stallion Global'));
    expect((rows, profile), (1, 1));
    expect(find.text('S'), findsOneWidget, reason: 'initial tile');
  });

  testWidgets('TagPill uses fixed colours, identical across schemes', (
    tester,
  ) async {
    Color fillOf(WidgetTester t) {
      final c = t.widget<Container>(
        find
            .descendant(
              of: find.byType(TagPill),
              matching: find.byType(Container),
            )
            .first,
      );
      return (c.decoration! as ShapeDecoration).color!;
    }

    await pump(
      tester,
      (_) => const TagPill(label: 'PRO', tone: TagPillTone.solidInfo),
    );
    final blue = fillOf(tester);
    await pump(
      tester,
      (_) => const TagPill(label: 'PRO', tone: TagPillTone.solidInfo),
      theme: AppTheme.amberLight(),
    );
    expect(fillOf(tester), blue);
    expect(blue, AppFixedColors.light.info);
  });

  testWidgets('HeaderBell hides the badge at 0 and shows the count', (
    tester,
  ) async {
    await pump(
      tester,
      (_) => Row(
        children: [
          HeaderBell(count: 0, onPressed: () {}),
          HeaderBell(count: 8, onPressed: () {}),
        ],
      ),
    );
    expect(find.text('8'), findsOneWidget);
    expect(find.text('0'), findsNothing);
  });

  testWidgets('SectionHeader wraps the subtitle under the title when narrow', (
    tester,
  ) async {
    await pump(
      tester,
      (_) => const SectionHeader(
        title: 'Performance Overview',
        subtitle: 'Analytics for the selected period',
      ),
      width: 320,
      textScale: 1.3,
    );
    expect(tester.takeException(), isNull);
    final title = tester.getRect(find.text('Performance Overview'));
    final sub = tester.getRect(find.text('Analytics for the selected period'));
    expect(sub.top, greaterThanOrEqualTo(title.bottom - 1));
  });
}
