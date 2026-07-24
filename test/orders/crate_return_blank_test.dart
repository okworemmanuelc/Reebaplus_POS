// #171 A2 — a blank part-deposit crate-count field must parse as 0 (never "all
// crates returned"), and Confirm is blocked until every field is filled. These
// are pure functions extracted from CrateReturnModal so the rule is testable
// without pumping the sheet.

import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/features/orders/widgets/crate_return_modal.dart';

void main() {
  group('parseReturnedCrateCount — blank means 0', () {
    test('an empty field parses to 0, NOT the expected count', () {
      expect(parseReturnedCrateCount(''), 0);
    });

    test('a whitespace-only field parses to 0', () {
      expect(parseReturnedCrateCount('   '), 0);
    });

    test('a non-numeric field parses to 0', () {
      expect(parseReturnedCrateCount('abc'), 0);
    });

    test('a real count parses to that number', () {
      expect(parseReturnedCrateCount('3'), 3);
      expect(parseReturnedCrateCount(' 12 '), 12);
      expect(parseReturnedCrateCount('0'), 0);
    });
  });

  group('allCrateCountsFilled — Confirm is blocked until every field is filled',
      () {
    test('a single blank field blocks Confirm', () {
      expect(allCrateCountsFilled(['3', '']), isFalse);
      expect(allCrateCountsFilled(['   ']), isFalse);
    });

    test('all fields filled (0 counts as filled) allows Confirm', () {
      expect(allCrateCountsFilled(['3', '0']), isTrue);
      expect(allCrateCountsFilled(['5']), isTrue);
    });

    test('an empty set is trivially filled (a non-crate order)', () {
      expect(allCrateCountsFilled(const []), isTrue);
    });
  });
}
