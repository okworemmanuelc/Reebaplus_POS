import 'package:flutter/material.dart';
import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:reebaplus_pos/core/theme/app_decorations.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/redesign.dart';

import 'package:reebaplus_pos/features/auth/screens/ceo_sign_up_screen.dart';
import 'package:reebaplus_pos/features/auth/screens/staff_sign_up_screen.dart';
import 'package:reebaplus_pos/features/auth/widgets/auth_form_kit.dart';
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
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      body: BrandedAuthBackground(
        child: SafeArea(
          child: Stack(
            children: [
              Align(
                alignment: Alignment.topLeft,
                child: IconButton(
                  icon: Icon(
                    AppIcons.arrowBackIos,
                    color: authTextPrimary(context),
                    size: 20,
                  ),
                  onPressed: () => Navigator.of(context).maybePop(),
                ),
              ),
              AuthCenteredScroll(
                children: [
                  const Center(
                    child: IconTile(
                      icon: AppIcons.personSearch,
                      tone: IconTileTone.info,
                      size: 80,
                    ),
                  ),
                  SizedBox(height: context.getRSize(24)),
                  Text(
                    'No account found',
                    textAlign: TextAlign.center,
                    style: context
                        .extraBoldStyle(26)
                        .copyWith(color: authTextPrimary(context)),
                  ),
                  SizedBox(height: context.getRSize(10)),
                  Text(
                    'We couldn\'t find an account for $email. '
                    'Create a new business or join an existing one with an '
                    'invite code.',
                    textAlign: TextAlign.center,
                    style: context
                        .regularStyle(15)
                        .copyWith(height: 1.45, color: authTextMuted(context)),
                  ),
                  SizedBox(height: context.getRSize(32)),
                  AppButton(
                    text: 'Create a new business',
                    onPressed: () => Navigator.of(context).pushReplacement(
                      SmoothRoute(page: CeoSignUpScreen(verifiedEmail: email)),
                    ),
                  ),
                  SizedBox(height: context.getRSize(12)),
                  AppButton(
                    text: 'Join with invite code',
                    variant: AppButtonVariant.outline,
                    onPressed: () => Navigator.of(
                      context,
                    ).push(SmoothRoute(page: const StaffSignUpScreen())),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
