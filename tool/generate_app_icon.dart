// Builds the two launcher-icon source images from the dark-theme logo.
//
//   assets/images/reebaplus_icon.png    — logo centered on a dark navy/charcoal
//                                          (#0B1220) background; used for iOS,
//                                          legacy Android, web, macOS, Windows.
//   assets/images/reebaplus_icon_fg.png — logo padded into a transparent canvas
//                                          (kept inside the adaptive-icon safe
//                                          zone); used as the Android adaptive
//                                          foreground over the #0B1220 background.
//
// Run from the project root, then regenerate the platform icons:
//   dart run tool/generate_app_icon.dart
//   dart run flutter_launcher_icons
//
// Uses the project's existing `image` dependency — no new packages.
import 'dart:io';

import 'package:image/image.dart' as img;

const _canvas = 1024;
// Dark navy/charcoal — the "dark theme" backdrop behind the logo.
const _bgR = 0x0B, _bgG = 0x12, _bgB = 0x20; // #0B1220

img.Image _scaleToFit(img.Image src, int target) {
  final longest = src.width >= src.height ? src.width : src.height;
  final scale = target / longest;
  return img.copyResize(
    src,
    width: (src.width * scale).round(),
    height: (src.height * scale).round(),
    interpolation: img.Interpolation.cubic,
  );
}

void _placeCentered(img.Image dst, img.Image src) {
  img.compositeImage(
    dst,
    src,
    dstX: ((dst.width - src.width) / 2).round(),
    dstY: ((dst.height - src.height) / 2).round(),
  );
}

void main() {
  final logo = img.decodePng(
    File('assets/images/reebaplus_logo.png').readAsBytesSync(),
  );
  if (logo == null) {
    stderr.writeln('Could not decode assets/images/reebaplus_logo.png');
    exit(1);
  }

  // Trim transparent margins so the visible mark sizes consistently.
  final mark = img.trim(logo, mode: img.TrimMode.transparent);

  // 1) Solid-background master icon — logo at ~78% of the canvas.
  final main = img.Image(width: _canvas, height: _canvas, numChannels: 4);
  img.fill(main, color: img.ColorRgba8(_bgR, _bgG, _bgB, 255));
  _placeCentered(main, _scaleToFit(mark, (_canvas * 0.78).round()));
  File('assets/images/reebaplus_icon.png').writeAsBytesSync(img.encodePng(main));

  // 2) Adaptive foreground — logo at ~60% on transparent (inside the safe zone).
  final fg = img.Image(width: _canvas, height: _canvas, numChannels: 4);
  _placeCentered(fg, _scaleToFit(mark, (_canvas * 0.60).round()));
  File('assets/images/reebaplus_icon_fg.png')
      .writeAsBytesSync(img.encodePng(fg));

  stdout.writeln(
    'Wrote reebaplus_icon.png and reebaplus_icon_fg.png '
    '(${_canvas}x$_canvas, mark trimmed to ${mark.width}x${mark.height}).',
  );
}
