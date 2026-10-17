import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/theme/app_decorations.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/theme/fixed_colors.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/features/subscription/widgets/subscription_parts.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/redesign.dart';
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
    final fixed = theme.extension<AppFixedColors>() ?? AppFixedColors.light;

    final periodEnd = widget.business.currentPeriodEnd;
    final renewsLine = periodEnd == null
        ? null
        : 'Renews ${DateFormat('d MMM yyyy').format(periodEnd)}';

    return SubscriptionStateFrame(
      hero: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildIcon(fixed),
          SizedBox(height: context.getRSize(28)),
          SlideTransition(
            position: _contentSlide,
            child: FadeTransition(
              opacity: _contentOpacity,
              child: Column(
                children: [
                  Text(
                    'Thank you for subscribing!',
                    textAlign: TextAlign.center,
                    style: context
                        .extraBoldStyle(28)
                        .copyWith(color: theme.colorScheme.onSurface),
                  ),
                  SizedBox(height: context.getRSize(10)),
                  Text(
                    '${widget.business.name} is now on the '
                    'Reebaplus monthly plan. Every feature is '
                    'unlocked — thank you for going PRO.',
                    textAlign: TextAlign.center,
                    style: context
                        .regularStyle(15)
                        .copyWith(
                          height: 1.45,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                  ),
                  SizedBox(height: context.getRSize(24)),
                  _planCard(theme, renewsLine),
                ],
              ),
            ),
          ),
        ],
      ),
      actions: FadeTransition(
        opacity: _contentOpacity,
        child: AppButton(
          text: 'Continue',
          isLoading: _continuing,
          onPressed: _onContinue,
        ),
      ),
    );
  }

  Widget _planCard(ThemeData theme, String? renewsLine) {
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: context.getRSize(16),
        vertical: context.getRSize(12),
      ),
      decoration: AppDecorations.card(context),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            _priceLine,
            textAlign: TextAlign.center,
            style: context
                .boldStyle(16)
                .copyWith(color: theme.colorScheme.onSurface),
          ),
          if (renewsLine != null) ...[
            SizedBox(height: context.getRSize(2)),
            Text(
              renewsLine,
              textAlign: TextAlign.center,
              style: context
                  .regularStyle(13)
                  .copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildIcon(AppFixedColors fixed) {
    final ring = context.getRSize(110);
    return Center(
      child: FadeTransition(
        opacity: _iconOpacity,
        child: ScaleTransition(
          scale: _iconScale,
          child: SizedBox(
            width: context.getRSize(120),
            height: context.getRSize(120),
            child: Stack(
              alignment: Alignment.center,
              children: [
                AnimatedBuilder(
                  animation: _pulseScale,
                  builder: (context, child) {
                    return Transform.scale(
                      scale: _pulseScale.value,
                      child: Container(
                        width: ring,
                        height: ring,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: fixed.green.withValues(alpha: 0.25),
                            width: 2,
                          ),
                        ),
                      ),
                    );
                  },
                ),
                IconTile(
                  icon: AppIcons.premium,
                  tone: IconTileTone.green,
                  size: 88,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
