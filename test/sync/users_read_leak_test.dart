import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';

/// Read-side companion to `sync_raw_write_leak_test.dart`. The existing leak
/// scanner only checks WRITES; this catches the cross-business READ leak, in the
/// two shapes it has actually shipped in:
///
///   1. a raw `db.select(db.users)` in a screen or widget (Session 92);
///   2. a raw `customSelect` whose SQL reads a tenant table with no
///      `business_id` predicate (#205 — the Staff detail screen's five figures).
///
/// The device deliberately holds more than one business's rows (offline-first,
/// shared till, a staff account re-onboarded into a second business), so either
/// shape returns EVERY business's rows. Feature/UI code must read through a
/// business-scoped DAO method — `whereBusiness(t)` / `requireBusinessId()` — and
/// never raw-select a business-owned table (architecture.md invariant #5).
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

  test('no raw customSelect reads a tenant table without a business_id predicate',
      () {
    final offenders = <String>[];

    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File) continue;
      final path = entity.path;
      if (!path.endsWith('.dart') || path.endsWith('.g.dart')) continue;
      if (_deviceWideReaders.contains(path)) continue;

      final src = entity.readAsStringSync();
      for (final call in _customSelectCall.allMatches(src)) {
        // The statement runs to the next `;` — that spans the SQL literal, the
        // `variables:` list and the trailing `.get()` / `.watch()`.
        final semi = src.indexOf(';', call.end);
        final stmt = src.substring(call.start, semi == -1 ? src.length : semi);

        final leaked = _unscopedTenantReads(stmt);
        if (leaked.isEmpty) continue;

        final line = '\n'.allMatches(src.substring(0, call.start)).length + 1;
        offenders.add('$path:$line  reads ${leaked.join(", ")}');
      }
    }

    expect(
      offenders,
      isEmpty,
      reason:
          'A raw customSelect reads a business-owned table with no business_id '
          'predicate, so on a device holding two businesses\' rows it returns '
          'both (architecture.md invariant #5). Move the query behind a '
          'business-scoped DAO method (`whereBusiness(t)` / '
          '`requireBusinessId()`) — a screen must not raw-select a tenant table '
          'at all:\n${offenders.join('\n')}',
    );
  });

  test('the customSelect scan is strict — a planted leak is caught, the '
      'scoped form is not', () {
    // The exact statement #205 removed from staff_detail_screen.dart…
    const planted = 'await db.customSelect("SELECT COUNT(*) AS cnt FROM '
        'quick_sale_requests WHERE requested_by = ?1").getSingleOrNull();';
    expect(_unscopedTenantReads(planted), contains('quick_sale_requests'),
        reason: 'an unscoped tenant customSelect must be caught');

    // …a JOIN onto a tenant table counts too…
    const plantedJoin = 'db.customSelect("SELECT 1 FROM inventory i JOIN '
        'products p ON p.id = i.product_id WHERE i.quantity > 0").get();';
    expect(_unscopedTenantReads(plantedJoin), contains('products'),
        reason: 'a tenant table reached by JOIN must be caught');

    // …and the scoped forms do not trip the ban.
    for (final scoped in [
      'db.customSelect("SELECT SUM(qty) FROM inventory WHERE business_id = ?", '
          'variables: [Variable(businessId)]).watch();',
      'db.customSelect("SELECT id FROM orders WHERE business_id IN (?, ?)").get();',
      'db.customSelect("PRAGMA table_info(orders)").get();',
      'db.customSelect("SELECT 1 FROM sync_queue WHERE id = ?").get();',
    ]) {
      expect(_unscopedTenantReads(scoped), isEmpty,
          reason: 'a scoped / non-tenant statement must not trip the ban: $scoped');
    }
  });
}

/// Files whose raw reads legitimately span every business on the device, so a
/// `business_id` predicate would be wrong rather than missing:
///   * `app_database.dart` — migrations run before any session binds and
///     back-fill each business's rows (they carry `business_id` through as data);
///   * `schema_audit.dart` — resolves WHICH business a user id belongs to, so
///     scoping it on the answer would be circular.
/// The sync engine needs no entry: it interpolates the table name (`FROM $table`),
/// which never matches a literal tenant name.
const _deviceWideReaders = <String>{
  'lib/core/database/app_database.dart',
  'lib/core/diagnostics/schema_audit.dart',
};

/// A raw-SQL read — `db.customSelect(` in a screen, or a bare `customSelect(`
/// inside a DAO.
final _customSelectCall = RegExp(r'customSelect\s*\(');

/// The tables a statement reads. Keywords are uppercase in this codebase's SQL,
/// so the match stays off Dart identifiers like `from`.
final _sqlTableRead = RegExp(r'\b(?:FROM|JOIN)\s+([a-z_][a-z0-9_]*)');

/// `business_id = ?` / `i.business_id IN (…)` — the tenant filter itself, not a
/// `business_id` that merely appears in the SELECT list.
final _businessIdPredicate = RegExp(r'business_id\s*(?:=|IN\b|in\b)');

/// The tenant tables [stmt] reads without filtering on `business_id` — empty
/// when the statement is scoped, reads no tenant table, or is a PRAGMA. The one
/// place the rule is expressed, so the scanner and its self-check can never
/// drift apart.
Set<String> _unscopedTenantReads(String stmt) {
  final tenantTables = kSyncedTenantTables.toSet();
  final read = _sqlTableRead
      .allMatches(stmt)
      .map((m) => m.group(1)!)
      .where(tenantTables.contains)
      .toSet();
  if (read.isEmpty || _businessIdPredicate.hasMatch(stmt)) return const {};
  return read;
}
