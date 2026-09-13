import 'package:flutter/material.dart';

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

  /// The "Add Product" action on [InventoryScreen] (Stop 2).
  addProductFab,
}

/// Registry storing active [GlobalKey] references for tagged spotlight targets.
///
/// Targets are tagged where they are built ([SpotlightTarget]) and registered here,
/// eliminating fragile runtime widget searches.
class SpotlightTargetRegistry {
  SpotlightTargetRegistry._();

  static final Map<SpotlightTargetId, GlobalKey> _targets = {};

  /// Incremented whenever a target is registered, unregistered, or cleared.
  static final ValueNotifier<int> registryRevision = ValueNotifier<int>(0);

  /// Registers a target [id] with its [key].
  static void register(SpotlightTargetId id, GlobalKey key) {
    _targets[id] = key;
    registryRevision.value++;
  }

  /// Unregisters a target [id] if the registered key matches [key].
  static void unregister(SpotlightTargetId id, GlobalKey key) {
    if (_targets[id] == key) {
      _targets.remove(id);
      registryRevision.value++;
    }
  }

  /// Looks up the [GlobalKey] registered for [id].
  static GlobalKey? getKey(SpotlightTargetId id) => _targets[id];

  /// Computes the bounding [Rect] in global screen coordinates for [id].
  ///
  /// Returns `null` if the target is unmounted, not attached, or has no size.
  static Rect? getTargetRect(SpotlightTargetId id) {
    final key = _targets[id];
    if (key == null) return null;
    final ctx = key.currentContext;
    if (ctx == null) return null;
    final renderBox = ctx.findRenderObject() as RenderBox?;
    if (renderBox == null || !renderBox.hasSize || !renderBox.attached) {
      return null;
    }
    try {
      final offset = renderBox.localToGlobal(Offset.zero);
      return offset & renderBox.size;
    } catch (_) {
      return null;
    }
  }

  /// Checks whether target [id] is currently visible within the screen bounds.
  ///
  /// If the rect extends outside vertical or horizontal viewport bounds, returns `false`.
  static bool isVisibleOnScreen(SpotlightTargetId id, {required Size screenSize}) {
    final rect = getTargetRect(id);
    if (rect == null) return false;
    if (rect.isEmpty) return false;
    // Check if within screen height and width
    return rect.top >= 0 &&
        rect.bottom <= screenSize.height &&
        rect.left >= 0 &&
        rect.right <= screenSize.width;
  }

  /// Clears all registrations (for testing).
  @visibleForTesting
  static void clear() {
    _targets.clear();
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
