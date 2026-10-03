// local_photo_files_test.dart
//
// #343. The two business-scoped helpers on LocalPhotoFiles:
//   * pendingUploadProductIds — which saved-offline photos can still upload
//     (the logout gate counts these), mirroring flushPending's rules.
//   * deleteForBusiness — clearing ONE business's photo copies, logo copy and
//     pending entries, leaving every other business's alone.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:reebaplus_pos/core/services/local_photo_files.dart';

const _key = LocalPhotoFiles.pendingProductUploadsKey;

void main() {
  late Directory docs;
  late Directory products;
  late Directory logos;

  setUp(() {
    docs = Directory.systemTemp.createTempSync('local_photo_files_test');
    products = Directory('${docs.path}/product_images')..createSync();
    logos = Directory('${docs.path}/business_logos')..createSync();
  });

  tearDown(() {
    if (docs.existsSync()) docs.deleteSync(recursive: true);
  });

  File photo(String productId) =>
      File('${products.path}/$productId.png')..writeAsBytesSync([1, 2, 3]);
  File record(String productId) =>
      File('${products.path}/$productId.url')..writeAsStringSync('u');
  File logo(String businessId) =>
      File('${logos.path}/$businessId.png')..writeAsBytesSync([4]);

  group('pendingUploadProductIds', () {
    test('lists only this business\'s entries whose copy is still there',
        () async {
      SharedPreferences.setMockInitialValues({
        _key: ['a|p1', 'a|gone', 'b|p2', 'malformed', '|p3', 'a|'],
      });
      photo('p1');
      photo('p2');

      expect(
        await LocalPhotoFiles.pendingUploadProductIds('a', documents: docs),
        ['p1'],
      );
      expect(
        await LocalPhotoFiles.pendingUploadProductIds('b', documents: docs),
        ['p2'],
      );
    });

    test('nothing waiting → empty', () async {
      SharedPreferences.setMockInitialValues({});
      expect(
        await LocalPhotoFiles.pendingUploadProductIds('a', documents: docs),
        isEmpty,
      );
    });
  });

  group('deleteForBusiness', () {
    test('removes that business\'s photo copies, logo and pending entries only',
        () async {
      SharedPreferences.setMockInitialValues({
        _key: ['old|p1', 'cur|p3'],
      });
      final oldPhoto = photo('p1');
      final oldRecord = record('p1');
      final oldPhoto2 = photo('p2');
      final oldLogo = logo('old');
      final curPhoto = photo('p3');
      final curRecord = record('p3');
      final curLogo = logo('cur');

      await LocalPhotoFiles.deleteForBusiness(
        businessId: 'old',
        productIds: ['p1', 'p2'],
        documents: docs,
      );

      expect(oldPhoto.existsSync(), isFalse);
      expect(oldRecord.existsSync(), isFalse);
      expect(oldPhoto2.existsSync(), isFalse);
      expect(oldLogo.existsSync(), isFalse);

      expect(curPhoto.existsSync(), isTrue);
      expect(curRecord.existsSync(), isTrue);
      expect(curLogo.existsSync(), isTrue);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getStringList(_key), ['cur|p3']);
    });

    test('missing files and folders are fine', () async {
      SharedPreferences.setMockInitialValues({});
      products.deleteSync(recursive: true);
      logos.deleteSync(recursive: true);

      await LocalPhotoFiles.deleteForBusiness(
        businessId: 'old',
        productIds: ['p1'],
        documents: docs,
      );
    });
  });
}
