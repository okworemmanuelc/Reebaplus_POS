import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/data/nigerian_lgas.dart';
import 'package:reebaplus_pos/core/data/nigerian_states.dart';

void main() {
  // INEC state-office directory; includes the six FCT area councils.
  const counts = {
    'Abia': 17, 'Adamawa': 21, 'Akwa Ibom': 31, 'Anambra': 21,
    'Bauchi': 20, 'Bayelsa': 8, 'Benue': 23, 'Borno': 27,
    'Cross River': 18, 'Delta': 25, 'Ebonyi': 13, 'Edo': 18,
    'Ekiti': 16, 'Enugu': 17, 'Federal Capital Territory': 6,
    'Gombe': 11, 'Imo': 27, 'Jigawa': 27, 'Kaduna': 23,
    'Kano': 44, 'Katsina': 34, 'Kebbi': 21, 'Kogi': 21,
    'Kwara': 16, 'Lagos': 20, 'Nasarawa': 13, 'Niger': 25,
    'Ogun': 20, 'Ondo': 18, 'Osun': 30, 'Oyo': 33,
    'Plateau': 17, 'Rivers': 23, 'Sokoto': 23, 'Taraba': 16,
    'Yobe': 17, 'Zamfara': 14,
  };

  test('all 36 states and FCT have the official number of distinct areas', () {
    expect(kNigerianStates, counts.keys.toList());
    expect(kNigerianLgas.keys, counts.keys);
    for (final entry in counts.entries) {
      final areas = kNigerianLgas[entry.key]!;
      expect(areas.length, entry.value, reason: entry.key);
      expect(areas.toSet().length, entry.value, reason: entry.key);
      expect(areas.every((area) => area.isNotEmpty && area == area.trim()), isTrue);
    }
    expect(kNigerianLgas.values.expand((areas) => areas).length, 774);
  });

  test('cloud seed contains exactly the bundled state/LGA pairs', () {
    final sql = File('supabase/migrations/0189_nigerian_areas.sql').readAsStringSync();
    final rows = RegExp(r"^  \('((?:''|[^'])*)', '((?:''|[^'])*)'\)[,;]$", multiLine: true)
        .allMatches(sql)
        .map((m) => (m[1]!.replaceAll("''", "'"), m[2]!.replaceAll("''", "'")))
        .toList();
    final expected = [
      for (final state in kNigerianLgas.entries)
        for (final area in state.value) (state.key, area),
    ];
    expect(rows, unorderedEquals(expected));
    expect(rows.toSet().length, 774);
  });

}
