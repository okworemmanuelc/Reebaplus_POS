// Builds every Reebaplus logo asset from the two official artworks.
//
// Sources (the designer's files, kept in the repo but NOT bundled in the app):
//   assets/branding/reebaplus_logo_on_dark.jpg  — logo on black (dark theme)
//   assets/branding/reebaplus_logo_on_light.jpg — logo on grey (light theme)
//
// Each artwork's flat background is keyed out ("colour to alpha", the inverse
// of compositing over that colour, so the logo looks identical when drawn back
// on its own background) and the ring mark is split from the wordmark.
//
// Outputs
//   In-app (bundled, see ReebaplusLogo):
//     assets/images/brand/reebaplus_mark_{dark,light}.png    — ring mark only
//     assets/images/brand/reebaplus_lockup_{dark,light}.png  — mark + wordmark
//   Launcher-icon sources (consumed by flutter_launcher_icons, not bundled):
//     assets/launcher/icon_light.png          — mark on the light background
//     assets/launcher/icon_fg_light.png       — Android adaptive foreground
//     assets/launcher/icon_monochrome.png     — Android 13+ themed icon
//     assets/launcher/icon_ios_dark.png       — iOS 18 dark / tinted icon
//   Android dark-mode launcher icon (written straight into res/, because
//   flutter_launcher_icons only knows one Android icon):
//     res/values-night/colors.xml                       ic_launcher_background
//     res/drawable-night-<dpi>/ic_launcher_foreground.png
//     res/mipmap-night-<dpi>/ic_launcher.png
//
// Run from the project root:
//   dart run tool/generate_brand_assets.dart && dart run flutter_launcher_icons
//
// Uses the project's existing `image` dependency — no new packages.
import 'dart:io';
import 'dart:math' as math;

import 'package:image/image.dart' as img;

const _darkSrc = 'assets/branding/reebaplus_logo_on_dark.jpg';
const _lightSrc = 'assets/branding/reebaplus_logo_on_light.jpg';
const _brandDir = 'assets/images/brand';
const _launcherDir = 'assets/launcher';
const _res = 'android/app/src/main/res';

/// Below this alpha a keyed pixel is JPEG noise in the background → cleared.
const _noiseFloor = 0.05;

class _Keyed {
  _Keyed(this.image, this.bg);
  final img.Image image; // RGBA, background keyed to transparent
  final img.Color bg; // the flat background colour that was keyed out
}

/// The artworks carry a thin frame line at the very edge — crop it away.
const _frame = 8;

img.Image _load(String path) {
  final src = img.decodeJpg(File(path).readAsBytesSync());
  if (src == null) {
    stderr.writeln('Could not decode $path');
    exit(1);
  }
  return img.copyCrop(
    src,
    x: _frame,
    y: _frame,
    width: src.width - 2 * _frame,
    height: src.height - 2 * _frame,
  );
}

/// Median colour of the four 24px corner patches = the flat background.
img.Color _backgroundOf(img.Image src) {
  final rs = <int>[], gs = <int>[], bs = <int>[];
  const p = 24;
  for (final (x0, y0) in [
    (0, 0),
    (src.width - p, 0),
    (0, src.height - p),
    (src.width - p, src.height - p),
  ]) {
    for (var y = y0; y < y0 + p; y++) {
      for (var x = x0; x < x0 + p; x++) {
        final c = src.getPixel(x, y);
        rs.add(c.r.toInt());
        gs.add(c.g.toInt());
        bs.add(c.b.toInt());
      }
    }
  }
  int median(List<int> v) => (v..sort())[v.length ~/ 2];
  return img.ColorRgb8(median(rs), median(gs), median(bs));
}

/// GIMP-style colour-to-alpha against [bg].
_Keyed _key(img.Image src) {
  final bg = _backgroundOf(src);
  final b = [bg.r / 255, bg.g / 255, bg.b / 255];
  final out = img.Image(width: src.width, height: src.height, numChannels: 4);
  for (final px in src) {
    final c = [px.r / 255, px.g / 255, px.b / 255];
    var a = 0.0;
    for (var i = 0; i < 3; i++) {
      final ai = c[i] > b[i]
          ? (c[i] - b[i]) / (1 - b[i])
          : c[i] < b[i]
          ? (b[i] - c[i]) / b[i]
          : 0.0;
      a = math.max(a, ai);
    }
    if (a < _noiseFloor) {
      out.setPixelRgba(px.x, px.y, 0, 0, 0, 0);
      continue;
    }
    int ch(int i) =>
        (((c[i] - b[i]) / a + b[i]) * 255).round().clamp(0, 255).toInt();
    out.setPixelRgba(px.x, px.y, ch(0), ch(1), ch(2), (a * 255).round());
  }
  return _Keyed(out, bg);
}

/// Splits the keyed artwork into (mark, lockup) crops. The wordmark sits
/// below the ring, separated by the tallest fully-empty band of rows.
(img.Image, img.Image) _split(img.Image keyed) {
  bool rowHasInk(int y) {
    for (var x = 0; x < keyed.width; x++) {
      if (keyed.getPixel(x, y).a > 40) return true;
    }
    return false;
  }

  final ink = [for (var y = 0; y < keyed.height; y++) rowHasInk(y)];
  final top = ink.indexOf(true);
  final bottom = ink.lastIndexOf(true);
  var gapStart = -1, gapLen = 0;
  for (var y = top, run = 0; y <= bottom; y++) {
    run = ink[y] ? 0 : run + 1;
    if (run > gapLen) {
      gapLen = run;
      gapStart = y - run + 1;
    }
  }
  if (gapLen < 8) {
    stderr.writeln('Could not find the gap between mark and wordmark');
    exit(1);
  }
  final markRegion = img.copyCrop(
    keyed,
    x: 0,
    y: 0,
    width: keyed.width,
    height: gapStart,
  );
  final mark = img.trim(markRegion, mode: img.TrimMode.transparent);
  final lockup = img.trim(keyed, mode: img.TrimMode.transparent);
  return (mark, lockup);
}

