import 'package:flutter/foundation.dart' show debugPrint;
import 'package:reebaplus_pos/core/errors/user_error_message.dart';

/// Typed result carrier — avoids throwing across layer boundaries.
///
/// Usage:
///   Result<String, AppError> r = Result.ok('hello');
///   Result<String, AppError> e = Result.err(AppError.io('oops'));
///   switch (r) {
///     case Ok(:final value): print(value);
///     case Err(:final error): print(error.message);
///   }
sealed class Result<T, E> {
  const Result._();

  static Result<T, E> ok<T, E>(T value) => Ok._(value);
  static Result<T, E> err<T, E>(E error) => Err._(error);

  bool get isOk => this is Ok<T, E>;
  bool get isErr => this is Err<T, E>;

  T get valueOrThrow => switch (this) {
    Ok(:final value) => value,
    Err(:final error) => throw StateError('Result is Err: $error'),
  };
}

final class Ok<T, E> extends Result<T, E> {
  const Ok._(this.value) : super._();
  final T value;
}

final class Err<T, E> extends Result<T, E> {
  const Err._(this.error) : super._();
  final E error;
}

// ── AppError ──────────────────────────────────────────────────────────────────

sealed class AppError {
  const AppError._(this.message);
  final String message;

  factory AppError.io(String message) = _IoError;
  factory AppError.network(String message) = _NetworkError;
  factory AppError.permission(String message) = _PermissionError;
  factory AppError.cancelled() = _CancelledError;
  factory AppError.unknown(Object error, {String action}) = _UnknownError;

  bool get isCancelled => this is _CancelledError;

  @override
  String toString() => 'AppError: $message';
}

final class _IoError extends AppError {
  const _IoError(super.message) : super._();
}

final class _NetworkError extends AppError {
  const _NetworkError(super.message) : super._();
}

final class _PermissionError extends AppError {
  const _PermissionError(super.message) : super._();
}

final class _CancelledError extends AppError {
  const _CancelledError() : super._('Cancelled');
}

final class _UnknownError extends AppError {
  /// #836 — the message is a plain sentence for shop staff; the raw error
  /// goes to the debug log only so support keeps the detail.
  _UnknownError(Object error, {String action = 'doing that'})
    : super._(_plainUnknownMessage(error, action));

  static String _plainUnknownMessage(Object error, String action) {
    debugPrint('[AppError] $action failed: $error');
    return userErrorMessage(error, action: action);
  }
}

/// #836 — plain sentence for a failed picture upload/removal. The raw storage
/// error is logged for support but never shown to staff.
String plainStorageFailure(Object error, {bool deleting = false}) {
  debugPrint('[Storage] ${deleting ? 'delete' : 'upload'} failed: $error');
  return deleting
      ? "Couldn't remove the picture. Check your internet connection and try again."
      : "Couldn't upload the picture. Check your internet connection and try again.";
}
