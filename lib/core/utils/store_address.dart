/// Formats a store's fused `stores.location` for a printed/on-screen receipt.
///
/// `stores.location` is stored as the single fused string
/// `"<street>, <city/state>, <country>"` (see the Add/Edit Store sheets and
/// onboarding's `locationCombined`). Receipts show the address **without the
/// country** (§15.1), so this drops the trailing comma-separated segment and
/// returns street + city/state only.
///
/// A single-segment location is returned unchanged (there is no country segment
/// to drop). Returns `null` when the input is null or has no usable parts.
String? receiptStoreAddress(String? location) {
  if (location == null) return null;
  final parts = location
      .split(',')
      .map((p) => p.trim())
      .where((p) => p.isNotEmpty)
      .toList();
  if (parts.isEmpty) return null;
  if (parts.length == 1) return parts.first;
  return parts.sublist(0, parts.length - 1).join(', ');
}
