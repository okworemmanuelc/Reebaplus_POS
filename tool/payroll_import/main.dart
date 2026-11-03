import 'dart:convert';
import 'dart:io';

import '../legacy_import/src/ids.dart';
import 'src/payroll_config.dart';
import 'src/payroll_ids.dart';
import 'src/payroll_plan.dart';
import 'src/payroll_sql.dart';

const String _usage = '''
Builds the old-POS payroll import (#672). Writes files only; it never touches
a database.

dart run tool/payroll_import/main.dart
  --export <dir>         the old export folder (with data/)
  --config <file>        the private import decisions (see README.md)
  --out <dir>            where import.sql, checks.sql and report.md go.
                         Never inside this repo.
  [--business-id <uuid>] default: the id the #623 import derived
''';

const Set<String> _required = {'export', 'config', 'out'};
const Set<String> _optional = {'business-id'};

Map<String, String> _parse(List<String> args) {
  final values = <String, String>{};
  for (var i = 0; i < args.length; i += 2) {
    final flag = args[i];
    final name = flag.startsWith('--') ? flag.substring(2) : flag;
    if (!_required.contains(name) && !_optional.contains(name)) {
      throw FormatException('Unknown argument: $flag');
    }
    if (i + 1 >= args.length) throw FormatException('$flag needs a value');
    values[name] = args[i + 1];
  }
  final missing = _required.difference(values.keys.toSet());
  if (missing.isNotEmpty) {
    throw FormatException('Missing: ${missing.map((m) => '--$m').join(', ')}');
  }
  return values;
}

void main(List<String> args) {
  final Map<String, String> values;
  try {
    values = _parse(args);
  } on FormatException catch (error) {
    stderr
      ..writeln(error.message)
      ..writeln()
      ..writeln(_usage);
    exitCode = 64;
    return;
  }

  final outDir = Directory(values['out']!).absolute;
  if (_isInsideRepo(outDir)) {
    stderr.writeln('--out must be outside the repo: output has real pay data');
    exitCode = 64;
    return;
  }

  final exportDir = values['export']!;
  final businessId =
      values['business-id']?.trim().toLowerCase() ??
      _derivedBusinessId(exportDir);
  final PayrollPlan plan;
  final PayrollImportConfig config;
  try {
    config = PayrollImportConfig.read(values['config']!);
    plan = PayrollPlanner(
      export: PayrollExport.load(exportDir),
      config: config,
      businessId: businessId,
    ).build();
  } on PayrollImportError catch (error) {
    stderr.writeln(error.message);
    exitCode = 65;
    return;
  } on FormatException catch (error) {
    stderr.writeln(error.message);
    exitCode = 65;
    return;
  }

  outDir.createSync(recursive: true);
  File(
    '${outDir.path}/import.sql',
  ).writeAsStringSync(buildPayrollImportSql(plan: plan, userId: importUserId));
  File('${outDir.path}/checks.sql').writeAsStringSync(
    buildPayrollChecksSql(plan: plan, expected: config.expected),
  );
  File('${outDir.path}/report.md').writeAsStringSync(buildPayrollReport(plan));
  stdout.writeln(
    'Wrote import.sql, checks.sql and report.md to ${outDir.path} '
    '(${plan.workers.length} workers, ${plan.entries.length} entries, '
    '${plan.statements.length} statements, ${plan.payTotals.length} pay lines)',
  );
}

/// The business id the main import (#623) gave the shop: derived from the old
/// settings row, exactly as tool/legacy_import/main.dart does.
String _derivedBusinessId(String exportDir) {
  final line = File(
    '$exportDir/data/BusinessSettings.jsonl',
  ).readAsLinesSync().firstWhere((l) => l.trim().isNotEmpty);
  final id = (jsonDecode(line) as Map<String, Object?>)['id'] as String;
  return legacyId('Business', id);
}

/// True when [directory] sits in a git checkout, which is how generated pay
/// data would end up in the public repo.
bool _isInsideRepo(Directory directory) {
  for (var current = directory.absolute; ; current = current.parent) {
    final marker = '${current.path}/.git';
    if (Directory(marker).existsSync() || File(marker).existsSync()) {
      return true;
    }
    if (current.parent.path == current.path) return false;
  }
}
