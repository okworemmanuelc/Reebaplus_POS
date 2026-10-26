import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:reebaplus_pos/core/storefront/shopper_cart.dart';
import 'package:reebaplus_pos/core/storefront/shopper_models.dart';
import 'package:reebaplus_pos/core/storefront/storefront_service.dart';
import 'package:reebaplus_pos/core/utils/network_failure.dart';

/// Why a signed-in Shopper command failed.
enum ShopperFailure {
  /// No connection, or the request never reached the server.
  offline,

  /// The session is gone — sign in again.
  signedOut,

  /// Place order needs the first-time details first.
  profileRequired,

  /// Cancel came after the shop answered.
  notCancellable,

  /// Too many reports in the last hour (#478).
  rateLimited,

  /// Anything else the server refused.
  failed,
}

/// What a Shopper can report (#478).
enum ReportTarget {
  product('product'),
  store('store');

  const ReportTarget(this.wire);
  final String wire;
}

/// Why a Shopper reports a listing (#478); `wire` is the cloud value.
enum ReportReason {
  wrongItem('wrong_item', 'Wrong item'),
  offensive('offensive', 'Offensive'),
  illegalOrRestricted('illegal_or_restricted', 'Illegal or restricted'),
  scam('scam', 'Scam'),
  other('other', 'Other');

  const ReportReason(this.wire, this.label);
  final String wire;
  final String label;
}

class ShopperException implements Exception {
  const ShopperException(this.failure, [this.cause]);
  final ShopperFailure failure;
  final Object? cause;

  @override
  String toString() => 'ShopperException($failure, $cause)';
}

/// The signed-in Shopper's commands (#426, ADR 0031): the `shopper_*`
/// SECURITY DEFINER RPCs and nothing else. Identity is the session's
/// `auth.uid()`, never a parameter; every rule (prices, stock, area,
/// min/step/max, spam limit) is re-checked by the server.
///
/// Sanctioned direct-Supabase exception (invariants #1/#4/#8, Shopper
/// exception): online only, never Drift, never the outbox.
class ShopperService {
  ShopperService(SupabaseClient client)
    : this.withRpc(
        rpc: (function, params) => client.rpc(function, params: params),
      );

  @visibleForTesting
  ShopperService.withRpc({
    required StorefrontRpc rpc,
    this.timeout = defaultTimeout,
  }) : _rpc = rpc;

  static const defaultTimeout = Duration(seconds: 20);

  final StorefrontRpc _rpc;
  final Duration timeout;

  /// The Shopper's details, or null before the first-time details.
  Future<ShopperProfile?> profile() async {
    final result = await _call('shopper_get_profile', const {});
    if (result == null) return null;
    if (result is! Map) throw ShopperException(ShopperFailure.failed, result);
    return ShopperProfile.fromJson(result.cast<String, Object?>());
  }

  /// First-time details or an edit: name, default phone, default address.
  Future<ShopperProfile> saveProfile({
    required String name,
    required String phone,
    required ShopperAddress address,
  }) async {
    final result = await _call('shopper_save_profile', {
      'p_name': name.trim(),
      'p_phone': phone.trim(),
      'p_country': address.country,
      'p_state': address.state,
      'p_lga': address.lga,
      'p_street': address.street.trim(),
    });
    if (result is! Map) throw ShopperException(ShopperFailure.failed, result);
    return ShopperProfile.fromJson(result.cast<String, Object?>());
  }

  /// Keeps another phone for later orders.
  Future<void> savePhone(String phone) =>
      _call('shopper_save_phone', {'p_phone': phone.trim()});

  /// Keeps another address for later orders.
  Future<void> saveAddress(ShopperAddress address) =>
      _call('shopper_save_address', {
        'p_country': address.country,
        'p_state': address.state,
        'p_lga': address.lga,
        'p_street': address.street.trim(),
      });

