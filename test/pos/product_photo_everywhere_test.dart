// #832: a saved product photo shows on every product picture (POS grid and
// list, Inventory rows); a product with no device copy keeps the category
// art. The photo reaches the tile through ProductImageService.ensureCached
// (the device copy), never through products.image_path.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/first_run_surface_state.dart';
import 'package:reebaplus_pos/core/services/product_image_service.dart';
import 'package:reebaplus_pos/features/inventory/screens/inventory_screen.dart';
import 'package:reebaplus_pos/features/pos/screens/pos_home_screen.dart';
import 'package:reebaplus_pos/features/pos/widgets/product_grid.dart';
import 'package:reebaplus_pos/shared/widgets/local_photo_image.dart';

import '../helpers/pos_home_harness.dart';
import '../helpers/screen_harness.dart';

/// Answers "device copy" for [withCopy] and nothing for every other product.
class _FakeImages extends ProductImageService {
  _FakeImages(super.client, this.withCopy, this.path);
  final String withCopy;
  final String path;

  @override
  Future<String?> ensureCached({
    required String productId,
    required String? imageUrl,
  }) async => productId == withCopy ? path : null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late PosTestEnvironment env;
  late Directory dir;
  late String photo;
  late ProductData withPhoto;
  late ProductData withoutPhoto;

  setUp(() async {
    env = await setupTestPosEnvironment(productCount: 4);
    dir = Directory.systemTemp.createTempSync('photo832');
    photo = '${dir.path}/p.png';
    File(photo).writeAsBytesSync(_png);
    withPhoto = env.products[0];
    withoutPhoto = env.products[1];
    // The cloud url exists on both; only one has a device copy.
    await env.db.customStatement(
      "UPDATE products SET image_url = 'https://x.test/a.jpg'",
    );
  });

  tearDown(() async {
    await env.dispose();
    dir.deleteSync(recursive: true);
  });

  List<Override> overrides() => [
    firstRunSurfaceStateProvider.overrideWithValue(
      FirstRunSurfaceState.hasContent,
    ),
    productImageServiceProvider.overrideWith((ref) {
      return _FakeImages(ref.read(supabaseClientProvider), withPhoto.id, photo);
    }),
  ];

  Finder photoIn(Finder of) =>
      find.descendant(of: of, matching: find.byType(LocalPhotoImage));

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  testWidgets('POS grid: photo for a product with a copy, art without', (
    tester,
  ) async {
    await pumpPosHome(
      tester,
      env: env,
      size: const Size(390, 844),
      overrides: overrides(),
    );
    await settle(tester);
    expect(
      photoIn(find.byKey(posProductTileKey(withPhoto.id))),
      findsOneWidget,
    );
    final plain = find.byKey(posProductTileKey(withoutPhoto.id));
    expect(plain, findsOneWidget);
    expect(photoIn(plain), findsNothing);
    await disposePosHome(tester);
  });

  testWidgets('POS list: photo for a product with a copy, art without', (
    tester,
  ) async {
    await pumpPosHome(
      tester,
      env: env,
      size: const Size(390, 844),
      overrides: overrides(),
    );
    await tester.tap(find.byKey(kPosViewSelectorKey));
    await tester.pumpAndSettle();
    await tester.tap(find.text('List View'));
    await settle(tester);
    expect(find.byType(SliverGrid), findsNothing);
    expect(
      photoIn(find.byKey(posProductTileKey(withPhoto.id))),
      findsOneWidget,
    );
    expect(
      photoIn(find.byKey(posProductTileKey(withoutPhoto.id))),
      findsNothing,
    );
    await disposePosHome(tester);
  });

  testWidgets('Inventory rows: photo for a product with a copy, art without', (
    tester,
  ) async {
    await pumpScreen(
      tester,
      env: env,
      size: const Size(390, 844),
      screen: const InventoryScreen(),
      grantedKeys: const {'sales.make', 'stock.view'},
      overrides: overrides(),
    );
    await settle(tester);
    expect(
      photoIn(find.byKey(inventoryProductRowKey(withPhoto.id))),
      findsOneWidget,
    );
    final plain = find.byKey(inventoryProductRowKey(withoutPhoto.id));
    expect(plain, findsOneWidget);
    expect(photoIn(plain), findsNothing);
    await disposeScreen(tester);
  });
}

// A 1x1 PNG.
const _png = <int>[
  0x89,
  0x50,
  0x4e,
  0x47,
  0x0d,
  0x0a,
  0x1a,
  0x0a,
  0x00,
  0x00,
  0x00,
  0x0d,
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
  0x1f,
  0x15,
  0xc4,
  0x89,
  0x00,
  0x00,
  0x00,
  0x0d,
  0x49,
  0x44,
  0x41,
  0x54,
  0x78,
  0x9c,
  0x63,
  0xf8,
  0xcf,
  0xc0,
  0xf0,
  0x1f,
  0x00,
  0x05,
  0x00,
  0x01,
  0xff,
  0x89,
  0x99,
  0x3d,
  0x1d,
  0x00,
  0x00,
  0x00,
  0x00,
  0x49,
  0x45,
  0x4e,
  0x44,
  0xae,
  0x42,
  0x60,
  0x82,
];
