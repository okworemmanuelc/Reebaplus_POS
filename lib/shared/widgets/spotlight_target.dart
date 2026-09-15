import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'package:reebaplus_pos/core/utils/frame_safe.dart';

/// Target identifiers for spotlight tour overlays (PRD #229, ADR 0026).
enum SpotlightTargetId {
  /// The app bar menu / drawer toggle button.
  menuButton,

  /// The scrollable navigation list inside [AppDrawer].
  drawerMenuList,

  /// The "Stores" navigation destination inside [AppDrawer].
  drawerStoresItem,

  /// The "Add Store" action / FAB on [StoresScreen].
  createStoreFab,

  /// The "New Store" form / save action on [StoresScreen].
  createStoreForm,

  /// The "Add Product" action on [InventoryScreen] (Stop 2).
  addProductFab,

  /// The "Get started" checklist card on [HomeScreen] (Hand-off).
  getStartedCard,
}

/// Registry storing active [GlobalKey] references for tagged spotlight targets.
///
/// Targets are tagged where they are built ([SpotlightTarget]) and registered here,
/// eliminating fragile runtime widget searches.
class SpotlightTargetRegistry {
  SpotlightTargetRegistry._();

  static final Map<SpotlightTargetId, Set<GlobalKey>> _targets = {};

  /// Incremented whenever a target is registered, unregistered, or cleared.
  static final ValueNotifier<int> registryRevision = ValueNotifier<int>(0);

  static bool _bumpScheduled = false;

