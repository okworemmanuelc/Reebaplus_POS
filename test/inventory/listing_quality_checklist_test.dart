import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/listings/listing_quality.dart';
import 'package:reebaplus_pos/features/inventory/widgets/listing_quality_checklist.dart';

void main() {
  Future<List<ListingGap>> pump(
    WidgetTester tester,
    List<ListingGap> gaps, {
    VoidCallback? shared,
  }) async {
    final tapped = <ListingGap>[];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ListingQualityChecklist(
          gaps: gaps,
          onFix: tapped.add,
          onUseSharedPhoto: shared,
        ),
      ),
    ));
    return tapped;
  }

  testWidgets('no gaps: all ticked, nothing tappable', (tester) async {
    await pump(tester, const []);
    expect(find.text('Ready for shoppers'), findsOneWidget);
    for (final g in ListingGap.values) {
      expect(find.byKey(ValueKey('listing-ok-${g.name}')), findsOneWidget);
      expect(find.byKey(ValueKey('listing-gap-${g.name}')), findsNothing);
    }
  });

  testWidgets('a gap row is a 48dp target and reports its gap', (tester) async {
    final tapped = await pump(tester, ListingGap.values);
    for (final g in ListingGap.values) {
      final row = find.byKey(ValueKey('listing-gap-${g.name}'));
      expect(tester.getSize(row).height, greaterThanOrEqualTo(kMinInteractiveDimension));
      await tester.tap(row);
    }
    expect(tapped, ListingGap.values);
  });

  testWidgets('shared photo button only with a photo gap and a handler',
      (tester) async {
    final button = find.byKey(const ValueKey('use-shared-photo'));
    await pump(tester, [ListingGap.photo]);
    expect(button, findsNothing);
    var used = 0;
    await pump(tester, [ListingGap.photo], shared: () => used++);
    expect(button, findsOneWidget);
    await tester.tap(button);
    expect(used, 1);
    await pump(tester, [ListingGap.description], shared: () => used++);
    expect(button, findsNothing);
  });
}
