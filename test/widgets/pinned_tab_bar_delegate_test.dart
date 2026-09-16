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

    test('shouldRebuild returns false for unchanged configuration', () {
      final child1 = Container(color: Colors.red);
      final child2 = Container(color: Colors.blue);

      final delegate1 = PinnedTabBarDelegate(
        extent: 60.0,
        child: child1,
      );
      final delegate2 = PinnedTabBarDelegate(
        extent: 60.0,
        child: child2,
      );

      // Distinct child widget instances without keys do not trigger rebuild
      expect(delegate2.shouldRebuild(delegate1), isFalse);
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
