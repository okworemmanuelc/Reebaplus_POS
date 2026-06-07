import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/core/utils/order_number.dart';

/// Collision-proof order numbers (master plan §30.8.1). The per-device tag is
/// what stops two offline tills minting the same `ORD-` code. See BUILD_LOG
/// Session 122.
void main() {
  group('deviceOrderTag', () {
    test('is deterministic — same device id → same tag', () {
      const id = '019e9d13-82f5-7ed3-b198-aabbccddeeff';
      expect(deviceOrderTag(id), deviceOrderTag(id));
    });

    test('is 6 Crockford-base32 chars (no ambiguous I/L/O/U)', () {
      final tag = deviceOrderTag(UuidV7.generate());
      expect(tag.length, 6);
      expect(RegExp(r'^[0-9A-HJKMNP-TV-Z]{6}$').hasMatch(tag), isTrue,
          reason: 'tag "$tag" must be uppercase Crockford base32');
    });

    test('different device ids effectively never collide', () {
      // 2000 distinct device ids → expect no collision in a ~1.07e9 space.
      final tags = <String>{};
      for (var i = 0; i < 2000; i++) {
        tags.add(deviceOrderTag(UuidV7.generate()));
      }
      expect(tags.length, 2000);
    });

    test('two devices at the same count produce different full numbers', () {
      final tagA = deviceOrderTag(UuidV7.generate());
      final tagB = deviceOrderTag(UuidV7.generate());
      expect(tagA, isNot(tagB));
      // Both tills offline, both at local count 122 → next is 000123 each.
      expect(formatOrderNumber(122, tagA), isNot(formatOrderNumber(122, tagB)));
    });
  });

  group('formatOrderNumber', () {
    test('zero-pads the count+1 and appends the tag', () {
      expect(formatOrderNumber(0, 'K7M2QX'), 'ORD-000001-K7M2QX');
      expect(formatOrderNumber(122, 'K7M2QX'), 'ORD-000123-K7M2QX');
    });

    test('a new ORD- code never equals a legacy suffix-less one', () {
      // Legacy orders kept their suffix-less ORD-000123; the suffixed form is a
      // different string, so they can't collide on (business_id, order_number).
      expect(formatOrderNumber(122, 'K7M2QX'), isNot('ORD-000123'));
    });
  });
}
