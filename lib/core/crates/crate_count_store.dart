/// Which store a crate count (or any store-stamped crate action) belongs to
/// when the user does not have to be asked (PRD #284 stories 32–34).
///
/// - A locked store ([lockedStoreId], the app-wide active store) is the answer.
/// - In All Stores, a business the user can select exactly one store in has
///   only one possible answer, so it is used without asking.
/// - Otherwise the result is null: the caller must make the user pick one of
///   [selectableStoreIds]. A count is never recorded against no store.
String? crateCountStoreWithoutAsking({
  required String? lockedStoreId,
  required List<String> selectableStoreIds,
}) {
  if (lockedStoreId != null) return lockedStoreId;
  if (selectableStoreIds.length == 1) return selectableStoreIds.single;
  return null;
}