img.Image _fit(img.Image src, int target) {
  final scale = target / math.max(src.width, src.height);
  return img.copyResize(
    src,
    width: (src.width * scale).round(),
    height: (src.height * scale).round(),
    interpolation: img.Interpolation.cubic,
  );
}

/// [mark] scaled to [fraction] of a [size]² canvas, centred, over [bg]
/// (transparent when null).
img.Image _onCanvas(
  img.Image mark,
  int size,
  double fraction, {
  img.Color? bg,
}) {
  final canvas = img.Image(width: size, height: size, numChannels: 4);
  if (bg != null) {
    img.fill(
      canvas,
      color: img.ColorRgba8(bg.r.toInt(), bg.g.toInt(), bg.b.toInt(), 255),
    );
  }
  final m = _fit(mark, (size * fraction).round());
  img.compositeImage(
    canvas,
    m,
    dstX: ((size - m.width) / 2).round(),
    dstY: ((size - m.height) / 2).round(),
  );
  return canvas;
}

/// White silhouette carrying only [src]'s alpha (Android themed icons).
img.Image _monochrome(img.Image src) {
  final out = img.Image(width: src.width, height: src.height, numChannels: 4);
  for (final px in src) {
    out.setPixelRgba(px.x, px.y, 255, 255, 255, px.a.toInt());
  }
  return out;
}

String _hex(img.Color c) =>
    '#${[c.r, c.g, c.b].map((v) => v.toInt().toRadixString(16).padLeft(2, '0')).join().toUpperCase()}';

void _write(String path, img.Image image) {
  File(path)
    ..parent.createSync(recursive: true)
    ..writeAsBytesSync(img.encodePng(image));
  stdout.writeln('  $path (${image.width}x${image.height})');
}

// Must match flutter_launcher_icons' layout so the night set mirrors the day
// set: adaptive foreground is 108dp, legacy icon is 48dp.
const _densities = {
  'mdpi': 1.0,
  'hdpi': 1.5,
  'xhdpi': 2.0,
  'xxhdpi': 3.0,
  'xxxhdpi': 4.0,
};

// Share of the canvas the ring mark fills.
const _iconFraction = 0.80; // opaque square icons (iOS, legacy, web)
const _adaptiveFraction = 0.86; // adaptive fg; the xml already insets 16%

void main() {
  final dark = _key(_load(_darkSrc));
  final light = _key(_load(_lightSrc));
  final (darkMark, darkLockup) = _split(dark.image);
  final (lightMark, lightLockup) = _split(light.image);

  stdout.writeln('Backgrounds: dark ${_hex(dark.bg)}, light ${_hex(light.bg)}');

  stdout.writeln('In-app:');
  _write('$_brandDir/reebaplus_mark_dark.png', _fit(darkMark, 512));
  _write('$_brandDir/reebaplus_mark_light.png', _fit(lightMark, 512));
  _write('$_brandDir/reebaplus_lockup_dark.png', _fit(darkLockup, 768));
  _write('$_brandDir/reebaplus_lockup_light.png', _fit(lightLockup, 768));

  stdout.writeln('Launcher sources:');
  _write(
    '$_launcherDir/icon_light.png',
    _onCanvas(lightMark, 1024, _iconFraction, bg: light.bg),
  );
  _write(
    '$_launcherDir/icon_fg_light.png',
    _onCanvas(lightMark, 1024, _adaptiveFraction),
  );
  _write(
    '$_launcherDir/icon_monochrome.png',
    _monochrome(_onCanvas(lightMark, 1024, _adaptiveFraction)),
  );
  _write(
    '$_launcherDir/icon_ios_dark.png',
    _onCanvas(darkMark, 1024, _iconFraction),
  );

  stdout.writeln('Android dark-mode launcher icon:');
  final darkFg = _onCanvas(darkMark, 1024, _adaptiveFraction);
  final darkLegacy = _onCanvas(darkMark, 1024, _iconFraction, bg: dark.bg);
  _densities.forEach((dpi, d) {
    _write(
      '$_res/drawable-night-$dpi/ic_launcher_foreground.png',
      img.copyResize(
        darkFg,
        width: (108 * d).round(),
        interpolation: img.Interpolation.cubic,
      ),
    );
    _write(
      '$_res/mipmap-night-$dpi/ic_launcher.png',
      img.copyResize(
        darkLegacy,
        width: (48 * d).round(),
        interpolation: img.Interpolation.cubic,
      ),
    );
  });
  File('$_res/values-night/colors.xml').writeAsStringSync(
    '<?xml version="1.0" encoding="utf-8"?>\n'
    '<!-- Generated by tool/generate_brand_assets.dart — dark-mode launcher icon background. -->\n'
    '<resources>\n'
    '    <color name="ic_launcher_background">${_hex(dark.bg)}</color>\n'
    '</resources>\n',
  );
  stdout.writeln('  $_res/values-night/colors.xml');
  stdout.writeln(
    '\nSet adaptive_icon_background to ${_hex(light.bg)} in pubspec.yaml, '
    'then run: dart run flutter_launcher_icons',
  );
}
