import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/painting.dart' show FileImage;
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:reebaplus_pos/core/result.dart';
import 'package:reebaplus_pos/core/services/local_photo_files.dart';
import 'package:reebaplus_pos/core/services/photo_encoding.dart';
import 'package:reebaplus_pos/core/services/product_photo_cache.dart';

/// Sanctioned direct-Supabase exception (#78, PRD #76): product photos go to
/// Supabase Storage (not the outbox) because Storage objects are not tenant
/// rows and have no Drift equivalent — same carve-out as [BusinessLogoService],
/// documented in architecture.md. Only the resulting public URL rides sync
/// (products.image_url); the bytes live in Storage + a device copy.
///
/// Public bucket: `product-images`
///   - Object path: `<businessId>/<productId>.jpg` (JPEG, #340; photos saved
///     before #340 are `<productId>.png`). The first folder segment is the
///     owning business, so the storage RLS can gate writes on
///     `current_user_business_ids()` (see migration 0144).
///   - The url written to products.image_url carries `?v=<millis>` (#340): the
///     object name never changes when a photo is replaced, so the version is
///     what tells other phones their copy is out of date ([ProductPhotoCache]).
///   - Read policy: public (getPublicUrl renders cross-device; offline render
///     comes from the device copy).
///   - Write policy: authenticated members of the business.
class ProductImageService {
  ProductImageService(this._client) {
    _cache = ProductPhotoCache(
      directory: LocalPhotoFiles.productImagesDir,
      download: _downloadBytes,
      isPendingUpload: _isPending,
      onFileReplaced: _evictFromImageCache,
    );
  }

  final SupabaseClient _client;
  late final ProductPhotoCache _cache;

  static const _bucket = 'product-images';
  // Products get a larger cap than the 512px logo — staff recognise items by
  // the photo.
  static const _maxDimension = 800;

  /// Device-local set of `<businessId>|<productId>` whose device copy is
  /// written but whose Storage upload hasn't succeeded yet (saved offline).
  /// Flushed on reconnect by [flushPending]. Survives restart
  /// (SharedPreferences); cleared by the logout wipe.
  static const _pendingKey = LocalPhotoFiles.pendingProductUploadsKey;

  // ── Pick + resize ──────────────────────────────────────────────────────────

  /// Opens the image picker (gallery), decodes, and returns a ≤800×800 JPEG
  /// (transparency flattened onto white). Returns [Result.err] if the user
  /// cancels or the image can't be decoded.
  Future<Result<Uint8List, AppError>> pickAndProcess({
    ImageSource source = ImageSource.gallery,
  }) async {
    try {
      final picker = ImagePicker();
      final picked = await picker.pickImage(source: source, imageQuality: 90);
      if (picked == null) return Result.err(AppError.cancelled());

      return processBytes(await picked.readAsBytes());
    } catch (e) {
      return Result.err(AppError.unknown(e));
    }
  }

  /// Decodes [raw] and runs it through the same [_encode] step as a picked
  /// photo (≤800px JPEG). For a photo that did not come from the picker (the
  /// shared barcode catalogue's suggestion, #332), so it is held and saved as
  /// the shop's own photo. Returns [Result.err] if [raw] can't be decoded.
  Result<Uint8List, AppError> processBytes(Uint8List raw) {
    try {
      final decoded = img.decodeImage(raw);
      if (decoded == null) {
        return Result.err(AppError.io('Could not decode image.'));
      }
      return Result.ok(_encode(decoded));
    } catch (e) {
      return Result.err(AppError.unknown(e));
    }
  }

  /// The one encode step every product photo goes through before it is saved:
  /// ≤800px, flattened onto white, JPEG at [kPhotoJpegQuality].
  Uint8List _encode(img.Image decoded) =>
      encodePhotoJpeg(decoded, maxDimension: _maxDimension);

  // ── Save (local + cloud) ───────────────────────────────────────────────────

