import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:reebaplus_pos/core/result.dart';

/// Sanctioned direct-Supabase exception (#78, PRD #76): product photos go to
/// Supabase Storage (not the outbox) because Storage objects are not tenant
/// rows and have no Drift equivalent — same carve-out as [BusinessLogoService],
/// documented in architecture.md. Only the resulting public URL rides sync
/// (products.image_url); the bytes live in Storage + a local file cache.
///
/// Public bucket: `product-images`
///   - Object path: `<businessId>/<productId>.png` — the first folder segment
///     is the owning business, so the storage RLS can gate writes on
///     `current_user_business_ids()` (see migration 0144).
///   - Read policy: public (getPublicUrl renders cross-device; offline render
///     comes from the local cache below).
///   - Write policy: authenticated members of the business.
class ProductImageService {
  ProductImageService(this._client);

  final SupabaseClient _client;

  static const _bucket = 'product-images';
  // Products get a larger cap than the 512px logo — staff recognise items by
  // the photo, and the POS/inventory still never render it (detail screen only).
  static const _maxDimension = 800;

  /// Device-local set of `<businessId>|<productId>` whose local cache is written
  /// but whose Storage upload hasn't succeeded yet (saved offline). Flushed on
  /// reconnect by [flushPending]. Survives restart (SharedPreferences).
  static const _pendingKey = 'pending_product_image_uploads';

  // ── Pick + resize ──────────────────────────────────────────────────────────

  /// Opens the image picker (gallery), decodes, resizes to ≤800×800 PNG.
  /// Returns [Result.err] if the user cancels or the image can't be decoded.
  Future<Result<Uint8List, AppError>> pickAndProcess({
    ImageSource source = ImageSource.gallery,
  }) async {
    try {
      final picker = ImagePicker();
      final picked = await picker.pickImage(source: source, imageQuality: 90);
      if (picked == null) return Result.err(AppError.cancelled());

      final rawBytes = await picked.readAsBytes();
      final decoded = img.decodeImage(rawBytes);
      if (decoded == null) {
        return Result.err(AppError.io('Could not decode image.'));
      }

      final resized = _resize(decoded);
      final pngBytes = Uint8List.fromList(img.encodePng(resized));
      return Result.ok(pngBytes);
    } catch (e) {
      return Result.err(AppError.unknown(e));
    }
  }

  img.Image _resize(img.Image src) {
    if (src.width <= _maxDimension && src.height <= _maxDimension) return src;
    final ratio = src.width > src.height
        ? _maxDimension / src.width
        : _maxDimension / src.height;
    return img.copyResize(
      src,
      width: (src.width * ratio).round(),
      height: (src.height * ratio).round(),
      interpolation: img.Interpolation.linear,
    );
  }

  // ── Save (local + cloud) ───────────────────────────────────────────────────

  /// Writes [bytes] to the local cache immediately (so the photo renders even
  /// offline), then uploads to Storage and returns the public URL. The caller
  /// writes that URL onto the product row (which syncs). On upload failure the
  /// local cache is still written and [Result.err] is returned, so the caller
  /// can mark the product for a later retry.
  Future<Result<String, AppError>> save({
    required String businessId,
    required String productId,
    required Uint8List bytes,
  }) async {
    // (a) Local cache first — always succeeds, gives instant + offline render.
    try {
      final path = await _localPath(productId);
      await File(path).parent.create(recursive: true);
      await File(path).writeAsBytes(bytes, flush: true);
    } catch (e) {
      return Result.err(AppError.io('Could not cache image locally.'));
    }

    // (b) Upload to Storage. On failure (offline), the local cache still
    // renders and the product is marked pending so [flushPending] retries it
    // when connectivity returns.
    try {
      final url = await _upload(businessId, productId, bytes);
      await _unmarkPending(productId);
      return Result.ok(url);
    } on StorageException catch (e) {
      await _markPending(businessId, productId);
      return Result.err(AppError.network('Storage upload failed: ${e.message}'));
    } catch (e) {
      await _markPending(businessId, productId);
      return Result.err(AppError.unknown(e));
    }
  }

