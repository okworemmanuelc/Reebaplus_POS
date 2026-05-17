import 'package:flutter/material.dart';

/// Animated step-progress indicator for the onboarding flow.
///
/// Shows dots connected by lines with short labels beneath each dot.
/// Completed steps show a checkmark, the current step pulses with a glow,
/// and future steps are dimmed.
class OnboardingStepIndicator extends StatefulWidget {
  /// 1-based index of the current step.
  final int currentStep;

  /// Total number of steps in this onboarding path.
  final int totalSteps;

  /// Short labels displayed beneath each dot. Length must equal [totalSteps].
  final List<String> stepLabels;

  const OnboardingStepIndicator({
    super.key,
    required this.currentStep,
    required this.totalSteps,
    required this.stepLabels,
  });

  /// Path A — New Business Owner (7 steps)
  static const pathALabels = [
    'Type',
    'Name',
    'Business',
    'Location',
    'Settings',
    'PIN',
    'Security',
  ];

  /// Path B — Join Existing Business (7 steps)
  static const pathBLabels = [
    'Type',
    'Invite',
    'Role',
    'Details',
    'Contacts',
    'PIN',
    'Security',
  ];

  @override
  State<OnboardingStepIndicator> createState() =>
      _OnboardingStepIndicatorState();
}

class _OnboardingStepIndicatorState extends State<OnboardingStepIndicator>
    with SingleTickerProviderStateMixin {
  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      duration: const Duration(milliseconds: 1200),
      vsync: this,
    )..repeat(reverse: true);

    _pulseAnimation = Tween<double>(begin: 0.3, end: 0.7).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 56,
      child: Column(
        children: [
          // Dots and connecting lines
          Row(
            children: List.generate(widget.totalSteps * 2 - 1, (index) {
              if (index.isEven) {
                // Dot
                final step = index ~/ 2 + 1;
                return _buildDot(step);
              } else {
                // Line between dots
                final leftStep = index ~/ 2 + 1;
                return _buildLine(leftStep);
              }
            }),
          ),
          const SizedBox(height: 6),
          // Labels
          Row(
            children: List.generate(widget.totalSteps * 2 - 1, (index) {
              if (index.isEven) {
                final step = index ~/ 2 + 1;
                return _buildLabel(step);
              } else {
                return const Expanded(child: SizedBox.shrink());
              }
            }),
          ),
        ],
      ),
    );
  }

  Widget _buildDot(int step) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final activeColor = theme.colorScheme.primary;
    final textColor = isDark ? Colors.white : Colors.black;

    final isCompleted = step < widget.currentStep;
    final isCurrent = step == widget.currentStep;

    if (isCurrent) {
      return AnimatedBuilder(
        animation: _pulseAnimation,
        builder: (context, child) {
          return Container(
            width: 18,
            height: 18,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: activeColor,
              border: Border.all(color: activeColor, width: 2),
              boxShadow: [
                BoxShadow(
                  color: activeColor.withValues(alpha: _pulseAnimation.value),
                  blurRadius: 8,
                  spreadRadius: 2,
                ),
              ],
            ),
          );
        },
      );
    }

    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
      width: 16,
      height: 16,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: isCompleted ? activeColor : Colors.transparent,
        border: Border.all(
          color: isCompleted ? activeColor : textColor.withValues(alpha: 0.3),
          width: 1.5,
        ),
      ),
      child: isCompleted
          ? const Center(
              child: Icon(Icons.check_rounded, size: 10, color: Colors.white),
            )
          : null,
    );
  }

  Widget _buildLine(int leftStep) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final activeColor = theme.colorScheme.primary;
    final textColor = isDark ? Colors.white : Colors.black;

    final isCompleted = leftStep < widget.currentStep;

    return Expanded(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2),
        child: SizedBox(
          height: 2,
          child: Stack(
            children: [
              // Background line (always visible)
              Container(
                decoration: BoxDecoration(
                  color: textColor.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(1),
                ),
              ),
              // Foreground fill (animated)
              AnimatedFractionallySizedBox(
                duration: const Duration(milliseconds: 500),
                curve: Curves.easeInOut,
                alignment: Alignment.centerLeft,
                widthFactor: isCompleted ? 1.0 : 0.0,
                child: Container(
                  decoration: BoxDecoration(
                    color: activeColor.withValues(alpha: 0.8),
                    borderRadius: BorderRadius.circular(1),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildLabel(int step) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final textColor = isDark ? Colors.white : Colors.black;
    final activeColor = theme.colorScheme.primary;

    final isActiveOrDone = step <= widget.currentStep;

    return SizedBox(
      width: 40,
      child: AnimatedDefaultTextStyle(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
        style: TextStyle(
          fontSize: 9,
          fontWeight: FontWeight.w500,
          color: isActiveOrDone
              ? (step == widget.currentStep ? activeColor : textColor)
              : textColor.withValues(alpha: 0.3),
        ),
        child: Text(
          widget.stepLabels[step - 1],
          textAlign: TextAlign.center,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    );
  }
}

/// Animated version of [FractionallySizedBox] that smoothly transitions
/// width/height factor changes.
class AnimatedFractionallySizedBox extends ImplicitlyAnimatedWidget {
  final double? widthFactor;
  final double? heightFactor;
  final AlignmentGeometry alignment;
  final Widget? child;

  const AnimatedFractionallySizedBox({
    super.key,
    this.widthFactor,
    this.heightFactor,
    this.alignment = Alignment.center,
    this.child,
    required super.duration,
    super.curve,
  });

  @override
  AnimatedWidgetBaseState<AnimatedFractionallySizedBox> createState() =>
      _AnimatedFractionallySizedBoxState();
}

class _AnimatedFractionallySizedBoxState
    extends AnimatedWidgetBaseState<AnimatedFractionallySizedBox> {
  Tween<double>? _widthFactor;
  Tween<double>? _heightFactor;

  @override
  void forEachTween(TweenVisitor<dynamic> visitor) {
    _widthFactor =
        visitor(
              _widthFactor,
              widget.widthFactor ?? 1.0,
              (value) => Tween<double>(begin: value as double),
            )
            as Tween<double>?;

    _heightFactor =
        visitor(
              _heightFactor,
              widget.heightFactor ?? 1.0,
              (value) => Tween<double>(begin: value as double),
            )
            as Tween<double>?;
  }

  @override
  Widget build(BuildContext context) {
    return FractionallySizedBox(
      alignment: widget.alignment,
      widthFactor: _widthFactor?.evaluate(animation),
      heightFactor: _heightFactor?.evaluate(animation),
      child: widget.child,
    );
  }
}
