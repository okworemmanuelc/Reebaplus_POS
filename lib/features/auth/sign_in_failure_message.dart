import 'package:reebaplus_pos/core/utils/network_failure.dart';

/// Shown when the sign-in flow could not reach the server. The phone is
/// untouched, so "try again" is the whole instruction (#285 decision 8).
const kSignInNetworkMessage =
    'Couldn\'t reach the server. Check your connection and try again.';

/// Shown for every other sign-in failure. Deliberately free of exception text:
/// the raw detail goes to the crash log, not to a shop floor (#285 decision 8).
const kSignInSetupFailedMessage =
    'We couldn\'t finish setting up this phone. Try again, or contact support.';

/// The message to show the user for a failed sign-in. Both entry screens use
/// this so the email-code path and the Google path can never drift apart.
String signInFailureMessage(Object error) =>
    isNetworkFailure(error) ? kSignInNetworkMessage : kSignInSetupFailedMessage;
