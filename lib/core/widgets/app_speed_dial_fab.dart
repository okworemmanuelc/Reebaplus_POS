import 'package:flutter/material.dart';

import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/core/widgets/app_fab.dart';

/// One labelled choice in an [AppSpeedDialFab]: an icon, a short [label], a
/// one-line [description] (the teaching surface — ADR 0006), and the action to
/// run when chosen. Permission-agnostic by design: callers decide which actions
/// survive gating (citing the named registry — ADR 0002) and hand the widget
/// only the ones the current user may take.
class AppSpeedDialAction {
  const AppSpeedDialAction({
    required this.icon,
    required this.label,
    required this.description,
    required this.onPressed,
  });

  /// Leading icon shown in the option pill and, when this is the sole surviving
  /// action, on the collapsed direct FAB.
  final IconData icon;

  /// The action name (e.g. "Add Product"). Doubles as the collapsed FAB label.
  final String label;

  /// One-line "what this does" helper, shown only in the expanded menu.
  final String description;

  /// Invoked when the option (or the collapsed direct FAB) is chosen. The dial
  /// closes itself before this runs.
  final VoidCallback onPressed;
}

/// A shared, permission-aware speed-dial floating action button (ADR 0006).
/// One "+" button expands to a stack of labelled [AppSpeedDialAction] pills,
/// each with a one-line description that doubles as a teaching surface.
///
/// **Permission-aware collapse is intrinsic to the widget, not the caller:**
/// the caller filters [actions] through the gate registry and this widget
/// renders the right shape for whatever survives — nothing for zero actions, a
/// single direct [AppFAB] (never a menu of one) for exactly one, and the
/// expandable dial for two or more. The gating decision stays at the call site;
/// the collapse *rendering* lives here so every speed-dial behaves the same.
class AppSpeedDialFab extends StatefulWidget {
  const AppSpeedDialFab({
    super.key,
    required this.actions,
    this.toggleIcon = Icons.add,
    this.reserveBottomInset = true,
  });

  /// The actions the current user may take, in display order (the first sits
  /// closest to the toggle). Already gate-filtered by the caller.
  final List<AppSpeedDialAction> actions;

  /// Icon on the collapsed toggle; rotates 45° into a close affordance when the
  /// dial is open. Ignored in the single-action (direct [AppFAB]) shape.
  final IconData toggleIcon;

  /// Passed through to the collapsed [AppFAB] and used to lift the toggle above
  /// the system navigation bar. See [AppFAB.reserveBottomInset].
  final bool reserveBottomInset;

  @override
  State<AppSpeedDialFab> createState() => _AppSpeedDialFabState();
}

