// The shared "first download in progress" signal (PRD #313, slice 1).
//
// Driven purely through its inputs in a ProviderContainer — the bound business,
// the pull stage, and the device's SharedPreferences — asserting only what a
// consumer can observe: is the first download on this phone still in progress?

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/business_scoped_stream.dart';
import 'package:reebaplus_pos/core/providers/first_download_state.dart';
import 'package:reebaplus_pos/core/services/first_load_marker_service.dart';
import 'package:reebaplus_pos/core/services/supabase_sync_service.dart';

final _stage = StateProvider<PullStage>((ref) => PullStage.idle);
final _business = StateProvider<String?>((ref) => 'biz1');

/// The business the pull behind the stage ran for.
final _pullBusiness = StateProvider<String?>((ref) => 'biz1');

/// A container whose signal is kept alive, as MainLayout keeps it in the app.
ProviderContainer _container() {
  final container = ProviderContainer(
    overrides: [
      currentBusinessIdProvider.overrideWith((ref) => ref.watch(_business)),
      pullStageProvider.overrideWith((ref) => ref.watch(_stage)),
      pullBusinessIdReaderProvider.overrideWith(
        (ref) => () => ref.read(_pullBusiness),
      ),
    ],
  );
  addTearDown(container.dispose);
  container.listen(firstDownloadInProgressProvider, (_, _) {});
  return container;
}

