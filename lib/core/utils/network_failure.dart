import 'dart:async';
import 'dart:io';

/// True when [error] is a transport failure rather than a real answer from the
/// server — no DNS, no route, a dropped socket, or a timeout.
///
/// Matched by type where the type is reachable, and by name for the transport
/// exceptions that live inside the HTTP/Supabase clients (`ClientException`,
/// `AuthRetryableFetchException`) rather than taking a dependency on them here.
bool isNetworkFailure(Object error) {
  if (error is SocketException) return true;
  if (error is TimeoutException) return true;
  if (error is HttpException) return true;
  final name = error.runtimeType.toString();
  if (name == 'ClientException' || name == 'AuthRetryableFetchException') {
    return true;
  }
  final text = error.toString().toLowerCase();
  return text.contains('failed host lookup') ||
      text.contains('connection closed') ||
      text.contains('connection refused') ||
      text.contains('connection reset') ||
      text.contains('network is unreachable') ||
      text.contains('software caused connection abort');
}
