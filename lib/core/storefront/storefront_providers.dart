import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/storefront/storefront_models.dart';
import 'package:reebaplus_pos/core/storefront/storefront_service.dart';

/// The storefront read path (#425). Overridden in tests.
final storefrontServiceProvider = Provider<StorefrontService>(
  (ref) => StorefrontService(ref.read(supabaseClientProvider)),
);

/// The Shopper's chosen browsing area, kept in device key-value storage only
/// (never Drift / outbox). `null` = not chosen yet (first Browse asks).
class ShopperAreaNotifier extends AsyncNotifier<ShopperArea?> {
  static const prefKey = 'storefront_shopper_area_v1';

  @override
  Future<ShopperArea?> build() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(prefKey);
      if (raw == null) return null;
      return ShopperArea.fromJson(jsonDecode(raw));
    } catch (_) {
      return null;
    }
  }

  Future<void> choose(ShopperArea area) async {
    state = AsyncData(area);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(prefKey, jsonEncode(area.toJson()));
    } catch (_) {
      // Remembering the area is a convenience; browsing still works.
    }
  }
}

final shopperAreaProvider =
    AsyncNotifierProvider<ShopperAreaNotifier, ShopperArea?>(
      ShopperAreaNotifier.new,
    );

/// Which list of cards to load.
enum StorefrontListKind { feed, search, store }

class StorefrontQuery {
  const StorefrontQuery.feed({required ShopperArea this.area, this.category})
    : kind = StorefrontListKind.feed,
      query = null,
      storeId = null;

  const StorefrontQuery.search({
    required ShopperArea this.area,
    required String this.query,
    this.category,
  }) : kind = StorefrontListKind.search,
       storeId = null;

  const StorefrontQuery.store({
    required String this.storeId,
    this.query,
    this.category,
  }) : kind = StorefrontListKind.store,
       area = null;

  final StorefrontListKind kind;
  final ShopperArea? area;
  final String? storeId;
  final String? query;
  final String? category;

  @override
  bool operator ==(Object other) =>
      other is StorefrontQuery &&
      other.kind == kind &&
      other.area == area &&
      other.storeId == storeId &&
      other.query == query &&
      other.category == category;

  @override
  int get hashCode => Object.hash(kind, area, storeId, query, category);
}

enum StorefrontListStatus { loading, ready, offline, failed }

class StorefrontListState {
  const StorefrontListState({
    this.status = StorefrontListStatus.loading,
    this.cards = const [],
    this.nextCursor,
    this.loadingMore = false,
  });

  final StorefrontListStatus status;
  final List<StorefrontCard> cards;
  final String? nextCursor;
  final bool loadingMore;

  bool get hasMore => nextCursor != null;

  StorefrontListState copyWith({
    StorefrontListStatus? status,
    List<StorefrontCard>? cards,
    String? nextCursor,
    bool clearCursor = false,
    bool? loadingMore,
  }) => StorefrontListState(
    status: status ?? this.status,
    cards: cards ?? this.cards,
    nextCursor: clearCursor ? null : (nextCursor ?? this.nextCursor),
    loadingMore: loadingMore ?? this.loadingMore,
  );
}

/// Loads a storefront list page by page (keyset cursor from the server).
class StorefrontListNotifier
    extends AutoDisposeFamilyNotifier<StorefrontListState, StorefrontQuery> {
  int _generation = 0;

  @override
  StorefrontListState build(StorefrontQuery arg) {
    _generation++;
    unawaited(_loadFirst(_generation));
    return const StorefrontListState();
  }

  Future<StorefrontPage> _fetch(String? after) {
    final service = ref.read(storefrontServiceProvider);
    return switch (arg.kind) {
      StorefrontListKind.feed => service.feed(
        area: arg.area!,
        category: arg.category,
        after: after,
      ),
      StorefrontListKind.search => service.search(
        area: arg.area!,
        query: arg.query!,
        category: arg.category,
        after: after,
      ),
      StorefrontListKind.store => service.storeProducts(
        storeId: arg.storeId!,
        query: arg.query,
        category: arg.category,
        after: after,
      ),
    };
  }

  Future<void> _loadFirst(int generation) async {
    try {
      final page = await _fetch(null);
      if (generation != _generation) return;
      state = StorefrontListState(
        status: StorefrontListStatus.ready,
        cards: page.cards,
        nextCursor: page.nextCursor,
      );
    } on StorefrontException catch (e) {
      if (generation != _generation) return;
      state = StorefrontListState(
        status: e.failure == StorefrontFailure.offline
            ? StorefrontListStatus.offline
            : StorefrontListStatus.failed,
      );
    }
  }

  /// Starts over (the "Try again" button).
  Future<void> retry() {
    _generation++;
    state = const StorefrontListState();
    return _loadFirst(_generation);
  }

  /// Appends the next page; a failure keeps what is shown.
  Future<void> loadMore() async {
    final cursor = state.nextCursor;
    if (cursor == null || state.loadingMore) return;
    final generation = _generation;
    state = state.copyWith(loadingMore: true);
    try {
      final page = await _fetch(cursor);
      if (generation != _generation) return;
      state = state.copyWith(
        cards: [...state.cards, ...page.cards],
        nextCursor: page.nextCursor,
        clearCursor: page.nextCursor == null,
        loadingMore: false,
      );
    } on StorefrontException {
      if (generation != _generation) return;
      state = state.copyWith(loadingMore: false);
    }
  }
}

final storefrontListProvider = NotifierProvider.autoDispose
    .family<StorefrontListNotifier, StorefrontListState, StorefrontQuery>(
      StorefrontListNotifier.new,
    );

/// One store's header for the shopper's area. `null` = not listed.
final storefrontStoreProvider = FutureProvider.autoDispose
    .family<StorefrontStore?, ({String storeId, ShopperArea area})>(
      (ref, key) => ref
          .read(storefrontServiceProvider)
          .store(storeId: key.storeId, area: key.area),
    );
