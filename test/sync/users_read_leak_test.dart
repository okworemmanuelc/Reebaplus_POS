import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Read-side companion to `sync_raw_write_leak_test.dart`. The existing leak
/// scanner only checks WRITES; this catches the cross-business READ leak.
///
/// The device deliberately holds more than one business's users (offline-first,
/// shared till). A bare `db.select(db.users)` in a screen or widget therefore
/// returns EVERY business's staff — the home-screen leak fixed in Session 92.
/// Feature/UI code must read users through a business-scoped DAO method (e.g.
/// `StoresDao.getUsersForCurrentBusiness`, or a method that filters by an
/// explicit `businessId`), never a raw unscoped select.
void main() {
  test('no raw unscoped db.select(db.users) under lib/features or lib/shared/widgets',
      () {
    final dirs = ['lib/features', 'lib/shared/widgets'];
    final offenders = <String>[];
    for (final d in dirs) {
      final dir = Directory(d);
      if (!dir.existsSync()) continue;
      for (final entity in dir.listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        if (entity.path.endsWith('.g.dart')) continue;
        final lines = entity.readAsLinesSync();
        for (var i = 0; i < lines.length; i++) {
          final code = lines[i].split('//').first; // strip line comments
          if (RegExp(r'select\(\s*db\.users\s*\)').hasMatch(code)) {
            offenders.add('${entity.path}:${i + 1}: ${lines[i].trim()}');
          }
        }
      }
    }
    expect(
      offenders,
      isEmpty,
      reason: 'Raw users read bypasses business scoping — route through a '
          'business-scoped DAO (e.g. StoresDao.getUsersForCurrentBusiness):\n'
          '${offenders.join('\n')}',
    );
  });
}
