import 'package:flutter/widgets.dart';

import 'package:reebaplus_pos/core/utils/frame_safe.dart';
import 'package:reebaplus_pos/shared/services/navigation_service.dart';

/// Wraps a surface the app has opened over itself that is **not** a route —
/// in practice, an `OverlayEntry` — and reports its presence to
/// [NavigationService.coverOpenNotifier] for as long as it is mounted.
///
/// Why this exists: the first-run rail's non-blocking pointer sits in
/// `MainLayout`'s Stack, above the tab bodies. Anything a screen opens into
/// its own Overlay therefore renders *below* the pointer, which then draws its
/// caption across it. Inventory's speed dial is the case that bit: the rail
/// asked the owner to tap "+", and then covered both of the options that
/// appeared with the instruction telling them to tap it.
///
/// A pushed page announces itself through the tab's `NavigatorObserver`
/// ([NavigationService.currentTabCanPop]). An `OverlayEntry` announces nothing,
/// so it has to say so itself — the same bargain [DrawerPresence] strikes for
/// a drawer that does not belong to MainLayout's Scaffold.
///
/// Both edges go through [frameSafe]: mounting and unmounting happen while the
/// framework is building, and writing the notifier there would mark a listener
/// that is not an ancestor dirty mid-build. See ADR 0026 sections 7 and 15.
class ScreenCover extends StatefulWidget {
  const ScreenCover({super.key, required this.child});

  final Widget child;

  @override
  State<ScreenCover> createState() => _ScreenCoverState();
}

class _ScreenCoverState extends State<ScreenCover> {
  @override
  void initState() {
    super.initState();
    frameSafe(NavigationService().coverMounted);
  }

  @override
  void dispose() {
    frameSafe(NavigationService().coverDismounted);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
