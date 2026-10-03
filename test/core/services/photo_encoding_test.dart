import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:reebaplus_pos/core/services/photo_encoding.dart';
import 'package:reebaplus_pos/core/services/product_image_service.dart';

bool _isJpeg(Uint8List b) =>
    b.length > 3 && b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF;

void main() {
  group('encodePhotoJpeg (#340)', () {
    test('outputs a JPEG, longest side capped at 800, aspect kept', () {
      final src = img.Image(width: 2000, height: 1000);
      img.fill(src, color: img.ColorRgb8(200, 30, 30));

      final out = encodePhotoJpeg(src, maxDimension: 800);

      expect(_isJpeg(out), isTrue);
      final decoded = img.decodeJpg(out)!;
      expect(decoded.width, 800);
      expect(decoded.height, 400);
    });

    test('portrait photo: height capped at 800', () {
      final src = img.Image(width: 900, height: 1800);
      final decoded = img.decodeJpg(encodePhotoJpeg(src, maxDimension: 800))!;
      expect(decoded.height, 800);
      expect(decoded.width, 400);
    });

    test('a small image is not enlarged', () {
      final src = img.Image(width: 300, height: 200);
      final decoded = img.decodeJpg(encodePhotoJpeg(src, maxDimension: 800))!;
      expect(decoded.width, 300);
      expect(decoded.height, 200);
    });

    test('logo cap of 512 is honoured', () {
      final src = img.Image(width: 1024, height: 1024);
      final decoded = img.decodeJpg(encodePhotoJpeg(src, maxDimension: 512))!;
      expect(decoded.width, 512);
      expect(decoded.height, 512);
    });

    test('transparent pixels become white, opaque pixels keep colour', () {
      final src = img.Image(width: 64, height: 64, numChannels: 4);
      // Left half fully transparent (black underneath), right half opaque blue.
      for (final p in src) {
        if (p.x < 32) {
          p.setRgba(0, 0, 0, 0);
        } else {
          p.setRgba(0, 0, 255, 255);
        }
      }

      final decoded = img.decodeJpg(encodePhotoJpeg(src, maxDimension: 800))!;

      final clear = decoded.getPixel(8, 32);
      expect(clear.r, greaterThan(245));
      expect(clear.g, greaterThan(245));
      expect(clear.b, greaterThan(245));
      final solid = decoded.getPixel(56, 32);
      expect(solid.b, greaterThan(220));
      expect(solid.r, lessThan(40));
    });

    test('half-transparent pixels blend toward white', () {
      final src = img.Image(width: 4, height: 4, numChannels: 4);
      for (final p in src) {
        p.setRgba(0, 0, 0, 128);
      }
      final flat = flattenOntoWhite(src);
      expect(flat.numChannels, 3);
      final p = flat.getPixel(0, 0);
      expect(p.r, inInclusiveRange(125, 129));
    });
  });

  group('looksLikePng / jpegForUpload (offline uploads queued before #340)', () {
    test('a pre-#340 PNG is re-encoded to a ≤800px JPEG', () {
      final png = Uint8List.fromList(
        img.encodePng(img.Image(width: 1600, height: 1200)),
      );
      expect(looksLikePng(png), isTrue);

      final out = ProductImageService.jpegForUpload(png, 800);

      expect(_isJpeg(out), isTrue);
      final decoded = img.decodeJpg(out)!;
      expect(decoded.width, 800);
      expect(decoded.height, 600);
    });

    test('JPEG bytes pass through untouched', () {
      final jpg = encodePhotoJpeg(img.Image(width: 10, height: 10),
          maxDimension: 800);
      expect(looksLikePng(jpg), isFalse);
      expect(identical(ProductImageService.jpegForUpload(jpg, 800), jpg),
          isTrue);
    });
  });

  group('storage urls', () {
    const base = 'https://x.supabase.co/storage/v1/object/public/'
        'product-images/biz-1/prod-1.jpg';

    test('versionedUrl adds v= and a new version gives a new url', () {
      final a = ProductImageService.versionedUrl(base, 1);
      final b = ProductImageService.versionedUrl(base, 2);
      expect(a, '$base?v=1');
      expect(a, isNot(b));
    });

    test('object path ignores the ?v= query', () {
      expect(
        storageObjectPathFromPublicUrl('$base?v=123', 'product-images'),
        'biz-1/prod-1.jpg',
      );
      expect(
        storageObjectPathFromPublicUrl(
            base.replaceAll('.jpg', '.png'), 'product-images'),
        'biz-1/prod-1.png',
      );
      expect(storageObjectPathFromPublicUrl('https://x/p.png', 'product-images'),
          isNull);
    });
  });
}
