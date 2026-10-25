// #474: the swipeable storefront gallery and the Product Details Photos card.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/features/inventory/widgets/product_photos_card.dart';
import 'package:reebaplus_pos/shared/widgets/product_photo_gallery.dart';

Widget _host(Widget child) => MaterialApp(
      theme: AppTheme.light(),
      home: Scaffold(body: SingleChildScrollView(child: child)),
    );

void main() {
  testWidgets('gallery swipes through photos in order', (tester) async {
    await tester.pumpWidget(_host(ProductPhotoGallery(
      photos: const ['cover', 'two', 'three'],
      height: 200,
      placeholder: const Text('none'),
      photoBuilder: (_, p) => Center(child: Text(p)),
    )));
    expect(find.text('cover'), findsOneWidget);
    await tester.fling(
        find.byKey(const Key('product-photo-gallery')), const Offset(-400, 0), 1000);
    await tester.pumpAndSettle();
    expect(find.text('two'), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp('Photo 2 of 3')), findsOneWidget);
  });

  testWidgets('gallery with one photo has no pager; none shows placeholder',
      (tester) async {
    await tester.pumpWidget(_host(ProductPhotoGallery(
      photos: const ['only'],
      height: 200,
      placeholder: const Text('none'),
      photoBuilder: (_, p) => Text(p),
    )));
    expect(find.byKey(const Key('product-photo-gallery')), findsNothing);
    expect(find.text('only'), findsOneWidget);
    await tester.pumpWidget(_host(ProductPhotoGallery(
      photos: const [],
      height: 200,
      placeholder: const Text('none'),
      photoBuilder: (_, p) => Text(p),
    )));
    expect(find.text('none'), findsOneWidget);
  });

  testWidgets('photos card moves, removes, and hides Add when full',
      (tester) async {
    final moves = <(int, int)>[];
    final removed = <String>[];
    var added = 0;
    Widget card(List<String> photos) => _host(ProductPhotosCard(
          hasCover: true,
          cover: const SizedBox(),
          photos: photos,
          maxPhotos: 5,
          thumbnail: (_, __) => const SizedBox(),
          onAdd: () => added++,
          onMove: (a, b) => moves.add((a, b)),
          onRemove: removed.add,
        ));
    await tester.pumpWidget(card(const ['a', 'b']));
    expect(find.text('3 of 5 · shoppers swipe through them'), findsOneWidget);
    await tester.tap(find.byTooltip('Move photo 2 up'));
    expect(moves, isEmpty, reason: 'the first photo cannot move up');
    await tester.tap(find.byTooltip('Move photo 2 down'));
    await tester.tap(find.byTooltip('Remove photo 3'));
    await tester.tap(find.byKey(const ValueKey('product-photos-add')));
    expect(moves, [(0, 1)]);
    expect(removed, ['b']);
    expect(added, 1);

    await tester.pumpWidget(card(const ['a', 'b', 'c', 'd']));
    expect(find.byKey(const ValueKey('product-photos-add')), findsNothing);
    expect(find.textContaining('the most photos it can have'), findsOneWidget);
  });
}
