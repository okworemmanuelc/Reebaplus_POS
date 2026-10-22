import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:reebaplus_pos/core/theme/app_decorations.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/theme/fixed_colors.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/icon_tile.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/shared/widgets/main_layout.dart';
import 'package:reebaplus_pos/features/auth/widgets/auth_form_kit.dart';
import 'package:reebaplus_pos/features/auth/widgets/branded_auth_background.dart';

class AccessGrantedScreen extends ConsumerStatefulWidget {
  final UserData user;

  const AccessGrantedScreen({super.key, required this.user});

  @override
  ConsumerState<AccessGrantedScreen> createState() =>
      _AccessGrantedScreenState();
}

class _AccessGrantedScreenState extends ConsumerState<AccessGrantedScreen>
    with TickerProviderStateMixin {
  late Future<Map<String, String>> _futureDetails;
  Timer? _contentTimer;

  // Animation controllers
  late final AnimationController _iconController;
  late final AnimationController _contentController;
  late final AnimationController _pulseController;

  // Icon animations
  late final Animation<double> _iconScale;
  late final Animation<double> _iconOpacity;

  // Content stagger animations
  late final Animation<double> _headerOpacity;
  late final Animation<Offset> _headerSlide;
  late final Animation<double> _cardsOpacity;
  late final Animation<Offset> _cardsSlide;
  late final Animation<double> _buttonOpacity;
  late final Animation<Offset> _buttonSlide;

  // Pulse glow
  late final Animation<double> _pulseScale;

  @override
  void initState() {
    super.initState();
    _futureDetails = _fetchDetails();

    // Icon entrance: scale + fade
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

    // Staggered content entrance
    _contentController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
    _headerOpacity = CurvedAnimation(
      parent: _contentController,
      curve: const Interval(0.0, 0.4, curve: Curves.easeOut),
    );
    _headerSlide = Tween<Offset>(begin: const Offset(0, 0.15), end: Offset.zero)
        .animate(
          CurvedAnimation(
            parent: _contentController,
            curve: const Interval(0.0, 0.4, curve: Curves.easeOut),
          ),
        );
    _cardsOpacity = CurvedAnimation(
      parent: _contentController,
      curve: const Interval(0.25, 0.65, curve: Curves.easeOut),
    );
    _cardsSlide = Tween<Offset>(begin: const Offset(0, 0.15), end: Offset.zero)
        .animate(
          CurvedAnimation(
            parent: _contentController,
            curve: const Interval(0.25, 0.65, curve: Curves.easeOut),
          ),
        );
    _buttonOpacity = CurvedAnimation(
      parent: _contentController,
      curve: const Interval(0.55, 1.0, curve: Curves.easeOut),
    );
    _buttonSlide = Tween<Offset>(begin: const Offset(0, 0.15), end: Offset.zero)
        .animate(
          CurvedAnimation(
            parent: _contentController,
            curve: const Interval(0.55, 1.0, curve: Curves.easeOut),
          ),
        );

    // Continuous pulsing glow ring
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2000),
    )..repeat(reverse: true);
    _pulseScale = Tween<double>(begin: 1.0, end: 1.15).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );

    // Kick off animations with stagger
    _iconController.forward();
    _contentTimer = Timer(const Duration(milliseconds: 350), () {
      if (mounted) _contentController.forward();
    });
  }

  @override
  void dispose() {
    _contentTimer?.cancel();
    _iconController.dispose();
    _contentController.dispose();
    _pulseController.dispose();
    super.dispose();
  }

  Future<Map<String, String>> _fetchDetails() async {
    final db = ref.read(databaseProvider);
    final res = {
      'businessName': '...',
      'locationName': '...',
      'inviterName': '...',
    };

    final biz = await (db.select(
      db.businesses,
    )..where((t) => t.id.equals(widget.user.businessId))).getSingleOrNull();
    if (biz != null) res['businessName'] = biz.name;

    final storeId = widget.user.storeId;
    if (storeId != null) {
      final wh = await (db.select(
        db.stores,
      )..where((t) => t.id.equals(storeId))).getSingleOrNull();
      if (wh != null) res['locationName'] = wh.name;
    }

    return res;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final f = theme.extension<AppFixedColors>() ?? AppFixedColors.light;
    final textColor = authTextPrimary(context);
    final successColor = f.green;

    return Scaffold(
      body: BrandedAuthBackground(
        child: FutureBuilder<Map<String, String>>(
          future: _futureDetails,
          builder: (context, snapshot) {
            final details =
                snapshot.data ??
                {
                  'businessName': '...',
                  'locationName': '...',
                  'inviterName': '...',
                };

            return SafeArea(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  return SingleChildScrollView(
                    padding: EdgeInsets.symmetric(
                      horizontal: context.getRSize(24),
                      vertical: context.getRSize(32),
                    ),
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        minHeight: constraints.maxHeight - context.getRSize(64),
                      ),
                      child: IntrinsicHeight(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            const Spacer(),

                            // ── Animated Success Icon ──
                            _buildSuccessIcon(successColor, textColor),
                            SizedBox(height: context.getRSize(28)),

                            // ── Welcome Header ──
                            SlideTransition(
                              position: _headerSlide,
                              child: FadeTransition(
                                opacity: _headerOpacity,
                                child: Column(
                                  children: [
                                    Text(
                                      'Access Granted!',
                                      style: context
                                          .extraBoldStyle(30)
                                          .copyWith(
                                            color: textColor,
                                            letterSpacing: -0.5,
                                          ),
                                      textAlign: TextAlign.center,
                                    ),
                                    SizedBox(height: context.getRSize(8)),
                                    Text(
                                      'Welcome aboard, ${widget.user.name}',
                                      textAlign: TextAlign.center,
                                      style: authSubtitleStyle(context),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            SizedBox(height: context.getRSize(32)),

                            // ── Accent Divider ──
                            SlideTransition(
                              position: _cardsSlide,
                              child: FadeTransition(
                                opacity: _cardsOpacity,
                                child: Container(
                                  height: context.getRSize(2),
                                  margin: EdgeInsets.symmetric(
                                    horizontal: context.getRSize(40),
                                  ),
                                  decoration: BoxDecoration(
                                    gradient: LinearGradient(
                                      colors: [
                                        theme.colorScheme.primary.withValues(
                                          alpha: 0,
                                        ),
                                        theme.colorScheme.primary.withValues(
                                          alpha: 0.6,
                                        ),
                                        theme.colorScheme.primary.withValues(
                                          alpha: 0,
                                        ),
                                      ],
                                    ),
                                    borderRadius: BorderRadius.circular(1),
                                  ),
                                ),
                              ),
                            ),
                            SizedBox(height: context.getRSize(28)),

                            // ── Detail Cards ──
                            SlideTransition(
                              position: _cardsSlide,
                              child: FadeTransition(
                                opacity: _cardsOpacity,
                                child: Column(
                                  children: [
                                    _buildDetailCard(
                                      context,
                                      icon: AppIcons.business,
                                      label: 'Business',
                                      value: details['businessName']!,
                                      textColor: textColor,
                                    ),
                                    SizedBox(height: context.getRSize(12)),
                                    _buildDetailCard(
                                      context,
                                      icon: AppIcons.location,
                                      label: 'Location',
                                      value: details['locationName']!,
                                      textColor: textColor,
                                    ),
                                  ],
                                ),
                              ),
                            ),

                            const Spacer(),
                            SizedBox(height: context.getRSize(28)),

                            // ── Enter App Button ──
                            SlideTransition(
                              position: _buttonSlide,
                              child: FadeTransition(
                                opacity: _buttonOpacity,
                                child: AppButton(
                                  text: 'Enter App',
                                  onPressed: () {
                                    Navigator.of(context).pushAndRemoveUntil(
                                      MaterialPageRoute(
                                        builder: (_) => const MainLayout(),
                                      ),
                                      (route) => false,
                                    );
                                  },
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            );
          },
        ),
      ),
    );
  }

  /// Animated check-circle icon with pulsing ring.
  Widget _buildSuccessIcon(Color successColor, Color textColor) {
    final f =
        Theme.of(context).extension<AppFixedColors>() ?? AppFixedColors.light;
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
                // Pulsing ring
                AnimatedBuilder(
                  animation: _pulseScale,
                  builder: (context, child) {
                    return Transform.scale(
                      scale: _pulseScale.value,
                      child: Container(
                        width: context.getRSize(110),
                        height: context.getRSize(110),
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
                // Main circle
                Container(
                  width: context.getRSize(88),
                  height: context.getRSize(88),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: f.greenTint,
                  ),
                  child: Icon(
                    AppIcons.check,
                    color: successColor,
                    size: context.getRSize(48),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Individual detail card.
  Widget _buildDetailCard(
    BuildContext context, {
    required IconData icon,
    required String label,
    required String value,
    required Color textColor,
  }) {
    return Container(
      padding: EdgeInsets.all(context.getRSize(16)),
      decoration: AppDecorations.card(context),
      child: Row(
        children: [
          IconTile(icon: icon, size: 44),
          SizedBox(width: context.getRSize(16)),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: context
                      .mediumStyle(12)
                      .copyWith(color: authTextMuted(context, 0.6)),
                ),
                SizedBox(height: context.getRSize(2)),
                Text(
                  value,
                  style: context.semiBoldStyle(17).copyWith(color: textColor),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
