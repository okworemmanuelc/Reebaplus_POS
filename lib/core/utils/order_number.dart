/// Order-number formatting (master plan §30.8.1).
///
/// The order number is `ORD-NNNNNN-XXXXXX`: a per-device running count plus a
/// short, stable per-device tag. The tag makes the full code unique across
/// offline tills — two devices that both mint the same count still differ on
/// the tag — so the `UNIQUE(business_id, order_number)` constraint can't be
/// tripped during an offline sale. See BUILD_LOG Session 122.
library;

/// Crockford base32 — excludes I, L, O, U so the tag can't be misread on a
/// printed receipt.
const String _crockford = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';

/// A short, stable, per-device tag derived from the device's opaque id.
///
/// Pure and deterministic (FNV-1a 32-bit → Crockford base32): the same
/// [deviceId] always yields the same 6-char tag, and different device ids
/// effectively never collide (~1.07e9 space). We hash explicitly because Dart's
/// `String.hashCode` is NOT stable across launches.
String deviceOrderTag(String deviceId) {
  // FNV-1a, 32-bit. Native ints are 64-bit so the multiply stays exact before
  // the mask (max ~0xFFFFFFFF * 0x01000193 ≈ 7.2e16 < 2^63).
  var hash = 0x811c9dc5;
  for (final unit in deviceId.codeUnits) {
    hash = (hash ^ unit) & 0xFFFFFFFF;
    hash = (hash * 0x01000193) & 0xFFFFFFFF;
  }
  // 6 chars × 5 bits = 30 bits of the 32-bit hash.
  final buf = StringBuffer();
  for (var i = 0; i < 6; i++) {
    buf.write(_crockford[hash & 0x1F]);
    hash >>= 5;
  }
  return buf.toString();
}

/// Formats the full order number from the per-device running [count] (the
/// number of orders already recorded on this device for the business) and the
/// device [tag]. The new order is `count + 1`, zero-padded to 6 digits.
String formatOrderNumber(int count, String tag) =>
    'ORD-${(count + 1).toString().padLeft(6, '0')}-$tag';
