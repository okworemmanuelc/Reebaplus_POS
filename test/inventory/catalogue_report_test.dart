// catalogue_report_test.dart
//
// #335 (PRD #322, ADR 0029 §6) — "Report a problem with the shared details"
// on product details. A BarcodeCatalogueService built with fake fetchers
// stands in for the network.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show PostgrestException;

import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/business_scoped_stream.dart';
import 'package:reebaplus_pos/core/services/barcode_catalogue_service.dart';
import 'package:reebaplus_pos/features/inventory/widgets/catalogue_report_link.dart';
import 'package:reebaplus_pos/features/inventory/widgets/catalogue_report_sheet.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:reebaplus_pos/shared/widgets/app_input.dart';

/// A real factory GTIN (EAN-13, Nigeria prefix 615).
const _gtin = '6150001234561';
const _photoUrl =
    'https://x.test/storage/v1/object/public/barcode-catalogue-photos/1.jpg';

class _Fake {
  BarcodeSuggestionRow? row = (
    name: 'Peak Milk 400g',
    unit: 'Tin',
    photoUrl: _photoUrl,
  );
  Object? rowError;
  bool rowHangs = false;
  Object? sendError;
  final rowCalls = <String>[];
  final photoCalls = <Uri>[];
  final sent = <CatalogueReportRequest>[];

  BarcodeCatalogueService build() => BarcodeCatalogueService.withFetchers(
    fetchRow: (code) async {
      rowCalls.add(code);
      if (rowHangs) return Completer<BarcodeSuggestionRow?>().future;
      final error = rowError;
      if (error != null) throw error;
      return row;
    },
    fetchPhoto: (url) async {
      photoCalls.add(url);
      return Uint8List(0);
    },
    sendReport: (request) async {
      sent.add(request);
      final error = sendError;
      if (error != null) throw error;
    },
    timeout: const Duration(milliseconds: 200),
  );
}

