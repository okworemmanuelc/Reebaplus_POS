// #437 gate (ADR 0031): the shopper side sees no tenant data beyond what the
// storefront_* / shopper_* RPCs return — now that a business phone can open
// it from the till with a live tenant session. A static scan, so a new screen
// cannot quietly reach Drift tables or raw cloud tables.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

Iterable<File> _dartFiles(String dir) => Directory(dir)
    .listSync(recursive: true)
    .whereType<File>()
    .where((f) => f.path.endsWith('.dart'));

void main() {
  test('Browse screens never touch tenant data directly', () {
    const banned = <String, String>{
      // uuid_v7.dart (an id generator) is the one allowed database file.
      'core/database/app_database': 'Drift tables',
      'core/database/daos': 'DAOs',
      'stream_providers.dart': 'tenant stream providers',
      'databaseProvider': 'the tenant database',
      'supabaseClientProvider': 'the raw cloud client',
      '.from(': 'a raw cloud table read',
    };
    final offences = <String>[];
    for (final file in _dartFiles('lib/features/browse')) {
      final text = file.readAsStringSync();
      banned.forEach((needle, what) {
        if (text.contains(needle)) offences.add('${file.path}: $what');
      });
    }
    expect(offences, isEmpty);
  });

  test('storefront core reads no cloud tables and only its own RPCs', () {
    final offences = <String>[];
    final rpcName = RegExp(r"""(?:_rpc|_call|_rows)\(\s*'([a-z_]+)'""");
    for (final file in _dartFiles('lib/core/storefront')) {
      final text = file.readAsStringSync();
      if (text.contains('.from(')) offences.add('${file.path}: .from(');
      if (text.contains('core/database/app_database') ||
          text.contains('core/database/daos')) {
        offences.add('${file.path}: Drift import');
      }
      for (final m in rpcName.allMatches(text)) {
        final name = m.group(1)!;
        if (!RegExp(r'^(storefront|shopper)_').hasMatch(name)) {
          offences.add('${file.path}: rpc $name');
        }
      }
    }
    expect(offences, isEmpty);
  });

  test("only the owner's own store ids cross from the till (ownStoreIds)", () {
    // The single sanctioned bridge: storefront_providers reads the signed-in
    // business's own store ids to show "Your store". No other storefront file
    // may import tenant providers.
    final importers = [
      for (final file in _dartFiles('lib/core/storefront'))
        if (file.readAsStringSync().contains('stream_providers.dart'))
          file.path.split('/').last,
    ];
    expect(importers, ['storefront_providers.dart']);
  });
}
