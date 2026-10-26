// product_gallery_test.dart
//
// #474 — up to 5 photos per product. The cover stays in products.image_url;
// gallery photos 2–5 are deterministic slot rows in product_photos.
//   * setProductGallery: slot writes, reorder moves urls (no position change),
//     removal soft-deletes the tail, every change queues a full row.
//   * ProductGalleryService: Gates.manageListing at fire time, the 5-photo cap,
//     add offline stays waiting and still writes the synced row.
//   * ProductGalleryImages: pending survives (prefs), flush uploads + clears,
//     dead entries dropped; PendingPhotoUploads counts gallery photos (the
//     invariant #12 wipe gate).

import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/core/permissions/gate.dart';
import 'package:reebaplus_pos/core/result.dart';
import 'package:reebaplus_pos/core/services/local_photo_files.dart';
import 'package:reebaplus_pos/core/services/pending_photo_uploads.dart';
import 'package:reebaplus_pos/core/services/product_gallery_images.dart';
import 'package:reebaplus_pos/core/services/product_gallery_service.dart';
import 'package:reebaplus_pos/core/services/product_image_service.dart';

import '../../helpers/dispatch_test_utils.dart';

const _lister = GateContext(
    grantedKeys: {'products.manage_listing'},
    roleRank: GateTier.manager,
    isReady: true);
const _noListing = GateContext(
    grantedKeys: {'products.edit_price'},
    roleRank: GateTier.manager,
    isReady: true);

class _FakeStorage {
  bool online = true;
  final objects = <String, Uint8List>{};
  final removed = <String>[];

  ProductGalleryImages images(Directory gallery) => ProductGalleryImages(
        directory: () async => gallery,
        upload: (path, bytes) async {
          if (!online) throw const SocketException('offline');
          objects[path] = bytes;
        },
        download: (path) async => online ? objects[path] : null,
        remove: (paths) async => removed.addAll(paths),
        publicUrl: (path) =>
            'https://x.supabase.co/storage/v1/object/public/product-images/$path',
      );
}

