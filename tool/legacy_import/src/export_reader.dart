import 'dart:convert';
import 'dart:io';

/// One old row. The export writes integers as JSON strings and timestamps as
/// UTC ISO strings, so values are typed here, at the boundary.
class Row {
  final Map<String, Object?> _values;

  const Row(this._values);

  String get id => text('id');

  String text(String column) {
    final value = _values[column];
    if (value == null) throw FormatException('$column is null in row $_values');
    return value.toString();
  }

  /// The value, or null when missing or blank.
  String? textOrNull(String column) {
    final value = _values[column]?.toString().trim();
    return value == null || value.isEmpty ? null : value;
  }

  int? intOrNull(String column) {
    final value = _values[column];
    return value == null ? null : num.parse(value.toString()).toInt();
  }

  int integer(String column) => num.parse(text(column)).toInt();

  double? doubleOrNull(String column) {
    final value = _values[column];
    return value == null ? null : num.parse(value.toString()).toDouble();
  }

  double decimal(String column) => num.parse(text(column)).toDouble();

  DateTime? timeOrNull(String column) {
    final value = _values[column];
    return value == null ? null : DateTime.parse(value.toString()).toUtc();
  }

  DateTime time(String column) => DateTime.parse(text(column)).toUtc();

  bool flag(String column) => _values[column] == true;
}

/// The old tables the import reads. Anything else in the export stays archive.
const List<String> kImportedOldTables = [
  'BusinessSettings',
  'Category',
  'Customer',
  'CustomerLedgerEntry',
  'EmptiesDepositEntry',
  'EmptiesLedgerEntry',
  'Product',
  'Profile',
  'Sale',
  'SaleItem',
  'StockMovement',
  'Store',
  'StoreStock',
  'StoreTransfer',
  'StoreTransferItem',
  'Supplier',
  'SupplierLedgerEntry',
  'SupplyDelivery',
  'SupplyDeliveryItem',
  'Van',
  'VanTrip',
];

/// The export, read-only. Only `data/` and `manifest.json` are ever opened; the
/// sensitive `auth/` folder is never touched.
class Export {
  final Map<String, List<Row>> _tables;

  /// When the export was taken. Everything in it happened before this.
  final DateTime generatedAt;

  /// Old table → the row count the export's sender verified.
  final Map<String, int> manifestRows;

  /// The old app's customer ledger net (+ = customers owe), from the manifest.
  final int? manifestCustomerLedgerNetKobo;

  const Export({
    required Map<String, List<Row>> tables,
    required this.generatedAt,
    this.manifestRows = const {},
    this.manifestCustomerLedgerNetKobo,
  }) : _tables = tables;

  List<Row> rows(String table) => _tables[table] ?? const [];

  static Export load(String directory) {
    final manifestFile = File('$directory/manifest.json');
    final manifest =
        jsonDecode(manifestFile.readAsStringSync()) as Map<String, Object?>;

    final tables = <String, List<Row>>{};
    for (final table in kImportedOldTables) {
      final file = File('$directory/data/$table.jsonl');
      tables[table] = [
        for (final line in file.readAsLinesSync())
          if (line.trim().isNotEmpty)
            Row(jsonDecode(line) as Map<String, Object?>),
      ];
    }

    final public = manifest['public_tables'] as Map<String, Object?>;
    final headline = manifest['headline_counts'] as Map<String, Object?>;
    final ledger = headline['customer_ledger_by_type'] as List<Object?>;
    return Export(
      tables: tables,
      generatedAt: DateTime.parse(manifest['generated_at'] as String).toUtc(),
      manifestRows: {
        for (final table in kImportedOldTables)
          table:
              ((public[table] as Map<String, Object?>)['rows_in_jsonl_file']
                      as num)
                  .toInt(),
      },
      manifestCustomerLedgerNetKobo: ledger.fold<int>(0, (total, row) {
        final sum = (row as Map<String, Object?>)['sum_cents'] as String;
        return total + int.parse(sum);
      }),
    );
  }
}
