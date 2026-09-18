import 'package:flutter/material.dart';

import 'package:reebaplus_pos/shared/widgets/pinned_tab_bar_delegate.dart';

/// One tab's body, expressed as slivers rather than a box.
///
/// [storageKey] must be stable and unique within a [TabbedSliverScaffold]; it is
/// what lets each tab remember its scroll position across tab switches.
class TabSliverView {
  const TabSliverView({required this.storageKey, required this.slivers});

  /// Stable identity for this tab's scroll position.
  final String storageKey;

  /// The tab's content. Every entry must be a sliver. Nothing here may depend
  /// on a supplied height — that dependency is the defect (see class docs).
  final List<Widget> slivers;
}

/// The shared shape behind every tabbed screen with scroll-away headers:
/// header slivers that scroll out of the way, a tab bar pinned beneath them,
/// and one scroll view per tab.
///
/// ### Why this exists (Issue #243 / PRD #239)
///
/// Five screens — Inventory, Orders, Customer Detail, Supplier Detail and Driver
/// Profile — hand-rolled this shape, and each hand-rolled it the same wrong way:
/// a [NestedScrollView] whose body is a non-scrolling `Column` with a
/// fixed-height band (a filter row, a summary strip, a button bar) above an
/// [Expanded] list.
///
/// That fails because a `NestedScrollView` charges its body for the scroll
/// extent of the headers above it. The body box is laid out at
/// `viewportHeight - precedingScrollExtent`, so the taller the scroll-away
/// header, the shorter the body — at rest, regardless of how much screen there
/// actually is. Measured on Inventory: 163.5dp of body on a 320x568 portrait
/// phone, 35.0dp at 915x412, and **-17.0dp** at 800x360, where the filter band
/// alone (92.6dp) is taller than the whole body. No amount of tightened padding
/// closes a negative gap, and a single dropdown already spends 73dp of it.
///
/// Worse, the red overflow band is the *harmless* symptom. It only appears when
/// the tab's content is a fixed-height widget. With a list in there, the list is
/// handed zero height, renders nothing, and reports no error at all — a screen
/// that looks fine and is simply blank where the stock should be.
///
/// ### What this widget does about it
///
/// Each tab becomes its own [CustomScrollView] and its filter band becomes a
/// sliver above its list. Once nothing inside a tab depends on a supplied
/// height, the body's short box stops mattering: it is a viewport, its content
/// scrolls, and a short viewport costs the user a scroll rather than the
/// content.
///
/// The scaffold also pairs [SliverOverlapAbsorber] with [SliverOverlapInjector].
/// Without that pairing a tab's own scroll view starts at the top of the body
/// box and renders its first rows *underneath* the pinned tab bar. The pairing
/// exists nowhere else in this codebase, which is exactly why it belongs inside
/// one widget instead of at five call sites.
///
/// ### What it deliberately does not do
///
/// No orientation branch and no short-viewport predicate. The 320x568 portrait
/// case overflows and sits *above* the existing short-viewport threshold, so a
/// gated fix would miss it; and a structure that cannot overflow at 800x360
/// cannot overflow anywhere. One code path, one layout to maintain.
class TabbedSliverScaffold extends StatelessWidget {
  const TabbedSliverScaffold({
    super.key,
    required this.controller,
    required this.tabBar,
    required this.tabViews,
    this.headerSlivers = const <Widget>[],
    this.tabBarExtent,
    this.tabBarChromeExtent,
    this.scrollBehavior,
  });

  /// Drives both [tabBar] and the tab bodies. Owned by the host screen, whose
  /// tab set may change with role and business type.
  final TabController controller;

  /// The tab bar pinned under [headerSlivers]. Held at
  /// [kMinInteractiveDimension] by [PinnedTabBarDelegate] whatever the
  /// responsive scale resolves to.
  final Widget tabBar;

  /// One entry per tab, in the same order as [controller]'s tabs.
  final List<TabSliverView> tabViews;

  /// Slivers above the pinned tab bar. They scroll away as the user reads.
  final List<Widget> headerSlivers;

  /// Height for the pinned tab bar. Floored at [kMinInteractiveDimension].
  final double? tabBarExtent;

  /// Non-interactive decoration inside [tabBar] — a bottom margin plus any
  /// border, say — which must be reserved *on top of* the tap-target floor
  /// rather than taken out of it. See [PinnedTabBarDelegate.withChrome].
  final double? tabBarChromeExtent;

  /// Optional scroll behaviour for the tab bodies.
  final ScrollBehavior? scrollBehavior;

  SliverPersistentHeaderDelegate get _tabBarDelegate {
    final extent = tabBarExtent;
    final chrome = tabBarChromeExtent;
    if (extent != null && chrome != null) {
      return PinnedTabBarDelegate.withChrome(
        child: tabBar,
        extent: extent,
        chromeExtent: chrome,
      );
    }
    return PinnedTabBarDelegate(
      child: tabBar,
      extent: extent ?? kMinInteractiveDimension,
    );
  }

  @override
  Widget build(BuildContext context) {
    assert(
      tabViews.length == controller.length,
      'TabbedSliverScaffold was given ${tabViews.length} tab views for a '
      'controller with ${controller.length} tabs.',
    );
    return NestedScrollView(
      headerSliverBuilder: (context, innerBoxIsScrolled) => [
        ...headerSlivers,
        SliverOverlapAbsorber(
          handle: NestedScrollView.sliverOverlapAbsorberHandleFor(context),
          sliver: SliverPersistentHeader(
            pinned: true,
            delegate: _tabBarDelegate,
          ),
        ),
      ],
      body: TabBarView(
        controller: controller,
        children: [
          for (final view in tabViews)
            TabSliverBody(view: view, scrollBehavior: scrollBehavior),
        ],
      ),
    );
  }
}

/// One tab's scroll view. A named widget rather than an inline closure because
/// it needs a [BuildContext] *below* the [NestedScrollView] to resolve the
/// overlap handle.
@visibleForTesting
class TabSliverBody extends StatelessWidget {
  const TabSliverBody({super.key, required this.view, this.scrollBehavior});

  final TabSliverView view;
  final ScrollBehavior? scrollBehavior;

  @override
  Widget build(BuildContext context) {
    final scrollView = CustomScrollView(
      // Each tab keeps its own scroll offset across tab switches.
      key: PageStorageKey<String>(view.storageKey),
      slivers: [
        // Re-applies the overlap the pinned tab bar absorbed, so this tab's
        // first row starts below the tab bar instead of under it.
        SliverOverlapInjector(
          handle: NestedScrollView.sliverOverlapAbsorberHandleFor(context),
        ),
        ...view.slivers,
      ],
    );
    if (scrollBehavior == null) return scrollView;
    return ScrollConfiguration(behavior: scrollBehavior!, child: scrollView);
  }
}
