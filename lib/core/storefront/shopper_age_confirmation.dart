import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/storefront/storefront_service.dart';
import 'package:reebaplus_pos/core/utils/network_failure.dart';

/// The cloud side of the 18+ confirmation (#479, migration 0206): the
/// authenticated `shopper_confirm_age` / `shopper_age_confirmed_at` RPCs.
///
/// Sanctioned direct-Supabase exception (ADR 0031, Shopper surface): online
/// only, never Drift, never the outbox. The cloud is the authority at Place
/// order (`shopper_age_confirmation_missing`, called by the place-order RPC).
class ShopperAgeService {
  ShopperAgeService(SupabaseClient client)
    : this.withRpc(
        rpc: (function, params) => client.rpc(function, params: params),
        isSignedIn: () => client.auth.currentSession != null,
      );

  @visibleForTesting
  ShopperAgeService.withRpc({
    required StorefrontRpc rpc,
    required bool Function() isSignedIn,
    this.timeout = const Duration(seconds: 15),
  }) : _rpc = rpc,
       _isSignedIn = isSignedIn;

  final StorefrontRpc _rpc;
  final bool Function() _isSignedIn;
  final Duration timeout;

  bool get isSignedIn => _isSignedIn();

  /// Records "I am 18 or older" for the signed-in login (idempotent).
  Future<void> confirm() async {
    await _call('shopper_confirm_age');
  }

  /// Whether the signed-in login has confirmed before.
  Future<bool> isConfirmed() async =>
      await _call('shopper_age_confirmed_at') != null;

  Future<Object?> _call(String fn) async {
    try {
      return await _rpc(fn, const {}).timeout(timeout);
    } on TimeoutException catch (e) {
      throw StorefrontException(StorefrontFailure.offline, e);
    } catch (e) {
      debugPrint('ShopperAgeService: $fn failed ($e)');
      throw StorefrontException(
        isNetworkFailure(e) ? StorefrontFailure.offline : StorefrontFailure.failed,
        e,
      );
    }
  }
}

final shopperAgeServiceProvider = Provider<ShopperAgeService>(
  (ref) => ShopperAgeService(ref.read(supabaseClientProvider)),
);

/// Whether this Shopper has confirmed they are 18 or older (#479).
///
/// Signed out, the answer lives on the phone (device key-value storage, never
/// Drift / outbox). Signed in, it is also recorded on the login in the cloud,
/// which the place-order RPC re-checks.
class ShopperAgeConfirmationNotifier extends AsyncNotifier<bool> {
  static const prefKey = 'storefront_age_confirmed_v1';

  @override
  Future<bool> build() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(prefKey) ?? false;
    } catch (_) {
      return false;
    }
  }

  /// The Shopper said "I am 18 or older": remember it on the phone and, when
  /// signed in, on the login. A failed cloud write is retried by [syncToCloud]
  /// before Place order, so it never blocks adding to the cart.
  Future<void> confirm() async {
    state = const AsyncData(true);
    await _remember();
    final service = ref.read(shopperAgeServiceProvider);
    if (!service.isSignedIn) return;
    try {
      await service.confirm();
    } on StorefrontException catch (e) {
      debugPrint('Age confirmation not saved to the account yet ($e)');
    }
  }

  /// Before Place order (#426): makes the cloud agree with the phone.
  /// A confirmation made while signed out is copied to the login; one made on
  /// another phone is adopted here. Returns whether the login is confirmed.
  /// Throws [StorefrontException] when the cloud cannot be reached.
  Future<bool> syncToCloud() async {
    final service = ref.read(shopperAgeServiceProvider);
    if (!service.isSignedIn) return false;
    final local = await future;
    if (local) {
      await service.confirm();
      return true;
    }
    if (await service.isConfirmed()) {
      state = const AsyncData(true);
      await _remember();
      return true;
    }
    return false;
  }

  Future<void> _remember() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(prefKey, true);
    } catch (_) {
      // The cloud copy (when signed in) still counts at Place order.
    }
  }
}

final shopperAgeConfirmationProvider =
    AsyncNotifierProvider<ShopperAgeConfirmationNotifier, bool>(
      ShopperAgeConfirmationNotifier.new,
    );
