import 'quantity.dart';

/// Rows per INSERT statement in the generated file.
const int kInsertBatchSize = 500;

String sqlText(String? value) =>
    value == null ? 'NULL' : "'${value.replaceAll("'", "''")}'";

String sqlInt(int? value) => value?.toString() ?? 'NULL';

String sqlBool(bool value) => value ? 'true' : 'false';

String sqlTime(DateTime? value) =>
    value == null ? 'NULL' : "'${value.toUtc().toIso8601String()}'";

String sqlQty(double value) => qtyLiteral(value);

/// One target table's rows, as SQL literals. Column defaults fill anything not
/// listed (`last_updated_at` included: a fresh stamp, so every row is newer than
/// any cursor).
class TargetTable {
  final String name;
  final List<String> columns;
  final String onConflict;
  final List<List<String>> rows = [];

  /// `ON CONFLICT DO NOTHING` with deterministic ids makes a re-run a no-op.
  TargetTable(
    this.name,
    this.columns, {
    this.onConflict = 'ON CONFLICT DO NOTHING',
  });

  void add(Map<String, String> row) {
    if (row.length != columns.length) {
      throw ArgumentError('$name row has ${row.keys}, expected $columns');
    }
    rows.add([
      for (final column in columns)
        row[column] ?? (throw ArgumentError('$name row lacks $column')),
    ]);
  }

  void writeInserts(StringSink out) {
    final header = 'INSERT INTO public.$name (${columns.join(', ')}) VALUES';
    for (var start = 0; start < rows.length; start += kInsertBatchSize) {
      final end = start + kInsertBatchSize < rows.length
          ? start + kInsertBatchSize
          : rows.length;
      out.writeln(header);
      for (var i = start; i < end; i++) {
        out.write('  (${rows[i].join(', ')})');
        out.writeln(i == end - 1 ? '' : ',');
      }
      out.writeln('$onConflict;');
    }
  }
}
