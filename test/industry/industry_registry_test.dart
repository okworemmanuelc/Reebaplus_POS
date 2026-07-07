// Industry registry seam (issue #77, ADR 0015). The registry is the single
// source of truth for the app's industries — display label, icon, coming-soon
// flag, crate-eligibility — and `industryOf()` is the total normalizer that
// resolves a stored `businesses.type` string to one canonical [Industry].
//
// These tests exercise the module's public behaviour, never its internals:
//   (a) resolution   — canonical labels, legacy casings, unknown/null → generic;
//   (b) membership   — the catalogue holds exactly the expected industries, in
//                      plan order, with no duplicates and the same coming-soon
//                      set the app shipped (proves the #77 prefactor is
//                      user-visible-behaviour-preserving);
//   (c) crate-gate   — crate-eligibility stays Bar/Beverage-only and reproduces
//                      the old hardcoded `isCrateBusiness` truth table exactly;
//   (d) golden pin   — a frozen snapshot of every catalogue entry, so any drift
//                      in a label/icon/flag surfaces here for deliberate review.
//
// Prior art: test/permissions/gate_registry_membership_test.dart (membership)
// and test/sync/sync_registry_golden_test.dart (frozen golden).

import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/industry/industry.dart';

void main() {
  // === (a) RESOLUTION — industryOf() is total ============================

  group('industryOf resolution', () {
    test('resolves every catalogue label to its own Industry', () {
      for (final ind in Industry.catalogue) {
        expect(industryOf(ind.label), ind,
            reason: 'canonical label "${ind.label}" must round-trip');
      }
    });

    test('resolution is case- and whitespace-insensitive', () {
      expect(industryOf('  bar  '), Industry.bar);
      expect(industryOf('PHARMACY'), Industry.pharmacy);
      expect(industryOf('beverage distributor'), Industry.beverage);
    });

    test('maps the legacy "Beer distributor" DB value and casings to beverage',
        () {
      // The DB stores 'Beer distributor' for beverage tenants; older builds
      // stored non-canonical casings. All must resolve to the beverage profile.
      expect(industryOf('Beer distributor'), Industry.beverage);
      expect(industryOf('Beer Distributor'), Industry.beverage);
      expect(industryOf('beer distributor'), Industry.beverage);
    });

    test('unknown, empty, blank, and null all resolve to generic (no crash)',
        () {
      expect(industryOf(null), Industry.generic);
      expect(industryOf(''), Industry.generic);
      expect(industryOf('   '), Industry.generic);
      expect(industryOf('Spaceship Repair'), Industry.generic);
    });
  });

  // === (b) MEMBERSHIP — the catalogue is exactly today's seven ===========

  group('registry membership', () {
    test('catalogue is the seven master-plan industries in plan order', () {
      expect(
        Industry.catalogue.map((i) => i.label).toList(),
        const [
          'Restaurant',
          'Supermarket',
          'Bar',
          'Beverage distributor',
          'Pharmacy',
          'Building Materials',
          'Boutique',
        ],
      );
    });

    test('generic is the fallback and is never offered in the catalogue', () {
      expect(Industry.catalogue, isNot(contains(Industry.generic)));
    });

    test('catalogue labels are unique', () {
      final labels = Industry.catalogue.map((i) => i.label).toList();
      expect(labels.toSet().length, labels.length,
          reason: 'duplicate label in the catalogue: $labels');
    });

    test('only Beverage distributor is selectable today (rest coming soon)', () {
      // #77 is a pure prefactor: the onboarding picker must show the same
      // selectable/greyed set it shows today. #79 flips these all on.
      final comingSoon = {
        for (final i in Industry.catalogue) i.label: i.comingSoon,
      };
      expect(comingSoon, {
        'Restaurant': true,
        'Supermarket': true,
        'Bar': true,
        'Beverage distributor': false,
        'Pharmacy': true,
        'Building Materials': true,
        'Boutique': true,
      });
    });
  });

  // === (c) CRATE-GATE — Bar/Beverage only, isCrateBusiness parity ========

  group('crate-eligibility', () {
    test('only Bar and Beverage are crate-eligible', () {
      final eligible =
          Industry.catalogue.where((i) => i.crateEligible).map((i) => i.label);
      expect(eligible, unorderedEquals(['Bar', 'Beverage distributor']));
      expect(Industry.generic.crateEligible, isFalse);
    });

    test('isCrateBusiness reproduces the old hardcoded truth table', () {
      // Verbatim behaviour of the pre-registry gate: true for exactly
      // {bar, beer distributor, beverage distributor} (case-insensitive).
      const crateTrue = [
        'Bar',
        'bar',
        'Beer distributor',
        'Beer Distributor',
        'beverage distributor',
        'Beverage distributor',
      ];
      const crateFalse = [
        'Restaurant',
        'Supermarket',
        'Pharmacy',
        'Building Materials',
        'Boutique',
        'Phone & Gadgets',
        'nonsense',
        '',
      ];
      for (final t in crateTrue) {
        expect(isCrateBusiness(t), isTrue, reason: '"$t" should be crate');
      }
      for (final t in crateFalse) {
        expect(isCrateBusiness(t), isFalse, reason: '"$t" should not be crate');
      }
      expect(isCrateBusiness(null), isFalse);
    });

    test('isCrateBusiness is exactly the registry crate flag', () {
      for (final t in [
        'Bar',
        'Beverage distributor',
        'Beer distributor',
        'Restaurant',
        'unknown',
        null,
      ]) {
        expect(isCrateBusiness(t), industryOf(t).crateEligible,
            reason: 'the shim must equal the registry flag for "$t"');
      }
    });
  });

  // === (d) GOLDEN PIN — frozen snapshot of the catalogue =================

  group('catalogue golden', () {
    // FROZEN GOLDEN DATA — the exact facts each catalogue entry held when the
    // registry was introduced. A diff here means an industry's label, icon,
    // coming-soon or crate flag changed: update this golden in the SAME commit,
    // deliberately. (label | icon codepoint | comingSoon | crateEligible)
    const golden = <String>[
      'Restaurant|0xf0108|true|false',
      'Supermarket|0xf86e|true|false',
      'Bar|0xf865|true|true',
      'Beverage distributor|0xf01b8|false|true',
      'Pharmacy|0xf877|true|false',
      'Building Materials|0xf7a3|true|false',
      'Boutique|0xf639|true|false',
    ];

    test('catalogue matches the frozen golden', () {
      final actual = Industry.catalogue
          .map((i) =>
              '${i.label}|0x${i.icon.codePoint.toRadixString(16)}|'
              '${i.comingSoon}|${i.crateEligible}')
          .toList();
      expect(actual, golden);
    });
  });
}
