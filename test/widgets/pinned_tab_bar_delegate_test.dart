import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/shared/widgets/pinned_tab_bar_delegate.dart';

import '../helpers/viewports.dart';

void main() {
  group('PinnedTabBarDelegate', () {
    test('floors extent at kMinInteractiveDimension when given smaller value', () {
      final delegate = PinnedTabBarDelegate(
        extent: 42.0,
        child: const SizedBox(),
      );

      expect(delegate.minExtent, equals(kMinInteractiveDimension));
      expect(delegate.maxExtent, equals(kMinInteractiveDimension));
      expect(delegate.effectiveExtent, equals(kMinInteractiveDimension));
      expect(kMinInteractiveDimension, equals(48.0));
    });

    test('preserves extent when greater than kMinInteractiveDimension', () {
      final delegate = PinnedTabBarDelegate(
        extent: 60.0,
        child: const SizedBox(),
      );

      expect(delegate.minExtent, equals(60.0));
      expect(delegate.maxExtent, equals(60.0));
      expect(delegate.effectiveExtent, equals(60.0));
    });

    test('defaults extent to kMinInteractiveDimension if omitted', () {
      final delegate = PinnedTabBarDelegate(
        child: const SizedBox(),
      );

      expect(delegate.minExtent, equals(kMinInteractiveDimension));
      expect(delegate.maxExtent, equals(kMinInteractiveDimension));
      expect(delegate.effectiveExtent, equals(kMinInteractiveDimension));
    });

    test('shouldRebuild returns false for an identical configuration', () {
      const child = SizedBox();

      final delegate1 = PinnedTabBarDelegate(extent: 60.0, child: child);
      final delegate2 = PinnedTabBarDelegate(extent: 60.0, child: child);

      expect(delegate2.shouldRebuild(delegate1), isFalse);
    });

    test('shouldRebuild returns true for differently configured unkeyed children', () {
      // No host passes a key, so a key-only comparison would miss this and the
      // pinned header would go on painting its first child forever.
      final delegate1 = PinnedTabBarDelegate(
        extent: 60.0,
        child: Container(color: Colors.red),
      );
      final delegate2 = PinnedTabBarDelegate(
        extent: 60.0,
        child: Container(color: Colors.blue),
      );

      expect(delegate2.shouldRebuild(delegate1), isTrue);
    });

    test('shouldRebuild returns true when extent changes', () {
      final delegate1 = PinnedTabBarDelegate(
        extent: 60.0,
        child: const SizedBox(),
      );
      final delegate2 = PinnedTabBarDelegate(
        extent: 70.0,
        child: const SizedBox(),
      );

      expect(delegate2.shouldRebuild(delegate1), isTrue);
    });

    test('shouldRebuild returns true when child key changes', () {
      final delegate1 = PinnedTabBarDelegate(
        extent: 60.0,
        child: const SizedBox(key: ValueKey('tab_1')),
      );
      final delegate2 = PinnedTabBarDelegate(
        extent: 60.0,
        child: const SizedBox(key: ValueKey('tab_2')),
      );

      expect(delegate2.shouldRebuild(delegate1), isTrue);
    });

    testWidgets('pinned header follows a state change in its child', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: _FilterHost()));
      expect(find.text('header: Today'), findsOneWidget);

      await tester.tap(find.text('change filter'));
      await tester.pumpAndSettle();

      expect(find.text('body: This Week'), findsOneWidget,
          reason: 'sanity check: the scroll body rebuilt');
      expect(find.text('header: This Week'), findsOneWidget,
          reason: 'the pinned header must not paint a stale child');
    });

    test('withChrome reserves the chrome on top of the interactive floor', () {
      // 800x360: getRSize(60) = 42.0, getRSize(8) = 5.6.
      final delegate = PinnedTabBarDelegate.withChrome(
        extent: 42.0,
        chromeExtent: 5.6,
        child: const SizedBox(),
      );

      expect(delegate.effectiveExtent, equals(kMinInteractiveDimension + 5.6));
    });

    test('withChrome leaves a comfortable extent alone', () {
      // Baseline scale: getRSize(60) = 60.0 already clears 48 + 8.
      final delegate = PinnedTabBarDelegate.withChrome(
        extent: 60.0,
        chromeExtent: 8.0,
        child: const SizedBox(),
      );

      expect(delegate.effectiveExtent, equals(60.0));
    });

    testWidgets('withChrome keeps the tab bar itself at the interactive floor', (tester) async {
      await pumpWithViewport(
        tester,
        size: androidCompactLandscape,
        child: MaterialApp(
          home: Builder(
            builder: (context) {
              final margin = context.getRSize(8);
              return Scaffold(
                body: CustomScrollView(
                  slivers: [
                    SliverPersistentHeader(
                      pinned: true,
                      delegate: PinnedTabBarDelegate.withChrome(
                        extent: context.getRSize(60),
                        chromeExtent: margin,
                        // The margin sits outside the keyed box, so the
                        // measurement below is the interactive area itself,
                        // not the header that contains it.
                        child: Padding(
                          padding: EdgeInsets.only(bottom: margin),
                          child: Container(
                            key: const ValueKey('bar_with_margin'),
                            color: Colors.blue,
                          ),
                        ),
                      ),
                    ),
                    const SliverToBoxAdapter(child: SizedBox(height: 600)),
                  ],
                ),
              );
            },
          ),
        ),
      );

      final barHeight =
          tester.getSize(find.byKey(const ValueKey('bar_with_margin'))).height;
      expect(barHeight, greaterThanOrEqualTo(kMinInteractiveDimension));
    });

    testWidgets('forces child height to declared extent', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CustomScrollView(
              slivers: [
                SliverPersistentHeader(
                  pinned: true,
                  delegate: PinnedTabBarDelegate(
                    extent: 60.0,
                    child: Container(
                      key: const ValueKey('pinned_header_content'),
                      // Child specifies a shorter intrinsic height, but delegate forces 60.0
                      height: 20.0,
                      color: Colors.amber,
                    ),
                  ),
                ),
                SliverList(
                  delegate: SliverChildBuilderDelegate(
                    (context, index) => ListTile(title: Text('Item $index')),
                    childCount: 10,
                  ),
                ),
              ],
            ),
          ),
        ),
      );

      final headerFinder = find.byKey(const ValueKey('pinned_header_content'));
      expect(headerFinder, findsOneWidget);
      final size = tester.getSize(headerFinder);
      expect(size.height, equals(60.0));
    });

    testWidgets(
      'pumps at shortest supported landscape viewport and asserts tab bar is at least 48dp tall',
      (tester) async {
        await pumpWithViewport(
          tester,
          size: androidCompactLandscape,
          child: MaterialApp(
            home: Builder(
              builder: (context) {
                // On 800x360 landscape phone, getRSize(60) scales down to 42.0dp
                final scaledExtent = context.getRSize(60.0);
                expect(scaledExtent, equals(42.0));

                return Scaffold(
                  body: CustomScrollView(
                    slivers: [
                      SliverPersistentHeader(
                        pinned: true,
                        delegate: PinnedTabBarDelegate(
                          extent: scaledExtent,
                          child: Container(
                            key: const ValueKey('landscape_tab_bar'),
                            color: Colors.blue,
                            child: const Text('Tab Content'),
                          ),
                        ),
                      ),
                      SliverList(
                        delegate: SliverChildBuilderDelegate(
                          (context, index) => ListTile(title: Text('Row $index')),
                          childCount: 10,
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        );

        final tabBarFinder = find.byKey(const ValueKey('landscape_tab_bar'));
        expect(tabBarFinder, findsOneWidget);

        final renderedHeight = tester.getSize(tabBarFinder).height;
        // Even though scaledExtent was 42.0, the rendered height must be floored at kMinInteractiveDimension (48.0)
        expect(renderedHeight, greaterThanOrEqualTo(kMinInteractiveDimension));
        expect(renderedHeight, equals(48.0));
      },
    );
  });
}

/// Host that rebuilds its pinned header's child from its own state, the way
/// every real caller does (Orders' period dropdown and search-field clear
/// button, Inventory's visible tab set).
class _FilterHost extends StatefulWidget {
  const _FilterHost();

  @override
  State<_FilterHost> createState() => _FilterHostState();
}

class _FilterHostState extends State<_FilterHost> {
  String filter = 'Today';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          ElevatedButton(
            onPressed: () => setState(() => filter = 'This Week'),
            child: const Text('change filter'),
          ),
          Expanded(
            child: CustomScrollView(
              slivers: [
                SliverPersistentHeader(
                  pinned: true,
                  delegate: PinnedTabBarDelegate(
                    extent: 64.0,
                    child: Container(
                      color: Colors.amber,
                      alignment: Alignment.center,
                      child: Text('header: $filter'),
                    ),
                  ),
                ),
                SliverToBoxAdapter(child: Text('body: $filter')),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