void main() {
  late AppDatabase db;
  late String biz;
  late String productId;
  late Directory docs;
  late Directory gallery;
  late _FakeStorage storage;
  late ProductGalleryImages images;
  late ProductGalleryService service;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    try {
      await Supabase.initialize(
          url: 'https://placeholder.supabase.co', anonKey: 'placeholder');
    } catch (_) {}
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final boot = await bootstrapTestDb();
    db = boot.db;
    biz = boot.businessId;
    productId = UuidV7.generate();
    await db.into(db.products).insert(ProductsCompanion.insert(
        id: Value(productId), businessId: biz, name: 'Sneaker'));
    docs = Directory.systemTemp.createTempSync('product_gallery_test');
    gallery = await LocalPhotoFiles.galleryDir(documents: docs);
    storage = _FakeStorage();
    images = storage.images(gallery);
    service = ProductGalleryService(catalog: db.catalogDao, images: images);
  });

  tearDown(() async {
    await db.close();
    if (docs.existsSync()) docs.deleteSync(recursive: true);
  });

  String url(String photo) =>
      'https://x.supabase.co/storage/v1/object/public/product-images/'
      '$biz/$productId/$photo.jpg';

  Future<List<ProductPhotoData>> allSlots() =>
      (db.select(db.productPhotos)
            ..orderBy([(t) => OrderingTerm(expression: t.position)]))
          .get();

  Future<List<Map<String, dynamic>>> queuedPhotos() async =>
      (await getPendingQueue(db))
          .where((q) => q.actionType == 'product_photos:upsert')
          .map(decodePayload)
          .toList();

  group('CatalogDao.setProductGallery', () {
    test('writes slots 2.. with deterministic ids and queues full rows',
        () async {
      expect(await db.catalogDao.setProductGallery(
          productId: productId, imageUrls: [url('a'), url('b')]), isTrue);
      final rows = await allSlots();
      expect([for (final r in rows) r.position], [2, 3]);
      expect(rows.first.id, productPhotoSlotId(productId, 2));
      expect(rows.first.businessId, biz);
      final queued = await queuedPhotos();
      expect(queued, hasLength(2));
      expect(queued.first['image_url'], isNotNull);
      expect(queued.first['business_id'], biz);
    });

    test('a reorder swaps urls between slots; removal soft-deletes the tail',
        () async {
      await db.catalogDao.setProductGallery(
          productId: productId, imageUrls: [url('a'), url('b'), url('c')]);
      await db.catalogDao.setProductGallery(
          productId: productId, imageUrls: [url('c'), url('a'), url('b')]);
      var live = await db.catalogDao.getProductPhotos(productId);
      expect([for (final r in live) r.imageUrl], [url('c'), url('a'), url('b')]);
      expect([for (final r in live) r.position], [2, 3, 4]);

      await db.catalogDao.setProductGallery(
          productId: productId, imageUrls: [url('c')]);
      live = await db.catalogDao.getProductPhotos(productId);
      expect([for (final r in live) r.imageUrl], [url('c')]);
      final all = await allSlots();
      expect(all, hasLength(3), reason: 'slots are soft-deleted, not dropped');
      expect(all.where((r) => r.isDeleted), hasLength(2));
    });

    test('refuses another business\'s or a deleted product, and > 4 photos',
        () async {
      expect(await db.catalogDao.setProductGallery(
          productId: UuidV7.generate(), imageUrls: [url('a')]), isFalse);
      expect(
        () => db.catalogDao.setProductGallery(productId: productId,
            imageUrls: [for (var i = 0; i < 5; i++) url('$i')]),
        throwsArgumentError,
      );
      expect(await allSlots(), isEmpty);
    });
  });

  group('ProductGalleryService', () {
    final bytes = Uint8List.fromList([1, 2, 3]);

    test('needs products.manage_listing at fire time', () async {
      final r = await service.addPhoto(
          productId: productId, bytes: bytes, gateContext: _noListing);
      expect(r.isErr, isTrue);
      expect(await allSlots(), isEmpty);
      expect(storage.objects, isEmpty);
    });

    test('online add uploads to <biz>/<product>/<photo>.jpg', () async {
      final r = await service.addPhoto(
          productId: productId, bytes: bytes, gateContext: _lister);
      expect(r, isA<Ok<bool, AppError>>());
      expect((r as Ok<bool, AppError>).value, isTrue);
      final photo = (await db.catalogDao.getProductPhotos(productId)).single;
      final path = storage.objects.keys.single;
      expect(path, startsWith('$biz/$productId/'));
      expect(photo.imageUrl, endsWith(path));
      expect(await images.isPending(photo.imageUrl), isFalse);
    });

    test('offline add writes the synced row and waits; flush uploads it',
        () async {
      storage.online = false;
      final r = await service.addPhoto(
          productId: productId, bytes: bytes, gateContext: _lister);
      expect((r as Ok<bool, AppError>).value, isFalse);
      final photo = (await db.catalogDao.getProductPhotos(productId)).single;
      expect(await queuedPhotos(), hasLength(1));
      expect(await images.isPending(photo.imageUrl), isTrue);
      expect(await images.pendingCount(biz,
          isLiveProduct: db.catalogDao.productIsLive, documents: docs), 1);

      storage.online = true;
      await images.flushPending(biz, isLiveProduct: db.catalogDao.productIsLive);
      expect(storage.objects, hasLength(1));
      expect(await images.isPending(photo.imageUrl), isFalse);
    });

    test('caps the gallery at 4 photos after the cover (5 in all)', () async {
      for (var i = 0; i < 4; i++) {
        expect((await service.addPhoto(
            productId: productId, bytes: bytes, gateContext: _lister)).isOk,
            isTrue);
      }
      final r = await service.addPhoto(
          productId: productId, bytes: bytes, gateContext: _lister);
      expect(r.isErr, isTrue);
      expect(await db.catalogDao.getProductPhotos(productId), hasLength(4));
    });

    test('move and remove keep order; remove discards the copy and object',
        () async {
      for (var i = 0; i < 3; i++) {
        await service.addPhoto(
            productId: productId, bytes: bytes, gateContext: _lister);
      }
      final before = [
        for (final p in await db.catalogDao.getProductPhotos(productId))
          p.imageUrl,
      ];
      expect((await service.movePhoto(productId: productId, from: 2, to: 0,
          gateContext: _lister)).isOk, isTrue);
      var now = [
        for (final p in await db.catalogDao.getProductPhotos(productId))
          p.imageUrl,
      ];
      expect(now, [before[2], before[0], before[1]]);

      expect((await service.removePhoto(productId: productId,
          imageUrl: before[0], gateContext: _lister)).isOk, isTrue);
      now = [
        for (final p in await db.catalogDao.getProductPhotos(productId))
          p.imageUrl,
      ];
      expect(now, [before[2], before[1]]);
      expect(storage.removed, hasLength(1));
      final ref = ProductGalleryImages.parseUrl(before[0])!;
      expect(File('${gallery.path}/$productId/${ref.photoId}.jpg').existsSync(),
          isFalse);
    });
  });

  test('PendingPhotoUploads counts waiting gallery photos (wipe gate) and '
      'drops them once the product is deleted', () async {
    storage.online = false;
    await service.addPhoto(productId: productId,
        bytes: Uint8List.fromList([9]), gateContext: _lister);
    final pending = PendingPhotoUploads(
      images: ProductImageService(Supabase.instance.client),
      catalog: db.catalogDao,
      gallery: images,
      documents: docs,
    );
    expect(await pending.count(biz), 1);

    await (db.update(db.products)..where((p) => p.id.equals(productId)))
        .write(const ProductsCompanion(isDeleted: Value(true)));
    expect(await pending.count(biz), 0);
  });

  test('deleteForBusiness and deleteAll remove gallery copies and entries',
      () async {
    storage.online = false;
    await service.addPhoto(productId: productId,
        bytes: Uint8List.fromList([9]), gateContext: _lister);
    expect(await LocalPhotoFiles.pendingGalleryUploads(biz, documents: docs),
        hasLength(1));
    await LocalPhotoFiles.deleteForBusiness(
        businessId: biz, productIds: [productId], documents: docs);
    expect(Directory('${gallery.path}/$productId').existsSync(), isFalse);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getStringList(LocalPhotoFiles.pendingGalleryUploadsKey),
        isEmpty);
  });

  test('parseUrl reads gallery urls and rejects cover urls', () {
    final r = ProductGalleryImages.parseUrl(url('p1'))!;
    expect(r.businessId, biz);
    expect(r.productId, productId);
    expect(r.photoId, 'p1');
    expect(ProductGalleryImages.parseUrl(
        'https://x.supabase.co/storage/v1/object/public/product-images/'
        '$biz/$productId.jpg?v=1'), isNull);
  });
}
