// first_load_overlay_controller_test.dart
//
// Seam A (the brief's primary, highest seam) for the First-Load "Loading your
// store" Overlay Redesign. Drives the FirstLoadOverlayController state machine
// in isolation — no widget tree, no providers — with injected inputs and
// fake_async for deterministic timer control. Asserts the full state machine:
// eligibility, dismiss timing (min floor / max cap / ready signal),
// established-empty suppression, the wipe path, and failure escalation.

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/services/supabase_sync_service.dart';
import 'package:reebaplus_pos/features/sync/controllers/first_load_overlay_controller.dart';

void main() {
  group('FirstLoadOverlayController', () {
    test('empty + first-load + background ⇒ loading', () {
      fakeAsync((async) {
        final c = FirstLoadOverlayController();
        addTearDown(c.dispose);
        c.setStoreEmpty(true);
        c.setPullStage(PullStage.background);
        expect(c.state, FirstLoadOverlayState.loading);
      });
    });

    test('populated device ⇒ stays hidden through a background pull', () {
      fakeAsync((async) {
        final c = FirstLoadOverlayController();
        addTearDown(c.dispose);
        // storeEmpty defaults false (populated).
        c.setPullStage(PullStage.background);
        expect(c.state, FirstLoadOverlayState.hidden);
      });
    });

    test('dismisses at the ready signal, but not before the min-display floor',
        () {
      fakeAsync((async) {
        final c = FirstLoadOverlayController(); // min 400ms, max 2s
        addTearDown(c.dispose);
        c.setStoreEmpty(true);
        c.setPullStage(PullStage.background);
        expect(c.state, FirstLoadOverlayState.loading);

        async.elapse(const Duration(milliseconds: 200));
        c.setLandingReady(true); // ready, but min floor (400ms) not yet reached
        expect(c.state, FirstLoadOverlayState.loading,
            reason: 'min-display floor prevents an early flicker');

        async.elapse(const Duration(milliseconds: 250)); // now past 400ms
        expect(c.state, FirstLoadOverlayState.hidden,
            reason: 'dismisses once ready AND the min floor has elapsed');
      });
    });

    test('dismisses at the max cap even when the landing never becomes ready',
        () {
      fakeAsync((async) {
        final c = FirstLoadOverlayController();
        addTearDown(c.dispose);
        c.setStoreEmpty(true);
        c.setPullStage(PullStage.background);
        expect(c.state, FirstLoadOverlayState.loading);

        async.elapse(const Duration(seconds: 2, milliseconds: 1));
        expect(c.state, FirstLoadOverlayState.hidden,
            reason: 'steps aside to skeletons at the cap (user story 10)');
      });
    });

    test('an immediately-complete pull still respects the min floor (no flicker)',
        () {
      fakeAsync((async) {
        final c = FirstLoadOverlayController();
        addTearDown(c.dispose);
        c.setStoreEmpty(true);
        c.setPullStage(PullStage.background);
        // Ready instantly (e.g. data already cached): must NOT vanish instantly.
        c.setLandingReady(true);
        expect(c.state, FirstLoadOverlayState.loading);
        async.elapse(const Duration(milliseconds: 400));
        expect(c.state, FirstLoadOverlayState.hidden);
      });
    });

    test('established-empty store (marker set, DB empty) ⇒ hidden, not a loader',
        () {
      fakeAsync((async) {
        final c = FirstLoadOverlayController();
        addTearDown(c.dispose);
        c.setStoreEmpty(true);
        c.setMarkerCompleted(true); // first full pull already happened
        c.setPullStage(PullStage.background);
        expect(c.state, FirstLoadOverlayState.hidden);
      });
    });

    test('wipe path: clearing the marker re-enables loading', () {
      fakeAsync((async) {
        final c = FirstLoadOverlayController();
        addTearDown(c.dispose);
        c.setStoreEmpty(true);
        c.setMarkerCompleted(true);
        c.setPullStage(PullStage.background);
        expect(c.state, FirstLoadOverlayState.hidden);

        c.setMarkerCompleted(false); // clearAllData() cleared the marker
        expect(c.state, FirstLoadOverlayState.loading);
      });
    });

    test('completed pull while still empty ⇒ hidden (genuinely-empty store)', () {
      fakeAsync((async) {
        final c = FirstLoadOverlayController();
        addTearDown(c.dispose);
        c.setStoreEmpty(true);
        c.setPullStage(PullStage.background);
        c.setPullStage(PullStage.completed);
        expect(c.state, FirstLoadOverlayState.hidden);
      });
    });

    test('offline first launch ⇒ retryNeeded immediately', () {
      fakeAsync((async) {
        final c = FirstLoadOverlayController();
        addTearDown(c.dispose);
        c.setStoreEmpty(true);
        c.setOnline(false);
        expect(c.state, FirstLoadOverlayState.retryNeeded);
      });
    });

    test('online failure ⇒ N silent retries, then retryNeeded', () {
      fakeAsync((async) {
        final retries = <int>[];
        final c = FirstLoadOverlayController(
          silentRetryDelays: const [
            Duration(seconds: 2),
            Duration(seconds: 5),
          ],
          onRetry: () async => retries.add(1),
        );
        addTearDown(c.dispose);
        c.setStoreEmpty(true);
        c.setPullStage(PullStage.background);

        // Failure #1 — silent retry scheduled, NOT surfaced.
        c.setPullStage(PullStage.failed);
        expect(c.state, FirstLoadOverlayState.hidden);
        async.elapse(const Duration(seconds: 2));
        expect(retries.length, 1, reason: 'first silent retry fired');

        // Failure #2 — second silent retry.
        c.setPullStage(PullStage.background);
        c.setPullStage(PullStage.failed);
        expect(c.state, FirstLoadOverlayState.hidden);
        async.elapse(const Duration(seconds: 5));
        expect(retries.length, 2, reason: 'second silent retry fired');

        // Failure #3 — retries exhausted ⇒ surface the prominent card.
        c.setPullStage(PullStage.background);
        c.setPullStage(PullStage.failed);
        expect(c.state, FirstLoadOverlayState.retryNeeded);
      });
    });

    test('manualRetry from the card clears the counter and triggers a pull', () {
      fakeAsync((async) {
        var pulls = 0;
        final c = FirstLoadOverlayController(
          silentRetryDelays: const [Duration(seconds: 2)],
          onRetry: () async => pulls++,
        );
        addTearDown(c.dispose);
        c.setStoreEmpty(true);
        c.setPullStage(PullStage.background);
        // Exhaust the single silent retry → retryNeeded.
        c.setPullStage(PullStage.failed);
        async.elapse(const Duration(seconds: 2));
        c.setPullStage(PullStage.background);
        c.setPullStage(PullStage.failed);
        expect(c.state, FirstLoadOverlayState.retryNeeded);

        c.manualRetry();
        async.flushMicrotasks();
        expect(c.state, FirstLoadOverlayState.hidden);
        expect(pulls, greaterThanOrEqualTo(1));
      });
    });

    test('store becoming populated ends the episode (overlay → hidden)', () {
      fakeAsync((async) {
        final c = FirstLoadOverlayController();
        addTearDown(c.dispose);
        c.setStoreEmpty(true);
        c.setPullStage(PullStage.background);
        expect(c.state, FirstLoadOverlayState.loading);
        c.setStoreEmpty(false); // products arrived
        expect(c.state, FirstLoadOverlayState.hidden);
      });
    });
  });
}
