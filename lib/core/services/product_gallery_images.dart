import 'dart:io';
import 'dart:typed_data';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/core/services/local_photo_files.dart';
import 'package:reebaplus_pos/core/services/photo_encoding.dart';

/// The Storage side of a product's gallery photos (#474) — the photos after
/// the cover. Same sanctioned direct-Supabase carve-out as
/// `ProductImageService`: Storage objects are not tenant rows, only the url
/// rides sync (`product_photos.image_url`).
///
/// - Bucket `product-images`, object `<businessId>/<productId>/<photoId>.jpg`.
///   A fresh photoId per photo and never overwritten, so a url always means
///   the same bytes (no `?v=` needed). The existing 0144 write policies gate
///   on the first folder segment; 0186's 1 MB / image-type limits apply. Bytes
///   arrive already through `ProductImageService.processBytes` (≤800px JPEG).
/// - Device copy `<appDocs>/product_images/gallery/<productId>/<photoId>.jpg`.
///   Present → shown, never re-downloaded.
/// - A photo is staged (device copy + pending entry) BEFORE its row is
///   written, with its final public url — so an offline add is a normal synced
///   row. The bytes upload now or on the next reconnect; the pending list
///   survives restarts and the logout wipe gate counts it (invariant #12).
class ProductGalleryImages {
  ProductGalleryImages({
    required Future<void> Function(String objectPath, Uint8List bytes) upload,
    required Future<Uint8List?> Function(String objectPath) download,
    required Future<void> Function(List<String> objectPaths) remove,
    required String Function(String objectPath) publicUrl,
    Future<Directory> Function()? directory,
  })  : _upload = upload,
        _download = download,
        _remove = remove,
        _publicUrl = publicUrl,
        _directory = directory ?? (() => LocalPhotoFiles.galleryDir());

  /// The real Storage client.
  factory ProductGalleryImages.supabase(SupabaseClient client) {
    StorageFileApi bucket() => client.storage.from(bucketId);
    return ProductGalleryImages(
      upload: (path, bytes) => bucket().uploadBinary(
        path,
        bytes,
        fileOptions: const FileOptions(upsert: true, contentType: 'image/jpeg'),
      ),
      download: (path) async {
        try {
          return await bucket().download(path);
        } catch (_) {
          return null;
        }
      },
      remove: (paths) => bucket().remove(paths),
      publicUrl: (path) => bucket().getPublicUrl(path),
    );
  }

  static const bucketId = 'product-images';
  static const _pendingKey = LocalPhotoFiles.pendingGalleryUploadsKey;

  final Future<void> Function(String objectPath, Uint8List bytes) _upload;
  final Future<Uint8List?> Function(String objectPath) _download;
  final Future<void> Function(List<String> objectPaths) _remove;
  final String Function(String objectPath) _publicUrl;
  final Future<Directory> Function() _directory;

  /// `<businessId>/<productId>/<photoId>.jpg`.
  static String objectPath(
    String businessId,
    String productId,
    String photoId,
  ) => '$businessId/$productId/$photoId.jpg';

  /// The (business, product, photo) a gallery url points at, or null when it
  /// is not a gallery object (e.g. a cover url `<businessId>/<productId>.jpg`).
  static ({String businessId, String productId, String photoId})? parseUrl(
    String url,
  ) {
    final path = storageObjectPathFromPublicUrl(url, bucketId);
    if (path == null) return null;
    final parts = path.split('/');
    if (parts.length != 3 || !parts[2].endsWith('.jpg')) return null;
    final photoId = parts[2].substring(0, parts[2].length - 4);
    if (parts[0].isEmpty || parts[1].isEmpty || photoId.isEmpty) return null;
    return (businessId: parts[0], productId: parts[1], photoId: photoId);
  }

  Future<File> _copyFile(String productId, String photoId) async {
    final dir = await _directory();
    return File('${dir.path}/$productId/$photoId.jpg');
  }

  // ── Stage / upload / discard ──────────────────────────────────────────────

  /// Writes [bytes] as a new photo of [productId] on this phone, marks it
  /// waiting to upload and returns its final public url (computed offline).
  /// The caller writes that url onto a gallery slot, then calls [tryUpload].
  Future<String> stage({
    required String businessId,
    required String productId,
    required Uint8List bytes,
  }) async {
    final photoId = UuidV7.generate();
    final file = await _copyFile(productId, photoId);
    await file.parent.create(recursive: true);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsBytes(bytes, flush: true);
    await tmp.rename(file.path);
    await _setPending('$businessId|$productId|$photoId', pending: true);
    return _publicUrl(objectPath(businessId, productId, photoId));
  }

