// barcode_catalogue_service_test.dart
//
// #332 (ADR 0029 §8) — the shared barcode catalogue lookup is quiet: a
// non-factory code never reaches the network, and any failure gives null.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/services/barcode_catalogue_service.dart';
import 'package:reebaplus_pos/core/services/catalogue_lookup.dart';
import 'package:reebaplus_pos/core/services/catalogue_report.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show PostgrestException;

const _gtin = '6150001234561';

void main() {
  late List<String> rowCalls;
  late List<Uri> photoCalls;
  late List<CatalogueReportRequest> reportCalls;

  setUp(() {
    rowCalls = [];
    photoCalls = [];
    reportCalls = [];
  });

  BarcodeCatalogueService service({
    Future<BarcodeSuggestionRow?> Function(String code)? row,
    Future<Uint8List?> Function(Uri url)? photo,
    Future<void> Function(CatalogueReportRequest request)? send,
    Duration timeout = const Duration(milliseconds: 50),
  }) => BarcodeCatalogueService.withFetchers(
    fetchRow: (code) {
      rowCalls.add(code);
      return (row ?? (_) async => null)(code);
    },
    fetchPhoto: (url) {
      photoCalls.add(url);
      return (photo ?? (_) async => null)(url);
    },
    sendReport: (request) {
      reportCalls.add(request);
      return (send ?? (_) async {})(request);
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

  test('includePhoto false never downloads the photo', () async {
    final s = service(
      row: (_) async => (name: 'A', unit: 'Tin', photoUrl: 'https://x.test/a'),
      photo: (_) async => Uint8List.fromList([1]),
    );
    final got = await s.lookup(_gtin, includePhoto: false);
    expect(got!.name, 'A');
    expect(got.unit, 'Tin');
    expect(got.photoBytes, isNull);
    expect(photoCalls, isEmpty);
  });

  test('no photo URL skips the download; an all-empty row gives null',
      () async {
    final s = service(
      row: (_) async => (name: ' ', unit: null, photoUrl: null),
    );
    expect(await s.lookup(_gtin), isNull);
    expect(photoCalls, isEmpty);
  });

  group('lookupOutcome (#335)', () {
    test('a non-factory code is nothing shared, without a call', () async {
      final s = service(row: (_) async => (name: 'X', unit: null, photoUrl: null));
      expect(await s.lookupOutcome('SCAN-1'), isA<CatalogueNothingShared>());
      expect(rowCalls, isEmpty);
    });

    test('zero rows or an all-empty row is nothing shared', () async {
      expect(
        await service().lookupOutcome(_gtin),
        isA<CatalogueNothingShared>(),
      );
      final blank = service(
        row: (_) async => (name: ' ', unit: null, photoUrl: 'not a url'),
      );
      expect(await blank.lookupOutcome(_gtin), isA<CatalogueNothingShared>());
    });

    test('offline or slow is unreachable; a server error is failed', () async {
      final offline = service(
        row: (_) async => throw const SocketException('Failed host lookup'),
      );
      expect(await offline.lookupOutcome(_gtin), isA<CatalogueUnreachable>());

      final slow = service(
        row: (_) => Completer<BarcodeSuggestionRow?>().future,
      );
      expect(await slow.lookupOutcome(_gtin), isA<CatalogueUnreachable>());

      final broken = service(
        row: (_) async => throw const PostgrestException(message: 'boom'),
      );
      expect(await broken.lookupOutcome(_gtin), isA<CatalogueLookupFailed>());
    });

    test('keeps the photo URL without downloading it', () async {
      final s = service(
        row: (_) async => (name: null, unit: null, photoUrl: 'https://x.test/p.jpg'),
      );
      final got = await s.lookupOutcome(_gtin, includePhoto: false);
      final suggestion = (got as CatalogueFound).suggestion;
      expect(suggestion.photoUrl, 'https://x.test/p.jpg');
      expect(suggestion.photoBytes, isNull);
      expect(photoCalls, isEmpty);
      // Add Product's quiet lookup still has nothing to fill.
      expect(await s.lookup(_gtin, includePhoto: false), isNull);
    });
  });

  group('report (#335)', () {
    Future<CatalogueReportResult> send(BarcodeCatalogueService s) => s.report(
      businessId: 'biz-1',
      barcode: _gtin,
      reasons: {CatalogueReportReason.badPhoto, CatalogueReportReason.wrongName},
      note: '   ',
      shownName: 'Peak Milk',
      shownUnit: null,
      shownPhotoUrl: 'https://x.test/p.jpg',
    );

    test('sends the wire reasons in a fixed order and drops a blank note',
        () async {
      expect(await send(service()), isA<CatalogueReportSent>());
      final r = reportCalls.single;
      expect(r.businessId, 'biz-1');
      expect(r.barcode, _gtin);
      expect(r.reasons, ['wrong_name', 'bad_photo']);
      expect(r.note, isNull);
      expect(r.shownName, 'Peak Milk');
      expect(r.shownUnit, isNull);
      expect(r.shownPhotoUrl, 'https://x.test/p.jpg');
    });

    test('offline or slow is offline; a server error is failed', () async {
      final offline = service(
        send: (_) async => throw const SocketException('Network is unreachable'),
      );
      expect(await send(offline), isA<CatalogueReportOffline>());

      final slow = service(send: (_) => Completer<void>().future);
      expect(await send(slow), isA<CatalogueReportOffline>());

      final rejected = service(
        send: (_) async => throw const PostgrestException(
          message: 'not a member of this business',
          code: '42501',
        ),
      );
      expect(await send(rejected), isA<CatalogueReportFailed>());
    });
  });
}
