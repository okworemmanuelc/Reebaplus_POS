import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';

/// App version recorded with each crash. Mirrors `version:` in pubspec.yaml —
/// bump both together. (There is no package_info dependency; keeping this a
/// constant avoids adding one just for diagnostics.)
const String kAppVersion = '1.0.0+1';

/// App-wide crash safety net (master plan §33 — Reliability and Crash
/// Handling). Installs the global error handlers and records caught/uncaught
/// errors to the synced `error_logs` table via [ErrorLogDao].
///
/// Every path here is defensive: recording an error must NEVER throw — the
/// safety net can't become the thing that breaks the till.
class CrashReporter {
  CrashReporter._();

  /// Install the global Flutter + platform error handlers. Call once, early in
  /// `main()` (inside the guarded zone), after `ensureInitialized()`.
  static void install() {
    // Framework (build / layout / paint) errors.
    final FlutterExceptionHandler? prior = FlutterError.onError;
    FlutterError.onError = (FlutterErrorDetails details) {
      // Preserve the default console dump (and debug red box logging).
      if (prior != null) {
        prior(details);
      } else {
        FlutterError.presentError(details);
      }
      record(
        details.exception,
        details.stack,
        context: details.context?.toDescription(),
        isFatal: true,
      );
    };

    // Uncaught async / engine errors that don't go through FlutterError.
    PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
      record(error, stack, isFatal: true);
      // Returning true marks it handled so the engine doesn't tear down the app.
      return true;
    };
  }

  /// Record a single error. Safe to call from anywhere (global handlers, the
  /// guarded zone, [guardedRun], or a screen's catch block). Fire-and-forget;
  /// any failure to record is swallowed.
  static void record(
    Object error,
    StackTrace? stack, {
    String? context,
    String? role,
    bool isFatal = false,
  }) {
    try {
      unawaited(
        database.errorLogDao.logError(
          errorType: error.runtimeType.toString(),
          message: error.toString(),
          stackTrace: stack?.toString(),
          context: context,
          role: role,
          isFatal: isFatal,
          appVersion: kAppVersion,
          platform: defaultTargetPlatform.name,
        ),
      );
    } catch (_) {
      // Never throw from the crash reporter.
    }
  }
}
