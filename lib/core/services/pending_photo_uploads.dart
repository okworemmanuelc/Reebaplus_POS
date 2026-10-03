import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;

import 'package:reebaplus_pos/core/database/daos.dart';
import 'package:reebaplus_pos/core/services/local_photo_files.dart';
import 'package:reebaplus_pos/core/services/product_image_service.dart';

/// Product photos saved on this phone that have not reached the cloud yet
/// (#343). They wait in a SharedPreferences list, not the sync outbox, so the
/// logout wipe gate asks this — alongside the outbox counts — before it lets a
/// wipe delete them.
///
/// One rule decides which photos count and which [upload] tries: the photo
/// belongs to the business, its device copy is still there, and its product
/// still exists. A photo that fails any of those can never upload, so it never
/// holds up a logout.
class PendingPhotoUploads {
  PendingPhotoUploads({
    required ProductImageService images,
    required CatalogDao catalog,
    @visibleForTesting Directory? documents,
  })  : _images = images,
        _catalog = catalog,
        _documents = documents;

  final ProductImageService _images;
  final CatalogDao _catalog;
  final Directory? _documents;

  /// How many of [businessId]'s photos are still waiting to upload.
  Future<int> count(String businessId) async {
    final ids = await LocalPhotoFiles.pendingUploadProductIds(
      businessId,
      documents: _documents,
    );
    var live = 0;
    for (final id in ids) {
      if (await _catalog.productIsLive(id)) live++;
    }
    return live;
  }

  /// Uploads [businessId]'s waiting photos and writes each url onto its
  /// product (which queues the product row for sync). Photos that fail stay
  /// waiting for the next try.
  Future<void> upload(String businessId) => _images.flushPending(
        businessId,
        _catalog.setProductImageUrl,
        isLiveProduct: _catalog.productIsLive,
      );
}
