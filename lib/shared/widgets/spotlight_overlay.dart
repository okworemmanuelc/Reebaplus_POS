import 'dart:async';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/shared/widgets/spotlight_target.dart';

/// Recognizer that swallows taps outside the spotlight hole in blocking mode
/// while allowing vertical/horizontal drags to pass through to underlying scrollables.
class BlockingTapSwallowingRecognizer extends OneSequenceGestureRecognizer {
  BlockingTapSwallowingRecognizer();

  /// Called when a swallowed tap lands — a press and release outside the hole
  /// that never travelled far enough to become a drag. A tap that goes nowhere
  /// is the only evidence the overlay has that the owner is trying to do
  /// something the sheet is refusing to let them do.
  VoidCallback? onBlockedTap;

  final Map<int, Offset> _downPositions = {};

  @override
  void addAllowedPointer(PointerDownEvent event) {
    _downPositions[event.pointer] = event.position;
    startTrackingPointer(event.pointer, event.transform);
  }

  @override
  void handleEvent(PointerEvent event) {
    if (event is PointerUpEvent) {
      // Swallows the tap outside the hole by resolving accepted,
      // preventing any underlying tap recognizers from firing.
      resolve(GestureDisposition.accepted);
      final down = _downPositions.remove(event.pointer);
      if (down != null && (event.position - down).distance <= kTouchSlop) {
        onBlockedTap?.call();
      }
      stopTrackingPointer(event.pointer);
    } else if (event is PointerCancelEvent) {
      resolve(GestureDisposition.rejected);
      _downPositions.remove(event.pointer);
      stopTrackingPointer(event.pointer);
    }
  }

  @override
  String get debugDescription => 'blockingTapSwallowing';

  @override
  void didStopTrackingLastPointer(int pointer) {}
}

/// RenderBox for [SpotlightOverlay] that cuts a hole over [targetRect]
/// and customizes hit testing based on [blocking].
class RenderSpotlightOverlay extends RenderBox {
  RenderSpotlightOverlay({
    required Rect? targetRect,
    required bool blocking,
    required Color overlayColor,
    required double borderRadius,
    required EdgeInsets padding,
    VoidCallback? onBlockedTap,
  })  : _targetRect = targetRect,
        _blocking = blocking,
        _overlayColor = overlayColor,
        _borderRadius = borderRadius,
        _padding = padding {
    _tapSwallower.onBlockedTap = onBlockedTap;
  }

  Rect? _targetRect;
  set targetRect(Rect? val) {
    if (_targetRect != val) {
      _targetRect = val;
      markNeedsPaint();
    }
  }

  bool _blocking;
  set blocking(bool val) {
    if (_blocking != val) {
      _blocking = val;
    }
  }

  Color _overlayColor;
  set overlayColor(Color val) {
    if (_overlayColor != val) {
      _overlayColor = val;
      markNeedsPaint();
    }
  }

  double _borderRadius;
  set borderRadius(double val) {
    if (_borderRadius != val) {
      _borderRadius = val;
      markNeedsPaint();
    }
  }

  EdgeInsets _padding;
  set padding(EdgeInsets val) {
    if (_padding != val) {
      _padding = val;
      markNeedsPaint();
    }
  }

  set onBlockedTap(VoidCallback? val) => _tapSwallower.onBlockedTap = val;

  final BlockingTapSwallowingRecognizer _tapSwallower =
      BlockingTapSwallowingRecognizer();

  Rect? get paddedHoleRect {
    if (_targetRect == null) return null;
    return Rect.fromLTRB(
      _targetRect!.left - _padding.left,
      _targetRect!.top - _padding.top,
      _targetRect!.right + _padding.right,
      _targetRect!.bottom + _padding.bottom,
    );
  }

  @override
  bool hitTestSelf(Offset position) => false;

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    final hole = paddedHoleRect;

    // Inside the hole: let event pass through completely to target widget underneath
    if (hole != null && hole.contains(position)) {
      return false;
    }

    // Outside the hole in non-blocking mode: pass through
    if (!_blocking) {
      return false;
    }

    // Outside the hole in blocking mode:
    // Add the tap-swallower to the arena, but return false so RenderStack
    // continues hit-testing underlying children (e.g. scrollables for drag-through).
    result.add(
      BoxHitTestEntry(
        this,
        position,
      ),
    );
    return false;
  }

  @override
  void handleEvent(PointerEvent event, BoxHitTestEntry entry) {
    if (event is PointerDownEvent) {
      _tapSwallower.addPointer(event);
    }
  }

  @override
  void performLayout() {
    size = constraints.biggest;
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final canvas = context.canvas;
    final hole = paddedHoleRect;

    final fullRect = offset & size;
    final path = Path()..addRect(fullRect);

    if (hole != null) {
      final rrect = RRect.fromRectAndRadius(
        hole.shift(offset),
        Radius.circular(_borderRadius),
      );
      final holePath = Path()..addRRect(rrect);
      final combined = Path.combine(PathOperation.difference, path, holePath);
      canvas.drawPath(combined, Paint()..color = _overlayColor);
    } else {
      canvas.drawPath(path, Paint()..color = _overlayColor);
    }
  }

  @override
  void dispose() {
    _tapSwallower.dispose();
    super.dispose();
  }
}

