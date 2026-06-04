import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/utils/notifications.dart';
import 'package:reebaplus_pos/core/theme/app_decorations.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:reebaplus_pos/features/auth/screens/login_screen.dart';
import 'package:reebaplus_pos/features/auth/screens/otp_verification_screen.dart';
import 'package:reebaplus_pos/features/auth/screens/create_pin_screen.dart';
import 'package:reebaplus_pos/features/auth/screens/no_account_found_screen.dart';
import 'package:reebaplus_pos/features/auth/screens/existing_account_screen.dart';
import 'package:reebaplus_pos/shared/services/auth_service.dart';
import 'package:reebaplus_pos/features/auth/widgets/auth_form_kit.dart';
import 'package:reebaplus_pos/features/auth/widgets/branded_auth_background.dart';
import 'package:reebaplus_pos/core/database/app_database.dart' show UserData;
import 'package:reebaplus_pos/main.dart' show supabaseReady;

class EmailEntryScreen extends ConsumerStatefulWidget {
  /// When non-null, pre-fills the email field. If [lockedEmail] is also
  /// true, the field is rendered read-only — used by the invite-link path
  /// where the email must match the invite address (server-enforced via
  /// `email_mismatch` on redeem, but locking the input avoids typos).
  final String? prefilledEmail;
  final bool lockedEmail;

  const EmailEntryScreen({
    super.key,
    this.prefilledEmail,
    this.lockedEmail = false,
  });

  @override
  ConsumerState<EmailEntryScreen> createState() => _EmailEntryScreenState();
}

class _EmailEntryScreenState extends ConsumerState<EmailEntryScreen> {
  final _emailController = TextEditingController();
  bool _loading = false;
  bool _isEmailValid = false;

