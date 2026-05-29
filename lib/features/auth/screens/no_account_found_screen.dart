import 'package:flutter/material.dart';

import 'package:reebaplus_pos/core/theme/colors.dart';
import 'package:reebaplus_pos/features/auth/screens/ceo_sign_up_screen.dart';
import 'package:reebaplus_pos/features/auth/screens/staff_sign_up_screen.dart';
import 'package:reebaplus_pos/features/auth/widgets/branded_auth_background.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:reebaplus_pos/shared/widgets/smooth_route.dart';

/// Shown after OTP verification (master plan §7.1) when the email has no
/// Supabase account and no local user — i.e. a brand-new email that signed in
/// through the Login flow. Rather than silently dropping the user into CEO
/// sign-up, we offer the two real entry points.
///
/// The email has already been verified (the Supabase session exists from the
/// preceding OTP), so "Create a new business" hands it to [CeoSignUpScreen]
/// with `verifiedEmail` set, which skips the email + OTP steps.
class NoAccountFoundScreen extends StatelessWidget {
  final String email;

  const NoAccountFoundScreen({super.key, required this.email});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: adBg,
      body: BrandedAuthBackground(
        child: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(28, 24, 28, 28),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Align(
                  alignment: Alignment.centerLeft,
                  child: IconButton(
                    icon: const Icon(Icons.arrow_back_ios,
                        color: adTextPrimary, size: 20),
                    onPressed: () => Navigator.of(context).maybePop(),
                  ),
                ),
                const SizedBox(height: 24),
                Center(
                  child: Container(
                    padding: const EdgeInsets.all(22),
                    decoration: BoxDecoration(
                      color: amberPrimary.withValues(alpha: 0.12),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.person_search_outlined,
                        color: amberPrimary, size: 56),
                  ),
                ),
                const SizedBox(height: 28),
                const Text(
                  'No account found',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 26,
                    fontWeight: FontWeight.w800,
                    color: adTextPrimary,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  'We couldn\'t find an account for $email. '
                  'Create a new business or join an existing one with an '
                  'invite code.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 15,
                    height: 1.45,
                    color: adTextPrimary.withValues(alpha: 0.65),
                  ),
                ),
                const SizedBox(height: 36),
                AppButton(
                  text: 'Create a new business',
                  onPressed: () => Navigator.of(context).pushReplacement(
                    SmoothRoute(page: CeoSignUpScreen(verifiedEmail: email)),
                  ),
                ),
                const SizedBox(height: 14),
                AppButton(
                  text: 'Join with invite code',
                  variant: AppButtonVariant.outline,
                  onPressed: () => Navigator.of(context).push(
                    SmoothRoute(page: const StaffSignUpScreen()),
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
