import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';

/// Sync safeguard — Layer C (CLAUDE.md §5). Catches the genuinely *silent*
/// failure: a local write to a synced table that never enqueues, so the row
/// lives on-device and the cloud never sees it (no queue row, nothing in the
/// Sync Issues screen). Models the source-scan style of
/// tool/lint_tenant_queries.dart, but method-scoped.
///
/// Rule: for every raw Drift write to a synced table — `into(<t>)`,
/// `update(<t>)`, `delete(<t>)`, or a `customStatement/customUpdate/
/// customInsert` whose SQL writes a synced table — the *enclosing method* must
/// contain enqueue evidence (any `enqueue…(` / `…Enqueue…(` call, which covers
/// `enqueueUpsert`, `enqueueDelete`, the `enqueue('domain:…')` envelope, and
/// helper calls like `_enqueueFullProduct(`) OR a `// sync-exempt: <reason>`
/// marker. Method-scoping (not statement adjacency) is required: enqueues live
/// in other branches, later in transactions, or in helper methods.
///
/// Scope: the DAO file + lib/shared + lib/features + lib/core/services. The
/// sync engine carries a `// sync-exempt-file:` marker (it restores
/// cloud-authoritative state — §5 #1/#2). Generated `*.g.dart` is skipped.
///
/// Known limitation (acceptable): a leaky method that *also* contains an
/// unrelated `enqueue…(` call would pass. Layer A still guards mis-targeted
/// enqueues, and Layer B guards unregistered tables.
void main() {
  test('no raw write to a synced table escapes the enqueue path', () {
    final syncedGetters = kSyncedTenantTables.map(_snakeToCamel).toSet();
    final syncedSqlNames = kSyncedTenantTables.toSet();

    final files = <File>[
      File('lib/core/database/daos.dart'),
      ..._dartFilesUnder('lib/shared'),
      ..._dartFilesUnder('lib/features'),
      ..._dartFilesUnder('lib/core/services'),
    ];

    final leaks = <String>[];
    for (final file in files) {
      if (!file.existsSync()) continue;
      final src = file.readAsStringSync();
      if (src.contains('// sync-exempt-file:')) continue;
      _scan(file.path, src, syncedGetters, syncedSqlNames, leaks);
    }

    expect(
      leaks,
      isEmpty,
      reason: 'Raw write(s) to a synced table with no enqueue in the enclosing '
          'method — the row would never reach the cloud (CLAUDE.md §5):\n  '
          '${leaks.join('\n  ')}\n\nRoute the write through a DAO that calls '
          'enqueueUpsert / enqueueDelete / enqueue, or — if it is a legitimate '
          '§5 exception — add a `// sync-exempt: <reason>` comment inside the '
          'method (or `// sync-exempt-file: <reason>` for a whole sync-engine '
          'file).',
    );
  });
}

/// `order_items` -> `orderItems` (snake SQL name -> Drift table getter).
String _snakeToCamel(String snake) {
  final parts = snake.split('_');
  return parts.first +
      parts.skip(1).map((p) {
        if (p.isEmpty) return p;
        return p[0].toUpperCase() + p.substring(1);
      }).join();
}

List<File> _dartFilesUnder(String dir) {
  final d = Directory(dir);
  if (!d.existsSync()) return const [];
  return d
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart') && !f.path.endsWith('.g.dart'))
      .toList();
}

/// Top-level member boundary: a newline + exactly two spaces + non-space.
/// Same heuristic as tool/lint_tenant_queries.dart — bounds a class method.
final _memberBoundary = RegExp(r'\n  [^\s]');

/// Any enqueue-shaped call: enqueueUpsert(, enqueueDelete(, enqueue(,
/// _enqueueFullProduct( … . A bare comment ("we don't enqueue it") has no `(`
/// and so does not satisfy it.
final _enqueueEvidence = RegExp(r'[Ee]nqueue\w*\(');

/// `into(t)`, `update(t)`, `delete(t)` — optionally `into(db.t)` / `into(_db.t)`.
/// Only matches when the sole argument is a single (optionally dotted)
/// identifier, which is exactly the Drift table-write form.
final _builderWrite = RegExp(r'\b(?:into|update|delete)\(\s*(?:\w+\.)?(\w+)\s*\)');

/// Raw-SQL writes inside custom* calls: `INSERT INTO t` / `UPDATE t` /
/// `DELETE FROM t`.
final _sqlWrite =
    RegExp(r'(?:INSERT\s+INTO|UPDATE|DELETE\s+FROM)\s+(\w+)', caseSensitive: true);

void _scan(
  String path,
  String src,
  Set<String> syncedGetters,
  Set<String> syncedSqlNames,
  List<String> leaks,
) {
  void consider(int matchStart, String table, String kind) {
    final before = src.substring(0, matchStart);
    final starts = _memberBoundary.allMatches(before);
    final methodStart = starts.isEmpty ? 0 : starts.last.start;
    final afterMatch = _memberBoundary.firstMatch(src.substring(matchStart));
    final methodEnd =
        afterMatch == null ? src.length : matchStart + afterMatch.start;
    final body = src.substring(methodStart, methodEnd);

    if (_enqueueEvidence.hasMatch(body)) return;
    if (body.contains('// sync-exempt:')) return;

    final line = '\n'.allMatches(before).length + 1;
    leaks.add('$path:$line  $kind write to "$table" with no enqueue');
  }

  for (final m in _builderWrite.allMatches(src)) {
    final getter = m.group(1)!;
    if (syncedGetters.contains(getter)) {
      consider(m.start, getter, 'drift');
    }
  }

  for (final m in _sqlWrite.allMatches(src)) {
    final table = m.group(1)!;
    if (syncedSqlNames.contains(table)) {
      consider(m.start, table, 'sql');
    }
  }
}
