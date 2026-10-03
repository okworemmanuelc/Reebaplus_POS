import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Where the device keeps its copies of product photos and the business logo,
/// and the wipe that removes them (#340).
///
/// Kept free of Supabase / image-picker imports so `AppDatabase.clearAllData`
/// can call [deleteAll] without the database layer depending on network code
/// (same shape as `FirstLoadMarkerService` / `SyncCursorResetService`).
class LocalPhotoFiles {
  LocalPhotoFiles._();

  /// `<appDocs>/product_images/` — one `<productId>.png` (+ `.url` record) per
  /// product photo. See `ProductPhotoCache`.
  static const productImagesFolder = 'product_images';

  /// `<appDocs>/business_logos/` — one `<businessId>.png` per logo.
  static const businessLogosFolder = 'business_logos';

  /// SharedPreferences list of `<businessId>|<productId>` photos saved on this
  /// phone but not uploaded yet. Owned by `ProductImageService`.
  static const pendingProductUploadsKey = 'pending_product_image_uploads';

  static Future<Directory> productImagesDir() async {
    final docs = await getApplicationDocumentsDirectory();
    return Directory('${docs.path}/$productImagesFolder');
  }

  static Future<Directory> businessLogosDir() async {
    final docs = await getApplicationDocumentsDirectory();
    return Directory('${docs.path}/$businessLogosFolder');
  }

  /// The products of [businessId] whose photo was saved on this phone but has
  /// not uploaded yet AND whose device copy is still there — exactly the
  /// entries `ProductImageService.flushPending` would try to upload. Another
  /// business's entries, malformed entries and entries whose copy is gone are
  /// left out (flushPending skips or drops those too), so a dead entry can never
  /// hold up a logout (#343). Never throws: if the photo folder can't be found
  /// nothing can upload from it either, so the answer is an empty list.
  ///
  /// [documents] stands in for the app documents folder (tests); null = the
  /// real one.
  static Future<List<String>> pendingUploadProductIds(
    String businessId, {
    Directory? documents,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final entries =
          prefs.getStringList(pendingProductUploadsKey) ?? const <String>[];
      final ids = <String>[
        for (final entry in entries)
          if (entry.startsWith('$businessId|') &&
              entry.length > businessId.length + 1)
            entry.substring(businessId.length + 1),
      ];
      if (ids.isEmpty) return const [];
      final dir = await _productImagesDirIn(documents);
      return [
        for (final id in ids)
          if (File('${dir.path}/$id.png').existsSync()) id,
      ];
    } catch (_) {
      return const [];
    }
  }

  /// Removes ONE business's photos from this phone: the copies of
  /// [productIds] (`<productId>.png` + its `.url` record), the business's logo
  /// copy, and its entries in the pending-upload list. Called from
  /// `AppDatabase.clearBusinessData` (#285 / #343) when an older business is
  /// cleared at sign-in; every other business's files and entries are left
  /// alone. Best-effort per step, like [deleteAll]. Never throws.
  ///
  /// [documents] stands in for the app documents folder (tests); null = the
  /// real one.
  static Future<void> deleteForBusiness({
    required String businessId,
    required Iterable<String> productIds,
    Directory? documents,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final entries = prefs.getStringList(pendingProductUploadsKey);
      if (entries != null) {
        final keep =
            entries.where((e) => !e.startsWith('$businessId|')).toList();
        if (keep.length != entries.length) {
          await prefs.setStringList(pendingProductUploadsKey, keep);
        }
      }
    } catch (_) {}

    final Directory products;
    final Directory logos;
    try {
      products = await _productImagesDirIn(documents);
      logos = documents == null
          ? await businessLogosDir()
          : Directory('${documents.path}/$businessLogosFolder');
    } catch (_) {
      return;
    }
    final files = [
      for (final id in productIds) ...[
        File('${products.path}/$id.png'),
        File('${products.path}/$id.url'),
      ],
      File('${logos.path}/$businessId.png'),
    ];
    for (final file in files) {
      try {
        if (file.existsSync()) await file.delete();
      } catch (_) {}
    }
  }

  static Future<Directory> _productImagesDirIn(Directory? documents) async =>
      documents == null
          ? await productImagesDir()
          : Directory('${documents.path}/$productImagesFolder');

  /// Deletes every product photo copy, every logo copy and the pending-upload
  /// list. Called from `AppDatabase.clearAllData` (logout, resign, removal,
  /// business delete): one user per device, so the next user must not see the
  /// last one's photos. Each step is best-effort — a file-system hiccup must
  /// never abort the wipe. Never throws.
  ///
  /// [documents] stands in for the app documents folder in tests.
  static Future<void> deleteAll({
    @visibleForTesting Directory? documents,
  }) async {
    final Directory docs;
    try {
      docs = documents ?? await getApplicationDocumentsDirectory();
    } catch (_) {
      return;
    }
    for (final name in [productImagesFolder, businessLogosFolder]) {
      final dir = Directory('${docs.path}/$name');
      try {
        if (dir.existsSync()) await dir.delete(recursive: true);
      } catch (_) {}
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(pendingProductUploadsKey);
    } catch (_) {}
  }
}
