import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// JPEG quality for every photo the app uploads (product photos and the
/// business logo). ~80 keeps a phone photo at 800px well under 300 KB while
/// staying visually clean for item recognition (#340).
const int kPhotoJpegQuality = 80;

/// Shrinks [src] to fit inside [maxDimension]×[maxDimension] (aspect kept),
/// flattens any transparency onto white, and encodes it as a JPEG.
///
/// Pure (no I/O), so the product photo and logo services share it and tests
/// can drive it directly. JPEG has no alpha channel: without the flatten a
/// transparent PNG would come out with black (or garbage) where it was clear.
Uint8List encodePhotoJpeg(
  img.Image src, {
  required int maxDimension,
  int quality = kPhotoJpegQuality,
}) {
  final flat = flattenOntoWhite(resizeToFit(src, maxDimension));
  return Uint8List.fromList(img.encodeJpg(flat, quality: quality));
}

/// Returns [src] unchanged when it already fits inside [maxDimension]; else a
/// linear-resampled copy whose longer side is exactly [maxDimension].
img.Image resizeToFit(img.Image src, int maxDimension) {
  if (src.width <= maxDimension && src.height <= maxDimension) return src;
  final ratio = src.width > src.height
      ? maxDimension / src.width
      : maxDimension / src.height;
  return img.copyResize(
    src,
    width: (src.width * ratio).round(),
    height: (src.height * ratio).round(),
    interpolation: img.Interpolation.linear,
  );
}

/// An 8-bit RGB copy of [src] with every pixel alpha-blended onto white, so a
/// clear area becomes white instead of black once encoded as JPEG. Opaque
/// pixels keep their colour. Also normalises palette / 16-bit / float images
/// to plain 8-bit RGB, which is what the JPEG encoder expects.
img.Image flattenOntoWhite(img.Image src) {
  final out = img.Image(width: src.width, height: src.height, numChannels: 3);
  for (final p in src) {
    final a = p.aNormalized.toDouble();
    int blend(num c) =>
        (255 * (c.toDouble() * a + (1 - a))).round().clamp(0, 255);
    out.setPixelRgb(
      p.x,
      p.y,
      blend(p.rNormalized),
      blend(p.gNormalized),
      blend(p.bNormalized),
    );
  }
  return out;
}

/// True when [bytes] start with the PNG signature. Used to spot device copies
/// and offline uploads written before #340, which were PNG.
bool looksLikePng(Uint8List bytes) =>
    bytes.length >= 8 &&
    bytes[0] == 0x89 &&
    bytes[1] == 0x50 &&
    bytes[2] == 0x4E &&
    bytes[3] == 0x47 &&
    bytes[4] == 0x0D &&
    bytes[5] == 0x0A &&
    bytes[6] == 0x1A &&
    bytes[7] == 0x0A;

/// The object path inside [bucket] behind a public Supabase Storage url,
/// ignoring any query (the `?v=` version product photo urls carry, #340).
/// Null when [url] is not a public url of [bucket].
String? storageObjectPathFromPublicUrl(String url, String bucket) {
  final marker = '/object/public/$bucket/';
  final noQuery = url.split('?').first;
  final idx = noQuery.indexOf(marker);
  if (idx == -1) return null;
  final path = Uri.decodeFull(noQuery.substring(idx + marker.length));
  return path.isEmpty ? null : path;
}