/// Custom widget implementing the spotlight overlay render box.
class _SpotlightOverlayBackground extends LeafRenderObjectWidget {
  const _SpotlightOverlayBackground({
    required this.targetRect,
    required this.blocking,
    required this.overlayColor,
    required this.borderRadius,
    required this.padding,
    this.onBlockedTap,
  });

  final Rect? targetRect;
  final bool blocking;
  final Color overlayColor;
  final double borderRadius;
  final EdgeInsets padding;
  final VoidCallback? onBlockedTap;

  @override
  RenderSpotlightOverlay createRenderObject(BuildContext context) {
    return RenderSpotlightOverlay(
      targetRect: targetRect,
      blocking: blocking,
      overlayColor: overlayColor,
      borderRadius: borderRadius,
      padding: padding,
      onBlockedTap: onBlockedTap,
    );
  }

  @override
  void updateRenderObject(
    BuildContext context,
    RenderSpotlightOverlay renderObject,
  ) {
    renderObject
      ..targetRect = targetRect
      ..blocking = blocking
      ..overlayColor = overlayColor
      ..borderRadius = borderRadius
      ..padding = padding
      ..onBlockedTap = onBlockedTap;
  }
}

/// A general presentation overlay that cuts a spotlight hole over a target with a caption.
///
/// Knows nothing about Stores, Products, or rails. Supports [blocking] and non-blocking modes.
class SpotlightOverlay extends StatefulWidget {
  const SpotlightOverlay({
    super.key,
    this.targetId,
    this.targetRect,
    required this.caption,
    this.content,
    this.footer,
    this.blocking = true,
    this.onMissingTarget,
    this.onBlockedTap,
    this.overlayColor = const Color(0xB8000000), // ~72% black
    this.holeRadius = 12.0,
    this.holePadding = const EdgeInsets.all(6.0),
    this.targetLookupTimeout = const Duration(milliseconds: 600),
  });

  /// The registered target identifier to spotlight. If provided, overrides [targetRect].
  final SpotlightTargetId? targetId;

  /// Explicit bounding rect in global coordinates. Used if [targetId] is null.
  final Rect? targetRect;

  /// The user-facing instruction (e.g. "Tap the menu to get started").
  ///
  /// With no target to point at, the caption is centred on the sheet instead of
  /// being tucked beside a hole. A step that has something to say but nothing
  /// to circle is still a step.
  final String caption;

  /// Replaces the caption bubble entirely with an interactive panel, centred on
  /// the sheet. For a step that asks the reader for a decision rather than a
  /// tap on the app behind it.
  final Widget? content;

  /// Rendered beneath the caption bubble, and unlike the bubble it receives
  /// pointer events. For a hint or an escape hatch that belongs to the step.
  final Widget? footer;

  /// In blocking mode, outside taps are swallowed while drags pass through.
  /// In non-blocking mode, outside interactions pass through.
  final bool blocking;

  /// Called when target cannot be found or is missing after [targetLookupTimeout].
  final VoidCallback? onMissingTarget;

  /// Called each time a tap outside the hole is swallowed in blocking mode.
  final VoidCallback? onBlockedTap;

  /// Color of the darkened sheet.
  final Color overlayColor;

  /// Corner radius of the cutout hole.
  final double holeRadius;

  /// Padding around the target bounds.
  final EdgeInsets holePadding;

  /// Timeout before [onMissingTarget] fires if target cannot be resolved.
  final Duration targetLookupTimeout;

  @override
  State<SpotlightOverlay> createState() => _SpotlightOverlayState();
}

class _SpotlightOverlayState extends State<SpotlightOverlay> {
  Rect? _resolvedRect;
  Timer? _lookupTimer;
  Timer? _timeoutTimer;
  bool _notifiedMissing = false;

  @override
  void initState() {
    super.initState();
    SpotlightTargetRegistry.registryRevision.addListener(_onRegistryChanged);
    // While this overlay is up, the registry re-resolves target rects every
    // painted frame so the hole follows a target that is still animating into
    // place (the drawer slides in over ~250 ms).
    SpotlightTargetRegistry.beginTracking();
    _startTargetLookup();
  }

  @override
  void dispose() {
    SpotlightTargetRegistry.endTracking();
    SpotlightTargetRegistry.registryRevision.removeListener(_onRegistryChanged);
    _lookupTimer?.cancel();
    _timeoutTimer?.cancel();
    super.dispose();
  }

