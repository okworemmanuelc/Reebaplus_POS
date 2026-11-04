import 'package:flutter/foundation.dart';

/// Debug + profile timing logs (#682, PRD #680). In a release build
/// ([kReleaseMode]) every helper here just runs the work with no timing and
/// prints nothing, so the stopwatch code is dead and tree-shaken.
///
/// Output: `[perf] <label> <ms>ms <extra>` via [debugPrint]. Read it in the
/// terminal of `flutter run --profile`.

/// Runs [fn], logs how long it took (debug/profile only), returns its value.
T perfLog<T>(String label, T Function() fn, {String extra = ''}) {
  if (kReleaseMode) return fn();
  final sw = Stopwatch()..start();
  final result = fn();
  sw.stop();
  _emit(label, sw.elapsedMicroseconds, extra);
  return result;
}

/// Async twin of [perfLog]: times from call to completion (also when [fn]
/// throws, then rethrows).
Future<T> perfLogAsync<T>(
  String label,
  Future<T> Function() fn, {
  String extra = '',
}) async {
  if (kReleaseMode) return fn();
  final sw = Stopwatch()..start();
  try {
    return await fn();
  } finally {
    sw.stop();
    _emit(label, sw.elapsedMicroseconds, extra);
  }
}

/// A running stopwatch for spans that cannot be wrapped in one closure
/// (e.g. a loop). Inert in release.
class PerfClock {
  PerfClock() : _sw = kReleaseMode ? null : (Stopwatch()..start());
  final Stopwatch? _sw;

  void log(String label, {String extra = ''}) {
    final sw = _sw;
    if (sw == null) return;
    _emit(label, sw.elapsedMicroseconds, extra);
  }
}

void _emit(String label, int micros, String extra) {
  final ms = (micros / 1000).toStringAsFixed(1);
  debugPrint('[perf] $label ${ms}ms${extra.isEmpty ? '' : ' $extra'}');
}
