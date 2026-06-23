import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import 'package:reebaplus_pos/core/theme/app_decorations.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';

/// Continuously looping branded loading animation shown during the initial
/// full-pull on a fresh device. Uses a repeating AnimationController so the
/// glow never freezes (unlike a one-shot TweenAnimationBuilder).
///
/// Pass [progressLabel] and [done]/[total] to show "Setting up your store —
/// 4 of 12…". Omit them for the plain "Setting up your store…" fallback.
class InitialLoadAnimation extends StatefulWidget {
  final String? progressLabel;
  final int? done;
  final int? total;

  const InitialLoadAnimation({
    super.key,
    this.progressLabel,
    this.done,
    this.total,
  });

  @override
  State<InitialLoadAnimation> createState() => _InitialLoadAnimationState();
}

class _InitialLoadAnimationState extends State<InitialLoadAnimation>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _pulse;
  late final Animation<double> _iconFade;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    )..repeat(reverse: true);

    _pulse = Tween<double>(begin: 0.85, end: 1.15).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
    );

    _iconFade = Tween<double>(begin: 0.55, end: 1.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final cs = t.colorScheme;

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Container(
        width: double.infinity,
        height: double.infinity,
        decoration: AppDecorations.glassyBackground(context),
        child: SafeArea(
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: context.getRSize(24),
              vertical: context.getRSize(32),
            ),
            child: Column(
              children: [
                const Spacer(),
                _AnimatedBranding(
                  pulse: _pulse,
                  iconFade: _iconFade,
                  primaryColor: cs.primary,
                ),
                SizedBox(height: context.getRSize(48)),
                Text(
                  'Syncing Your Store',
                  style: t.textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                    color: cs.onSurface,
                    letterSpacing: -0.5,
                  ),
                ),
                SizedBox(height: context.getRSize(12)),
                _ProgressLabel(
                  label: widget.progressLabel,
                  done: widget.done,
                  total: widget.total,
                ),
                const Spacer(),
                Text(
                  'This only happens once on your fresh device login.\nPlease keep the app open.',
                  textAlign: TextAlign.center,
                  style: t.textTheme.bodySmall?.copyWith(
                    color: cs.onSurface.withValues(alpha: 0.4),
                  ),
                ),
                SizedBox(height: context.getRSize(16)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _AnimatedBranding extends StatelessWidget {
  final Animation<double> pulse;
  final Animation<double> iconFade;
  final Color primaryColor;

  const _AnimatedBranding({
    required this.pulse,
    required this.iconFade,
    required this.primaryColor,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: pulse,
      builder: (context, _) {
        return SizedBox(
          width: context.getRSize(160),
          height: context.getRSize(160),
          child: Stack(
            alignment: Alignment.center,
            children: [
              // Outer pulsing glow ring
              Container(
                width: context.getRSize(140) * pulse.value,
                height: context.getRSize(140) * pulse.value,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: primaryColor.withValues(
                        alpha: 0.18 * pulse.value,
                      ),
                      blurRadius: context.getRSize(40),
                      spreadRadius: context.getRSize(8),
                    ),
                  ],
                ),
              ),
              // Progress spinner
              SizedBox(
                width: context.getRSize(100),
                height: context.getRSize(100),
                child: CircularProgressIndicator(
                  strokeWidth: 3.5,
                  valueColor: AlwaysStoppedAnimation<Color>(primaryColor),
                  backgroundColor: primaryColor.withValues(alpha: 0.1),
                ),
              ),
              // Icon with subtle fade
              FadeTransition(
                opacity: iconFade,
                child: FaIcon(
                  FontAwesomeIcons.cloudArrowDown,
                  size: context.getRSize(34),
                  color: primaryColor,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _ProgressLabel extends StatelessWidget {
  final String? label;
  final int? done;
  final int? total;

  const _ProgressLabel({this.label, this.done, this.total});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final cs = t.colorScheme;

    final String text;
    if (done != null && total != null && total! > 0) {
      text = '${label ?? 'Setting up your store'} — $done of $total…';
    } else {
      text = label != null ? '$label…' : 'Setting up your store…';
    }

    return SizedBox(
      height: context.getRSize(44),
      child: Center(
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: t.textTheme.bodyMedium?.copyWith(
            color: cs.onSurface.withValues(alpha: 0.7),
            height: 1.4,
          ),
        ),
      ),
    );
  }
}
