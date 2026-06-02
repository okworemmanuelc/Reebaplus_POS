import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/utils/csv_export.dart';

void main() {
  group('buildCsv', () {
    test('joins header and rows with CRLF line endings', () {
      final csv = buildCsv(
        ['A', 'B'],
        [
          ['1', '2'],
          ['3', '4'],
        ],
      );
      expect(csv, 'A,B\r\n1,2\r\n3,4\r\n');
    });

    test('header only when there are no rows', () {
      expect(buildCsv(['A', 'B'], const []), 'A,B\r\n');
    });

    test('quotes fields containing a comma', () {
      final csv = buildCsv(
        ['Name', 'Value'],
        [
          ['Smith, John', '100'],
        ],
      );
      expect(csv, 'Name,Value\r\n"Smith, John",100\r\n');
    });

    test('escapes embedded double-quotes by doubling them and quoting', () {
      final csv = buildCsv(
        ['Note'],
        [
          ['He said "hi"'],
        ],
      );
      expect(csv, 'Note\r\n"He said ""hi"""\r\n');
    });

    test('quotes fields containing newlines', () {
      final csv = buildCsv(
        ['Note'],
        [
          ['line1\nline2'],
        ],
      );
      expect(csv, 'Note\r\n"line1\nline2"\r\n');
    });

    test('leaves plain fields unquoted', () {
      expect(buildCsv(['X'], [
        ['plain'],
      ]), 'X\r\nplain\r\n');
    });
  });
}
