@Tags(['integration'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:reebaplus_pos/core/data/marketplace_categories.dart';

void main() {
  final url = Platform.environment['TEST_SUPABASE_URL'];
  final key = Platform.environment['TEST_SUPABASE_ANON_KEY'];
  test('public cloud categories match bundled catalogue and restriction metadata', () async {
    final client = SupabaseClient(url!, key!);
    addTearDown(client.dispose);
    final actual = <Map<String, Object?>>[];
    for (var start = 0; ;) {
      final rows = await client.from('marketplace_categories')
          .select('slug,name,parent_slug,sort,restricted')
          .order('sort', ascending: true).order('slug', ascending: true)
          .range(start, start + 24);
      actual.addAll(rows);
      if (rows.isEmpty) break;
      start += rows.length;
    }
    expect(actual, [
      for (final c in marketplaceCategories) {
        'slug': c.slug, 'name': c.name, 'parent_slug': c.parentSlug,
        'sort': c.sort, 'restricted': c.restricted,
      },
    ]);
  }, skip: url == null || key == null
      ? 'Set TEST_SUPABASE_URL and TEST_SUPABASE_ANON_KEY on a test backend with 0190 + 0206 (#479).'
      : false);
}
