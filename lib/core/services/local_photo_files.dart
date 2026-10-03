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
