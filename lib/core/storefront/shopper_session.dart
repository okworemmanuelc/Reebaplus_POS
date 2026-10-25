import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/utils/network_failure.dart';

/// The Supabase Auth calls the Shopper sign-in needs (#426). A seam so tests
/// never touch the real client.
abstract class ShopperAuthPort {
  /// The signed-in login's email, or null when signed out.
  String? get currentEmail;

  /// Fires whenever the session changes (sign-in, sign-out, restore).
  Stream<void> get changes;

  /// Emails a one-time code. Creates the login on first use: a Shopper needs
  /// no business, so `shouldCreateUser` is right here (ADR 0030).
  Future<void> sendCode(String email);

  Future<void> verifyCode(String email, String code);

  /// Ends this phone's session only (never other devices).
  Future<void> signOut();
}

class SupabaseShopperAuthPort implements ShopperAuthPort {
  SupabaseShopperAuthPort(this._client);

  final SupabaseClient _client;

  @override
  String? get currentEmail => _client.auth.currentUser?.email;

  @override
  Stream<void> get changes => _client.auth.onAuthStateChange.map((_) {});

  @override
  Future<void> sendCode(String email) => _client.auth
      .signInWithOtp(email: email, shouldCreateUser: true)
      .timeout(const Duration(seconds: 25));

  @override
  Future<void> verifyCode(String email, String code) => _client.auth
      .verifyOTP(email: email, token: code, type: OtpType.email)
      .timeout(const Duration(seconds: 25));

  @override
  Future<void> signOut() => _client.auth.signOut(scope: SignOutScope.local);
}

final shopperAuthPortProvider = Provider<ShopperAuthPort>(
  (ref) => SupabaseShopperAuthPort(ref.read(supabaseClientProvider)),
);

/// Who is shopping on this phone.
@immutable
class ShopperSessionState {
  const ShopperSessionState({this.email, this.isBusinessPhone = false});

  /// The signed-in login's email; null = signed out.
  final String? email;

  /// A business is signed in on this phone (a device user exists). Its
  /// Supabase session is the business's: the Shopper side shops with it and
  /// must never replace it with a Shopper OTP or sign it out (ADR 0030).
  final bool isBusinessPhone;

  bool get isSignedIn => email != null;

  /// Shopper sign-out exists only on a Shopper-only phone.
  bool get canSignOut => isSignedIn && !isBusinessPhone;
}

/// Shopper sign-in / sign-out (#426). Email + one-time code, no PIN; the
/// Supabase session persists across restarts.
///
/// It never runs the business sign-in routing (`resolvePostVerifyRoute`), so
/// a login with no business membership lands back on the Shopper side, never
/// on "No account found". Sign-out is plain — no device wipe, no outbox gate:
/// a Shopper-only phone holds no tenant data (invariant #12 does not apply).
class ShopperSessionNotifier extends Notifier<ShopperSessionState> {
  StreamSubscription<void>? _sub;

  ShopperAuthPort get _port => ref.read(shopperAuthPortProvider);

  @override
  ShopperSessionState build() {
    final isBusinessPhone = ref.watch(deviceUserIdProvider).value != null;
    _sub?.cancel();
    _sub = _port.changes.listen((_) {
      state = ShopperSessionState(
        email: _port.currentEmail,
        isBusinessPhone: state.isBusinessPhone,
      );
    }, onError: (Object e) => debugPrint('[ShopperSession] auth stream: $e'));
    ref.onDispose(() => _sub?.cancel());
    return ShopperSessionState(
      email: _port.currentEmail,
      isBusinessPhone: isBusinessPhone,
    );
  }

  /// Sends the code. Returns an error message, or null when sent.
  Future<String?> sendCode(String email) async {
    if (state.isBusinessPhone) return _businessPhoneMessage;
    try {
      await _port.sendCode(email.trim().toLowerCase());
      return null;
    } catch (e) {
      return _message(e, fallback: "Couldn't send the code. Please try again.");
    }
  }

  /// Checks the code. Returns an error message, or null when signed in.
  Future<String?> verifyCode(String email, String code) async {
    if (state.isBusinessPhone) return _businessPhoneMessage;
    try {
      await _port.verifyCode(email.trim().toLowerCase(), code.trim());
    } on AuthException {
      return 'That code is wrong or has expired. Check it or send a new one.';
    } catch (e) {
      return _message(
        e,
        fallback: "Couldn't check the code. Please try again.",
      );
    }
    state = ShopperSessionState(email: _port.currentEmail);
    unawaited(
      ref
          .read(pushNotificationServiceProvider)
          .onShopperSignedIn()
          .catchError(
            (Object e) => debugPrint('[ShopperSession] push register: $e'),
          ),
    );
    return null;
  }

  /// Plain sign-out on a Shopper-only phone. Never touches Drift or the
  /// outbox. Refused on a business phone (that session runs the till).
  Future<void> signOut() async {
    if (!state.canSignOut) return;
    try {
      await ref.read(pushNotificationServiceProvider).onShopperSignedOut();
    } catch (e) {
      debugPrint('[ShopperSession] push clear: $e');
    }
    try {
      await _port.signOut();
    } catch (e) {
      // A local sign-out still drops the session on this phone.
      debugPrint('[ShopperSession] signOut: $e');
    }
    state = const ShopperSessionState();
  }

  static const _businessPhoneMessage =
      'This phone is signed in to a business. Shop with that sign-in.';

  static String _message(Object e, {required String fallback}) {
    if (isNetworkFailure(e)) {
      return 'No internet connection. Connect and try again.';
    }
    if (e is AuthException && e.message.trim().isNotEmpty) return e.message;
    return fallback;
  }
}

final shopperSessionProvider =
    NotifierProvider<ShopperSessionNotifier, ShopperSessionState>(
      ShopperSessionNotifier.new,
    );
