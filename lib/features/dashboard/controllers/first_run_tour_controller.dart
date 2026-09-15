import 'dart:async';

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
  /// Welcome card: what a store is for, and an offer to be walked there.
  intro,

  /// Point at MenuButton in top app bar.
  menuButton,

  /// Tell the owner to scroll the drawer when the Stores entry is below the fold.
  scrollDrawer,

  /// Point at Stores entry in drawer.
  storesMenuItem,

  /// Point at Add Store action / FAB on Stores screen.
  createStoreAction,

  /// Point at Add Store form sheet when open.
  createStoreForm,
}

/// Pure derivation of the current sub-step in Stop 1.
///
/// The introduction comes first and unconditionally: an owner who has not been
/// told what a store is for, or offered the choice of being walked to one, has
/// not agreed to anything the rest of the rail does to their screen.
///
/// Every step after it is read back off the app's own state rather than
/// advanced by a script, so an owner who reaches Stores by their own route —
/// or who backs out of the drawer — is followed rather than contradicted.
StopOneStep computeStopOneStep({
  required bool isStoresTab,
  required bool isDrawerOpen,
  required bool isStoresItemVisible,
  bool isCreateStoreFormOpen = false,
  bool introAcknowledged = true,
}) {
  if (!introAcknowledged) return StopOneStep.intro;
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
    case StopOneStep.intro:
      return 'Let’s set up your first store';
    case StopOneStep.menuButton:
      return 'Tap the menu to get started';
    case StopOneStep.scrollDrawer:
      return 'Scroll down to find Stores';
    case StopOneStep.storesMenuItem:
      return 'Tap Stores';
    case StopOneStep.createStoreAction:
      return 'Tap to create your first store';
    case StopOneStep.createStoreForm:
      return 'Name your store and tap Save Store';
  }
}

/// Returns the target identifier corresponding to [step], or `null` for a step
/// that has something to say but nothing to point at.
///
/// The scroll step deliberately has no target. Cutting the hole over the menu
/// list — the only target that contains the thing being looked for — makes
/// every other destination in the drawer tappable during the one stop whose
/// job is to stop the owner reaching a screen that cannot work yet.
SpotlightTargetId? targetIdForStopOneStep(StopOneStep step) {
  switch (step) {
    case StopOneStep.intro:
      return null;
    case StopOneStep.menuButton:
      return SpotlightTargetId.menuButton;
    case StopOneStep.scrollDrawer:
      return null;
    case StopOneStep.storesMenuItem:
      return SpotlightTargetId.drawerStoresItem;
    case StopOneStep.createStoreAction:
      return SpotlightTargetId.createStoreFab;
    case StopOneStep.createStoreForm:
      return SpotlightTargetId.createStoreForm;
  }
}

/// The owner chose to look around instead of being walked.
///
/// Ends the rail for this session and nothing more. It does **not** touch the
/// device abort count: that counter exists to retire a rail that is broken on a
/// particular phone, and an owner who understood the offer and declined it is
/// evidence of nothing except their own preference. The rail is derived from
/// the data, so it offers again on the next cold start.
void declineFirstRunTour(WidgetRef ref) {
  ref.read(tourSessionAbortedProvider.notifier).abort();
}

