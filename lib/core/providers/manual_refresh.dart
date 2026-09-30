/// The outcome of a pull-down refresh (PRD #313).
///
/// Syncing is silent except for a refresh the person asked for, and even that
/// one only ever says "Synced" — never "failed". So the one thing the UI needs
/// to know is whether a pull really completed for that pull-down.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/services/supabase_sync_service.dart';

/// Runs [pull] and answers whether a pull really completed for it.
///
/// "[pull] returned without throwing" is not that answer: `pushThenPull`
/// returns straight away when another pull is already in flight. So this
/// follows [status] instead. If a pull is still running when [pull] returns,
/// it waits for that one and reports how it ended — for at most [waitLimit],
/// after which it answers false rather than wait on a pull that never ends.
///
/// Rethrows whatever [pull] throws.
Future<bool> pullReallyCompleted({
  required ValueListenable<PullStatus> status,
  required Future<void> Function() pull,
  Duration waitLimit = const Duration(minutes: 2),
}) async {
  var stage = status.value.stage;
  // How the latest pull seen since the pull-down ended; null while one runs or
  // before any has been seen.
  bool? completed;
  Completer<void>? stageChanged;

  void onStatus() {
    final next = status.value.stage;
    if (next == stage) return;
    stage = next;
    switch (next) {
      case PullStage.background:
        completed = null;
      case PullStage.completed:
        completed = true;
      case PullStage.failed:
        completed = false;
      case PullStage.idle:
      case PullStage.minimum:
        break;
    }
    stageChanged?.complete();
    stageChanged = null;
  }

  status.addListener(onStatus);
  try {
    await pull();
    final waited = Stopwatch()..start();
    while (stage == PullStage.background) {
      final left = waitLimit - waited.elapsed;
      if (left <= Duration.zero) return false;
      final changed = stageChanged = Completer<void>();
      try {
        await changed.future.timeout(left);
      } on TimeoutException {
        return false;
      }
    }
    return completed ?? false;
  } finally {
    status.removeListener(onStatus);
  }
}

/// The pull behind a pull-down refresh: upload first, then download (§3.4).
/// Answers whether a pull really completed. A provider so a widget test can
/// stand in for the sync service.
final manualRefreshPullProvider = Provider<Future<bool> Function()>((ref) {
  return () async {
    final user = ref.read(authProvider).currentUser;
    if (user == null) return false;
    final sync = ref.read(supabaseSyncServiceProvider);
    return pullReallyCompleted(
      status: sync.pullStatus,
      pull: () => sync.pushThenPull(user.businessId),
    );
  };
});

/// Counts the pull-down refreshes whose pull really completed. `SyncPullBanner`
/// shows its brief "Synced" pill each time this moves; nothing else shows it.
class ManualRefreshSyncedNotifier extends Notifier<int> {
  @override
  int build() => 0;

  void recordSynced() => state++;
}

final manualRefreshSyncedProvider =
    NotifierProvider<ManualRefreshSyncedNotifier, int>(
      ManualRefreshSyncedNotifier.new,
    );
