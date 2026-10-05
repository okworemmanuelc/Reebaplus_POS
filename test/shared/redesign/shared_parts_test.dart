import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/theme/fixed_colors.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
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

  testWidgets('SectionHeader group variant: SemiBold 15, muted; default '
      'unchanged', (tester) async {
    await pump(
      tester,
      (_) => const Column(
        children: [
          SectionHeader(title: 'Default'),
          SectionHeader(title: 'Group', variant: SectionHeaderVariant.group),
        ],
      ),
    );
    final context = tester.element(find.text('Group'));
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall!.color;
    final group = tester.widget<Text>(find.text('Group')).style!;
    expect(group.fontWeight, FontWeight.w600);
    expect(group.fontSize, context.getRFontSize(15));
    expect(group.color, muted);
    final standard = tester.widget<Text>(find.text('Default')).style!;
    expect(standard.fontWeight, FontWeight.w800);
    expect(standard.fontSize, context.getRFontSize(17));
    expect(standard.color, t.colorScheme.onSurface);
    expect(
      const SectionHeader(title: 'x').variant,
      SectionHeaderVariant.standard,
    );
  });

  // A 1x1 opaque PNG.
  final pixel = Uint8List.fromList(const [
    0x89,
    0x50,
    0x4E,
    0x47,
    0x0D,
    0x0A,
    0x1A,
    0x0A,
    0x00,
    0x00,
    0x00,
    0x0D,
    0x49,
    0x48,
    0x44,
    0x52,
    0x00,
    0x00,
    0x00,
    0x01,
    0x00,
    0x00,
    0x00,
    0x01,
    0x08,
    0x06,
    0x00,
    0x00,
    0x00,
    0x1F,
    0x15,
    0xC4,
    0x89,
    0x00,
    0x00,
    0x00,
    0x0D,
    0x49,
    0x44,
    0x41,
    0x54,
    0x78,
    0x9C,
    0x63,
    0xF8,
    0xCF,
    0xC0,
    0xF0,
    0x1F,
    0x00,
    0x05,
    0x00,
    0x01,
    0xFF,
    0x89,
    0x99,
    0x3D,
    0x1D,
    0x00,
    0x00,
    0x00,
    0x00,
    0x49,
    0x45,
    0x4E,
    0x44,
    0xAE,
    0x42,
    0x60,
    0x82,
  ]);

  testWidgets('ProfileCard: no logo shows the initial', (tester) async {
    await pump(tester, (_) => const ProfileCard(title: 'Stallion Global'));
    expect(find.text('S'), findsOneWidget);
    expect(find.byType(Image), findsNothing);
  });

  testWidgets('ProfileCard: a logo fills the tile instead of the initial', (
    tester,
  ) async {
    await pump(
      tester,
      (_) => ProfileCard(title: 'Stallion Global', logo: MemoryImage(pixel)),
    );
    await tester.runAsync(() async {
      await precacheImage(
        MemoryImage(pixel),
        tester.element(find.byType(ProfileCard)),
      );
    });
    await tester.pump();
    final image = find.byType(Image);
    expect(image, findsOneWidget);
    expect(find.text('S'), findsNothing);
    final context = tester.element(image);
    final edge = context.getRSize(56);
    expect(tester.getSize(image), Size(edge, edge));
  });

  testWidgets('ProfileCard: a logo that fails to load falls back to the '
      'initial', (tester) async {
    await pump(
      tester,
      (_) => ProfileCard(
        title: 'Stallion Global',
        logo: MemoryImage(Uint8List.fromList(const [1, 2, 3])),
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();
    expect(find.text('S'), findsOneWidget);
    tester.takeException();
  });
}
