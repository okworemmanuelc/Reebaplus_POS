@Tags(['integration'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:reebaplus_pos/core/data/nigerian_lgas.dart';

void main() {
  final env = Platform.environment;
  final url = env['TEST_SUPABASE_URL'];
  final key = env['TEST_SUPABASE_ANON_KEY'];

  test('public cloud area reference exactly matches all bundled pairs', () async {
    final client = SupabaseClient(url!, key!);
    addTearDown(client.dispose);
    final actual = <(String, String)>[];
    // Explicit pagination: never assume the backend's configured row cap.
    const pageSize = 100;
    for (var start = 0; ;) {
      final rows = await client.from('ng_areas').select('state,lga')
          .order('state').order('lga').range(start, start + pageSize - 1);
      actual.addAll(rows.map((row) => (row['state'] as String, row['lga'] as String)));
      if (rows.isEmpty) break;
      start += rows.length;
    }
    expect(actual, unorderedEquals([
      for (final state in kNigerianLgas.entries)
        for (final area in state.value) (state.key, area),
    ]));
    expect(actual.length, 774);
  }, skip: url == null || key == null
      ? 'Set TEST_SUPABASE_URL and TEST_SUPABASE_ANON_KEY after deploying 0189 to a test backend.'
      : false);
}
