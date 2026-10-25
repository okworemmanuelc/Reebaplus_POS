// #478: report a product or store. Service wire shape, rate limit, the
// dialog (with the keyboard up) and the sign-in gate.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/storefront/shopper_service.dart';
import 'package:reebaplus_pos/features/browse/screens/shopper_sign_in_screen.dart';
import 'package:reebaplus_pos/features/browse/screens/storefront_store_screen.dart';
import 'package:reebaplus_pos/features/browse/widgets/report_listing_dialog.dart';

import 'shopper_fixtures.dart';

Future<void> tapKey(WidgetTester tester, Key key) async {
  await tester.ensureVisible(find.byKey(key));
  await tester.tap(find.byKey(key));
  await tester.pumpAndSettle();
}

void main() {
  group('ShopperService.reportListing', () {
    test('sends the wire values and trims details', () async {
      final backend = FakeShopperBackend();
      await backend.service.reportListing(
        target: ReportTarget.product,
        targetId: 'p1',
        reason: ReportReason.illegalOrRestricted,
        details: '  sells fakes ',
      );
      expect(backend.calls.single.$1, 'shopper_report_listing');
      expect(backend.calls.single.$2, {
        'p_target_type': 'product',
        'p_target_id': 'p1',
        'p_reason': 'illegal_or_restricted',
        'p_details': 'sells fakes',
      });
    });

    test('blank details are sent as null', () async {
      final backend = FakeShopperBackend();
      await backend.service.reportListing(
        target: ReportTarget.store,
        targetId: 's1',
        reason: ReportReason.scam,
        details: '   ',
      );
      expect(backend.calls.single.$2['p_details'], isNull);
      expect(backend.calls.single.$2['p_target_type'], 'store');
    });

    test('a rate-limited answer is ShopperFailure.rateLimited', () async {
      final backend = FakeShopperBackend()
        ..reportResult = {'ok': false, 'code': 'rate_limited'};
      expect(
        backend.service.reportListing(
          target: ReportTarget.store,
          targetId: 's1',
          reason: ReportReason.other,
        ),
        throwsA(isA<ShopperException>()
            .having((e) => e.failure, 'failure', ShopperFailure.rateLimited)),
      );
    });

    test('signed-out refusal is ShopperFailure.signedOut', () async {
      final service = ShopperService.withRpc(
        rpc: (fn, params) async => throw Exception('sign in to continue'),
      );
      expect(
        service.reportListing(
          target: ReportTarget.product,
          targetId: 'p1',
          reason: ReportReason.offensive,
        ),
        throwsA(isA<ShopperException>()
            .having((e) => e.failure, 'failure', ShopperFailure.signedOut)),
      );
    });
  });

  group('report on the store page', () {
    testWidgets('signed in: pick a reason, add details, send', (tester) async {
      final backend = FakeShopperBackend();
      await pumpShopper(tester,
          screen: const StorefrontStoreScreen(storeId: 'store-1'),
          backend: backend,
          auth: FakeShopperAuth(email: 'ada@example.com'));
      await tapKey(tester, const Key('browse-report-store'));
      // Send does nothing until a reason is picked.
      await tester.tap(find.byKey(const Key('report-send')));
      await tester.pumpAndSettle();
      expect(find.byType(ReportListingDialog), findsOneWidget);
      expect(backend.calls.where((c) => c.$1 == 'shopper_report_listing'),
          isEmpty);
      await tapKey(tester, const Key('report-reason-scam'));
      await tester.enterText(
          find.byKey(const Key('report-details')), 'Took my money');
      await tapKey(tester, const Key('report-send'));
      final call = backend.calls.singleWhere(
          (c) => c.$1 == 'shopper_report_listing');
      expect(call.$2['p_target_type'], 'store');
      expect(call.$2['p_target_id'], 'store-1');
      expect(call.$2['p_reason'], 'scam');
      expect(call.$2['p_details'], 'Took my money');
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('signed out: asked to sign in, nothing is sent',
        (tester) async {
      final backend = FakeShopperBackend();
      await pumpShopper(tester,
          screen: const StorefrontStoreScreen(storeId: 'store-1'),
          backend: backend);
      await tapKey(tester, const Key('browse-report-store'));
      expect(find.byType(ShopperSignInScreen), findsOneWidget);
      expect(find.byType(ReportListingDialog), findsNothing);
      expect(backend.calls.where((c) => c.$1 == 'shopper_report_listing'),
          isEmpty);
    });
  });

  group('keyboard up (owner rule: text boxes stay reachable)', () {
    testWidgets('report dialog details box', (tester) async {
      await pumpShopper(
        tester,
        screen: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              key: const Key('open'),
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) =>
                    const ReportListingDialog(target: ReportTarget.product),
              ),
              child: const Text('open'),
            ),
          ),
        ),
        size: const Size(390, 640),
      );
      await tapKey(tester, const Key('open'));
      tester.view.viewInsets = const FakeViewPadding(bottom: 336);
      addTearDown(tester.view.resetViewInsets);
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('report-details')), 'x');
      await tester.pump();
      expect(tester.takeException(), isNull);
      // The dialog scrolls, so the box can be brought into view.
      await tester.ensureVisible(find.byKey(const Key('report-details')));
      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('report-send')), findsOneWidget);
    });
  });
}