  /// Writes [bytes] to the device copy immediately (so the photo renders even
  /// offline), then uploads to Storage and returns the public URL. The caller
  /// writes that URL onto the product row (which syncs). The product is marked
  /// pending before the upload and unmarked once it lands, so an upload that
  /// fails (offline) or never finishes (app killed) is retried by
  /// [flushPending]; on failure [Result.err] is returned.
  Future<Result<String, AppError>> save({
    required String businessId,
    required String productId,
    required Uint8List bytes,
  }) async {
    // (a) Device copy first — gives instant + offline render.
    try {
      await _cache.writeLocal(productId, bytes);
    } catch (e) {
      return Result.err(AppError.io('Could not cache image locally.'));
    }

    // (b) Upload to Storage.
    try {
      await _markPending(businessId, productId);
      final url = await _upload(businessId, productId, bytes);
      await _cache.recordUrl(productId, url);
      await _unmarkPending(productId);
      return Result.ok(url);
    } on StorageException catch (e) {
      return Result.err(AppError.network('Storage upload failed: ${e.message}'));
    } catch (e) {
      return Result.err(AppError.unknown(e));
    }
  }

  /// Uploads JPEG [bytes] to `<businessId>/<productId>.jpg` and returns its
  /// versioned public URL. A photo saved before #340 lived at `.png`; once the
  /// `.jpg` is up that old object is removed in the background (best effort —
  /// it never blocks or fails the save).
  Future<String> _upload(
    String businessId,
    String productId,
    Uint8List bytes,
  ) async {
    final objectPath = _objectPath(businessId, productId);
    await _client.storage.from(_bucket).uploadBinary(
          objectPath,
          bytes,
          fileOptions: const FileOptions(upsert: true, contentType: 'image/jpeg'),
        );
    unawaited(_removeQuietly(_legacyObjectPath(businessId, productId)));
    return versionedUrl(
      _client.storage.from(_bucket).getPublicUrl(objectPath),
      DateTime.now().millisecondsSinceEpoch,
    );
  }

  Future<void> _removeQuietly(String objectPath) async {
    try {
      await _client.storage.from(_bucket).remove([objectPath]);
    } catch (_) {}
  }

  // ── Offline retry ───────────────────────────────────────────────────────────

  /// Uploads any photos saved offline for [businessId] and reports each public
  /// URL back via [onUploaded] (which writes it onto the product row so it
  /// syncs). Only entries for [businessId] are handled — the DAO patch is
  /// business-scoped, so another business's pending uploads wait until it is
  /// the active one. Failed uploads stay pending for the next reconnect.
  ///
  /// A photo saved offline before #340 is still PNG on disk: it is re-encoded
  /// to JPEG here so it uploads like any new photo (and fits the 1 MB bucket
  /// limit).
  ///
  /// [isLiveProduct], when given, drops an entry whose product no longer
  /// exists (deleted since the photo was saved) instead of uploading a photo
  /// nobody will see — the same rule the logout gate counts by (#343).
  Future<void> flushPending(
    String businessId,
    Future<void> Function(String productId, String url) onUploaded, {
    Future<bool> Function(String productId)? isLiveProduct,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final entries = prefs.getStringList(_pendingKey) ?? const <String>[];
    if (entries.isEmpty) return;

    final keep = <String>[];
    for (final entry in entries) {
      final sep = entry.indexOf('|');
      if (sep <= 0) continue; // malformed → drop
      final entryBiz = entry.substring(0, sep);
      final productId = entry.substring(sep + 1);
      if (entryBiz != businessId) {
        keep.add(entry); // not this business — leave for when it's active
        continue;
      }
      final file = File(await _cache.pathFor(productId));
      if (!file.existsSync()) continue; // copy gone → nothing to upload, drop
      try {
        if (isLiveProduct != null && !await isLiveProduct(productId)) {
          continue; // product deleted → nothing to show it on, drop
        }
        final bytes = jpegForUpload(await file.readAsBytes(), _maxDimension);
        final url = await _upload(entryBiz, productId, bytes);
        await _cache.recordUrl(productId, url);
        await onUploaded(productId, url);
      } catch (_) {
        keep.add(entry); // still offline / failed — retry next reconnect
      }
    }
    // Re-read so an entry added while the uploads ran isn't lost.
    final latest = prefs.getStringList(_pendingKey) ?? const <String>[];
    final handled = entries.toSet()..removeAll(keep);
    await prefs.setStringList(
      _pendingKey,
      latest.where((e) => !handled.contains(e)).toList(),
    );
  }

  Future<bool> _isPending(String productId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final entries = prefs.getStringList(_pendingKey) ?? const <String>[];
      return entries.any((e) => e.endsWith('|$productId'));
    } catch (_) {
      return false;
    }
  }

