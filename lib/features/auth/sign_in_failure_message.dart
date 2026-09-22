import 'dart:async';
import 'dart:io';

/// Shown when the sign-in flow could not reach the server. The phone is
/// untouched, so "try again" is the whole instruction (#285 decision 8).
const kSignInNetworkMessage =
    'Couldn\'t reach the server. Check your connection and try again.';

/// Shown for every other sign-in failure. Deliberately free of exception text:
/// the raw detail goes to the crash log, not to a shop floor (#285 decision 8).
const kSignInSetupFailedMessage =
    'We couldn\'t finish setting up this phone. Try again, or contact support.';

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

/// The message to show the user for a failed sign-in. Both entry screens use
/// this so the email-code path and the Google path can never drift apart.
String signInFailureMessage(Object error) =>
    isNetworkFailure(error) ? kSignInNetworkMessage : kSignInSetupFailedMessage;