  @override
  void initState() {
    super.initState();
    if (widget.prefilledEmail != null && widget.prefilledEmail!.isNotEmpty) {
      _emailController.text = widget.prefilledEmail!;
    }
    _emailController.addListener(_validateEmail);
    _validateEmail();

    // One-shot snackbar after a remote-kick logout (another device signed
    // in and revoked this session). Read-and-clear so a later rebuild of
    // this screen doesn't show it again.
    final auth = ref.read(authProvider);
    if (auth.kickedByRemoteSignIn) {
      auth.kickedByRemoteSignIn = false;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        AppNotification.showInfo(
          context,
          "You've been signed in on another device — signed out.",
        );
      });
    }
  }

  void _validateEmail() {
    final email = _emailController.text.trim().toLowerCase();
    final isValid = email.contains('@') && email.contains('.');
    if (_isEmailValid != isValid) {
      setState(() => _isEmailValid = isValid);
    }
  }

  @override
  void dispose() {
    _emailController.removeListener(_validateEmail);
    _emailController.dispose();
    super.dispose();
  }

  Future<void> _signInWithGoogle() async {
    setState(() => _loading = true);
    final auth = ref.read(authProvider);

    // Ensure Supabase is ready before Google sign-in (it verifies via Supabase).
    try {
      await supabaseReady.timeout(const Duration(seconds: 10));
    } catch (_) {
      if (mounted) {
        setState(() => _loading = false);
        AppNotification.showError(
          context,
          'Network timeout. Please check your internet connection.',
        );
      }
      return;
    }

    final email = await auth.signInWithGoogle();
    if (!mounted) return;

    if (email == null) {
      setState(() => _loading = false);
      AppNotification.showError(context, 'Google sign-in cancelled or failed.');
      return;
    }

    // Save auth method as google
    await auth.saveAuthMethod('google');

    // Look up the cloud account (if any) and the local user. Mirrors the
    // post-OTP flow: on a fresh device with an existing cloud account, the
    // user confirms the business before we pull data and seed a local row.
    final account = await auth.fetchSupabaseAccount();
    var localUser = await auth.getUserByEmail(email);
    if (!mounted) return;

    if (account != null && localUser == null) {
      setState(() => _loading = false);
      Navigator.of(context).pushReplacement(
        PageRouteBuilder(
          pageBuilder: (_, __, ___) =>
              ExistingAccountScreen(email: email, account: account),
          transitionsBuilder: (_, animation, __, child) {
            final curve = CurvedAnimation(
              parent: animation,
              curve: Curves.easeInOutCubic,
            );
            return FadeTransition(opacity: curve, child: child);
          },
          transitionDuration: const Duration(milliseconds: 500),
        ),
      );
      return;
    }

    if (account != null && localUser != null) {
      // Returning device — sync silently and refresh the local row.
      await auth.syncOnLogin(account.businessId);
      await auth.upsertLocalUserFromProfile();
      localUser = await auth.getUserByEmail(email) ?? localUser;
      if (!mounted) return;
    }

    setState(() => _loading = false);

    if (localUser == null) {
      // Brand-new email (no cloud account, no local user) — master plan §7.1:
      // show "No account found" with the two real entry points. Google already
      // verified the email, so Create skips the in-flow email/OTP steps.
      Navigator.of(context).pushReplacement(
        PageRouteBuilder(
          pageBuilder: (_, __, ___) => NoAccountFoundScreen(email: email),
          transitionsBuilder: (_, animation, __, child) {
            final curve = CurvedAnimation(
              parent: animation,
              curve: Curves.easeInOutCubic,
            );
            return FadeTransition(opacity: curve, child: child);
          },
          transitionDuration: const Duration(milliseconds: 500),
        ),
      );
      return;
    }

    final user = localUser;
    final isSetupRequired = user.pin == AuthService.setupRequiredPin;
    final hasPin = user.pin.isNotEmpty && !isSetupRequired;

    await auth.saveDeviceUserId(user.id);
    await auth.saveLastLoggedInEmail(email);
    if (!mounted) return;

    if (hasPin) {
      Navigator.of(context).pushReplacement(
        PageRouteBuilder(
          pageBuilder: (_, __, ___) => const LoginScreen(),
          transitionsBuilder: (_, animation, __, child) {
            final curve = CurvedAnimation(
              parent: animation,
              curve: Curves.easeInOutCubic,
            );
            return FadeTransition(opacity: curve, child: child);
          },
          transitionDuration: const Duration(milliseconds: 500),
        ),
      );
    } else {
      Navigator.of(context).pushReplacement(
        PageRouteBuilder(
          pageBuilder: (_, __, ___) => CreatePinScreen(user: user),
          transitionsBuilder: (_, animation, __, child) {
            final curve = CurvedAnimation(
              parent: animation,
              curve: Curves.easeInOutCubic,
            );
            return FadeTransition(opacity: curve, child: child);
          },
          transitionDuration: const Duration(milliseconds: 500),
        ),
      );
    }
  }

  Future<void> _submit() async {
    final email = _emailController.text.trim().toLowerCase();

    if (!email.contains('@') || !email.contains('.')) {
      AppNotification.showError(context, 'Enter a valid email address.');
      return;
    }

    setState(() => _loading = true);

    if (!mounted) return;

    // Run DB lookup and OTP send in parallel.
    // supabaseReady is chained inside sendOtp only — getUserByEmail starts
    // immediately so we don't block the DB query on Supabase init.
    final auth = ref.read(authProvider);
    UserData? localUser;
    String? otpError;
    bool dbCheckDone = false;
    bool otpSent = false;
    try {
      debugPrint('[EmailEntry] Starting DB + Supabase parallel tasks...');
      await Future.wait([
        auth
            .getUserByEmail(email)
            .then((u) {
              debugPrint('[EmailEntry] Local user check done: ${u != null}');
              localUser = u;
              dbCheckDone = true;
            })
            .catchError((e) {
              debugPrint('[EmailEntry] Local user check error: $e');
            }),
        supabaseReady
            .then((_) {
              debugPrint('[EmailEntry] Supabase ready. Sending OTP...');
              return auth.sendOtp(email);
            })
            .then((e) {
              debugPrint('[EmailEntry] Send OTP result: ${e ?? "Success"}');
              otpError = e;
              otpSent = true;
            })
            .catchError((e) {
              debugPrint('[EmailEntry] Supabase/OTP error: $e');
            }),
      ]).timeout(const Duration(seconds: 30));
    } on TimeoutException {
      debugPrint(
        '[EmailEntry] Task timed out. DB: $dbCheckDone, OTP: $otpSent',
      );
      if (!dbCheckDone) {
        otpError = 'Database response delayed. Please restart the app.';
      } else {
        otpError =
            'OTP request is taking longer than expected. Please try again.';
      }
    } catch (e) {
      debugPrint('[EmailEntry] Submit error: $e');
      otpError = 'Something went wrong. Please try again.';
    } finally {
      if (mounted) setState(() => _loading = false);
    }

    if (!mounted) return;

    if (otpError != null) {
      AppNotification.showError(context, otpError!);
      return;
    }

    Navigator.of(context).push(
      PageRouteBuilder(
        pageBuilder: (context, animation, secondaryAnimation) =>
            OtpVerificationScreen(user: localUser, email: email),
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          return FadeTransition(opacity: animation, child: child);
        },
        transitionDuration: const Duration(milliseconds: 500),
      ),
    );
  }

  void _goToPinDirectly() {
    Navigator.of(context).pushReplacement(
      PageRouteBuilder(
        pageBuilder: (context, animation, secondaryAnimation) =>
            const LoginScreen(),
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          final curve = CurvedAnimation(
            parent: animation,
            curve: Curves.easeInOutCubic,
          );
          return FadeTransition(
            opacity: curve,
            child: ScaleTransition(
              scale: Tween<double>(begin: 0.96, end: 1.0).animate(curve),
              child: child,
            ),
          );
        },
        transitionDuration: const Duration(milliseconds: 500),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final textColor = authTextPrimary(context);

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      body: BrandedAuthBackground(
        child: SafeArea(
          child: AuthFormShell(
            title: 'Sign in',
            subtitle: 'Enter your email to continue.',
            children: [
              // Email card
              AuthInputCard(
                child: TextField(
                  controller: _emailController,
                  keyboardType: TextInputType.emailAddress,
                  autofocus: false,
                  readOnly: widget.lockedEmail,
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => _loading ? null : _submit(),
                  style: TextStyle(color: textColor),
                  decoration: AppDecorations.authInputDecoration(
                    context,
                    label: widget.lockedEmail
                        ? 'Email (from invite)'
                        : 'Email Address',
                    prefixIcon: Icons.email_outlined,
                  ),
                ),
              ),
              const SizedBox(height: 16),

              // Terms and Privacy Policy
              Center(
                child: RichText(
                  textAlign: TextAlign.center,
                  text: TextSpan(
                    style: TextStyle(
                      fontSize: 12,
                      color: textColor.withValues(alpha: 0.6),
                      height: 1.5,
                    ),
                    children: const [
                      TextSpan(text: 'By continuing, you agree to our\n'),
                      TextSpan(
                        text: 'Terms of Service',
                        style: TextStyle(
                          decoration: TextDecoration.underline,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      TextSpan(text: ' and '),
                      TextSpan(
                        text: 'Privacy Policy',
                        style: TextStyle(
                          decoration: TextDecoration.underline,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 24),

              AppButton(
                text: 'Send Code',
                isLoading: _loading,
                onPressed: (_loading || !_isEmailValid) ? null : _submit,
              ),
              const SizedBox(height: 16),

              // OR divider
              Row(
                children: [
                  Expanded(
                    child: Divider(
                      color: textColor.withValues(alpha: 0.2),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Text(
                      'OR',
                      style: TextStyle(
                        color: textColor.withValues(alpha: 0.5),
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  Expanded(
                    child: Divider(
                      color: textColor.withValues(alpha: 0.2),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),

              // Google Sign-In button
              Container(
                decoration: AppDecorations.glassCard(context),
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    onTap: _loading ? null : _signInWithGoogle,
                    borderRadius: BorderRadius.circular(12),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          FaIcon(
                            FontAwesomeIcons.google,
                            size: 20,
                            color: textColor.withValues(alpha: 0.8),
                          ),
                          const SizedBox(width: 12),
                          Text(
                            'Sign in with Google',
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                              color: textColor.withValues(alpha: 0.8),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 20),

              Center(
                child: TextButton(
                  onPressed: _goToPinDirectly,
                  child: Text(
                    'Already set up on this device? Login with PIN',
                    style: TextStyle(
                      color: textColor.withValues(alpha: 0.65),
                      fontSize: 13,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