  Future<String> _upload(
    String businessId,
    String productId,
    Uint8List bytes,
  ) async {
    final objectPath = _objectPath(businessId, productId);
    await _client.storage.from(_bucket).uploadBinary(
          objectPath,
          bytes,
          fileOptions: const FileOptions(upsert: true, contentType: 'image/png'),
        );
    return _client.storage.from(_bucket).getPublicUrl(objectPath);
  }

  // ── Offline retry ───────────────────────────────────────────────────────────

  /// Uploads any photos saved offline for [businessId] and reports each public
  /// URL back via [onUploaded] (which writes it onto the product row so it
  /// syncs). Only entries for [businessId] are handled — the DAO patch is
  /// business-scoped, so another business's pending uploads wait until it is
  /// the active one. Failed uploads stay pending for the next reconnect.
  Future<void> flushPending(
    String businessId,
    Future<void> Function(String productId, String url) onUploaded,
  ) async {
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
      final file = File(await _localPath(productId));
      if (!file.existsSync()) continue; // cache gone → nothing to upload, drop
      try {
        final url = await _upload(entryBiz, productId, await file.readAsBytes());
        await onUploaded(productId, url);
      } catch (_) {
        keep.add(entry); // still offline / failed — retry next reconnect
      }
    }
    await prefs.setStringList(_pendingKey, keep);
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

  // ── Local cache helpers ────────────────────────────────────────────────────

  /// Returns the expected local file path for [productId] — does not check
  /// whether the file exists.
  Future<String> localPathFor(String productId) => _localPath(productId);

  /// Returns the local file path, downloading from [imageUrl] once if the local
  /// cache is absent. Returns null if neither the local cache nor the URL
  /// yields an image (e.g. offline with no cache).
  Future<String?> ensureCached({
    required String productId,
    required String? imageUrl,
  }) async {
    final path = await _localPath(productId);
    if (File(path).existsSync()) return path;
    if (imageUrl == null || imageUrl.isEmpty) return null;

    try {
      await File(path).parent.create(recursive: true);
      final bytes = await _downloadBytes(imageUrl);
      if (bytes == null) return null;
      await File(path).writeAsBytes(bytes, flush: true);
      return path;
    } catch (_) {
      return null;
    }
  }

  Future<Uint8List?> _downloadBytes(String imageUrl) async {
    // A public-bucket URL embeds the object path after `/object/public/<bucket>/`.
    // Prefer the authenticated Storage client so a member can fetch even if the
    // public URL is unreachable; fall back to null on any failure.
    const marker = '/object/public/$_bucket/';
    final idx = imageUrl.indexOf(marker);
    if (idx == -1) return null;
    final objectPath = imageUrl.substring(idx + marker.length);
    try {
      return await _client.storage.from(_bucket).download(objectPath);
    } catch (_) {
      return null;
    }
  }

  // ── Clear ──────────────────────────────────────────────────────────────────

  /// Deletes the local cache file and the Storage object.
  Future<Result<void, AppError>> clear({
    required String businessId,
    required String productId,
  }) async {
    try {
      final path = await _localPath(productId);
      final file = File(path);
      if (file.existsSync()) await file.delete();

      await _client.storage
          .from(_bucket)
          .remove([_objectPath(businessId, productId)]);
      return Result.ok(null);
    } on StorageException catch (e) {
      return Result.err(AppError.network('Storage delete failed: ${e.message}'));
    } catch (e) {
      return Result.err(AppError.unknown(e));
    }
  }

  // ── Internals ──────────────────────────────────────────────────────────────

  String _objectPath(String businessId, String productId) =>
      '$businessId/$productId.png';

  Future<String> _localPath(String productId) async {
    final docs = await getApplicationDocumentsDirectory();
    return '${docs.path}/product_images/$productId.png';
  }
}