  void _onRegistryChanged() {
    _updateTargetRect();
    if (_resolvedRect != null) {
      _lookupTimer?.cancel();
      _timeoutTimer?.cancel();
    }
  }

  @override
  void didUpdateWidget(SpotlightOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.targetId != widget.targetId ||
        oldWidget.targetRect != widget.targetRect) {
      _notifiedMissing = false;
      _startTargetLookup();
    }
  }

  void _startTargetLookup() {
    _lookupTimer?.cancel();
    _timeoutTimer?.cancel();

    // Check immediately
    _updateTargetRect();

    if (_resolvedRect == null && widget.targetId != null) {
      // Poll briefly across animation frames
      _lookupTimer = Timer.periodic(const Duration(milliseconds: 50), (_) {
        _updateTargetRect();
        if (_resolvedRect != null) {
          _lookupTimer?.cancel();
          _timeoutTimer?.cancel();
        }
      });

      _timeoutTimer = Timer(widget.targetLookupTimeout, () {
        _lookupTimer?.cancel();
        if (_resolvedRect == null && !_notifiedMissing) {
          _notifiedMissing = true;
          widget.onMissingTarget?.call();
        }
      });
    }
  }

  void _updateTargetRect() {
    Rect? rect;
    if (widget.targetId != null) {
      rect = SpotlightTargetRegistry.getTargetRect(widget.targetId!);
    } else {
      rect = widget.targetRect;
    }

    if (_resolvedRect != rect) {
      if (mounted) {
        setState(() {
          _resolvedRect = rect;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final screenSize = Size(context.screenWidth, context.screenHeight);
    final hole = _resolvedRect;

    return Stack(
      fit: StackFit.expand,
      children: [
        // 1. Darkened sheet with cutout hole
        _SpotlightOverlayBackground(
          targetRect: hole,
          blocking: widget.blocking,
          overlayColor: widget.overlayColor,
          borderRadius: widget.holeRadius,
          padding: widget.holePadding,
          onBlockedTap: widget.onBlockedTap,
        ),

        // 2. Either a panel asking for a decision, or the instruction — beside
        //    the hole when there is one, centred on the sheet when there isn't.
        if (widget.content != null)
          _buildContentPanel(context)
        else if (hole != null)
          _buildCaption(context, hole, screenSize)
        else
          _buildCentredCaption(context),
      ],
    );
  }

  Widget _buildContentPanel(BuildContext context) {
    return Positioned.fill(
      child: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: EdgeInsets.symmetric(horizontal: context.getRSize(24)),
            child: widget.content,
          ),
        ),
      ),
    );
  }

  Widget _buildCentredCaption(BuildContext context) {
    return Positioned.fill(
      child: SafeArea(
        child: Center(
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: context.getRSize(24)),
            child: _captionColumn(context),
          ),
        ),
      ),
    );
  }

  Widget _buildCaption(BuildContext context, Rect hole, Size screenSize) {
    final isTopHalf = hole.center.dy < screenSize.height * 0.55;

    // Position above or below hole
    final double? topPos = isTopHalf
        ? (hole.bottom + widget.holePadding.bottom + context.getRSize(16))
        : null;
    final double? bottomPos = !isTopHalf
        ? (screenSize.height - hole.top + widget.holePadding.top + context.getRSize(16))
        : null;

    return Positioned(
      top: topPos,
      bottom: bottomPos,
      left: context.getRSize(24),
      right: context.getRSize(24),
      child: Center(child: _captionColumn(context)),
    );
  }

  /// The instruction bubble, plus whatever the step hung under it.
  ///
  /// Only the bubble ignores pointers — a footer exists to be tapped, and
  /// wrapping the whole column would make the one escape the owner has as
  /// dead as the sheet around it.
  Widget _captionColumn(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        IgnorePointer(
          child: Container(
            constraints: BoxConstraints(maxWidth: context.getRSize(320)),
            padding: EdgeInsets.symmetric(
              horizontal: context.getRSize(16),
              vertical: context.getRSize(12),
            ),
            decoration: BoxDecoration(
              color: theme.colorScheme.surface,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: theme.colorScheme.primary.withValues(alpha: 0.4),
                width: 1.5,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.3),
                  blurRadius: 16,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: context.getRSize(8),
                  height: context.getRSize(8),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: theme.colorScheme.primary,
                  ),
                ),
                SizedBox(width: context.getRSize(10)),
                Flexible(
                  child: Text(
                    widget.caption,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: theme.colorScheme.onSurface,
                    ),
                    textAlign: TextAlign.left,
                  ),
                ),
              ],
            ),
          ),
        ),
        if (widget.footer != null) ...[
          SizedBox(height: context.getRSize(12)),
          widget.footer!,
        ],
      ],
    );
  }
}
