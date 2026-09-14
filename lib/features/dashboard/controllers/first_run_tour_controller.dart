import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/core/providers/first_run_tour_state.dart';
import 'package:reebaplus_pos/shared/services/navigation_service.dart';
import 'package:reebaplus_pos/shared/widgets/spotlight_overlay.dart';
import 'package:reebaplus_pos/shared/widgets/spotlight_target.dart';

/// Sub-steps within Stop 1 (Create a Store) of the first-run rail (PRD #229, Issue #233).
enum StopOneStep {
  /// Point at MenuButton in top app bar.
  menuButton,

  /// Point at drawer menu list if Stores entry is off-screen.
  scrollDrawer,

  /// Point at Stores entry in drawer.
  storesMenuItem,

  /// Point at Add Store action / FAB on Stores screen.
  createStoreAction,

  /// Point at Add Store form sheet when open.
  createStoreForm,
}

/// Pure derivation of the current sub-step in Stop 1.
StopOneStep computeStopOneStep({
  required bool isStoresTab,
  required bool isDrawerOpen,
  required bool isStoresItemVisible,
  bool isCreateStoreFormOpen = false,
}) {
  if (isCreateStoreFormOpen) return StopOneStep.createStoreForm;
  if (isStoresTab) return StopOneStep.createStoreAction;
  if (isDrawerOpen) {
    return isStoresItemVisible
        ? StopOneStep.storesMenuItem
        : StopOneStep.scrollDrawer;
  }
  return StopOneStep.menuButton;
}

/// Returns the user-facing instruction caption for [step].
String captionForStopOneStep(StopOneStep step) {
  switch (step) {
    case StopOneStep.menuButton:
      return 'Tap the menu to get started';
    case StopOneStep.scrollDrawer:
      return 'Scroll down to find Stores';
    case StopOneStep.storesMenuItem:
      return 'Tap Stores';
    case StopOneStep.createStoreAction:
      return 'Tap to create your first store';
    case StopOneStep.createStoreForm:
      return 'Enter store details and tap Save Store';
  }
}

/// Returns the target identifier corresponding to [step].
SpotlightTargetId targetIdForStopOneStep(StopOneStep step) {
  switch (step) {
    case StopOneStep.menuButton:
      return SpotlightTargetId.menuButton;
    case StopOneStep.scrollDrawer:
      return SpotlightTargetId.drawerMenuList;
    case StopOneStep.storesMenuItem:
      return SpotlightTargetId.drawerStoresItem;
    case StopOneStep.createStoreAction:
      return SpotlightTargetId.createStoreFab;
    case StopOneStep.createStoreForm:
      return SpotlightTargetId.createStoreForm;
  }
}

/// Aborts the tour: sets device-local session flag, increments device abort count,
/// and tears down the overlay (leaving user in app with empty states).
void abortFirstRunTour(WidgetRef ref) {
  ref.read(tourSessionAbortedProvider.notifier).abort();
  ref.read(tourDeviceAbortCountProvider.notifier).recordAbort();
}

/// The overlay widget rendering the active stop and sub-steps of the first-run rail.
///
/// Mounted at the top of [MainLayout]'s Stack. Handles Stop 1 (Create Store, blocking)
/// and non-blocking bridge to Stop 2 (Add Product).
class FirstRunRailTourView extends ConsumerWidget {
  const FirstRunRailTourView({
    super.key,
    this.targetLookupTimeout = const Duration(milliseconds: 600),
  });

  final Duration targetLookupTimeout;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tourStop = ref.watch(firstRunTourStopProvider);
    if (tourStop == TourStop.none) {
      return const SizedBox.shrink();
    }

    if (tourStop == TourStop.addProduct) {
      return ListenableBuilder(
        listenable: SpotlightTargetRegistry.registryRevision,
        builder: (context, _) {
          final hasTarget =
              SpotlightTargetRegistry.getKey(SpotlightTargetId.addProductFab) != null;
          if (!hasTarget) return const SizedBox.shrink();
          return const SpotlightOverlay(
            targetId: SpotlightTargetId.addProductFab,
            caption: 'Tap to add your first product',
            blocking: false,
          );
        },
      );
    }

    final nav = ref.watch(navigationProvider);

    return ListenableBuilder(
      listenable: Listenable.merge([
        nav.currentIndex,
        nav.drawerOpenNotifier,
        SpotlightTargetRegistry.registryRevision,
      ]),
      builder: (context, _) {
        final isStoresTab = nav.currentIndex.value == NavigationService.storesTab;
        final isDrawerOpen = nav.isDrawerOpen;

        final screenSize = Size(context.screenWidth, context.screenHeight);
        final isStoresItemVisible = SpotlightTargetRegistry.isVisibleOnScreen(
          SpotlightTargetId.drawerStoresItem,
          screenSize: screenSize,
        );
        final isCreateStoreFormOpen =
            SpotlightTargetRegistry.getKey(SpotlightTargetId.createStoreForm) != null;

        final step = computeStopOneStep(
          isStoresTab: isStoresTab,
          isDrawerOpen: isDrawerOpen,
          isStoresItemVisible: isStoresItemVisible,
          isCreateStoreFormOpen: isCreateStoreFormOpen,
        );

        return SpotlightOverlay(
          targetId: targetIdForStopOneStep(step),
          caption: captionForStopOneStep(step),
          blocking: true,
          targetLookupTimeout: targetLookupTimeout,
          onMissingTarget: () => abortFirstRunTour(ref),
        );
      },
    );
  }
}