  Future<void> _markPending(String businessId, String productId) async {
    final prefs = await SharedPreferences.getInstance();
    final entries = (prefs.getStringList(_pendingKey) ?? const <String>[])
        .where((e) => !e.endsWith('|$productId'))
        .toList()
      ..add('$businessId|$productId');
    await prefs.setStringList(_pendingKey, entries);
  }

  Future<void> _unmarkPending(String productId) async {
    final prefs = await SharedPreferences.getInstance();
    final entries = prefs.getStringList(_pendingKey);
    if (entries == null || entries.isEmpty) return;
    final next = entries.where((e) => !e.endsWith('|$productId')).toList();
    if (next.length != entries.length) {
      await prefs.setStringList(_pendingKey, next);
    }
  }

  // ── Device copy ────────────────────────────────────────────────────────────

  /// The device-copy path for [productId] — does not check whether the file
  /// exists. Stable per product (see [ProductPhotoCache]).
  Future<String> localPathFor(String productId) => _cache.pathFor(productId);

  /// Returns a local path that shows the photo at [imageUrl]. Downloads only
  /// when this phone has no copy, or its copy is of a different `image_url`
  /// (the photo was changed on another phone); an unchanged photo is never
  /// downloaded again. Returns null if there is nothing to show (e.g. offline
  /// with no copy).
  Future<String?> ensureCached({
    required String productId,
    required String? imageUrl,
  }) =>
      _cache.resolve(productId: productId, imageUrl: imageUrl);

  Future<Uint8List?> _downloadBytes(String imageUrl) async {
    // Prefer the authenticated Storage client (by object path) so a member can
    // fetch even if the public URL is unreachable; null on any failure.
    final objectPath = storageObjectPathFromPublicUrl(imageUrl, _bucket);
    if (objectPath == null) return null;
    try {
      return await _client.storage.from(_bucket).download(objectPath);
    } catch (_) {
      return null;
    }
  }

  /// A replaced file keeps its path, so drop Flutter's decoded copy or
  /// `Image.file` keeps painting the old photo for the rest of the session.
  static void _evictFromImageCache(String path) {
    try {
      unawaited(FileImage(File(path)).evict().catchError((_) => false));
    } catch (_) {}
  }

  // ── Clear ──────────────────────────────────────────────────────────────────

  /// Deletes the device copy and the Storage object (both the `.jpg` and a
  /// pre-#340 `.png`).
  Future<Result<void, AppError>> clear({
    required String businessId,
    required String productId,
  }) async {
    try {
      await _cache.remove(productId);
      await _unmarkPending(productId);

      await _client.storage.from(_bucket).remove([
        _objectPath(businessId, productId),
        _legacyObjectPath(businessId, productId),
      ]);
      return Result.ok(null);
    } on StorageException catch (e) {
      return Result.err(AppError.network('Storage delete failed: ${e.message}'));
    } catch (e) {
      return Result.err(AppError.unknown(e));
    }
  }

  // ── Internals ──────────────────────────────────────────────────────────────

  String _objectPath(String businessId, String productId) =>
      '$businessId/$productId.jpg';

  String _legacyObjectPath(String businessId, String productId) =>
      '$businessId/$productId.png';

  /// [publicUrl] with `v=<version>` so each saved photo has its own url.
  @visibleForTesting
  static String versionedUrl(String publicUrl, int version) {
    final uri = Uri.parse(publicUrl);
    return uri.replace(
      queryParameters: {...uri.queryParameters, 'v': '$version'},
    ).toString();
  }

  /// Bytes ready to upload as `.jpg`: JPEG passes through; a pre-#340 PNG is
  /// re-encoded (≤[maxDimension], flattened, JPEG). Throws if a PNG can't be
  /// decoded, which leaves the upload pending.
  @visibleForTesting
  static Uint8List jpegForUpload(Uint8List bytes, int maxDimension) {
    if (!looksLikePng(bytes)) return bytes;
    final decoded = img.decodePng(bytes);
    if (decoded == null) {
      throw const FormatException('Pending product photo is not a valid PNG.');
    }
    return encodePhotoJpeg(decoded, maxDimension: maxDimension);
  }
}
