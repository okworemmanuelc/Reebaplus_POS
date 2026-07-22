import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Crate Pool seam guard (#157 / ADR 0020). The empty-crate pool has exactly ONE
/// writer: `CratePoolDao` in `lib/core/database/daos_crates.dart`. This test
/// fails the build if any other file writes a crate table — `crate_ledger`,
/// `supplier_crate_ledger`, or a `*_crate_balances` cache — or mutates the
/// `manufacturers.empty_crate_stock` scalar. That single-writer rule is what
/// keeps the ledger the source of truth: a new surface (report, van, screen) has
/// exactly one place to call and cannot reintroduce the balance drift the whole
/// refactor removes.
///
/// Scope: every `lib/**/*.dart` except the seam file itself, generated
/// `*.g.dart`, and files carrying a `// crate-seam-exempt-file:` marker — the
/// sync engine (restores cloud-authoritative rows on pull, not user movements)
/// and `app_database.dart` (crate writes there are DDL / append-only triggers /
/// the v63 opening-balance seed / clearAllData — table lifecycle, not
/// movements). A single line may opt out with a `// crate-seam-exempt:` marker
/// for a documented one-off.
///
/// Modeled on `test/sync/sync_raw_write_leak_test.dart`.
void main() {
  const seamFile = 'lib/core/database/daos_crates.dart';

  // The six crate tables — SQL names + their Drift table getters.
  const crateSqlTables = {
    'crate_ledger',
    'supplier_crate_ledger',
    'customer_crate_balances',
    'manufacturer_crate_balances',
    'store_crate_balances',
    'supplier_crate_balances',
  };
  const crateGetters = {
    'crateLedger',
    'supplierCrateLedger',
    'customerCrateBalances',
    'manufacturerCrateBalances',
    'storeCrateBalances',
    'supplierCrateBalances',
  };

  // Builder writes: into(t) / update(t) / delete(t), optionally db.-/_db.-qualified.
  final builderWrite =
      RegExp(r'\b(?:into|update|delete)\(\s*(?:_?db\.)?(\w+)\s*\)');
  // Raw-SQL writes to a crate table.
  final sqlWrite = RegExp(r'(?:INSERT\s+INTO|UPDATE|DELETE\s+FROM)\s+(\w+)');
  // A SET on the physical-pool scalar (a movement). Manufacturer *creation* via
  // a companion insert (`emptyCrateStock:`) is allowed — only the `= ...` SET
  // form is a mutation.
  final scalarMutation = RegExp(r'empty_crate_stock\s*=');
  // The Drift-builder form of a scalar mutation: a BARE `ManufacturersCompanion(`
  // — the update companion, distinct from `ManufacturersCompanion.insert(`
  // (creation, allowed) — that sets `emptyCrateStock`. Matched against the whole
  // source (the companion spans lines), so a future
  // `update(manufacturers).write(ManufacturersCompanion(emptyCrateStock: …))`
  // outside the seam is caught, not just the raw-SQL form.
  final updateCompanion = RegExp(r'ManufacturersCompanion\(');

  test('no crate table (or the empty_crate_stock scalar) is written outside the '
      'seam', () {
    final leaks = <String>[];
    for (final file in _dartFilesUnder('lib')) {
      final path = file.path;
      if (path.endsWith('.g.dart')) continue;
      if (path == seamFile) continue;
      final src = file.readAsStringSync();
      if (src.contains('// crate-seam-exempt-file:')) continue;

      final lines = src.split('\n');
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i];
        final trimmed = line.trimLeft();
        // Skip comment lines (a doc/inline comment naming a crate table is not a
        // write) — but the exempt marker itself is honored first.
        if (line.contains('// crate-seam-exempt:')) continue;
        if (trimmed.startsWith('//') || trimmed.startsWith('*')) continue;

        for (final m in builderWrite.allMatches(line)) {
          if (crateGetters.contains(m.group(1))) {
            leaks.add('$path:${i + 1}  builder write to "${m.group(1)}"');
          }
        }
        for (final m in sqlWrite.allMatches(line)) {
          if (crateSqlTables.contains(m.group(1))) {
            leaks.add('$path:${i + 1}  raw-SQL write to "${m.group(1)}"');
          }
        }
        if (scalarMutation.hasMatch(line)) {
          leaks.add(
            '$path:${i + 1}  mutation of manufacturers.empty_crate_stock',
          );
        }
      }

      // Builder-form scalar mutation: a bare update companion that sets the
      // scalar. Scanned over the whole source since the companion spans lines.
      for (final m in updateCompanion.allMatches(src)) {
        final window = src.substring(
          m.start,
          (m.start + 250).clamp(0, src.length),
        );
        if (window.contains('emptyCrateStock')) {
          final lineNo = '\n'.allMatches(src.substring(0, m.start)).length + 1;
          leaks.add(
            '$path:$lineNo  builder mutation of manufacturers.empty_crate_stock '
            '(update companion)',
          );
        }
      }
    }

    expect(
      leaks,
      isEmpty,
      reason:
          'Crate write(s) outside the CratePoolDao seam ($seamFile). Route the '
          'movement through a CratePoolDao domain verb — or, for a documented '
          'non-movement, add a `// crate-seam-exempt:` line marker (or '
          '`// crate-seam-exempt-file:` for a whole infra file):\n  '
          '${leaks.join('\n  ')}',
    );
  });
}

List<File> _dartFilesUnder(String dir) {
  final d = Directory(dir);
  if (!d.existsSync()) return const [];
  return d
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart'))
      .toList();
}
