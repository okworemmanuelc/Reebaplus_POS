import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:reebaplus_pos/core/storefront/storefront_models.dart';
import 'package:reebaplus_pos/core/utils/network_failure.dart';

/// Calls one storefront RPC and returns its decoded JSON.
typedef StorefrontRpc =
    Future<Object?> Function(String function, Map<String, Object?> params);

/// Why a storefront read failed.
enum StorefrontFailure {
  /// No connection (or the request never reached the server).
  offline,

  /// The server answered with an error, or the answer was unreadable.
  failed,
}

class StorefrontException implements Exception {
  const StorefrontException(this.failure, [this.cause]);
  final StorefrontFailure failure;
  final Object? cause;

  @override
  String toString() => 'StorefrontException($failure, $cause)';
}

/// The Shopper's read path (#425, ADR 0031): the four signed-out storefront
/// RPCs (`storefront_feed`, `storefront_search`, `storefront_store`,
/// `storefront_store_products`) and nothing else.
///
/// Sanctioned direct-Supabase exception (architecture.md invariants #1/#4/#8,
/// Shopper exception): online only, never Drift, never the outbox, nothing
/// kept on the phone. Every eligibility rule and the stock label are decided
/// by the server; this class only shapes the rows.
class StorefrontService {
  StorefrontService(SupabaseClient client)
    : this.withRpc(
        rpc: (function, params) => client.rpc(function, params: params),
        isOnline: _connectivityOnline,
      );

  @visibleForTesting
  StorefrontService.withRpc({
    required StorefrontRpc rpc,
    Future<bool> Function()? isOnline,
    this.timeout = defaultTimeout,
  }) : _rpc = rpc,
       _isOnline = isOnline ?? _alwaysOnline;

  static const defaultTimeout = Duration(seconds: 15);

  /// Cards per page.
  static const pageSize = 24;

  final StorefrontRpc _rpc;
  final Future<bool> Function() _isOnline;
  final Duration timeout;

  /// The ranked cross-shop feed for [area] (in-stock items only).
  Future<StorefrontPage> feed({
    required ShopperArea area,
    String? category,
    String? after,
  }) => _page('storefront_feed', {
    ...area.toRpcParams(),
    'p_category': category,
    'p_after': after,
    'p_limit': pageSize,
  });

  /// Cross-store search by product name; out-of-stock items included.
  Future<StorefrontPage> search({
    required ShopperArea area,
    required String query,
    String? category,
    String? after,
  }) => _page('storefront_search', {
    'p_query': query.trim(),
    ...area.toRpcParams(),
    'p_category': category,
    'p_after': after,
    'p_limit': pageSize,
  });

  /// One store's header, or null when the store is not listed.
  Future<StorefrontStore?> store({
    required String storeId,
    required ShopperArea area,
  }) async {
    final rows = await _rows('storefront_store', {
      'p_store_id': storeId,
      ...area.toRpcParams(),
    });
    return rows.isEmpty ? null : StorefrontStore.fromRow(rows.first);
  }

  /// One store's catalogue (+ its own search); out-of-stock items included.
  Future<StorefrontPage> storeProducts({
    required String storeId,
    String? query,
    String? category,
    String? after,
  }) {
    final trimmed = query?.trim();
    return _page('storefront_store_products', {
      'p_store_id': storeId,
      'p_query': trimmed == null || trimmed.isEmpty ? null : trimmed,
      'p_category': category,
      'p_after': after,
      'p_limit': pageSize,
    });
  }

  Future<StorefrontPage> _page(String fn, Map<String, Object?> params) async {
    final rows = await _rows(fn, params);
    final cards = <StorefrontCard>[];
    try {
      for (final row in rows) {
        cards.add(StorefrontCard.fromRow(row));
      }
    } catch (e) {
      throw StorefrontException(StorefrontFailure.failed, e);
    }
    return StorefrontPage(
      cards: cards,
      nextCursor: cards.length >= pageSize ? cards.last.cursor : null,
    );
  }

  Future<List<Map<String, Object?>>> _rows(
    String fn,
    Map<String, Object?> params,
  ) async {
    if (!await _isOnline()) {
      throw const StorefrontException(StorefrontFailure.offline);
    }
    final Object? result;
    try {
      result = await _rpc(fn, params).timeout(timeout);
    } on TimeoutException catch (e) {
      throw StorefrontException(StorefrontFailure.offline, e);
    } catch (e) {
      debugPrint('StorefrontService: $fn failed ($e)');
      throw StorefrontException(
        isNetworkFailure(e) ? StorefrontFailure.offline : StorefrontFailure.failed,
        e,
      );
    }
    if (result is! List) {
      throw StorefrontException(StorefrontFailure.failed, result);
    }
    return [
      for (final row in result)
        if (row is Map) row.cast<String, Object?>(),
    ];
  }

  static Future<bool> _alwaysOnline() async => true;

  static Future<bool> _connectivityOnline() async {
    try {
      final results = await Connectivity().checkConnectivity();
      return results.any((r) => r != ConnectivityResult.none);
    } catch (_) {
      // Unknown: let the request decide.
      return true;
    }
  }
}