  /// Places one Online Order per shop group. [orderIds] maps store id → the
  /// client-generated order id (reused on a retry, so a retry never doubles
  /// an order). Results come back per shop.
  Future<List<PlaceOrderResult>> placeOrders({
    required List<ShopperCartGroup> groups,
    required Map<String, String> orderIds,
    required String phone,
    required ShopperAddress address,
    String? note,
  }) async {
    final trimmedNote = note?.trim();
    final result = await _call('shopper_place_orders', {
      'p_orders': [
        for (final g in groups)
          {
            'id': orderIds[g.storeId],
            'store_id': g.storeId,
            'lines': [
              for (final l in g.lines)
                {'product_id': l.productId, 'quantity': l.quantity},
            ],
          },
      ],
      'p_phone': phone.trim(),
      'p_address': address.toRpc(),
      'p_note': trimmedNote == null || trimmedNote.isEmpty ? null : trimmedNote,
    });
    if (result is! List) throw ShopperException(ShopperFailure.failed, result);
    return [
      for (final row in result)
        if (row is Map) PlaceOrderResult.fromRow(row.cast<String, Object?>()),
    ];
  }

  /// Cancels an own order while it is still `new`.
  Future<void> cancelOrder(String orderId) =>
      _call('shopper_cancel_order', {'p_order_id': orderId});

  /// The Shopper's own orders, newest first.
  Future<List<ShopperOrder>> myOrders() async {
    final result = await _call('shopper_my_orders', {'p_limit': 50});
    if (result is! List) throw ShopperException(ShopperFailure.failed, result);
    return [
      for (final row in result)
        if (row is Map) ShopperOrder.fromRow(row.cast<String, Object?>()),
    ];
  }

  /// Everything held about the Shopper (#477): profile, phones, addresses and
  /// own Online Orders, as the server's JSON.
  Future<Map<String, Object?>> exportData() async {
    final result = await _call('shopper_export', const {});
    if (result is! Map) throw ShopperException(ShopperFailure.failed, result);
    return result.cast<String, Object?>();
  }

  /// Marketing consent (#477); returns the stored value.
  Future<bool> setMarketingOptIn(bool optIn) async {
    final result = await _call('shopper_set_marketing_opt_in', {
      'p_opt_in': optIn,
    });
    return result == true;
  }

  /// Deletes the Shopper's account (#438): cancels their New orders, erases
  /// their saved details and unlinks shop Customers. The login itself goes
  /// later (server job) unless it also belongs to a business.
  Future<void> deleteAccount() async {
    final result = await _call('shopper_delete_account', const {});
    if (result is Map && result['ok'] == true) return;
    throw ShopperException(ShopperFailure.failed, result);
  }

  /// Reports a product or a store (#478). Cloud-only; the server rate-limits
  /// (10 an hour) and keeps one open report per Shopper per target. Throws
  /// [ShopperException] (`rateLimited`, `signedOut`, ...) on failure.
  Future<void> reportListing({
    required ReportTarget target,
    required String targetId,
    required ReportReason reason,
    String? details,
  }) async {
    final trimmed = details?.trim();
    final result = await _call('shopper_report_listing', {
      'p_target_type': target.wire,
      'p_target_id': targetId,
      'p_reason': reason.wire,
      'p_details': trimmed == null || trimmed.isEmpty ? null : trimmed,
    });
    if (result is Map && result['ok'] == true) return;
    if (result is Map && result['code'] == 'rate_limited') {
      throw ShopperException(ShopperFailure.rateLimited, result);
    }
    throw ShopperException(ShopperFailure.failed, result);
  }

  Future<Object?> _call(String fn, Map<String, Object?> params) async {
    try {
      return await _rpc(fn, params).timeout(timeout);
    } on TimeoutException catch (e) {
      throw ShopperException(ShopperFailure.offline, e);
    } catch (e) {
      debugPrint('ShopperService: $fn failed ($e)');
      throw ShopperException(_classify(e), e);
    }
  }

  static ShopperFailure _classify(Object e) {
    if (isNetworkFailure(e)) return ShopperFailure.offline;
    final text = e is PostgrestException ? '${e.message} ${e.code}' : '$e';
    if (text.contains('order_not_cancellable')) {
      return ShopperFailure.notCancellable;
    }
    if (text.contains('shopper_profile_required')) {
      return ShopperFailure.profileRequired;
    }
    if (text.contains('sign in to continue') || text.contains('JWT')) {
      return ShopperFailure.signedOut;
    }
    return ShopperFailure.failed;
  }
}
