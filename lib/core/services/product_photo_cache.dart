import 'dart:io';
import 'dart:typed_data';

/// The device copy of each product photo, tied to the `image_url` it came from
/// (#340).
///
/// **File name stays `<productId>.png`.** `products.image_path` is synced and
/// can hold this absolute path (the POS / Receive Stock grids render it with
/// `Image.file`), so renaming the file would blank photos on upgraded phones.
/// The bytes inside are JPEG from #340 on; image decoders read the content, not
/// the extension.
///
/// **Which photo the file holds** is recorded beside it in `<productId>.url`
/// (the exact `image_url` it was downloaded for, or uploaded as). The rule:
///
/// - file + record match the product's `image_url` → use it, never download;
/// - a different `image_url` (another phone changed the photo) → download it
///   once, replace the file, record the new url;
/// - a photo saved on this phone but not uploaded yet (pending) → always the
///   local file — it is newer than any url;
/// - a file with no record (written before #340) → adopted as the copy of the
///   current url, so upgrading never re-downloads every photo;
/// - download fails (offline) → the old file if there is one, so the photo
///   still shows.
///
/// Pure `dart:io` with injected seams, so tests run it against a temp folder
/// with a fake downloader.
class ProductPhotoCache {
  ProductPhotoCache({
    required Future<Directory> Function() directory,
    required Future<Uint8List?> Function(String imageUrl) download,
    required Future<bool> Function(String productId) isPendingUpload,
    void Function(String path)? onFileReplaced,
  })  : _directory = directory,
        _download = download,
        _isPendingUpload = isPendingUpload,
        _onFileReplaced = onFileReplaced;

  final Future<Directory> Function() _directory;
  final Future<Uint8List?> Function(String imageUrl) _download;
  final Future<bool> Function(String productId) _isPendingUpload;
  final void Function(String path)? _onFileReplaced;

  /// One download per (product, url) at a time — the details screen and the
  /// edit sheet can ask for the same photo together.
  final Map<String, Future<String?>> _inFlight = {};

  /// The device-copy path for [productId] (whether or not it exists yet).
  Future<String> pathFor(String productId) async {
    final dir = await _directory();
    return '${dir.path}/$productId.png';
  }

  Future<File> _recordFile(String productId) async {
    final dir = await _directory();
    return File('${dir.path}/$productId.url');
  }

  /// The `image_url` the device copy was saved for, or null when unknown.
  Future<String?> recordedUrl(String productId) async {
    final f = await _recordFile(productId);
    if (!f.existsSync()) return null;
    try {
      final v = (await f.readAsString()).trim();
      return v.isEmpty ? null : v;
    } catch (_) {
      return null;
    }
  }

  /// Notes that the device copy of [productId] is the photo at [imageUrl].
  Future<void> recordUrl(String productId, String imageUrl) async {
    final f = await _recordFile(productId);
    await f.parent.create(recursive: true);
    await f.writeAsString(imageUrl, flush: true);
  }

  /// Writes a photo picked on this phone. The url record is dropped: the file
  /// now holds a photo that has no uploaded url yet.
  Future<String> writeLocal(String productId, Uint8List bytes) async {
    final rec = await _recordFile(productId);
    if (rec.existsSync()) await rec.delete();
    return _writeFile(productId, bytes);
  }

  /// Returns a path that renders the photo for [imageUrl], downloading it only
  /// when the device copy is missing or holds a different photo. See the class
  /// doc for the full rule. Null when there is nothing to show.
  Future<String?> resolve({
    required String productId,
    required String? imageUrl,
  }) async {
    final path = await pathFor(productId);
    final file = File(path);
    final hasFile = file.existsSync();

    // No url: keep today's behaviour — whatever is on the phone (a photo saved
    // here and not uploaded yet, or nothing).
    if (imageUrl == null || imageUrl.isEmpty) return hasFile ? path : null;

    if (hasFile) {
      if (await _isPendingUpload(productId)) return path;
      final recorded = await recordedUrl(productId);
      if (recorded == imageUrl) return path;
      if (recorded == null) {
        // Copy from before #340: adopt it rather than re-download every photo.
        await recordUrl(productId, imageUrl);
        return path;
      }
    }

    final key = '$productId|$imageUrl';
    final running = _inFlight[key];
    if (running != null) return running;
    final job = _fetch(productId, imageUrl, fallback: hasFile ? path : null);
    _inFlight[key] = job;
    try {
      return await job;
    } finally {
      _inFlight.remove(key);
    }
  }

  Future<String?> _fetch(
    String productId,
    String imageUrl, {
    required String? fallback,
  }) async {
    try {
      final bytes = await _download(imageUrl);
      if (bytes == null || bytes.isEmpty) return fallback;
      // A photo picked here while the download ran wins over the download.
      if (await _isPendingUpload(productId)) return fallback;
      final path = await _writeFile(productId, bytes);
      await recordUrl(productId, imageUrl);
      return path;
    } catch (_) {
      return fallback;
    }
  }

  /// Deletes the device copy of [productId] and its url record.
  Future<void> remove(String productId) async {
    final file = File(await pathFor(productId));
    if (file.existsSync()) await file.delete();
    final rec = await _recordFile(productId);
    if (rec.existsSync()) await rec.delete();
    _onFileReplaced?.call(file.path);
  }

  /// Write to a temp file then rename, so a half-written download never
  /// replaces a good photo.
  Future<String> _writeFile(String productId, Uint8List bytes) async {
    final path = await pathFor(productId);
    final tmp = File('$path.tmp');
    await tmp.parent.create(recursive: true);
    await tmp.writeAsBytes(bytes, flush: true);
    await tmp.rename(path);
    _onFileReplaced?.call(path);
    return path;
  }
}
