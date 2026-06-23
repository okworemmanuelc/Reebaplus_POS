import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:reebaplus_pos/core/result.dart';

/// Sanctioned direct-Supabase exception: logo uploads go to Supabase Storage
/// (not the outbox) because Storage objects are not tenant rows and have no
/// Drift equivalent. Documented alongside redeem_invite_code and Sync Issues
/// in architecture.md.
///
/// Public bucket: `business-logos`
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

  /// Opens the image picker (gallery), decodes, resizes to ≤512×512 PNG.
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
      final objectPath = '$businessId.png';
      await _client.storage.from(_bucket).uploadBinary(
            objectPath,
            bytes,
            fileOptions: const FileOptions(
              upsert: true,
              contentType: 'image/png',
            ),
          );

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
      final objectPath = '$businessId.png';
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

      await _client.storage.from(_bucket).remove(['$businessId.png']);
      return Result.ok(null);
    } on StorageException catch (e) {
      return Result.err(AppError.network('Storage delete failed: ${e.message}'));
    } catch (e) {
      return Result.err(AppError.unknown(e));
    }
  }

  // ── Internals ──────────────────────────────────────────────────────────────

  Future<String> _localPath(String businessId) async {
    final docs = await getApplicationDocumentsDirectory();
    return '${docs.path}/business_logos/$businessId.png';
  }
}
