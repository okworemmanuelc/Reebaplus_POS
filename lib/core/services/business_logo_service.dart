import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:reebaplus_pos/core/result.dart';
import 'package:reebaplus_pos/core/services/local_photo_files.dart';
import 'package:reebaplus_pos/core/services/photo_encoding.dart';

/// Sanctioned direct-Supabase exception: logo uploads go to Supabase Storage
/// (not the outbox) because Storage objects are not tenant rows and have no
/// Drift equivalent. Documented alongside redeem_invite_code and Sync Issues
/// in architecture.md.
///
/// Public bucket: `business-logos`
///   - Object path: `<businessId>.jpg` (JPEG ≤512px, #340; logos saved before
///     #340 are `<businessId>.png`; a save leaves that object in place, #343 —
///     only [clear] removes it).
///   - Upload policy: authenticated user is a member of the business
///     whose `businessId` matches the file path prefix.
///   - Read policy: public (no auth required — receipts may load offline
///     cached file; cross-device download uses Storage client auth).
class BusinessLogoService {
  BusinessLogoService(this._client);

  final SupabaseClient _client;

  static const _bucket = 'business-logos';
  static const _maxDimension = 512;

  // ── Pick + resize ──────────────────────────────────────────────────────────

  /// Opens the image picker (gallery), decodes, and returns a ≤512×512 JPEG
  /// (transparency flattened onto white).
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

      return Result.ok(encodePhotoJpeg(decoded, maxDimension: _maxDimension));
    } catch (e) {
      return Result.err(AppError.unknown(e));
    }
  }

  // ── Save (local + cloud) ───────────────────────────────────────────────────

  /// Writes [bytes] to the local cache, uploads to Storage, and returns the
  /// public URL.
  Future<Result<String, AppError>> save({
    required String businessId,
    required Uint8List bytes,
  }) async {
    try {
      // (a) Local cache.
      final path = await _localPath(businessId);
      await File(path).parent.create(recursive: true);
      await File(path).writeAsBytes(bytes, flush: true);

      // (b) Upload to Storage.
      final objectPath = '$businessId.jpg';
      await _client.storage.from(_bucket).uploadBinary(
            objectPath,
            bytes,
            fileOptions: const FileOptions(
              upsert: true,
              contentType: 'image/jpeg',
            ),
          );
      // The pre-#340 `<businessId>.png` is deliberately NOT removed here
      // (#343): an older-version phone saving its PNG logo at the same moment
      // could otherwise end up with logoUrl pointing at a deleted object.

      // (c) Public URL.
      final url = _client.storage.from(_bucket).getPublicUrl(objectPath);
      return Result.ok(url);
    } on StorageException catch (e) {
      return Result.err(AppError.network('Storage upload failed: ${e.message}'));
    } catch (e) {
      return Result.err(AppError.unknown(e));
    }
  }

  // ── Local cache helpers ────────────────────────────────────────────────────

  /// Returns the expected local file path for [businessId] — does not
  /// check whether the file exists.
  Future<String> localPathFor(String businessId) => _localPath(businessId);

  /// Returns the local file path if the cached file exists, otherwise null.
  Future<String?> localPathIfExists(String businessId) async {
    final path = await _localPath(businessId);
    return File(path).existsSync() ? path : null;
  }

  /// Returns the local file path, downloading from [logoUrl] once if the
  /// local cache is absent. Returns null if neither local nor URL exists.
  Future<String?> ensureCached({
    required String businessId,
    required String? logoUrl,
  }) async {
    final path = await _localPath(businessId);
    if (File(path).existsSync()) return path;
    if (logoUrl == null || logoUrl.isEmpty) return null;

    // Download from Storage using the authenticated client.
    try {
      await File(path).parent.create(recursive: true);
      // The object behind the url: `.jpg` from #340, `.png` before it.
      final objectPath =
          storageObjectPathFromPublicUrl(logoUrl, _bucket) ??
              '$businessId.jpg';
      final bytes = await _client.storage.from(_bucket).download(objectPath);
      await File(path).writeAsBytes(bytes, flush: true);
      return path;
    } catch (_) {
      // Network unavailable or object missing — graceful null.
      return null;
    }
  }

  // ── Clear ──────────────────────────────────────────────────────────────────

  /// Deletes the local cache file and the Storage object.
  Future<Result<void, AppError>> clear(String businessId) async {
    try {
      final path = await _localPath(businessId);
      final file = File(path);
      if (file.existsSync()) await file.delete();

      await _client.storage
          .from(_bucket)
          .remove(['$businessId.jpg', '$businessId.png']);
      return Result.ok(null);
    } on StorageException catch (e) {
      return Result.err(AppError.network('Storage delete failed: ${e.message}'));
    } catch (e) {
      return Result.err(AppError.unknown(e));
    }
  }

  // ── Internals ──────────────────────────────────────────────────────────────

  // The device copy keeps its `.png` name across #340 (receipts decode the
  // content, not the extension). Wiped on logout by LocalPhotoFiles.deleteAll.
  Future<String> _localPath(String businessId) async {
    final dir = await LocalPhotoFiles.businessLogosDir();
    return '${dir.path}/$businessId.png';
  }
}
