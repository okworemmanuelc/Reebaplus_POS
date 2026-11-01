import 'dart:io';

import 'src/config.dart';
import 'src/export_reader.dart';
import 'src/ids.dart';
import 'src/outputs.dart';
import 'src/plan.dart';

const String _usage = '''
Builds the legacy-POS import. Writes files only; it never touches a database.

dart run tool/legacy_import/main.dart
  --export <dir>            the export folder (with data/ and manifest.json)
  --out <dir>               where import.sql, checks.sql and report.md go.
                            Never inside this repo.
  --accounts <file>         accounts JSON (see README.md)
  --business-name <name>
  --business-type <type>
  --owner-auth-uid <uuid>   businesses.owner_id; must be in the accounts file
  [--business-phone <p>] [--business-email <e>]  default: the old settings
  [--business-id <uuid>]    default: derived from the old settings row
''';

const Set<String> _required = {
  'export',
  'out',
  'accounts',
  'business-name',
  'business-type',
  'owner-auth-uid',
};
const Set<String> _optional = {
  'business-phone',
  'business-email',
  'business-id',
};

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
    stderr.writeln('--out must be outside the repo: output has real shop data');
    exitCode = 64;
    return;
  }

  final export = Export.load(values['export']!);
  final accountsFile = readAccountsFile(values['accounts']!);
  final settingsRow = export.rows('BusinessSettings').first;
  final config = ImportConfig(
    businessId: values['business-id'] ?? legacyId('Business', settingsRow.id),
    businessName: values['business-name']!,
    businessType: values['business-type']!,
    businessPhone: values['business-phone'],
    businessEmail: values['business-email'],
    ownerAuthUid: values['owner-auth-uid']!.trim().toLowerCase(),
    accounts: accountsFile.accounts,
    productTypeCategories: accountsFile.productTypeCategories,
  );

  final plan = Planner(export: export, config: config).build();

  outDir.createSync(recursive: true);
  File(
    '${outDir.path}/import.sql',
  ).writeAsStringSync(buildImportSql(plan: plan, config: config));
  File(
    '${outDir.path}/checks.sql',
  ).writeAsStringSync(buildChecksSql(plan: plan, config: config));
  File('${outDir.path}/report.md').writeAsStringSync(
    buildReport(plan: plan, config: config, manifestRows: export.manifestRows),
  );
  stdout.writeln(
    'Wrote import.sql, checks.sql and report.md to ${outDir.path}',
  );
}

/// True when [directory] sits in a git checkout, which is how generated shop
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
