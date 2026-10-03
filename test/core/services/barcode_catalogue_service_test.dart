// barcode_catalogue_service_test.dart
//
// #332 (ADR 0029 §8) — the shared barcode catalogue lookup is quiet: a
// non-factory code never reaches the network, and any failure gives null.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/services/barcode_catalogue_service.dart';

const _gtin = '6150001234561';

void main() {
  late List<String> rowCalls;
  late List<Uri> photoCalls;

  setUp(() {
    rowCalls = [];
    photoCalls = [];
  });

  BarcodeCatalogueService service({
    required Future<BarcodeSuggestionRow?> Function(String code) row,
    Future<Uint8List?> Function(Uri url)? photo,
    Duration timeout = const Duration(milliseconds: 50),
  }) => BarcodeCatalogueService.withFetchers(
    fetchRow: (code) {
      rowCalls.add(code);
      return row(code);
    },
    fetchPhoto: (url) {
      photoCalls.add(url);
      return (photo ?? (_) async => null)(url);
    },
    timeout: timeout,
  );

  test('a non-factory code never calls the RPC', () async {
    final s = service(
      row: (_) async => (name: 'X', unit: null, photoUrl: null),
    );
    expect(await s.lookup('SCAN-1'), isNull);
    expect(await s.lookup('6150001234562'), isNull); // bad check digit
    expect(await s.lookup(' $_gtin'), isNull); // strict, no trimming
    expect(rowCalls, isEmpty);
  });

  test('a row gives a trimmed name and unit plus the photo bytes', () async {
    final bytes = Uint8List.fromList([1, 2, 3]);
    final s = service(
      row: (_) async => (
        name: '  Peak Milk 400g ',
        unit: ' Tin',
        photoUrl: 'https://x.test/storage/v1/object/public/b/0.png',
      ),
      photo: (_) async => bytes,
    );
    final got = await s.lookup(_gtin);
    expect(got!.name, 'Peak Milk 400g');
    expect(got.unit, 'Tin');
    expect(got.photoBytes, bytes);
    expect(rowCalls, [_gtin]);
    expect(photoCalls.single.path, '/storage/v1/object/public/b/0.png');
  });

  test('zero rows gives null', () async {
    final s = service(row: (_) async => null);
    expect(await s.lookup(_gtin), isNull);
  });

  test('an RPC error gives null', () async {
    final s = service(row: (_) async => throw Exception('offline'));
    expect(await s.lookup(_gtin), isNull);
  });

  test('an RPC slower than the timeout gives null', () async {
    final never = Completer<BarcodeSuggestionRow?>();
    final s = service(row: (_) => never.future);
    expect(await s.lookup(_gtin), isNull);
  });

  test('a failed or slow photo keeps the name and unit', () async {
    final failing = service(
      row: (_) async => (name: 'A', unit: 'Tin', photoUrl: 'https://x.test/a'),
      photo: (_) async => throw Exception('404'),
    );
    final a = await failing.lookup(_gtin);
    expect(a!.name, 'A');
    expect(a.photoBytes, isNull);

    final slow = service(
      row: (_) async => (name: 'B', unit: null, photoUrl: 'https://x.test/b'),
      photo: (_) => Completer<Uint8List?>().future,
    );
    final b = await slow.lookup(_gtin);
    expect(b!.name, 'B');
    expect(b.photoBytes, isNull);
  });

  test('no photo URL skips the download; an all-empty row gives null',
      () async {
    final s = service(
      row: (_) async => (name: ' ', unit: null, photoUrl: null),
    );
    expect(await s.lookup(_gtin), isNull);
    expect(photoCalls, isEmpty);
  });
}
