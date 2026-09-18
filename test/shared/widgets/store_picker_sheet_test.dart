// Store picker sheet vertical budget (#239 family): the modal's default height
// cap is 9/16 of the screen, which in landscape fits only ~2 rows. The option
// list must scroll inside that cap instead of overflowing it.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/shared/widgets/store_picker_sheet.dart';

StoreData _store(String id, String name) => StoreData(
      id: id,
      businessId: 'biz',
      name: name,
      location: null,
      kind: kStoreKindStore,
      isDeleted: false,
      createdAt: DateTime.utc(2026, 1, 1),
      lastUpdatedAt: DateTime.utc(2026, 1, 1),
    );

Future<void> _openSheet(WidgetTester tester, Size logicalSize) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = logicalSize;
  addTearDown(tester.view.reset);

  final stores = [
    _store('s1', 'Abuja HQ'),
    _store('s2', 'Makurdi Branch'),
    _store('s3', 'Lagos Depot'),
    _store('s4', 'Enugu Outlet'),
  ];

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        selectableStoresProvider.overrideWithValue(stores),
        canViewAllStoresProvider.overrideWithValue(true),
        storeInventoryCountsProvider.overrideWith(
          (ref) => Stream.value({
            for (final s in stores) s.id: (skuCount: 12, totalQuantity: 340),
          }),
        ),
      ],
      child: MaterialApp(
        home: Consumer(
          builder: (context, ref, _) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () => showStorePickerSheet(context, ref),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('landscape phone: store list scrolls instead of overflowing',
      (tester) async {
    await _openSheet(tester, const Size(891, 411));

    expect(tester.takeException(), isNull);
    expect(find.text('Select Store'), findsOneWidget);
    // The last store is reachable by scrolling the list.
    await tester.scrollUntilVisible(
      find.text('Enugu Outlet'),
      50,
      scrollable: find.byType(Scrollable).last,
    );
    expect(find.text('Enugu Outlet'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('portrait phone: every store fits without overflow',
      (tester) async {
    await _openSheet(tester, const Size(411, 891));

    expect(tester.takeException(), isNull);
    for (final name in ['All Stores', 'Abuja HQ', 'Enugu Outlet']) {
      expect(find.text(name).hitTestable(), findsOneWidget);
    }
  });
}