class _AppSpeedDialFabState extends State<AppSpeedDialFab>
    with SingleTickerProviderStateMixin {
  final LayerLink _link = LayerLink();
  late final AnimationController _controller;
  OverlayEntry? _entry;

  bool get _isOpen => _entry != null;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 180),
    );
  }

  @override
  void didUpdateWidget(covariant AppSpeedDialFab oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Permissions can resolve mid-session; if the dial collapses below two
    // actions while open (e.g. live revocation), close it so it can't outlive
    // its expandable shape.
    if (_isOpen && widget.actions.length < 2) {
      _close();
    }
  }

  @override
  void dispose() {
    _removeEntry();
    _controller.dispose();
    super.dispose();
  }

  void _toggle() => _isOpen ? _close() : _open();

  void _open() {
    if (_isOpen) return;
    _entry = OverlayEntry(builder: _buildOverlay);
    Overlay.of(context).insert(_entry!);
    _controller.forward();
    setState(() {});
  }

  Future<void> _close() async {
    if (!_isOpen) return;
    await _controller.reverse();
    _removeEntry();
    if (mounted) setState(() {});
  }

  void _removeEntry() {
    _entry?.remove();
    _entry = null;
  }

  /// Close the dial, then run the chosen action after this frame so navigation
  /// starts from a settled overlay.
  void _select(AppSpeedDialAction action) {
    _close();
    action.onPressed();
  }

  @override
  Widget build(BuildContext context) {
    final actions = widget.actions;

    // Zero surviving actions → no FAB at all.
    if (actions.isEmpty) return const SizedBox.shrink();

    // Exactly one → a direct FAB, never a menu of one (ADR 0006).
    if (actions.length == 1) {
      final only = actions.single;
      return AppFAB(
        label: only.label,
        icon: only.icon,
        onPressed: only.onPressed,
        reserveBottomInset: widget.reserveBottomInset,
      );
    }

    // Two or more → the expandable dial toggle. The expanded pills live in an
    // Overlay (so their scrim can cover the whole screen); this slot holds only
    // the anchored toggle button.
    Widget toggle = CompositedTransformTarget(
      link: _link,
      child: _ToggleButton(
        icon: widget.toggleIcon,
        progress: _controller,
        onPressed: _toggle,
      ),
    );

    if (widget.reserveBottomInset) {
      toggle = Padding(
        padding: EdgeInsets.only(bottom: context.deviceBottomPadding),
        child: toggle,
      );
    }
    return toggle;
  }

  Widget _buildOverlay(BuildContext overlayContext) {
    final actions = widget.actions;
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final t = Curves.easeOut.transform(_controller.value);
        return Stack(
          children: [
            // Full-screen scrim: dims the app and dismisses the dial on an
            // outside tap.
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _close,
                child: ColoredBox(
                  color: Colors.black.withValues(alpha: 0.35 * t),
                ),
              ),
            ),
            // The option pills, anchored directly above the toggle button and
            // right-aligned with it.
            CompositedTransformFollower(
              link: _link,
              targetAnchor: Alignment.topRight,
              followerAnchor: Alignment.bottomRight,
              offset: Offset(0, -rSize(context, 12)),
              child: Align(
                alignment: Alignment.bottomRight,
                child: Opacity(
                  opacity: t,
                  child: Transform.translate(
                    offset: Offset(0, (1 - t) * rSize(context, 16)),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        for (final action in actions) ...[
                          _OptionPill(
                            action: action,
                            onTap: () => _select(action),
                          ),
                          SizedBox(height: rSize(context, 12)),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// The collapsed "+" toggle — a circular gradient button matching [AppFAB]'s
/// palette whose icon rotates 45° as [progress] drives from closed to open.
class _ToggleButton extends StatelessWidget {
  const _ToggleButton({
    required this.icon,
    required this.progress,
    required this.onPressed,
  });

  final IconData icon;
  final Animation<double> progress;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final double size = rSize(context, 56);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [colorScheme.primary, colorScheme.secondary],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
            color: colorScheme.primary.withValues(alpha: 0.35),
            blurRadius: 12,
            offset: const Offset(0, 5),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onPressed,
          child: Center(
            child: RotationTransition(
              turns: Tween<double>(begin: 0, end: 0.125).animate(progress),
              child: Icon(
                icon,
                color: colorScheme.onPrimary,
                size: rSize(context, 24),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// One expanded option: a surface pill with a gradient icon badge, the action
/// [AppSpeedDialAction.label] (bold) and its one-line description.
class _OptionPill extends StatelessWidget {
  const _OptionPill({required this.action, required this.onTap});

  final AppSpeedDialAction action;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final double badge = rSize(context, 40);
    return Material(
      color: colorScheme.surface,
      elevation: 6,
      shadowColor: Colors.black.withValues(alpha: 0.2),
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: rSize(context, 280)),
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: rSize(context, 14),
              vertical: rSize(context, 12),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: badge,
                  height: badge,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [colorScheme.primary, colorScheme.secondary],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    action.icon,
                    color: colorScheme.onPrimary,
                    size: rSize(context, 18),
                  ),
                ),
                SizedBox(width: rSize(context, 12)),
                Flexible(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        action.label,
                        style: TextStyle(
                          color: colorScheme.onSurface,
                          fontWeight: FontWeight.bold,
                          fontSize: rFontSize(context, 15),
                        ),
                      ),
                      SizedBox(height: rSize(context, 2)),
                      Text(
                        action.description,
                        style: TextStyle(
                          color: colorScheme.onSurface.withValues(alpha: 0.65),
                          fontSize: rFontSize(context, 12),
                          height: 1.25,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
