import 'package:flutter/material.dart';
import 'package:reebaplus_pos/core/theme/colors.dart';
import 'package:reebaplus_pos/features/auth/screens/ceo_sign_up_screen.dart';
import 'package:reebaplus_pos/features/auth/screens/coming_soon_screen.dart';
import 'package:reebaplus_pos/features/auth/screens/email_entry_screen.dart';
import 'package:reebaplus_pos/features/auth/screens/staff_sign_up_screen.dart';
import 'package:reebaplus_pos/features/auth/widgets/branded_auth_background.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:reebaplus_pos/shared/widgets/smooth_route.dart';

/// First screen on a fresh install and after a full logout (master plan §4).
/// Branded entry with three CTAs. The CTAs route to today's auth entry points;
/// the §5 CEO sign-up restructure will repoint "Create a new business" later.
class WelcomeScreen extends StatefulWidget {
  const WelcomeScreen({super.key});

  @override
  State<WelcomeScreen> createState() => _WelcomeScreenState();
}

class _WelcomeScreenState extends State<WelcomeScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _fade;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );
    _fade = CurvedAnimation(parent: _controller, curve: Curves.easeOut);
    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _push(Widget page) {
    Navigator.of(context).push(SmoothRoute(page: page));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: adBg,
      body: BrandedAuthBackground(
        child: SafeArea(
          child: FadeTransition(
            opacity: _fade,
            child: SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(0, 0.04),
                end: Offset.zero,
              ).animate(_fade),
              child: Center(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(28, 32, 28, 28),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const _WelcomeLogo(),
                      const SizedBox(height: 20),
                      const Text(
                        'Reebaplus',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 30,
                          fontWeight: FontWeight.w800,
                          color: adTextPrimary,
                          letterSpacing: 0.5,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        'Sales, stock, and staff — all in your pocket.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 15,
                          height: 1.4,
                          color: adTextPrimary.withValues(alpha: 0.65),
                        ),
                      ),
                      const SizedBox(height: 44),
                      AppButton(
                        text: 'Create a new business',
                        onPressed: () => _push(const CeoSignUpScreen()),
                      ),
                      const SizedBox(height: 14),
                      AppButton(
                        text: 'Join with invite code',
                        variant: AppButtonVariant.outline,
                        onPressed: () => _push(const StaffSignUpScreen()),
                      ),
                      const SizedBox(height: 22),
                      _SignInLink(onTap: () => _push(const EmailEntryScreen())),
                      const SizedBox(height: 36),
                      const _SmallPrint(),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SignInLink extends StatelessWidget {
  final VoidCallback onTap;
  const _SignInLink({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Text.rich(
        TextSpan(
          text: 'Already have an account? ',
          style: TextStyle(
            fontSize: 14,
            color: adTextPrimary.withValues(alpha: 0.65),
          ),
          children: const [
            TextSpan(
              text: 'Sign in',
              style: TextStyle(
                color: amberPrimary,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
        textAlign: TextAlign.center,
      ),
    );
  }
}

class _SmallPrint extends StatelessWidget {
  const _SmallPrint();

  void _openPlaceholder(BuildContext context, String title) {
    Navigator.of(context).push(
      SmoothRoute(
        page: ComingSoonScreen(
          title: title,
          message: '$title — coming soon.',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final baseStyle = TextStyle(
      fontSize: 12,
      height: 1.5,
      color: adTextPrimary.withValues(alpha: 0.45),
    );
    final linkStyle = baseStyle.copyWith(
      color: adTextPrimary.withValues(alpha: 0.7),
      decoration: TextDecoration.underline,
    );

    return DefaultTextStyle(
      style: baseStyle,
      textAlign: TextAlign.center,
      child: Wrap(
        alignment: WrapAlignment.center,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          const Text('By continuing, you agree to our '),
          GestureDetector(
            onTap: () => _openPlaceholder(context, 'Terms of Service'),
            child: Text('Terms of Service', style: linkStyle),
          ),
          const Text(' and '),
          GestureDetector(
            onTap: () => _openPlaceholder(context, 'Privacy Policy'),
            child: Text('Privacy Policy', style: linkStyle),
          ),
          const Text('.'),
        ],
      ),
    );
  }
}

/// Logo with the master-plan §4.1 fallback: a rounded square with "RP" in the
/// amber accent, shown only if the asset fails to load.
class _WelcomeLogo extends StatelessWidget {
  const _WelcomeLogo();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Image.asset(
        'assets/images/reebaplus_logo.png',
        height: 104,
        errorBuilder: (_, __, ___) => Container(
          width: 104,
          height: 104,
          decoration: BoxDecoration(
            color: amberPrimary.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: amberPrimary, width: 2),
          ),
          alignment: Alignment.center,
          child: const Text(
            'RP',
            style: TextStyle(
              fontSize: 40,
              fontWeight: FontWeight.w800,
              color: amberPrimary,
            ),
          ),
        ),
      ),
    );
  }
}

