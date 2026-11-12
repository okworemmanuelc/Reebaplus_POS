import 'package:flutter/foundation.dart';

/// True while Supabase has no login for this phone (#798): the server refused
/// to renew it, or it was never restored. Set by the app root from the
/// Supabase auth stream.
///
/// It does NOT block anything. A phone in this state sells like an offline
/// phone; uploads and downloads pause, and `SignInAgainBanner` offers to sign
/// in again. Starts false so nothing flashes during the cold-start restore.
final ValueNotifier<bool> cloudLoginLost = ValueNotifier<bool>(false);
