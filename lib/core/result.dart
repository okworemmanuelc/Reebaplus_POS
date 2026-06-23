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
  factory AppError.unknown(Object error) = _UnknownError;

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
  _UnknownError(Object error) : super._('$error');
}
