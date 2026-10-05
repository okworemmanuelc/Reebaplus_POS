import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';

import 'package:reebaplus_pos/core/theme/app_icons.dart';

/// What a flight can land on (#352 PR 3). Target-agnostic on purpose: a new
/// destination (e.g. Receive Stock's receiving-cart button, Wave 2 A) adds a
/// value here, wraps its button in a [FlyTarget] with that id, and calls
/// [flyToTarget] with it.
enum FlyTargetId {
  /// The sales cart: the bottom-bar Cart item (under 600dp), the rail Cart
  /// item (600dp+), or the cart panel header while the panel is open.
  cart,
}

/// Where flights land, by [FlyTargetId]. [FlyTarget] widgets register
/// themselves; [flyToTarget] resolves the one that is actually showing at
/// launch. Never a screen coordinate.
class FlyTargetRegistry {
  FlyTargetRegistry._();

  static final Map<FlyTargetId, Map<GlobalKey, _Registration>> _targets = {};

  static void _register(FlyTargetId id, GlobalKey key, _Registration r) {
    _targets.putIfAbsent(id, () => {})[key] = r;
  }

  static void _unregister(FlyTargetId id, GlobalKey key) {
    final map = _targets[id];
    map?.remove(key);
    if (map != null && map.isEmpty) _targets.remove(id);
  }

  /// Whether [object] is actually painted: no ancestor (an `Offstage` tab, a
  /// hidden fixed cart panel) suppresses it.
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

  /// The global landing point for [id]: of the registered targets that are
  /// mounted, laid out, painted and whose landing point lies inside [bounds]
  /// (the overlay the flight draws in, in global coordinates), the one with
  /// the highest priority. Null when none is showing — e.g. a pushed page
  /// hides the bottom bar, or the slide-in panel is parked off-screen.
  static Offset? resolve(FlyTargetId id, Rect bounds) {
    final map = _targets[id];
    if (map == null) return null;
    Offset? best;
    var bestPriority = -1;
    for (final entry in map.entries) {
      final ctx = entry.key.currentContext;
      if (ctx == null) continue;
      final box = ctx.findRenderObject();
      if (box is! RenderBox || !box.attached || !box.hasSize) continue;
      if (box.size.isEmpty || !_isPainted(box)) continue;
      final r = entry.value;
      final local = r.anchor.alongSize(box.size) + r.offset;
      final point = box.localToGlobal(local);
      if (!bounds.contains(point)) continue;
      if (r.priority > bestPriority) {
        best = point;
        bestPriority = r.priority;
      }
    }
    return best;
  }

  /// Clears every registration (tests only).
  @visibleForTesting
  static void clear() => _targets.clear();
}

class _Registration {
  const _Registration(this.priority, this.anchor, this.offset);
  final int priority;
  final Alignment anchor;
  final Offset offset;
}

/// Marks [child] as a landing spot for flights to [id].
///
/// When several are showing at once, the highest [priority] wins (the cart
/// panel header, 1, beats the nav Cart item, 0). The flight lands at [anchor]
/// within the child, nudged by [anchorOffset].
class FlyTarget extends StatefulWidget {
  const FlyTarget({
    super.key,
    required this.id,
    required this.child,
    this.priority = 0,
    this.anchor = Alignment.center,
    this.anchorOffset = Offset.zero,
  });

  final FlyTargetId id;
  final Widget child;
  final int priority;
  final Alignment anchor;
  final Offset anchorOffset;

  @override
  State<FlyTarget> createState() => _FlyTargetState();
}

class _FlyTargetState extends State<FlyTarget> {
  final GlobalKey _key = GlobalKey();

  _Registration get _registration =>
      _Registration(widget.priority, widget.anchor, widget.anchorOffset);

  @override
  void initState() {
    super.initState();
    FlyTargetRegistry._register(widget.id, _key, _registration);
  }

  @override
  void didUpdateWidget(FlyTarget oldWidget) {
    super.didUpdateWidget(oldWidget);
    FlyTargetRegistry._unregister(oldWidget.id, _key);
    FlyTargetRegistry._register(widget.id, _key, _registration);
  }

  @override
  void dispose() {
    FlyTargetRegistry._unregister(widget.id, _key);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      KeyedSubtree(key: _key, child: widget.child);
}

/// A flight in progress. [cancel] removes it at once (safe to call twice or
/// after it has landed).
class FlyToCartFlight {
  FlyToCartFlight._(this._entry);

  OverlayEntry? _entry;

  /// Whether the flight is still on screen.
  bool get isActive => _entry != null;