/// Aborts the tour: sets device-local session flag, increments device abort count,
/// and tears down the overlay (leaving user in app with empty states).
///
/// Called when the overlay cannot find its target, and when the owner reports
/// being stuck — both are failures, and three of either on one device retire
/// the rail there.
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
    this.stallPatience = const Duration(seconds: 20),
    this.stallTapLimit = 3,
  });

  final Duration targetLookupTimeout;

  /// How long a single step may sit on screen with nothing happening before the
  /// owner is offered a way out.
  final Duration stallPatience;

  /// How many swallowed taps on one step count as the owner asking for help.
  final int stallTapLimit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Stop 1 ending is a transition, not a state: the store count says "one"
    // forever afterwards, including for an owner who had a store before the app
    // opened. Only an owner who was actually being walked is owed a hand-off.
    ref.listen<TourStop>(firstRunTourStopProvider, (previous, next) {
      if (previous == TourStop.createStore && next == TourStop.addProduct) {
        ref.read(tourHandoffProvider.notifier).owe();
      }
    });

    final tourStop = ref.watch(firstRunTourStopProvider);
    if (tourStop == TourStop.none) {
      return const SizedBox.shrink();
    }

    if (tourStop == TourStop.addProduct) {
      if (ref.watch(tourHandoffProvider)) {
        return _buildHandoff(context, ref);
      }
      return _buildAddProductPointer(context, ref);
    }

    final nav = ref.watch(navigationProvider);
    final introAcknowledged = ref.watch(tourIntroAcknowledgedProvider);

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
        // Vertical bounds only: the drawer slides in sideways over ~250 ms, and
        // a horizontal test would answer "off-screen" for the whole animation,
        // flicking the caption from "scroll down" to "tap Stores" once it lands.
        final isStoresItemVisible = SpotlightTargetRegistry.isVisibleOnScreen(
          SpotlightTargetId.drawerStoresItem,
          screenSize: screenSize,
          verticalOnly: true,
        );
        final isCreateStoreFormOpen =
            SpotlightTargetRegistry.getKey(SpotlightTargetId.createStoreForm) != null;

        final step = computeStopOneStep(
          isStoresTab: isStoresTab,
          isDrawerOpen: isDrawerOpen,
          isStoresItemVisible: isStoresItemVisible,
          isCreateStoreFormOpen: isCreateStoreFormOpen,
          introAcknowledged: introAcknowledged,
        );

        if (step == StopOneStep.intro) return _buildIntro(context, ref);

        return _StallWatch(
          stepKey: step,
          patience: stallPatience,
          blockedTapLimit: stallTapLimit,
          onGiveUp: () => abortFirstRunTour(ref),
          builder: (context, escape, onBlockedTap) {
            final footer = _stepFooter(context, step, escape);
            return SpotlightOverlay(
              targetId: targetIdForStopOneStep(step),
              caption: captionForStopOneStep(step),
              footer: footer,
              blocking: true,
              targetLookupTimeout: targetLookupTimeout,
              onMissingTarget: () => abortFirstRunTour(ref),
              onBlockedTap: onBlockedTap,
            );
          },
        );
      },
    );
  }

  Widget? _stepFooter(BuildContext context, StopOneStep step, Widget? escape) {
    final showChevron = step == StopOneStep.scrollDrawer;
    if (!showChevron && escape == null) return null;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (showChevron) const _ScrollHint(),
        if (showChevron && escape != null) SizedBox(height: context.getRSize(12)),
        if (escape != null) escape,
      ],
    );
  }

  /// Stop 2: a pointer at the Inventory "+", and a way to put it away.
  ///
  /// Unlike stop 1 this stop asks for nothing and blocks nothing, so it must
  /// also know when to stand aside. Every screen the "+" leads to — Add
  /// Product, Receive Stock — is pushed onto the tab's own Navigator, which
  /// sits below this overlay in MainLayout's Stack. Left up, the pointer would
  /// hang over the very form it asked the owner to fill in, still circling a
  /// button that page has covered. `currentTabCanPop` is the signal the bottom
  /// nav already uses to hide itself for the same reason.
  Widget _buildAddProductPointer(BuildContext context, WidgetRef ref) {
    final nav = ref.watch(navigationProvider);

    return ListenableBuilder(
      listenable: Listenable.merge([
        nav.currentTabCanPop,
        SpotlightTargetRegistry.registryRevision,
      ]),
      builder: (context, _) {
        if (nav.currentTabCanPop.value) return const SizedBox.shrink();

        final hasTarget =
            SpotlightTargetRegistry.getKey(SpotlightTargetId.addProductFab) !=
                null;
        if (!hasTarget) return const SizedBox.shrink();

        return SpotlightOverlay(
          targetId: SpotlightTargetId.addProductFab,
          caption: 'Tap to add your first product',
          blocking: false,
          // Dismissing the last stop is a preference, not a failure, so it
          // costs the device nothing (ADR 0026 section 13). The rail is derived
          // from the data, so it offers again on the next cold start until a
          // product exists.
          footer: _EscapeLink(
            label: 'Not now',
            onTap: () => declineFirstRunTour(ref),
          ),
        );
      },
    );
  }

  Widget _buildIntro(BuildContext context, WidgetRef ref) {
    final firstName = ref.watch(tourOwnerFirstNameProvider);

    return SpotlightOverlay(
      caption: captionForStopOneStep(StopOneStep.intro),
      blocking: true,
      content: _TourCard(
        title: firstName.isEmpty ? 'Welcome' : 'Welcome, $firstName',
        body:
            'A store is where your stock and your sales live. Let’s set up your '
            'first one — it takes a minute.',
        primaryLabel: 'Set up my store',
        onPrimary: () =>
            ref.read(tourIntroAcknowledgedProvider.notifier).acknowledge(),
        secondaryLabel: 'I’ll look around first',
        onSecondary: () => declineFirstRunTour(ref),
      ),
    );
  }

  Widget _buildHandoff(BuildContext context, WidgetRef ref) {
    final storeName = ref.watch(tourFirstStoreNameProvider) ?? 'Your store';
    final nav = ref.read(navigationProvider);

    return SpotlightOverlay(
      caption: 'Your store is ready',
      blocking: true,
      content: _TourCard(
        icon: Icons.check_circle_rounded,
        title: '$storeName is ready.',
        body: 'Next, add something to sell.',
        primaryLabel: 'Add a product',
        onPrimary: () {
          ref.read(tourHandoffProvider.notifier).settle();
          nav.currentIndex.value = _inventoryTab;
        },
        secondaryLabel: 'Not now',
        onSecondary: () => ref.read(tourHandoffProvider.notifier).settle(),
      ),
    );
  }

  /// Inventory is tab 2 in [NavigationService.indexToRoute].
  static const int _inventoryTab = 2;
}

/// The welcome and hand-off panels: the two moments the rail asks the owner for
/// a decision rather than for a tap on the app behind it.
class _TourCard extends StatelessWidget {
  const _TourCard({
    required this.title,
    required this.body,
    required this.primaryLabel,
    required this.onPrimary,
    required this.secondaryLabel,
    required this.onSecondary,
    this.icon,
  });

