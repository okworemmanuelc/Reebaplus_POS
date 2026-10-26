import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/providers/business_scoped_stream.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/storefront/listing_quality.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Listing gaps for one store (#475): the sellable, online-visible products
/// that have stock at [storeId], and what each is still missing. Cheap and
/// derived; nothing is stored.
final storeListingGapsProvider =
    Provider.autoDispose.family<StoreListingGaps, String>((ref, storeId) {
  final held = ref.watch(_storeProductsProvider(storeId)).valueOrNull ??
      const <ProductDataWithStock>[];
  final categories = ref.watch(allCategoriesProvider).valueOrNull ?? const [];
  final marketplace = {
    for (final c in categories)
      if ((c.marketplaceCategory ?? '').trim().isNotEmpty) c.id,
  };
  return summariseStoreGaps([
    for (final h in held)
      if (h.totalStock > 0 &&
          h.product.showOnline &&
          h.product.isAvailable &&
          !h.product.isDeleted)
        ListingFacts(
          productId: h.product.id,
          hasPhoto: (h.product.imageUrl ?? '').trim().isNotEmpty,
          hasMarketplaceCategory: marketplace.contains(h.product.categoryId),
          hasDescription: (h.product.onlineDescription ?? '').trim().isNotEmpty,
        ),
  ]);
});

final _storeProductsProvider = businessScopedStreamAutoDisposeFamily<
    List<ProductDataWithStock>, String>(
  (ref, db, businessId, storeId) => db.inventoryDao.watchProductsByStore(storeId),
  whenAbsent: const [],
);
