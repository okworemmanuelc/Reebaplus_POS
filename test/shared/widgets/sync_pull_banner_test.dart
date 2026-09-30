import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/first_download_state.dart';
import 'package:reebaplus_pos/core/providers/manual_refresh.dart';
import 'package:reebaplus_pos/core/services/supabase_sync_service.dart';
import 'package:reebaplus_pos/features/sync/controllers/first_load_overlay_controller.dart';
import 'package:reebaplus_pos/shared/widgets/sync_pull_banner.dart';

/// PRD #313 slice 2 — quiet sync indicators. Pumps every [PullStage] with the
/// "first download in progress" signal on and off and asserts which of the top
/// bar, the pill, the centred overlay and the retry card is on screen.
void main() {
  final bar = find.byType(LinearProgressIndicator);
  final syncedPill = find.text('Synced');
  final failedPill = find.textContaining('Sync failed');
  final overlay = find.textContaining('Setting up');
  final card = find.text("Couldn't reach your store");

  /// Pumps the banner. The overlay state is pinned: its own state machine is
  /// covered by `first_load_overlay_controller_test.dart`.
  Future<ProviderContainer> pumpBanner(
    WidgetTester tester, {
    required PullStage stage,
    required bool firstDownload,
    FirstLoadOverlayState overlayState = FirstLoadOverlayState.hidden,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          pullStatusProvider.overrideWith(
            (ref) => ValueNotifier(PullStatus(stage: stage)),
          ),
          firstDownloadInProgressProvider.overrideWith(
            (ref) => ref.watch(_firstDownload),
          ),
          _firstDownload.overrideWith((ref) => firstDownload),
          firstLoadOverlayProvider.overrideWith(
            (ref) => _PinnedOverlay(overlayState),
          ),
          currentBusinessNameProvider.overrideWith((ref) => 'Mama Nkechi'),
        ],
        child: const MaterialApp(home: Scaffold(body: SyncPullBanner())),
      ),
    );
    return ProviderScope.containerOf(
      tester.element(find.byType(SyncPullBanner)),
    );
  }

  void setStage(ProviderContainer container, PullStage stage) =>
      container.read(pullStatusProvider).value = PullStatus(stage: stage);

  /// Lets the 250 ms cross-fades finish. Not pumpAndSettle: the bar and the
  /// spinners animate forever.
  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  group('top bar', () {
    for (final stage in PullStage.values) {
      testWidgets('$stage, first download in progress', (tester) async {
        await pumpBanner(tester, stage: stage, firstDownload: true);
        await settle(tester);

        expect(
          bar,
          stage == PullStage.background ? findsOneWidget : findsNothing,
        );
        expect(syncedPill, findsNothing);
        expect(failedPill, findsNothing);
        expect(overlay, findsNothing);
        expect(card, findsNothing);
      });

      testWidgets('$stage, first download finished: nothing at all', (
        tester,
      ) async {
        await pumpBanner(tester, stage: stage, firstDownload: false);
        await settle(tester);

        expect(bar, findsNothing);
        expect(syncedPill, findsNothing);
        expect(failedPill, findsNothing);
        expect(overlay, findsNothing);
        expect(card, findsNothing);
      });
    }

    testWidgets('stays until the first download finishes, then leaves no pill', (
      tester,
    ) async {
      final container = await pumpBanner(
        tester,
        stage: PullStage.background,
        firstDownload: true,
      );
      await settle(tester);
      expect(bar, findsOneWidget);

      setStage(container, PullStage.completed);
      container.read(_firstDownload.notifier).state = false;
      await settle(tester);

      expect(bar, findsNothing);
      expect(syncedPill, findsNothing);
    });

    testWidgets('stands down while the pull-down circle is showing', (
      tester,
    ) async {
      final container = await pumpBanner(
        tester,
        stage: PullStage.background,
        firstDownload: true,
      );
      container.read(manualPullActiveProvider.notifier).state = true;
      await settle(tester);
      expect(bar, findsNothing);

      container.read(manualPullActiveProvider.notifier).state = false;
      await settle(tester);
      expect(bar, findsOneWidget);
    });
  });

  group('a background pull on a phone that finished its download', () {
    testWidgets('succeeding shows no bar and no pill', (tester) async {
      final container = await pumpBanner(
        tester,
        stage: PullStage.completed,
        firstDownload: false,
      );

      setStage(container, PullStage.background);
      await settle(tester);
      expect(bar, findsNothing);

      setStage(container, PullStage.completed);
      await settle(tester);
      expect(bar, findsNothing);
      expect(syncedPill, findsNothing);
    });

    testWidgets('failing shows no bar and no pill', (tester) async {
      final container = await pumpBanner(
        tester,
        stage: PullStage.completed,
        firstDownload: false,
      );

      setStage(container, PullStage.background);
      await settle(tester);
      setStage(container, PullStage.failed);
      await settle(tester);

      expect(bar, findsNothing);
      expect(failedPill, findsNothing);
      expect(find.text('Retry'), findsNothing);
      expect(syncedPill, findsNothing);
    });
  });

  group('"Synced" pill', () {
    testWidgets('shows for 2 s after a pull-down refresh that really synced', (
      tester,
    ) async {
      final container = await pumpBanner(
        tester,
        stage: PullStage.completed,
        firstDownload: false,
      );
      await settle(tester);
      expect(syncedPill, findsNothing);

      container.read(manualRefreshSyncedProvider.notifier).recordSynced();
      await settle(tester);
      expect(syncedPill, findsOneWidget);

      await tester.pump(const Duration(seconds: 2));
      await settle(tester);
      expect(syncedPill, findsNothing);
    });
  });

  group('centre', () {
    testWidgets('the "Setting up…" overlay renders while the controller says loading', (
      tester,
    ) async {
      await pumpBanner(
        tester,
        stage: PullStage.background,
        firstDownload: true,
        overlayState: FirstLoadOverlayState.loading,
      );
      await settle(tester);

      expect(find.text('Setting up Mama Nkechi…'), findsOneWidget);
      expect(card, findsNothing);
      expect(bar, findsOneWidget);
      expect(syncedPill, findsNothing);
    });

    for (final firstDownload in [true, false]) {
      testWidgets(
        'the retry card renders when the controller says retryNeeded '
        '(first download in progress: $firstDownload)',
        (tester) async {
          await pumpBanner(
            tester,
            stage: PullStage.failed,
            firstDownload: firstDownload,
            overlayState: FirstLoadOverlayState.retryNeeded,
          );
          await settle(tester);

          expect(card, findsOneWidget);
          expect(find.widgetWithText(FilledButton, 'Retry'), findsOneWidget);
          expect(overlay, findsNothing);
          expect(bar, findsNothing);
          expect(failedPill, findsNothing);
          expect(syncedPill, findsNothing);
        },
      );
    }
  });
}

final _firstDownload = StateProvider<bool>((ref) => true);

/// A first-load overlay controller held at one state.
class _PinnedOverlay extends FirstLoadOverlayController {
  _PinnedOverlay(FirstLoadOverlayState pinned) {
    state = pinned;
  }
}
