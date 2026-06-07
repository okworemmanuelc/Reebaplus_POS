import 'package:reebaplus_pos/core/services/crash_reporter.dart';

/// Runs [action] inside an error boundary (master plan §33.4). Any thrown error
/// is recorded to the crash log and surfaced via [onError]; it never escapes as
/// an uncaught crash. Returns the action's result, or null on failure.
///
/// Use for action handlers — button taps, save/checkout flows — so a failure
/// shows a clear, recoverable message instead of a blank/red screen. Wrap
/// screen and action logic, NOT the DAO enqueue path: the sync invariants
/// (CLAUDE.md §5) must still fail loudly, so don't swallow them here.
///
/// [context] is a short tag for where this ran (e.g. "pos.checkout.confirm");
/// [role] is the active user's role, when known.
Future<T?> guardedRun<T>(
  Future<T> Function() action, {
  String? context,
  String? role,
  void Function(Object error, StackTrace stack)? onError,
}) async {
  try {
    return await action();
  } catch (error, stack) {
    CrashReporter.record(error, stack, context: context, role: role);
    if (onError != null) onError(error, stack);
    return null;
  }
}