  /// Uploads the device copy behind [url]. True once it is in Storage (it then
  /// stops waiting); false leaves it waiting for [flushPending].
  Future<bool> tryUpload(String url) async {
    final ref = parseUrl(url);
    if (ref == null) return false;
    final file = await _copyFile(ref.productId, ref.photoId);
    if (!file.existsSync()) return false;
    try {
      await _upload(
        objectPath(ref.businessId, ref.productId, ref.photoId),
        await file.readAsBytes(),
      );
    } catch (_) {
      return false;
    }
    await _setPending(
      '${ref.businessId}|${ref.productId}|${ref.photoId}',
      pending: false,
    );
    return true;
  }

  /// Forgets a photo that left the gallery: stops waiting, deletes the device
  /// copy and (best effort, online) the Storage object. Never throws.
  Future<void> discard(String url) async {
    final ref = parseUrl(url);
    if (ref == null) return;
    try {
      await _setPending(
        '${ref.businessId}|${ref.productId}|${ref.photoId}',
        pending: false,
      );
      final file = await _copyFile(ref.productId, ref.photoId);
      if (file.existsSync()) await file.delete();
    } catch (_) {}
    try {
      await _remove([objectPath(ref.businessId, ref.productId, ref.photoId)]);
    } catch (_) {}
  }

  // ── Offline retry ─────────────────────────────────────────────────────────

  /// Uploads [businessId]'s waiting photos. An entry whose device copy is gone
  /// or whose product was deleted ([isLiveProduct]) is dropped; a failed
  /// upload stays waiting. Other businesses' entries are left alone.
  Future<void> flushPending(
    String businessId, {
    Future<bool> Function(String productId)? isLiveProduct,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final entries = prefs.getStringList(_pendingKey) ?? const <String>[];
    if (entries.isEmpty) return;
    final handled = <String>{};
    for (final entry in entries) {
      final parts = entry.split('|');
      if (parts.length != 3) {
        handled.add(entry); // malformed → drop
        continue;
      }
      if (parts[0] != businessId) continue;
      final file = await _copyFile(parts[1], parts[2]);
      if (!file.existsSync()) {
        handled.add(entry);
        continue;
      }
      try {
        if (isLiveProduct != null && !await isLiveProduct(parts[1])) {
          handled.add(entry);
          continue;
        }
        await _upload(
          objectPath(parts[0], parts[1], parts[2]),
          await file.readAsBytes(),
        );
        handled.add(entry);
      } catch (_) {
        // Still offline / failed — retry next reconnect.
      }
    }
    // Re-read so an entry added while the uploads ran isn't lost.
    final latest = prefs.getStringList(_pendingKey) ?? const <String>[];
    await prefs.setStringList(
      _pendingKey,
      latest.where((e) => !handled.contains(e)).toList(),
    );
  }

  /// How many of [businessId]'s gallery photos still wait to upload: copy
  /// still on the phone and product still live (the rule [flushPending]
  /// uploads by).
  Future<int> pendingCount(
    String businessId, {
    required Future<bool> Function(String productId) isLiveProduct,
    Directory? documents,
  }) async {
    final waiting = await LocalPhotoFiles.pendingGalleryUploads(
      businessId,
      documents: documents,
    );
    var live = 0;
    for (final w in waiting) {
      if (await isLiveProduct(w.productId)) live++;
    }
    return live;
  }

  Future<bool> isPending(String url) async {
    final ref = parseUrl(url);
    if (ref == null) return false;
    try {
      final prefs = await SharedPreferences.getInstance();
      return (prefs.getStringList(_pendingKey) ?? const <String>[])
          .contains('${ref.businessId}|${ref.productId}|${ref.photoId}');
    } catch (_) {
      return false;
    }
  }

  Future<void> _setPending(String entry, {required bool pending}) async {
    final prefs = await SharedPreferences.getInstance();
    final entries = (prefs.getStringList(_pendingKey) ?? const <String>[])
        .where((e) => e != entry)
        .toList();
    if (pending) entries.add(entry);
    await prefs.setStringList(_pendingKey, entries);
  }

  // ── Device copy ───────────────────────────────────────────────────────────

  /// A local path that shows the photo at [url]: the device copy when there
  /// is one, else downloaded once and kept. Null when it can't be shown (not
  /// a gallery url, or offline with no copy).
  Future<String?> ensureCached(String url) async {
    final ref = parseUrl(url);
    if (ref == null) return null;
    final file = await _copyFile(ref.productId, ref.photoId);
    if (file.existsSync()) return file.path;
    final bytes =
        await _download(objectPath(ref.businessId, ref.productId, ref.photoId));
    if (bytes == null || bytes.isEmpty) return null;
    try {
      await file.parent.create(recursive: true);
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsBytes(bytes, flush: true);
      await tmp.rename(file.path);
      return file.path;
    } catch (_) {
      return null;
    }
  }
}
