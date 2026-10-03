import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:reebaplus_pos/core/services/local_photo_files.dart';
import 'package:reebaplus_pos/core/services/product_photo_cache.dart';

const _urlA = 'https://x/storage/v1/object/public/product-images/b/p.jpg?v=1';
const _urlB = 'https://x/storage/v1/object/public/product-images/b/p.jpg?v=2';

Uint8List _bytes(int fill) => Uint8List.fromList(List.filled(16, fill));

void main() {
  late Directory tmp;
  late Directory dir;
  late List<String> downloads;
  late Map<String, Uint8List?> remote;
  late Set<String> pending;
  late List<String> evicted;
  late ProductPhotoCache cache;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('photo_cache_test');
    dir = Directory('${tmp.path}/product_images');
    downloads = [];
    remote = {_urlA: _bytes(1), _urlB: _bytes(2)};
    pending = {};
    evicted = [];
    cache = ProductPhotoCache(
      directory: () async => dir,
      download: (url) async {
        downloads.add(url);
        return remote[url];
      },
      isPendingUpload: (id) async => pending.contains(id),
      onFileReplaced: evicted.add,
    );
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  Future<List<int>> onDisk(String path) => File(path).readAsBytes();

  test('no copy → downloads once, then the same url never downloads again',
      () async {
    final path = await cache.resolve(productId: 'p', imageUrl: _urlA);
    expect(downloads, [_urlA]);
    expect(await onDisk(path!), _bytes(1));

    await cache.resolve(productId: 'p', imageUrl: _urlA);
    await cache.resolve(productId: 'p', imageUrl: _urlA);
    expect(downloads, [_urlA]);
  });

  test('changed url (photo changed on another phone) → one download, file '
      'replaced at the same path', () async {
    final first = await cache.resolve(productId: 'p', imageUrl: _urlA);

    final second = await cache.resolve(productId: 'p', imageUrl: _urlB);
    await cache.resolve(productId: 'p', imageUrl: _urlB);

    expect(downloads, [_urlA, _urlB]);
    expect(second, first, reason: 'path is stable (products.image_path)');
    expect(await onDisk(second!), _bytes(2));
    expect(await cache.recordedUrl('p'), _urlB);
    expect(evicted, contains(second));
  });

  test('two lookups at once share one download', () async {
    final results = await Future.wait([
      cache.resolve(productId: 'p', imageUrl: _urlA),
      cache.resolve(productId: 'p', imageUrl: _urlA),
    ]);
    expect(downloads, [_urlA]);
    expect(results[0], results[1]);
  });

  test('photo saved here, not uploaded yet → local copy wins, no download',
      () async {
    await cache.resolve(productId: 'p', imageUrl: _urlA);
    await cache.writeLocal('p', _bytes(9));
    pending.add('p');

    final path = await cache.resolve(productId: 'p', imageUrl: _urlA);

    expect(downloads, [_urlA]);
    expect(await onDisk(path!), _bytes(9));
  });

  test('uploaded photo recorded under its url is not downloaded back',
      () async {
    await cache.writeLocal('p', _bytes(9));
    await cache.recordUrl('p', _urlB);

    final path = await cache.resolve(productId: 'p', imageUrl: _urlB);

    expect(downloads, isEmpty);
    expect(await onDisk(path!), _bytes(9));
  });

  test('copy from before #340 (no url record) is adopted, not re-downloaded',
      () async {
    dir.createSync(recursive: true);
    final legacy = File('${dir.path}/p.png')..writeAsBytesSync(_bytes(7));
    const legacyUrl =
        'https://x/storage/v1/object/public/product-images/b/p.png';

    final path = await cache.resolve(productId: 'p', imageUrl: legacyUrl);

    expect(path, legacy.path);
    expect(downloads, isEmpty);
    expect(await cache.recordedUrl('p'), legacyUrl);

    // …and once another phone saves a new photo, it refreshes.
    await cache.resolve(productId: 'p', imageUrl: _urlB);
    expect(downloads, [_urlB]);
  });

  test('download fails (offline) → the old copy still shows', () async {
    final old = await cache.resolve(productId: 'p', imageUrl: _urlA);
    remote[_urlB] = null;

    final path = await cache.resolve(productId: 'p', imageUrl: _urlB);

    expect(path, old);
    expect(await onDisk(path!), _bytes(1));
    expect(await cache.recordedUrl('p'), _urlA,
        reason: 'stays stale so the next look retries');
  });

  test('offline with no copy → null', () async {
    remote[_urlA] = null;
    expect(await cache.resolve(productId: 'p', imageUrl: _urlA), isNull);
  });

  test('no url → whatever is on the phone, never a download', () async {
    expect(await cache.resolve(productId: 'p', imageUrl: null), isNull);
    final local = await cache.writeLocal('p', _bytes(3));
    expect(await cache.resolve(productId: 'p', imageUrl: null), local);
    expect(downloads, isEmpty);
  });

  test('remove deletes the copy and its record', () async {
    final path = await cache.resolve(productId: 'p', imageUrl: _urlA);
    await cache.remove('p');
    expect(File(path!).existsSync(), isFalse);
    expect(await cache.recordedUrl('p'), isNull);
  });

  test('logout wipe deletes product_images/, business_logos/ and the pending '
      'list', () async {
    SharedPreferences.setMockInitialValues({
      LocalPhotoFiles.pendingProductUploadsKey: ['b|p'],
    });
    await cache.resolve(productId: 'p', imageUrl: _urlA);
    final logos = Directory('${tmp.path}/business_logos')..createSync();
    File('${logos.path}/b.png').writeAsBytesSync(_bytes(5));

    await LocalPhotoFiles.deleteAll(documents: tmp);

    expect(dir.existsSync(), isFalse);
    expect(logos.existsSync(), isFalse);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getStringList(LocalPhotoFiles.pendingProductUploadsKey),
        isNull);
  });
}
