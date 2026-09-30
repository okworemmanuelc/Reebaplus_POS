import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/providers/manual_refresh.dart';
import 'package:reebaplus_pos/core/services/supabase_sync_service.dart';

/// PRD #313 slice 2: "Synced" must reflect a pull that really completed.
/// `pushThenPull` returns normally when another pull is already in flight, so
/// the answer is read from the pull status, not from the call returning.
void main() {
  late ValueNotifier<PullStatus> status;

  void stage(PullStage s) => status.value = PullStatus(stage: s);

  setUp(() => status = ValueNotifier(PullStatus.idle));
  tearDown(() => status.dispose());

  test('its own pull completing counts', () async {
    final synced = await pullReallyCompleted(
      status: status,
      pull: () async {
        stage(PullStage.background);
        stage(PullStage.completed);
      },
    );

    expect(synced, isTrue);
  });

  test('its own pull failing is rethrown, not reported as synced', () async {
    final result = pullReallyCompleted(
      status: status,
      pull: () async {
        stage(PullStage.background);
        stage(PullStage.failed);
        throw StateError('pull failed');
      },
    );

    await expectLater(result, throwsStateError);
  });

  test('a call that returns without any pull running does not count', () async {
    // A `completed` left over from an earlier pull is not this refresh's.
    stage(PullStage.completed);

    final synced = await pullReallyCompleted(status: status, pull: () async {});

    expect(synced, isFalse);
  });

  test('skipped behind a pull in flight: waits for that pull to complete', () async {
    stage(PullStage.background);
    var answered = false;

    final result = pullReallyCompleted(status: status, pull: () async {})
      ..then((_) => answered = true);
    await pumpEventQueue();
    expect(answered, isFalse, reason: 'The pull in flight has not ended yet');

    // Progress ticks keep the stage; they must not end the wait.
    status.value = status.value.copyWith(tablesDone: 3);
    await pumpEventQueue();
    expect(answered, isFalse);

    stage(PullStage.completed);
    expect(await result, isTrue);
  });

  test('skipped behind a pull in flight that then fails does not count', () async {
    stage(PullStage.background);

    final result = pullReallyCompleted(status: status, pull: () async {});
    await pumpEventQueue();
    stage(PullStage.failed);

    expect(await result, isFalse);
  });

  test('an earlier pull failing during the upload does not mask its own pull', () async {
    stage(PullStage.background);

    final synced = await pullReallyCompleted(
      status: status,
      pull: () async {
        // The pull that was in flight fails while the outbox drains…
        stage(PullStage.failed);
        // …then this refresh's own pull runs and completes.
        stage(PullStage.background);
        stage(PullStage.completed);
      },
    );

    expect(synced, isTrue);
  });

  test('stops listening once it has answered', () async {
    final counting = _CountingStatus();
    addTearDown(counting.dispose);

    await pullReallyCompleted(status: counting, pull: () async {});

    expect(counting.listeners, 0);
  });
}

class _CountingStatus extends ValueNotifier<PullStatus> {
  _CountingStatus() : super(PullStatus.idle);

  int listeners = 0;

  @override
  void addListener(VoidCallback listener) {
    listeners++;
    super.addListener(listener);
  }

  @override
  void removeListener(VoidCallback listener) {
    listeners--;
    super.removeListener(listener);
  }
}