  void cancel() {
    final entry = _entry;
    _entry = null;
    if (entry != null && entry.mounted) entry.remove();
  }
}

/// The fly-to-cart animation (#352 PR 3), with POS's feel from before the
/// redesign kept exactly: 620ms; position eased with `Curves.easeIn`; x
/// straight from source to target; y the straight line plus an upward arc of
/// `-110 * sin(π·t)` on the raw progress; scale 1 → 0.35 (eased); fully opaque
/// until 82% and then fading out; a 30dp primary circle with a 0.55 primary
/// glow (blur 10, spread 1) and a white 15dp cart icon.
///
/// Flies from [source] (the tile tapped; the point at [sourceAnchor], by
/// default the centre a third of the way down) to the [target] that is
/// actually showing — see [FlyTargetRegistry.resolve].
///
/// Purely cosmetic, so it never throws and never blocks: it returns null and
/// does nothing when animations are disabled (reduced motion), when no target
/// is showing, or when [source] has no size. It draws in the root `Overlay`
/// in its own `OverlayEntry` that owns its controller, so the tapped tile may
/// unmount mid-flight; the entry removes itself when it lands.
FlyToCartFlight? flyToTarget(
  BuildContext source, {
  FlyTargetId target = FlyTargetId.cart,
  Alignment sourceAnchor = const Alignment(0, -1 / 3),
}) {
  if (!source.mounted) return null;
  if (MediaQuery.maybeDisableAnimationsOf(source) ?? false) return null;
  final overlay = Overlay.maybeOf(source, rootOverlay: true);
  if (overlay == null) return null;
  final overlayBox = overlay.context.findRenderObject();
  final sourceBox = source.findRenderObject();
  if (overlayBox is! RenderBox || !overlayBox.hasSize) return null;
  if (sourceBox is! RenderBox || !sourceBox.hasSize) return null;

  final overlayOrigin = overlayBox.localToGlobal(Offset.zero);
  final bounds = overlayOrigin & overlayBox.size;
  final to = FlyTargetRegistry.resolve(target, bounds);
  if (to == null) return null;
  final from = sourceBox.localToGlobal(sourceAnchor.alongSize(sourceBox.size));

  final primary = Theme.of(source).colorScheme.primary;
  late final FlyToCartFlight flight;
  final entry = OverlayEntry(
    builder: (_) => _Flight(
      from: from - overlayOrigin,
      to: to - overlayOrigin,
      color: primary,
      onDone: () => flight.cancel(),
    ),
  );
  flight = FlyToCartFlight._(entry);
  overlay.insert(entry);
  return flight;
}

/// Duration of a flight; also what tests pump.
const Duration kFlyToCartDuration = Duration(milliseconds: 620);

class _Flight extends StatefulWidget {
  const _Flight({
    required this.from,
    required this.to,
    required this.color,
    required this.onDone,
  });

  final Offset from;
  final Offset to;
  final Color color;
  final VoidCallback onDone;

  @override
  State<_Flight> createState() => _FlightState();
}

class _FlightState extends State<_Flight> with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: kFlyToCartDuration,
  );

  bool _disposing = false;

  @override
  void initState() {
    super.initState();
    _ctrl.forward().whenCompleteOrCancel(() {
      // Landed: take the entry out. Not while being disposed (the entry is
      // already going, e.g. cancelled or its overlay torn down).
      if (mounted && !_disposing) widget.onDone();
    });
  }

  @override
  void dispose() {
    _disposing = true;
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (context, child) {
        final raw = _ctrl.value;
        final t = Curves.easeIn.transform(raw);
        final x = lerpDouble(widget.from.dx, widget.to.dx, t)!;
        final yBase = lerpDouble(widget.from.dy, widget.to.dy, t)!;
        final y = yBase - 110.0 * math.sin(math.pi * raw); // upward arc
        final scale = lerpDouble(1.0, 0.35, t)!;
        final opacity = raw > 0.82 ? ((1.0 - raw) / 0.18).clamp(0.0, 1.0) : 1.0;
        return Positioned(
          left: x - 15,
          top: y - 15,
          child: IgnorePointer(
            child: Opacity(
              opacity: opacity,
              child: Transform.scale(scale: scale, child: child),
            ),
          ),
        );
      },
      child: Container(
        key: const Key('fly-to-cart-particle'),
        width: 30,
        height: 30,
        decoration: BoxDecoration(
          color: widget.color,
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: widget.color.withValues(alpha: 0.55),
              blurRadius: 10,
              spreadRadius: 1,
            ),
          ],
        ),
        // The pre-redesign particle's white icon; on the primary circle it is
        // the scheme's on-primary.
        child: AppIcon(
          AppIcons.cart,
          size: 15,
          color: Theme.of(context).colorScheme.onPrimary,
        ),
      ),
    );
  }
}
