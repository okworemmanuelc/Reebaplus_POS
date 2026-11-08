// #763: a picked product photo is shrunk by the engine's codec (decoded
// straight to the reduced size, turned upright from its EXIF) and JPEG-encoded
// on a background isolate, so a big phone photo can no longer run the app out
// of memory or freeze the screen. The saved form is unchanged from #340:
// ≤800px, JPEG, transparency on white.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:reebaplus_pos/core/result.dart';
import 'package:reebaplus_pos/core/services/photo_encoding.dart';
import 'package:reebaplus_pos/core/services/product_image_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<Result<Uint8List, AppError>> shrink(
    WidgetTester tester,
    Uint8List raw,
  ) async => (await tester.runAsync(() => ProductImageService.shrinkPicked(raw)))!;

  /// Decodes a shrink result, failing the test on an error.
  img.Image decoded(Result<Uint8List, AppError> result) {
    final bytes = switch (result) {
      Ok(:final value) => value,
      Err(:final error) => fail('shrinkPicked failed: $error'),
    };
    expect(looksLikePng(bytes), isFalse);
    expect(bytes.sublist(0, 2), [0xFF, 0xD8], reason: 'a JPEG');
    return img.decodeJpg(bytes)!;
  }

  img.Image solid(int w, int h, img.Color c) =>
      img.fill(img.Image(width: w, height: h), color: c);

  testWidgets('a large photo comes out 800px on its long side, aspect kept', (
    tester,
  ) async {
    final raw = img.encodeJpg(solid(3200, 2400, img.ColorRgb8(200, 40, 40)));
    final out = decoded(await shrink(tester, Uint8List.fromList(raw)));

    expect((out.width, out.height), (800, 600));
    final p = out.getPixel(400, 300);
    expect(p.r, closeTo(200, 12));
    expect(p.g, closeTo(40, 12));
    expect(p.b, closeTo(40, 12));
  });

  testWidgets('a sideways camera photo comes out upright', (tester) async {
    // Stored landscape with EXIF "rotate 90° clockwise", as phones save a
    // portrait shot.
    final stored = solid(1600, 1200, img.ColorRgb8(30, 120, 200));
    stored.exif.imageIfd.orientation = 6;
    final raw = img.encodeJpg(stored);
    final out = decoded(await shrink(tester, Uint8List.fromList(raw)));

    expect((out.width, out.height), (600, 800));
  });

  testWidgets('a photo already small enough keeps its size', (tester) async {
    final raw = img.encodeJpg(solid(300, 200, img.ColorRgb8(10, 160, 60)));
    final out = decoded(await shrink(tester, Uint8List.fromList(raw)));

    expect((out.width, out.height), (300, 200));
  });

  testWidgets('a transparent picture lands on white, not black', (
    tester,
  ) async {
    final clear = img.Image(width: 40, height: 40, numChannels: 4);
    final raw = img.encodePng(clear);
    final out = decoded(await shrink(tester, Uint8List.fromList(raw)));

    final p = out.getPixel(20, 20);
    expect(p.r, greaterThan(245));
    expect(p.g, greaterThan(245));
    expect(p.b, greaterThan(245));
  });

  testWidgets('bytes that are not a picture fail cleanly', (tester) async {
    final result = await shrink(
      tester,
      Uint8List.fromList(List<int>.generate(64, (i) => i)),
    );

    expect(result, isA<Err<Uint8List, AppError>>());
  });

  group('fitWithin', () {
    test('shrinks the long side to the cap, aspect kept', () {
      expect(fitWithin(4000, 3000, 800), (width: 800, height: 600));
      expect(fitWithin(3000, 4000, 800), (width: 600, height: 800));
    });

    test('leaves a picture that fits alone', () {
      expect(fitWithin(800, 600, 800), (width: 800, height: 600));
    });

    test('never goes under 1px for a very thin picture', () {
      expect(fitWithin(10000, 2, 800), (width: 800, height: 1));
    });
  });

  group('encodePremultipliedRgbaJpeg', () {
    test('opaque pixels keep their colour; clear ones turn white', () {
      // Two pixels: opaque red, fully clear (premultiplied: all zero).
      final rgba = Uint8List.fromList([220, 20, 20, 255, 0, 0, 0, 0]);
      final out = img.decodeJpg(encodePremultipliedRgbaJpeg(rgba, 2, 1))!;

      expect((out.width, out.height), (2, 1));
      expect(out.getPixel(1, 0).r, greaterThan(200));
      expect(out.getPixel(1, 0).g, greaterThan(200));
    });
  });
}
