import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/utils/name_case.dart';

void main() {
  group('toNameCase', () {
    test('empty or whitespace-only returns empty string', () {
      expect(toNameCase(''), '');
      expect(toNameCase('   '), '');
      expect(toNameCase('\t\n'), '');
    });

    test('trims and squashes repeated spaces into one', () {
      expect(toNameCase('  ADEBAYO   okafor  '), 'Adebayo Okafor');
      expect(toNameCase('star   lager     beer'), 'Star Lager Beer');
    });

    test('capitalises first letter of each word and lowers the rest', () {
      expect(toNameCase('sTAR'), 'Star');
      expect(toNameCase('ADEBAYO okafor'), 'Adebayo Okafor');
      expect(toNameCase('star lager beer'), 'Star Lager Beer');
      expect(toNameCase('ALLCAPS'), 'Allcaps');
    });

    test('capitalises after a hyphen', () {
      expect(toNameCase('coca-cola'), 'Coca-Cola');
      expect(toNameCase('COCA-COLA'), 'Coca-Cola');
      expect(toNameCase('co-op'), 'Co-Op');
      expect(toNameCase('ready-to-drink'), 'Ready-To-Drink');
    });

    test('capitalises after an opening bracket', () {
      expect(toNameCase('(big)'), '(Big)');
      expect(toNameCase('(BIG)'), '(Big)');
      expect(toNameCase('[crate]'), '[Crate]');
      expect(toNameCase('{small}'), '{Small}');
      expect(toNameCase('coca-cola (big)'), 'Coca-Cola (Big)');
      expect(toNameCase('(coca-cola)'), '(Coca-Cola)');
    });

    test('does not capitalise after an apostrophe', () {
      expect(toNameCase("mama's"), "Mama's");
      expect(toNameCase("MAMA's"), "Mama's");
      expect(toNameCase("MAMA'S"), "Mama's");
      expect(toNameCase("MAMA's kitchen"), "Mama's Kitchen");
      expect(toNameCase("MAMA'S KITCHEN"), "Mama's Kitchen");
      expect(toNameCase("d'angelo"), "D'angelo");
      expect(toNameCase("o'connor"), "O'connor");
      // Curly apostrophes
      expect(toNameCase("mama’s"), "Mama’s");
      expect(toNameCase("MAMA’S"), "Mama’S".replaceAll("’S", "’s"));
    });

    test('a word containing a digit stays exactly as typed', () {
      expect(toNameCase('50cl'), '50cl');
      expect(toNameCase('1.5L'), '1.5L');
      expect(toNameCase('7UP'), '7UP');
      expect(toNameCase('A14'), 'A14');
      expect(toNameCase('60CL'), '60CL');
      expect(toNameCase('(50cl)'), '(50cl)');
      expect(toNameCase('(1.5L)'), '(1.5L)');
      expect(toNameCase('sTAR lager 60CL'), 'Star Lager 60CL');
      expect(toNameCase('iphone 14 pro max'), 'Iphone 14 Pro Max');
      expect(toNameCase('coca-cola (50cl)'), 'Coca-Cola (50cl)');
    });

    test('is strictly idempotent', () {
      final cases = [
        '',
        '   ',
        'ADEBAYO okafor',
        'star lager beer',
        "MAMA's kitchen",
        "MAMA'S KITCHEN",
        'coca-cola',
        '(big)',
        '50cl',
        '1.5L',
        '7UP',
        'A14',
        'sTAR lager 60CL',
        'coca-cola (50cl)',
        'ready-to-drink (big) 330ml',
        "mr & mrs okafor's store",
      ];

      for (final input in cases) {
        final once = toNameCase(input);
        final twice = toNameCase(once);
        expect(twice, once, reason: 'Failed idempotency for "$input"');
      }
    });
  });
}
