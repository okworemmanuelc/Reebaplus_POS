/// The shared "first download in progress" signal (PRD #313).
///
/// A full sign-in lands on a phone that holds nothing but the handful of tables
/// the sign-in screen pulled; everything else streams in behind the shell. Until
/// that download has finished, "there are no products" and "there are no orders"
/// say nothing about the business — so every first-time surface (the Get started
/// card, the empty-state prompts, the walkthrough) reads this one signal and
/// waits.
///
/// It is true from the moment a business is bound until a pull for it reaches
/// [PullStage.completed]. That transition is the only thing it takes from the
/// pull stage, and it never looks at whether the store has products: it must
/// already be true before the pull starts and during the "Setting up…" overlay,
/// and it must stay true until the END of the download (products arrive early,
/// orders late).
///
/// A logout wipes the phone and clears the stored marker, so the next full
/// sign-in is a first download again; a PIN unlock leaves the marker alone.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/business_scoped_stream.dart';
import 'package:reebaplus_pos/core/services/first_load_marker_service.dart';
import 'package:reebaplus_pos/core/services/supabase_sync_service.dart';

/// Whether an earlier app session already finished this business's first
/// download on this phone. A one-shot read of the stored marker, so on its own
/// it does not flip when a pull completes — [FirstDownloadFinishedNotifier] does.
final firstDownloadMarkerProvider = FutureProvider<bool>((ref) async {
  final businessId = ref.watch(currentBusinessIdProvider);
  if (businessId == null) return false;
  return FirstLoadMarkerService.hasFinishedFirstDownload(businessId);
});

/// Latches on when a pull for the bound business reaches
/// [PullStage.completed] during this app session, and stores the marker so the
/// next session knows too. Only the transition counts: a `completed` stage left
/// over from before sign-in belongs to some other pull. Rebinding to another
/// business starts the latch over.
class FirstDownloadFinishedNotifier extends Notifier<bool> {
  @override
  bool build() {
    final businessId = ref.watch(currentBusinessIdProvider);
    if (businessId == null) return false;
    ref.listen<PullStage>(pullStageProvider, (previous, next) {
      if (next != PullStage.completed || previous == PullStage.completed) {
        return;
      }
      state = true;
      unawaited(_remember(businessId));
    });
    return false;
  }

  Future<void> _remember(String businessId) async {
    try {
      await FirstLoadMarkerService.markFirstDownloadFinished(businessId);
    } catch (e) {
      // The latch already holds for this session. Without the stored marker the
      // next session waits for its own first completed pull — seconds, not a
      // wrong answer.
      debugPrint('[FirstDownload] could not store the finished marker: $e');
    }
  }
}

final firstDownloadFinishedThisSessionProvider =
    NotifierProvider<FirstDownloadFinishedNotifier, bool>(
      FirstDownloadFinishedNotifier.new,
    );

/// True until the first download for the bound business has finished on this
/// phone. Also true while the stored marker is still being read, and when no
/// business is bound: not knowing is not a reason to show a first-time prompt.
final firstDownloadInProgressProvider = Provider<bool>((ref) {
  if (ref.watch(firstDownloadFinishedThisSessionProvider)) return false;
  final finishedEarlier =
      ref.watch(firstDownloadMarkerProvider).valueOrNull ?? false;
  return !finishedEarlier;
});
