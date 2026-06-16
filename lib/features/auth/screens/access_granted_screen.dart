import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:reebaplus_pos/core/theme/semantic_colors.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/shared/widgets/main_layout.dart';
import 'package:reebaplus_pos/features/auth/widgets/auth_background.dart';

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
    final isDark = theme.brightness == Brightness.dark;
    final textColor = isDark ? Colors.white : Colors.black;
    final successColor =
        theme.extension<AppSemanticColors>()?.success ??
        const Color(0xFF30D158);

    return AuthBackground(
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
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 32,
                  ),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      minHeight: constraints.maxHeight - 64,
                    ),
                    child: IntrinsicHeight(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const Spacer(),

                          // ── Animated Success Icon ──
                          _buildSuccessIcon(successColor, textColor),
                          const SizedBox(height: 28),

                          // ── Welcome Header ──
                          SlideTransition(
                            position: _headerSlide,
                            child: FadeTransition(
                              opacity: _headerOpacity,
                              child: Column(
                                children: [
                                  Text(
                                    'Access Granted!',
                                    style: TextStyle(
                                      fontSize: 30,
                                      fontWeight: FontWeight.w800,
                                      color: textColor,
                                      letterSpacing: -0.5,
                                    ),
                                    textAlign: TextAlign.center,
                                  ),
                                  const SizedBox(height: 8),
                                  Text(
                                    'Welcome aboard, ${widget.user.name}',
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      fontSize: 15,
                                      color: textColor.withValues(alpha: 0.7),
                                      height: 1.4,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(height: 32),

                          // ── Accent Divider ──
                          SlideTransition(
                            position: _cardsSlide,
                            child: FadeTransition(
                              opacity: _cardsOpacity,
                              child: Container(
                                height: 2,
                                margin: const EdgeInsets.symmetric(
                                  horizontal: 40,
                                ),
                                decoration: BoxDecoration(
                                  gradient: LinearGradient(
                                    colors: [
                                      Colors.transparent,
                                      theme.colorScheme.primary.withValues(
                                        alpha: 0.6,
                                      ),
                                      Colors.transparent,
                                    ],
                                  ),
                                  borderRadius: BorderRadius.circular(1),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 28),

                          // ── Detail Cards ──
                          SlideTransition(
                            position: _cardsSlide,
                            child: FadeTransition(
                              opacity: _cardsOpacity,
                              child: Column(
                                children: [
                                  _buildDetailCard(
                                    context,
                                    icon: Icons.business_rounded,
                                    label: 'Business',
                                    value: details['businessName']!,
                                    textColor: textColor,
                                  ),
                                  const SizedBox(height: 12),
                                  _buildDetailCard(
                                    context,
                                    icon: Icons.location_on_rounded,
                                    label: 'Location',
                                    value: details['locationName']!,
                                    textColor: textColor,
                                  ),
                                ],
                              ),
                            ),
                          ),

                          const Spacer(),
                          const SizedBox(height: 28),

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
    );
  }

  /// Animated check-circle icon with pulsing glow ring.
  Widget _buildSuccessIcon(Color successColor, Color textColor) {
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
                // Pulsing glow ring
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
                // Main circle
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
                    Icons.check_rounded,
                    color: successColor,
                    size: 48,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Individual glassmorphism detail card.
  Widget _buildDetailCard(
    BuildContext context, {
    required IconData icon,
    required String label,
    required String value,
    required Color textColor,
  }) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: isDark
                ? Colors.white.withValues(alpha: 0.08)
                : Colors.black.withValues(alpha: 0.04),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: isDark
                  ? Colors.white.withValues(alpha: 0.15)
                  : Colors.black.withValues(alpha: 0.08),
            ),
          ),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary.withValues(alpha: 0.12),
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, color: theme.colorScheme.primary, size: 22),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                        color: textColor.withValues(alpha: 0.5),
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      value,
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w600,
                        color: textColor,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
