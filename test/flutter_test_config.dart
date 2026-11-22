// Real fonts for every test under test/ (#352).
//
// Without this, widget tests draw every family with the FlutterTest font (each
// glyph a 1em square), so goldens show boxes instead of letters and an overflow
// that only DM Sans's real widths cause can never show up.
//
// Loads, under the family names the app asks for:
//   * DM Sans 400/500/600/700/800 as `DMSans` (pubspec, `appFontFamily`);
//   * Roboto Mono 400 as `RobotoMono` (`appMonoFontFamily`);
//   * Material Symbols Outlined as
//     `packages/material_symbols_icons/MaterialSymbolsOutlined`, the family
//     `AppIcons` resolves to.
//
// Deliberately does NOT initialise the test binding. #349's experiment called
// `TestWidgetsFlutterBinding.ensureInitialized()` (to use `rootBundle`) and that
// broke `device_registry_push_token_test.dart`, which must set up its own
// binding in `main()`. The bytes are read straight from disk with dart:io and
// handed to `FontLoader`, which only calls the engine's `loadFontFromList` —
// no binding, no asset bundle. A file that is missing (e.g. a CI runner without
// the pub cache) is skipped, never fatal: tests then fall back to the test font
// exactly as before.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  await _loadAppFonts();
  _useCiGoldenTolerance();
  await testMain();
}

/// On GitHub Actions (`CI=true`) screenshot goldens may differ by up to this
/// share of pixels. GitHub's Mac runners anti-alias edges slightly differently
/// from the owner's Mac (first CI run: 993 goldens off by 0.00–0.78%, median
/// 0.10%). Real layout changes, overflow errors and missing widgets still fail.
/// Locally the comparison stays pixel-exact, so run the goldens of any screen
/// you touch on your own machine.
const double _ciGoldenTolerance = 0.01;

void _useCiGoldenTolerance() {
  if (Platform.environment['CI'] != 'true') return;
  final current = goldenFileComparator;
  if (current is! LocalFileComparator) return;
  // flutter test sets a comparator rooted at this test file's folder; rebuild
  // it with the same root (any file name in that folder gives the same basedir).
  goldenFileComparator = _TolerantComparator(
    current.basedir.resolve('flutter_test_config_ci.dart'),
  );
}

class _TolerantComparator extends LocalFileComparator {
  _TolerantComparator(super.testFile);

  @override
  Future<bool> compare(Uint8List imageBytes, Uri golden) async {
    final result = await GoldenFileComparator.compareLists(
      imageBytes,
      await getGoldenBytes(golden),
    );
    if (result.passed || result.diffPercent <= _ciGoldenTolerance) {
      result.dispose();
      return true;
    }
    final error = await generateFailureOutput(result, golden, basedir);
    result.dispose();
    throw FlutterError(error);
  }
}

Future<void> _loadAppFonts() async {
  await _loadFamily('DMSans', const [
    'assets/google_fonts/DMSans-Regular.ttf',
    'assets/google_fonts/DMSans-Medium.ttf',
    'assets/google_fonts/DMSans-SemiBold.ttf',
    'assets/google_fonts/DMSans-Bold.ttf',
    'assets/google_fonts/DMSans-ExtraBold.ttf',
  ]);
  await _loadFamily('RobotoMono', const [
    'assets/google_fonts/RobotoMono-Regular.ttf',
  ]);
  final symbolsRoot = _packageRoot('material_symbols_icons');
  if (symbolsRoot != null) {
    await _loadFamily(
      'packages/material_symbols_icons/MaterialSymbolsOutlined',
      ['$symbolsRoot/lib/fonts/MaterialSymbolsOutlined.ttf'],
    );
  }
}

Future<void> _loadFamily(String family, List<String> paths) async {
  final loader = FontLoader(family);
  var any = false;
  for (final path in paths) {
    final file = File(path);
    if (!file.existsSync()) continue;
    final bytes = file.readAsBytesSync();
    loader.addFont(
      Future.value(ByteData.sublistView(Uint8List.fromList(bytes))),
    );
    any = true;
  }
  if (any) await loader.load();
}

/// The directory holding [package], read from `.dart_tool/package_config.json`
/// (flutter test runs from the project root).
String? _packageRoot(String package) {
  final config = File('.dart_tool/package_config.json');
  if (!config.existsSync()) return null;
  try {
    final json = jsonDecode(config.readAsStringSync()) as Map<String, Object?>;
    final packages = json['packages'] as List<Object?>? ?? const [];
    for (final entry in packages) {
      if (entry is! Map<String, Object?> || entry['name'] != package) continue;
      final rootUri = entry['rootUri'] as String?;
      if (rootUri == null) return null;
      final resolved = config.absolute.uri.resolve(rootUri);
      return resolved.toFilePath().replaceAll(RegExp(r'/$'), '');
    }
  } on FormatException {
    return null;
  }
  return null;
}
