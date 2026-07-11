/// Sentinel category-filter id for the **Uncategorized** bucket — the products
/// whose `categoryId` is `null` (e.g. after their category was deleted, #109).
///
/// A distinct sentinel rather than `null` because `null` already means "All" in
/// both the POS and Inventory category filters. This value is a UI-filter
/// concept only: it is never written to a product row, never enqueued, and
/// never reaches the cloud — a real `categoryId` is always a UUIDv7.
const String kUncategorizedCategoryId = '__uncategorized__';