void main() {
  late _Fake fake;

  setUp(() => fake = _Fake());

  Future<void> pumpLink(WidgetTester tester, String? barcode) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          barcodeCatalogueServiceProvider.overrideWithValue(fake.build()),
          currentBusinessIdProvider.overrideWithValue('biz-1'),
        ],
        child: MaterialApp(
          home: Scaffold(body: CatalogueReportLink(barcode: barcode)),
        ),
      ),
    );
  }

  Future<void> openSheet(WidgetTester tester) async {
    await pumpLink(tester, _gtin);
    await tester.tap(find.text(CatalogueReportLink.label));
    await tester.pumpAndSettle();
  }

  AppButton sendButton(WidgetTester tester) => tester.widget<AppButton>(
    find.widgetWithText(AppButton, CatalogueReportSheet.sendLabel),
  );

  /// Lets AppNotification's 4 s auto-dismiss timer run out.
  Future<void> drainToast(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  }

  group('the link', () {
    testWidgets('is hidden with no barcode or a non-GTIN barcode', (
      tester,
    ) async {
      for (final code in [null, '', 'SCAN-1', '6150001234562', '2001234567893']) {
        await pumpLink(tester, code);
        expect(
          find.text(CatalogueReportLink.label),
          findsNothing,
          reason: 'barcode $code',
        );
      }
      expect(fake.rowCalls, isEmpty);
    });

    testWidgets('shows for a factory GTIN', (tester) async {
      await pumpLink(tester, _gtin);
      expect(find.text(CatalogueReportLink.label), findsOneWidget);
    });
  });

  group('the sheet', () {
    testWidgets('shows the shared name, unit and photo, without downloading it', (
      tester,
    ) async {
      await openSheet(tester);

      expect(find.byType(CatalogueReportSheet), findsOneWidget);
      expect(fake.rowCalls, [_gtin]);
      expect(find.textContaining('Peak Milk 400g', findRichText: true), findsOneWidget);
      expect(find.textContaining('Tin', findRichText: true), findsOneWidget);
      final photo = tester.widget<Image>(
        find.byKey(const ValueKey('catalogue-report-photo')),
      );
      expect((photo.image as NetworkImage).url, _photoUrl);
      expect(fake.photoCalls, isEmpty);
      for (final label in [
        'Wrong name',
        'Wrong unit',
        'Bad or private photo',
      ]) {
        expect(find.text(label), findsOneWidget);
      }
    });

    testWidgets('Send stays disabled until a reason is ticked', (tester) async {
      await openSheet(tester);
      expect(sendButton(tester).onPressed, isNull);

      await tester.tap(find.text('Wrong unit'));
      await tester.pump();
      expect(sendButton(tester).onPressed, isNotNull);

      await tester.tap(find.text('Wrong unit'));
      await tester.pump();
      expect(sendButton(tester).onPressed, isNull);
    });

    testWidgets('nothing shared: says so and has no Send', (tester) async {
      fake.row = null;
      await openSheet(tester);
      expect(find.text(CatalogueReportSheet.nothingShared), findsOneWidget);
      expect(find.text(CatalogueReportSheet.sendLabel), findsNothing);
    });

    testWidgets('offline while loading: asks for internet, has no Send', (
      tester,
    ) async {
      fake.rowError = const SocketException('Failed host lookup');
      await openSheet(tester);
      expect(find.text(CatalogueReportSheet.offline), findsOneWidget);
      expect(find.text(CatalogueReportSheet.sendLabel), findsNothing);
    });

    testWidgets('a lookup slower than ~2 s counts as offline', (tester) async {
      fake.rowHangs = true;
      await pumpLink(tester, _gtin);
      await tester.tap(find.text(CatalogueReportLink.label));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      expect(find.text(CatalogueReportSheet.offline), findsOneWidget);
      expect(find.text(CatalogueReportSheet.sendLabel), findsNothing);
    });

    testWidgets('a successful send closes the sheet with the toast', (
      tester,
    ) async {
      await openSheet(tester);
      await tester.tap(find.text('Wrong name'));
      await tester.tap(find.text('Bad or private photo'));
      await tester.pump();
      await tester.enterText(find.byType(AppInput), '  It is a photo of a cat ');
      await tester.tap(find.text(CatalogueReportSheet.sendLabel));
      await tester.pumpAndSettle();

      expect(find.byType(CatalogueReportSheet), findsNothing);
      expect(find.text(CatalogueReportLink.sentMessage), findsOneWidget);
      final request = fake.sent.single;
      expect(request.businessId, 'biz-1');
      expect(request.barcode, _gtin);
      expect(request.reasons, ['wrong_name', 'bad_photo']);
      expect(request.note, 'It is a photo of a cat');
      expect(request.shownName, 'Peak Milk 400g');
      expect(request.shownUnit, 'Tin');
      expect(request.shownPhotoUrl, _photoUrl);
      await drainToast(tester);
    });

    testWidgets('offline on send: asks for internet, stays open, nothing queued', (
      tester,
    ) async {
      fake.sendError = const SocketException('Network is unreachable');
      await openSheet(tester);
      await tester.tap(find.text('Wrong name'));
      await tester.pump();
      await tester.tap(find.text(CatalogueReportSheet.sendLabel));
      await tester.pumpAndSettle();

      expect(find.byType(CatalogueReportSheet), findsOneWidget);
      expect(find.text(CatalogueReportSheet.offline), findsOneWidget);
      expect(find.text(CatalogueReportLink.sentMessage), findsNothing);
      expect(fake.sent, hasLength(1));
      // Can send again once back online.
      expect(sendButton(tester).onPressed, isNotNull);
    });

    testWidgets('a server failure shows an inline error and stays open', (
      tester,
    ) async {
      fake.sendError = const PostgrestException(message: 'boom', code: 'P0001');
      await openSheet(tester);
      await tester.tap(find.text('Wrong name'));
      await tester.pump();
      await tester.tap(find.text(CatalogueReportSheet.sendLabel));
      await tester.pumpAndSettle();

      expect(find.byType(CatalogueReportSheet), findsOneWidget);
      expect(find.text(CatalogueReportSheet.sendFailed), findsOneWidget);
      expect(find.text(CatalogueReportLink.sentMessage), findsNothing);
      expect(sendButton(tester).onPressed, isNotNull);
    });
  });
}
