import 'dart:typed_data';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/permissions/gate.dart';
import 'package:reebaplus_pos/core/permissions/gate_registry.dart';
import 'package:reebaplus_pos/core/result.dart';
import 'package:reebaplus_pos/core/services/crash_reporter.dart';
import 'package:reebaplus_pos/core/services/product_gallery_images.dart';

/// The write boundary for a product's gallery photos (#474) — the photos after
/// the cover. Listing content, so every write rechecks `Gates.manageListing`
/// at fire time (like `ProductListingService`). Offline-first: the slot rows
/// commit to Drift + the outbox; the bytes upload now or later.
///
/// The cover (gallery position 1, `products.image_url`) is not edited here —
/// it keeps its own flow and gate on the product photo.
class ProductGalleryService {
  const ProductGalleryService({
    required CatalogDao catalog,
    required ProductGalleryImages images,
  })  : _catalog = catalog,
        _images = images;

  final CatalogDao _catalog;
  final ProductGalleryImages _images;

  /// Most gallery photos after the cover.
  static const maxGalleryPhotos = kMaxProductPhotos - 1;

  static AppError _denied() =>
      AppError.permission('You no longer have access to Manage online listings.');

  /// Adds [bytes] (already processed, ≤800px JPEG) as the last gallery photo.
  /// Ok(true) = uploaded now; Ok(false) = saved on this phone, uploads when
  /// back online.
  Future<Result<bool, AppError>> addPhoto({
    required String productId,
    required Uint8List bytes,
    required GateContext gateContext,
  }) async {
    if (!Gates.manageListing.evaluate(gateContext)) return Result.err(_denied());
    String? staged;
    try {
      final product = await _catalog.findById(productId);
      if (product == null || product.isDeleted) {
        return Result.err(AppError.io('This product is no longer available.'));
      }
      final urls = await _urls(productId);
      if (urls.length >= maxGalleryPhotos) {
        return Result.err(AppError.io(
          'A product can have up to $kMaxProductPhotos photos.'));
      }
      staged = await _images.stage(
        businessId: product.businessId,
        productId: productId,
        bytes: bytes,
      );
      final saved = await _catalog.setProductGallery(
        productId: productId, imageUrls: [...urls, staged]);
      if (!saved) {
        await _images.discard(staged);
        return Result.err(AppError.io('This product is no longer available.'));
      }
      return Result.ok(await _images.tryUpload(staged));
    } catch (error, stack) {
      if (staged != null) await _images.discard(staged);
      CrashReporter.record(error, stack, context: 'inventory.product_gallery');
      return Result.err(AppError.io('Could not add the photo. Try again.'));
    }
  }

  /// Removes the gallery photo at [imageUrl]; the later photos move up.
  Future<Result<void, AppError>> removePhoto({
    required String productId,
    required String imageUrl,
    required GateContext gateContext,
  }) async {
    if (!Gates.manageListing.evaluate(gateContext)) return Result.err(_denied());
    try {
      final urls = await _urls(productId);
      if (!urls.contains(imageUrl)) return Result.ok(null);
      final saved = await _catalog.setProductGallery(
        productId: productId,
        imageUrls: [for (final u in urls) if (u != imageUrl) u],
      );
      if (!saved) {
        return Result.err(AppError.io('This product is no longer available.'));
      }
      await _images.discard(imageUrl);
      return Result.ok(null);
    } catch (error, stack) {
      CrashReporter.record(error, stack, context: 'inventory.product_gallery');
      return Result.err(AppError.io('Could not remove the photo. Try again.'));
    }
  }

  /// Moves the gallery photo at index [from] to index [to] (0 = the first
  /// photo after the cover).
  Future<Result<void, AppError>> movePhoto({
    required String productId,
    required int from,
    required int to,
    required GateContext gateContext,
  }) async {
    if (!Gates.manageListing.evaluate(gateContext)) return Result.err(_denied());
    try {
      final urls = await _urls(productId);
      if (from < 0 || from >= urls.length || to < 0 || to >= urls.length) {
        return Result.err(AppError.io('That photo has moved. Try again.'));
      }
      if (from == to) return Result.ok(null);
      final next = [...urls];
      next.insert(to, next.removeAt(from));
      final saved =
          await _catalog.setProductGallery(productId: productId, imageUrls: next);
      if (!saved) {
        return Result.err(AppError.io('This product is no longer available.'));
      }
      return Result.ok(null);
    } catch (error, stack) {
      CrashReporter.record(error, stack, context: 'inventory.product_gallery');
      return Result.err(AppError.io('Could not move the photo. Try again.'));
    }
  }

  Future<List<String>> _urls(String productId) async => [
    for (final p in await _catalog.getProductPhotos(productId)) p.imageUrl,
  ];
}