  /// Bumps [registryRevision] without ever marking a listener dirty mid-build.
  ///
  /// Targets register from [State.initState] and unregister from
  /// [State.dispose], both of which run while the framework is building or
  /// finalising the tree. Mutating the notifier there synchronously calls
  /// `markNeedsBuild()` on every listening `ListenableBuilder` — and a listener
  /// that is not an ancestor of the widget currently being built throws
  /// "setState() or markNeedsBuild() called during build". Tagging a
  /// [SpotlightTarget] anywhere outside the tour's own subtree would crash the
  /// app while the rail is on screen.
  ///
  /// During a frame's build/layout/paint phase the bump is deferred to the end
  /// of that frame, which also coalesces a burst of registrations (a whole tab
  /// warming up) into one notification.
  static void _bumpRevision() {
    if (!isFrameLocked()) {
      registryRevision.value++;
      return;
    }
    if (_bumpScheduled) return;
    _bumpScheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _bumpScheduled = false;
      registryRevision.value++;
    });
  }

  /// Registers a target [id] with its [key].
  static void register(SpotlightTargetId id, GlobalKey key) {
    _targets.putIfAbsent(id, () => <GlobalKey>{}).add(key);
    _bumpRevision();
  }

  /// Unregisters a target [id] if the registered key matches [key].
  static void unregister(SpotlightTargetId id, GlobalKey key) {
    final set = _targets[id];
    if (set != null) {
      set.remove(key);
      if (set.isEmpty) {
        _targets.remove(id);
      }
      _bumpRevision();
    }
  }

  /// Whether [object] is actually painted, i.e. no ancestor is suppressing it.
  ///
  /// [MainLayout] keeps every visited tab mounted under an [Offstage], and an
  /// offstage subtree is still laid out — it has a size, is attached, and
  /// reports a plausible global offset. Without this check the registry can
  /// hand back the [MenuButton] of a tab nobody is looking at and the hole is
  /// cut over empty screen.
  static bool _isPainted(RenderObject object) {
    RenderObject child = object;
    RenderObject? parent = object.parent;
    while (parent != null) {
      if (!parent.paintsChild(child)) return false;
      child = parent;
      parent = parent.parent;
    }
    return true;
  }

  /// The [RenderBox] behind [key] when it is mounted, laid out and painted.
  static RenderBox? _liveRenderBox(GlobalKey key) {
    final ctx = key.currentContext;
    if (ctx == null) return null;
    final box = ctx.findRenderObject() as RenderBox?;
    if (box == null || !box.attached || !box.hasSize) return null;
    if (box.size.width <= 0 || box.size.height <= 0) return null;
    if (!_isPainted(box)) return null;
    return box;
  }

  /// Looks up the best active [GlobalKey] registered for [id].
  static GlobalKey? getKey(SpotlightTargetId id) {
    final keys = _targets[id];
    if (keys == null || keys.isEmpty) return null;
    for (final key in keys) {
      if (_liveRenderBox(key) != null) return key;
    }
    for (final key in keys) {
      if (key.currentContext != null) return key;
    }
    return keys.first;
  }

  /// Computes the bounding [Rect] in global screen coordinates for [id].
  ///
  /// Returns `null` if the target is unmounted, not attached, or has no size.
  static Rect? getTargetRect(SpotlightTargetId id) {
    final keys = _targets[id];
    if (keys == null || keys.isEmpty) return null;

    for (final key in keys) {
      final renderBox = _liveRenderBox(key);
      if (renderBox == null) continue;
      try {
        final offset = renderBox.localToGlobal(Offset.zero);
        return offset & renderBox.size;
      } catch (_) {
        continue;
      }
    }
    return null;
  }

  // ── Per-frame movement tracking ────────────────────────────────────────
  //
  // Registration alone is not enough to keep a spotlight aligned. A target
  // moves after it registers: the drawer slides in over ~250 ms, a sheet
  // animates up, a list settles. Anything derived from a target's rect — the
  // hole position, and whether the Stores entry counts as on-screen — is stale
  // the moment it is computed from the target's very first frame.
  //
  // While a [SpotlightOverlay] is mounted, re-resolve every registered rect
  // after each painted frame and bump [registryRevision] only when one has
  // actually moved. Bumping unconditionally would rebuild a listener, which
  // schedules another frame, which ticks again — a frame loop that never idles.

  static int _trackers = 0;
  static bool _watchScheduled = false;
  static final Map<SpotlightTargetId, Rect?> _lastRects = {};

  /// Starts per-frame movement tracking. Paired with [endTracking].
  static void beginTracking() {
    _trackers++;
    _scheduleRectWatch();
  }

  /// Stops per-frame movement tracking started by [beginTracking].
  static void endTracking() {
    if (_trackers > 0) _trackers--;
    if (_trackers == 0) _lastRects.clear();
  }

  static void _scheduleRectWatch() {
    if (_watchScheduled || _trackers == 0) return;
    _watchScheduled = true;
    // A post-frame callback does not itself request a frame, so this chain is
    // passive: it fires only when something else painted, and idles for free.
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _watchScheduled = false;
      if (_trackers == 0) return;
      if (_refreshRects()) registryRevision.value++;
      _scheduleRectWatch();
    });
  }

  /// Re-resolves every registered target, returning whether any rect changed.
  static bool _refreshRects() {
    var moved = false;
    for (final id in _targets.keys) {
      final rect = getTargetRect(id);
      if (_lastRects[id] != rect) {
        _lastRects[id] = rect;
        moved = true;
      }
    }
    // A target that unregistered between frames leaves a stale entry behind.
    _lastRects.removeWhere((id, _) => !_targets.containsKey(id));
    return moved;
  }

  /// Notifies listeners that targets may have moved (e.g. on scroll).
  static void notifyTargetsMoved() {
    _bumpRevision();
  }

  /// Checks whether target [id] is currently visible within the screen bounds.
  ///
  /// If the rect extends outside vertical or horizontal viewport bounds, returns `false`.
  ///
  /// [verticalOnly] drops the horizontal test. Ask for it when the question is
  /// "has this scrolled below the fold?" and the target lives in something that
  /// moves sideways — a drawer slides in over ~250 ms, so a horizontal test
  /// answers "off-screen" for the whole animation and a caption derived from it
  /// flickers from "scroll down to find it" to "tap it" once the slide lands.
  static bool isVisibleOnScreen(
    SpotlightTargetId id, {
    required Size screenSize,
    bool verticalOnly = false,
  }) {
    final rect = getTargetRect(id);
    if (rect == null) return false;
    if (rect.isEmpty) return false;
    if (rect.top < 0 || rect.bottom > screenSize.height) return false;
    if (verticalOnly) return true;
    return rect.left >= 0 && rect.right <= screenSize.width;
  }

  /// Whether per-frame movement tracking is currently running.
  @visibleForTesting
  static bool get debugIsTracking => _trackers > 0;

  /// Clears all registrations (for testing).
  @visibleForTesting
  static void clear() {
    _targets.clear();
    _lastRects.clear();
    _trackers = 0;
    _bumpScheduled = false;
    registryRevision.value++;
  }
}

/// A widget wrapper that tags a UI element for the spotlight tour overlay.
class SpotlightTarget extends StatefulWidget {
  const SpotlightTarget({
    super.key,
    required this.id,
    required this.child,
  });

  final SpotlightTargetId id;
  final Widget child;

  @override
  State<SpotlightTarget> createState() => _SpotlightTargetState();
}

class _SpotlightTargetState extends State<SpotlightTarget> {
  final GlobalKey _key = GlobalKey();

  @override
  void initState() {
    super.initState();
    SpotlightTargetRegistry.register(widget.id, _key);
  }

  @override
  void didUpdateWidget(SpotlightTarget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.id != widget.id) {
      SpotlightTargetRegistry.unregister(oldWidget.id, _key);
      SpotlightTargetRegistry.register(widget.id, _key);
    }
  }

  @override
  void dispose() {
    SpotlightTargetRegistry.unregister(widget.id, _key);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return KeyedSubtree(
      key: _key,
      child: widget.child,
    );
  }
}