  final String title;
  final String body;
  final String primaryLabel;
  final VoidCallback onPrimary;
  final String secondaryLabel;
  final VoidCallback onSecondary;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);

    return Container(
      constraints: BoxConstraints(maxWidth: context.getRSize(340)),
      padding: EdgeInsets.all(context.getRSize(24)),
      decoration: BoxDecoration(
        color: t.colorScheme.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: t.colorScheme.primary.withValues(alpha: 0.35),
          width: 1.5,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.35),
            blurRadius: 24,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (icon != null) ...[
            Icon(icon, color: t.colorScheme.primary, size: context.getRSize(32)),
            SizedBox(height: context.getRSize(12)),
          ],
          Text(
            title,
            style: t.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w700,
              color: t.colorScheme.onSurface,
            ),
          ),
          SizedBox(height: context.getRSize(10)),
          Text(
            body,
            style: t.textTheme.bodyMedium?.copyWith(
              color: t.colorScheme.onSurface.withValues(alpha: 0.75),
              height: 1.45,
            ),
          ),
          SizedBox(height: context.getRSize(22)),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: onPrimary,
              style: FilledButton.styleFrom(
                padding: EdgeInsets.symmetric(vertical: context.getRSize(14)),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              child: Text(primaryLabel),
            ),
          ),
          SizedBox(height: context.getRSize(4)),
          Center(
            child: TextButton(
              onPressed: onSecondary,
              child: Text(
                secondaryLabel,
                style: t.textTheme.bodyMedium?.copyWith(
                  color: t.colorScheme.onSurface.withValues(alpha: 0.6),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The nudge under the scroll caption.
class _ScrollHint extends StatefulWidget {
  const _ScrollHint();

  @override
  State<_ScrollHint> createState() => _ScrollHintState();
}

class _ScrollHintState extends State<_ScrollHint>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) => Transform.translate(
        offset: Offset(0, _controller.value * context.getRSize(8)),
        child: child,
      ),
      child: Icon(
        Icons.keyboard_double_arrow_down_rounded,
        color: Colors.white.withValues(alpha: 0.85),
        size: context.getRSize(30),
      ),
    );
  }
}

/// Watches a single step for signs the owner is stuck, and offers a way out.
///
/// The rail's only designed exit is a target it cannot find. That catches a
/// target that is gone; it cannot catch a step that is simply wrong — the
/// target resolves, the hole is cut somewhere useless, and the sheet keeps
/// swallowing every tap. Two signals, because they catch different owners: one
/// reads the caption and waits, the other jabs at the screen.
class _StallWatch extends StatefulWidget {
  const _StallWatch({
    required this.stepKey,
    required this.onGiveUp,
    required this.builder,
    this.patience = const Duration(seconds: 20),
    this.blockedTapLimit = 3,
  });

  /// Changing this resets the watch: progress has been made.
  final Object stepKey;

  final VoidCallback onGiveUp;
  final Duration patience;
  final int blockedTapLimit;

  /// Called with the escape widget (null until the owner looks stuck) and the
  /// callback the overlay should fire for each swallowed tap.
  final Widget Function(
    BuildContext context,
    Widget? escape,
    VoidCallback onBlockedTap,
  ) builder;

  @override
  State<_StallWatch> createState() => _StallWatchState();
}

class _StallWatchState extends State<_StallWatch> {
  Timer? _timer;
  int _blockedTaps = 0;
  bool _stalled = false;

  @override
  void initState() {
    super.initState();
    _restart();
  }

  @override
  void didUpdateWidget(_StallWatch oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.stepKey != widget.stepKey) _restart();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _restart() {
    _timer?.cancel();
    _blockedTaps = 0;
    _stalled = false;
    _timer = Timer(widget.patience, () {
      if (mounted) setState(() => _stalled = true);
    });
  }

  void _onBlockedTap() {
    if (_stalled) return;
    _blockedTaps++;
    if (_blockedTaps >= widget.blockedTapLimit) {
      setState(() => _stalled = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return widget.builder(
      context,
      _stalled ? _EscapeLink(onTap: widget.onGiveUp) : null,
      _onBlockedTap,
    );
  }
}

class _EscapeLink extends StatelessWidget {
  const _EscapeLink({
    required this.onTap,
    this.label = 'Having trouble? Skip setup',
  });

  final VoidCallback onTap;

  /// What the way out is called. The stall net's wording names the trouble it
  /// just detected; stop 2's pointer is simply being put away.
  final String label;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return TextButton(
      onPressed: onTap,
      style: TextButton.styleFrom(
        backgroundColor: t.colorScheme.surface.withValues(alpha: 0.92),
        padding: EdgeInsets.symmetric(
          horizontal: context.getRSize(16),
          vertical: context.getRSize(10),
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
      ),
      child: Text(
        label,
        style: t.textTheme.bodySmall?.copyWith(
          fontWeight: FontWeight.w600,
          color: t.colorScheme.onSurface.withValues(alpha: 0.8),
        ),
      ),
    );
  }
}
