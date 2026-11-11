import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/services/supabase_sync_service.dart';
import 'package:reebaplus_pos/features/sync/widgets/sync_download_card.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('downloadPercent', () {
    test('empty / unknown total gives no percentage', () {
      expect(downloadPercent(0, 0), isNull);
      expect(downloadPercent(5, null), isNull);
      expect(downloadPercent(null, null), isNull);
    });
    test('one list and many lists', () {
      expect(downloadPercent(0, 100), 0);
      expect(downloadPercent(42, 100), 42);
      expect(downloadPercent(1, 3), 33);
      expect(downloadPercent(250, 1000), 25);
    });
    test('done > total is capped at 99 while running', () {
      expect(downloadPercent(150, 100), 99);
      expect(downloadPercent(100, 100), 99);
      expect(downloadPercent(999, 1000), 99);
    });
    test('finished is 100', () {
      expect(downloadPercent(100, 100, finished: true), 100);
      expect(downloadPercent(0, 0, finished: true), 100);
    });
    test('holdPercent never goes backwards', () {
      expect(holdPercent(null, 10), 10);
      expect(holdPercent(40, 30), 40);
      expect(holdPercent(40, 55), 55);
      expect(holdPercent(40, null), 40);
    });
  });

  group('card text', () {
    Future<ValueNotifier<PullStatus>> pump(
      WidgetTester tester,
      PullStatus first,
    ) async {
      SharedPreferences.setMockInitialValues({});
      final n = ValueNotifier(first);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [pullStatusProvider.overrideWith((ref) => n)],
          child: const MaterialApp(
            home: Scaffold(body: SyncDownloadCard(businessId: null)),
          ),
        ),
      );
      return n;
    }

    testWidgets('shows during a download, never backwards, gone when idle', (
      tester,
    ) async {
      final n = await pump(
        tester,
        const PullStatus(
          stage: PullStage.background,
          rowsTotal: 200,
          rowsDone: 100,
        ),
      );
      expect(find.text('50%'), findsOneWidget);
      n.value = const PullStatus(
        stage: PullStage.background,
        rowsTotal: 400,
        rowsDone: 100,
      );
      await tester.pump();
      expect(find.text('50%'), findsOneWidget);
      n.value = const PullStatus(
        stage: PullStage.background,
        rowsTotal: 400,
        rowsDone: 400,
      );
      await tester.pump();
      expect(find.text('99%'), findsOneWidget);
      n.value = PullStatus.idle;
      await tester.pump();
      expect(find.byKey(SyncDownloadCard.percentKey), findsNothing);
    });

    testWidgets('no percentage when total unknown', (tester) async {
      await pump(tester, const PullStatus(stage: PullStage.background));
      expect(find.byKey(SyncDownloadCard.percentKey), findsNothing);
    });
  });
}
