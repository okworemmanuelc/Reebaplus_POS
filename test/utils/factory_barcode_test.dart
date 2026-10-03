import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/utils/factory_barcode.dart';

/// One vector from the shared fixture `test/fixtures/gtin_vectors.json`.
///
/// The same file is read by the tier-2 SQL test
/// (`test/integration/rpcs/barcode_suggestion_test.dart`), so the Dart parser
/// and `public.is_factory_gtin` / `public.gtin14` stay in lockstep (#330).
class _Vector {
  const _Vector({
    required this.code,
    required this.isFactory,
    required this.gtin14,
    required this.note,
  });

  factory _Vector.fromJson(Map<String, Object?> json) => _Vector(
    code: json['code']! as String,
    isFactory: json['factory']! as bool,
    gtin14: json['gtin14'] as String?,
    note: json['note']! as String,
  );

  final String code;
  final bool isFactory;
  final String? gtin14;
  final String note;
}

List<_Vector> _loadVectors() {
  final raw = File('test/fixtures/gtin_vectors.json').readAsStringSync();
  final decoded = jsonDecode(raw) as Map<String, Object?>;
  final list = decoded['vectors']! as List<Object?>;
  return [
    for (final item in list) _Vector.fromJson(item! as Map<String, Object?>),
  ];
}

void main() {
  final vectors = _loadVectors();

  test('the shared fixture has both factory and non-factory vectors', () {
    expect(vectors.where((v) => v.isFactory), isNotEmpty);
    expect(vectors.where((v) => !v.isFactory), isNotEmpty);
  });

  group('FactoryBarcode over the shared vectors', () {
    for (final v in vectors) {
      test('${jsonEncode(v.code)}: ${v.note}', () {
        expect(FactoryBarcode.isFactoryGtin(v.code), v.isFactory);
        expect(FactoryBarcode.padToGtin14(v.code), v.gtin14);

        final parsed = FactoryBarcode.tryParse(v.code);
        if (v.isFactory) {
          expect(parsed, isNotNull);
          expect(parsed!.gtin14, v.gtin14);
        } else {
          expect(parsed, isNull);
        }
      });
    }
  });

  test('UPC-A, EAN-13 with a leading 0 and GTIN-14 are one catalogue key', () {
    const upcA = '049000050103';
    final asUpc = FactoryBarcode.tryParse(upcA);
    final asEan = FactoryBarcode.tryParse('0$upcA');
    final asGtin14 = FactoryBarcode.tryParse('00$upcA');

    expect(asUpc, isNotNull);
    expect(asUpc!.gtin14, '00049000050103');
    expect(asEan, asUpc);
    expect(asGtin14, asUpc);
    expect(asEan.hashCode, asUpc.hashCode);
  });
}