/// Lets the stored marker resolve and any stage change reach the signal.
Future<void> _settle(ProviderContainer container) async {
  await container.read(firstDownloadMarkerProvider.future);
  await container.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('after a full sign-in it is in progress before any pull has started',
      () async {
    final container = _container();

    expect(container.read(firstDownloadInProgressProvider), isTrue);
    await _settle(container);
    expect(container.read(_stage), PullStage.idle);
    expect(container.read(firstDownloadInProgressProvider), isTrue);
  });

  test('it stays in progress while the pull is running', () async {
    final container = _container();
    await _settle(container);

    container.read(_stage.notifier).state = PullStage.background;
    await container.pump();

    expect(container.read(firstDownloadInProgressProvider), isTrue);
  });

  test('a pull that reaches completed ends it', () async {
    final container = _container();
    await _settle(container);

    container.read(_stage.notifier).state = PullStage.background;
    await container.pump();
    container.read(_stage.notifier).state = PullStage.completed;
    await container.pump();

    expect(container.read(firstDownloadInProgressProvider), isFalse);
  });

  test('a failed pull does not end it; the next completed pull does',
      () async {
    final container = _container();
    await _settle(container);

    container.read(_stage.notifier).state = PullStage.background;
    await container.pump();
    container.read(_stage.notifier).state = PullStage.failed;
    await container.pump();
    expect(container.read(firstDownloadInProgressProvider), isTrue);

    container.read(_stage.notifier).state = PullStage.background;
    await container.pump();
    container.read(_stage.notifier).state = PullStage.completed;
    await container.pump();
    expect(container.read(firstDownloadInProgressProvider), isFalse);
  });

  test('once ended it stays ended through later background pulls', () async {
    final container = _container();
    await _settle(container);
    container.read(_stage.notifier).state = PullStage.background;
    await container.pump();
    container.read(_stage.notifier).state = PullStage.completed;
    await container.pump();

    for (final stage in [PullStage.background, PullStage.failed]) {
      container.read(_stage.notifier).state = stage;
      await container.pump();
      expect(
        container.read(firstDownloadInProgressProvider),
        isFalse,
        reason: 'stage=$stage',
      );
    }
  });

  test('a finished download is remembered on the next app open', () async {
    final first = _container();
    await _settle(first);
    first.read(_stage.notifier).state = PullStage.background;
    await first.pump();
    first.read(_stage.notifier).state = PullStage.completed;
    await first.pump();
    // The write is fire-and-forget; give it a turn to land.
    await Future<void>.delayed(Duration.zero);

    // A cold start: nothing carried over but the device's stored preferences.
    // No pull has run yet, and none needs to.
    final restarted = _container();
    await _settle(restarted);

    expect(restarted.read(_stage), PullStage.idle);
    expect(restarted.read(firstDownloadInProgressProvider), isFalse);
  });

  test(
      'a download that finished with a table deferred still counts, so it does '
      'not come back on the next app open', () async {
    // pullChanges sets its own "clean full pull" marker only when nothing was
    // deferred. This device never got that marker, only a completed stage.
    final first = _container();
    await _settle(first);
    first.read(_stage.notifier).state = PullStage.background;
    await first.pump();
    first.read(_stage.notifier).state = PullStage.completed;
    await first.pump();
    await Future<void>.delayed(Duration.zero);

    expect(await FirstLoadMarkerService.hasCompletedPull('biz1'), isFalse);

    final restarted = _container();
    await _settle(restarted);
    expect(restarted.read(firstDownloadInProgressProvider), isFalse);
  });

  test('a phone that already holds a clean full pull is never in progress '
      'once its stored marker is read (PIN unlock)', () async {
    SharedPreferences.setMockInitialValues({'first_pull_done_v1_biz1': true});
    final container = _container();

    // Not known yet — first-time surfaces must not show on this frame either.
    expect(container.read(firstDownloadInProgressProvider), isTrue);
    await _settle(container);

    expect(container.read(firstDownloadInProgressProvider), isFalse);
  });

  test('a completed stage left over from before sign-in does not end it',
      () async {
    final container = ProviderContainer(
      overrides: [
        currentBusinessIdProvider.overrideWith((ref) => ref.watch(_business)),
        pullStageProvider.overrideWith((ref) => ref.watch(_stage)),
      pullBusinessIdReaderProvider.overrideWith(
        (ref) => () => ref.read(_pullBusiness),
      ),
        _stage.overrideWith((ref) => PullStage.completed),
      ],
    );
    addTearDown(container.dispose);
    container.listen(firstDownloadInProgressProvider, (_, _) {});
    await _settle(container);

    expect(container.read(firstDownloadInProgressProvider), isTrue);
  });

  test('with no business bound it reads as in progress', () async {
    final container = _container();
    container.read(_business.notifier).state = null;
    await _settle(container);

    expect(container.read(firstDownloadInProgressProvider), isTrue);
  });

  test('one business finishing does not end it for the next business signed '
      'in on the same phone', () async {
    final container = _container();
    await _settle(container);
    container.read(_stage.notifier).state = PullStage.background;
    await container.pump();
    container.read(_stage.notifier).state = PullStage.completed;
    await container.pump();
    expect(container.read(firstDownloadInProgressProvider), isFalse);

    container.read(_business.notifier).state = 'biz2';
    await _settle(container);

    expect(container.read(firstDownloadInProgressProvider), isTrue);
  });

  test('a pull that completes for another business does not end it, and is '
      'not remembered', () async {
    final container = _container();
    container.read(_pullBusiness.notifier).state = 'biz0';
    await _settle(container);
    container.read(_stage.notifier).state = PullStage.background;
    await container.pump();
    container.read(_stage.notifier).state = PullStage.completed;
    await container.pump();

    expect(container.read(firstDownloadInProgressProvider), isTrue);
    expect(await FirstLoadMarkerService.hasFinishedFirstDownload('biz1'), isFalse);
    expect(await FirstLoadMarkerService.hasFinishedFirstDownload('biz0'), isFalse);

    // Its own pull then runs and completes.
    container.read(_pullBusiness.notifier).state = 'biz1';
    container.read(_stage.notifier).state = PullStage.background;
    await container.pump();
    container.read(_stage.notifier).state = PullStage.completed;
    await container.pump();

    expect(container.read(firstDownloadInProgressProvider), isFalse);
  });

  group('FirstLoadMarkerService — finished-download marker', () {
    test('a wipe clears it, so the next sign-in is a first download again',
        () async {
      await FirstLoadMarkerService.markFirstDownloadFinished('biz1');
      expect(
        await FirstLoadMarkerService.hasFinishedFirstDownload('biz1'),
        isTrue,
      );

      await FirstLoadMarkerService.clearAllMarkers();

      expect(
        await FirstLoadMarkerService.hasFinishedFirstDownload('biz1'),
        isFalse,
      );
    });

    test('clearing one business leaves the other business finished', () async {
      await FirstLoadMarkerService.markFirstDownloadFinished('biz1');
      await FirstLoadMarkerService.markFirstDownloadFinished('biz2');

      await FirstLoadMarkerService.clearMarkerForBusiness('biz1');

      expect(
        await FirstLoadMarkerService.hasFinishedFirstDownload('biz1'),
        isFalse,
      );
      expect(
        await FirstLoadMarkerService.hasFinishedFirstDownload('biz2'),
        isTrue,
      );
    });
  });
}
