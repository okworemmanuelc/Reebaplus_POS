import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/theme/semantic_colors.dart';
import 'package:reebaplus_pos/features/auth/widgets/auth_background.dart';
import 'package:reebaplus_pos/features/subscription/subscription_thanks.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';

/// Celebratory full-screen shown once per activation (master plan §32) when the
/// admin console flips a business to `active`. Mirrors the post-login success
/// screens (AccessGrantedScreen) in look and feel. "Continue" acknowledges the
/// current activation so it won't show again until the next renewal — the
/// home() gate then swaps this out for the app shell automatically.
class ThankYouSubscriptionScreen extends ConsumerStatefulWidget {
  final BusinessData business;

  const ThankYouSubscriptionScreen({super.key, required this.business});

  @override
  ConsumerState<ThankYouSubscriptionScreen> createState() =>
      _ThankYouSubscriptionScreenState();
}

class _ThankYouSubscriptionScreenState
    extends ConsumerState<ThankYouSubscriptionScreen>
    with TickerProviderStateMixin {
  late final AnimationController _iconController;
  late final AnimationController _contentController;
  late final AnimationController _pulseController;

  late final Animation<double> _iconScale;
  late final Animation<double> _iconOpacity;
  late final Animation<double> _contentOpacity;
  late final Animation<Offset> _contentSlide;
  late final Animation<double> _pulseScale;

  bool _continuing = false;

  @override
  void initState() {
    super.initState();

    _iconController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    );
    _iconScale = CurvedAnimation(
      parent: _iconController,
      curve: Curves.elasticOut,
    );
    _iconOpacity = CurvedAnimation(
      parent: _iconController,
      curve: const Interval(0.0, 0.4, curve: Curves.easeIn),
    );

    _contentController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    );
    _contentOpacity = CurvedAnimation(
      parent: _contentController,
      curve: Curves.easeOut,
    );
    _contentSlide =
        Tween<Offset>(begin: const Offset(0, 0.12), end: Offset.zero).animate(
          CurvedAnimation(parent: _contentController, curve: Curves.easeOut),
        );

    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2000),
    )..repeat(reverse: true);
    _pulseScale = Tween<double>(begin: 1.0, end: 1.15).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );

    _iconController.forward();
    Future.delayed(const Duration(milliseconds: 350), () {
      if (mounted) _contentController.forward();
    });
  }

  @override
  void dispose() {
    _iconController.dispose();
    _contentController.dispose();
    _pulseController.dispose();
    super.dispose();
  }

  /// Fixed subscription price (§32) — mirrors SubscriptionScreen.
  String get _priceLine => widget.business.subscriptionPlan == 'international'
      ? '\$10 per month'
      : '₦5,000 per month';

  Future<void> _onContinue() async {
    if (_continuing) return;
    setState(() => _continuing = true);
    // Acknowledge the activation; the home() gate watches the thanks provider
    // and rebuilds into the app shell once this resolves.
    await ref.read(subscriptionThanksProvider).acknowledge(widget.business);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final textColor = isDark ? Colors.white : Colors.black;
    final successColor =
        theme.extension<AppSemanticColors>()?.success ??
        const Color(0xFF30D158);

    final periodEnd = widget.business.currentPeriodEnd;
    final renewsLine = periodEnd == null
        ? null
        : 'Renews ${DateFormat('d MMM yyyy').format(periodEnd)}';

    return AuthBackground(
      child: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            return SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  minHeight: constraints.maxHeight - 64,
                ),
                child: IntrinsicHeight(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Spacer(),
                      _buildIcon(successColor),
                      const SizedBox(height: 28),
                      SlideTransition(
                        position: _contentSlide,
                        child: FadeTransition(
                          opacity: _contentOpacity,
                          child: Column(
                            children: [
                              Text(
                                'Thank you for subscribing!',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  fontSize: 28,
                                  fontWeight: FontWeight.w800,
                                  color: textColor,
                                  letterSpacing: -0.5,
                                ),
                              ),
                              const SizedBox(height: 10),
                              Text(
                                '${widget.business.name} is now on the '
                                'Reebaplus monthly plan. Every feature is '
                                'unlocked — thank you for going PRO.',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  fontSize: 15,
                                  height: 1.45,
                                  color: textColor.withValues(alpha: 0.7),
                                ),
                              ),
                              const SizedBox(height: 24),
                              _planChip(theme, successColor, renewsLine),
                            ],
                          ),
                        ),
                      ),
                      const Spacer(),
                      const SizedBox(height: 28),
                      FadeTransition(
                        opacity: _contentOpacity,
                        child: AppButton(
                          text: 'Continue',
                          isLoading: _continuing,
                          onPressed: _onContinue,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _planChip(ThemeData theme, Color successColor, String? renewsLine) {
    final textColor = theme.brightness == Brightness.dark
        ? Colors.white
        : Colors.black;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: successColor.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: successColor.withValues(alpha: 0.3)),
      ),
      child: Column(
        children: [
          Text(
            _priceLine,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: textColor,
            ),
          ),
          if (renewsLine != null) ...[
            const SizedBox(height: 2),
            Text(
              renewsLine,
              style: TextStyle(
                fontSize: 12.5,
                color: textColor.withValues(alpha: 0.6),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildIcon(Color successColor) {
    return Center(
      child: FadeTransition(
        opacity: _iconOpacity,
        child: ScaleTransition(
          scale: _iconScale,
          child: SizedBox(
            width: 120,
            height: 120,
            child: Stack(
              alignment: Alignment.center,
              children: [
                AnimatedBuilder(
                  animation: _pulseScale,
                  builder: (context, child) {
                    return Transform.scale(
                      scale: _pulseScale.value,
                      child: Container(
                        width: 110,
                        height: 110,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: successColor.withValues(alpha: 0.25),
                            width: 2,
                          ),
                        ),
                      ),
                    );
                  },
                ),
                Container(
                  width: 88,
                  height: 88,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: successColor.withValues(alpha: 0.15),
                    boxShadow: [
                      BoxShadow(
                        color: successColor.withValues(alpha: 0.2),
                        blurRadius: 30,
                        spreadRadius: 5,
                      ),
                    ],
                  ),
                  child: Icon(
                    Icons.workspace_premium_rounded,
                    color: successColor,
                    size: 46,
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
