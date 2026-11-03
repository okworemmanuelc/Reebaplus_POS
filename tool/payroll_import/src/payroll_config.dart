import 'dart:convert';
import 'dart:io';

/// The private import decisions (#672). The file lives beside the old export,
/// never in this repo: it names workers and holds the plan's expected totals.
class PayrollImportConfig {
  /// Old `Staff.id`s to import, in order. Anyone else stays archived, with
  /// every entry, loan and statement of theirs.
  final List<String> workerIds;

  /// Old `Staff.id` → the name to save, when it differs from the export.
  final Map<String, String> names;

  /// Old entry id (payroll or loan) → 'cash' | 'transfer' | 'other'. Anything
  /// not listed is 'cash', except a loan repayment taken out of a salary,
  /// which is always 'other' (as the app records it).
  final Map<String, String> paymentMethods;

  /// Old loan entry id → 'YYYY-MM-DD', for a loan whose real date is not a
  /// date written in its note (for example "Sometime in September").
  final Map<String, String> loanDates;

  /// Old salary entry id → 'YYYY-MM'. Default: the month before the payday.
  final Map<String, String> salaryMonths;

  /// The plan's figures, checked against the database after the import.
  final PayrollExpected expected;

  const PayrollImportConfig({
    required this.workerIds,
    this.names = const {},
    this.paymentMethods = const {},
    this.loanDates = const {},
    this.salaryMonths = const {},
    required this.expected,
  });

  factory PayrollImportConfig.fromJson(Map<String, Object?> json) {
    Map<String, String> strings(String key) => {
      for (final MapEntry(:key, :value)
          in ((json[key] as Map<String, Object?>?) ?? const {}).entries)
        key: value as String,
    };
    final workers = (json['workers'] as List<Object?>?) ?? const [];
    if (workers.isEmpty) {
      throw const FormatException('config: "workers" must list old Staff ids');
    }
    final config = PayrollImportConfig(
      workerIds: [for (final w in workers) w as String],
      names: strings('names'),
      paymentMethods: strings('paymentMethods'),
      loanDates: strings('loanDates'),
      salaryMonths: strings('salaryMonths'),
      expected: PayrollExpected.fromJson(
        (json['expected'] as Map<String, Object?>?) ??
            (throw const FormatException('config: "expected" is required')),
      ),
    );
    for (final method in config.paymentMethods.values) {
      if (!kPaymentMethods.contains(method)) {
        throw FormatException('config: unknown payment method "$method"');
      }
    }
    for (final day in config.loanDates.values) {
      if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(day)) {
        throw FormatException('config: loan date "$day" is not YYYY-MM-DD');
      }
    }
    for (final month in config.salaryMonths.values) {
      if (!RegExp(r'^\d{4}-(0[1-9]|1[0-2])$').hasMatch(month)) {
        throw FormatException('config: salary month "$month" is not YYYY-MM');
      }
    }
    return config;
  }

  static PayrollImportConfig read(String path) => PayrollImportConfig.fromJson(
    jsonDecode(File(path).readAsStringSync()) as Map<String, Object?>,
  );
}

const Set<String> kPaymentMethods = {'cash', 'transfer', 'other'};

/// The plan's "Checks after import", in kobo.
class PayrollExpected {
  final int workers;
  final int statements;
  final int salaryKobo;
  final int cashOutKobo;
  final int loanEntries;

  /// Old `Staff.id` → what that worker still owes. Workers not listed owe 0.
  final Map<String, int> loansOwedKobo;

  const PayrollExpected({
    required this.workers,
    required this.statements,
    required this.salaryKobo,
    required this.cashOutKobo,
    required this.loanEntries,
    required this.loansOwedKobo,
  });

  int get totalLoansOwedKobo =>
      loansOwedKobo.values.fold(0, (sum, owed) => sum + owed);

  factory PayrollExpected.fromJson(Map<String, Object?> json) {
    int number(String key) =>
        (json[key] as num?)?.toInt() ??
        (throw FormatException('config: expected.$key is required'));
    return PayrollExpected(
      workers: number('workers'),
      statements: number('statements'),
      salaryKobo: number('salaryKobo'),
      cashOutKobo: number('cashOutKobo'),
      loanEntries: number('loanEntries'),
      loansOwedKobo: {
        for (final MapEntry(:key, :value)
            in ((json['loansOwedKobo'] as Map<String, Object?>?) ?? const {})
                .entries)
          key: (value as num).toInt(),
      },
    );
  }
}
