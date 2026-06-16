import 'dart:async';
import 'package:flutter/material.dart';
import 'package:reebaplus_pos/core/theme/app_decorations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/features/auth/auth_post_verify_route.dart';
import 'package:reebaplus_pos/core/utils/notifications.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:reebaplus_pos/features/auth/screens/create_pin_screen.dart';
import 'package:reebaplus_pos/features/auth/screens/existing_account_screen.dart';
import 'package:reebaplus_pos/features/auth/screens/login_screen.dart';
import 'package:reebaplus_pos/features/auth/screens/no_account_found_screen.dart';
import 'package:reebaplus_pos/shared/widgets/smooth_route.dart';
import 'package:reebaplus_pos/features/auth/widgets/auth_form_kit.dart';
import 'package:reebaplus_pos/features/auth/widgets/branded_auth_background.dart';
import 'package:reebaplus_pos/features/auth/widgets/shake_widget.dart';
import 'package:reebaplus_pos/features/auth/widgets/otp_input.dart';

class OtpVerificationScreen extends ConsumerStatefulWidget {
  final UserData? user;
  final String email;
  final bool isPinReset;

  const OtpVerificationScreen({
    super.key,
    required this.user,
    required this.email,
    this.isPinReset = false,
  });

  @override
  ConsumerState<OtpVerificationScreen> createState() =>
      _OtpVerificationScreenState();
}

class _OtpVerificationScreenState extends ConsumerState<OtpVerificationScreen> {
  final _otpController = TextEditingController();
  final GlobalKey<ShakeWidgetState> _shakeKey = GlobalKey();

  bool _loading = false;
  bool _verified = false;
  String? _errorMessage;

  // Resend cooldown: 60 seconds after each send
  int _resendCountdown = 60;
  Timer? _resendTimer;

  int _resendAttempts = 0;
  int _failedAttempts = 0;
  DateTime? _lockoutEndTime;
  bool _isLockedOut = false;
  Timer? _lockoutTimer;

  @override
  void initState() {
    super.initState();
    _checkLockoutStatus();
    _otpController.addListener(() {
      if (_errorMessage != null) {
        setState(() => _errorMessage = null);
      }
      if (_otpController.text.trim().length == 6 &&
          !_loading &&
          !_isLockedOut) {
        _submit();
      }
    });
    _startResendTimer();
  }

  void _startResendTimer() {
    _resendCountdown = 60;
    _resendTimer?.cancel();
    _resendTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      setState(() {
        if (_resendCountdown > 0) {
          _resendCountdown--;
        } else {
          t.cancel();
        }
      });
    });
  }

  Future<void> _checkLockoutStatus() async {
    final prefs = await SharedPreferences.getInstance();
    final lockoutTimeString = prefs.getString('otp_lockout_until');

    if (lockoutTimeString != null) {
      final lockoutTime = DateTime.parse(lockoutTimeString);
      if (DateTime.now().isBefore(lockoutTime)) {
        setState(() {
          _lockoutEndTime = lockoutTime;
          _isLockedOut = true;
          _errorMessage = 'Too many failed attempts. Try again later.';
        });
        _startLockoutTimer();
      } else {
        prefs.remove('otp_lockout_until');
      }
    }
  }

  void _startLockoutTimer() {
    _lockoutTimer?.cancel();
    _lockoutTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      if (_lockoutEndTime != null && DateTime.now().isAfter(_lockoutEndTime!)) {
        setState(() {
          _isLockedOut = false;
          _failedAttempts = 0;
          _errorMessage = null;
        });
        t.cancel();
      } else {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _otpController.dispose();
    _resendTimer?.cancel();
    _lockoutTimer?.cancel();
    super.dispose();
  }

  bool get _canSubmit =>
      _otpController.text.trim().length == 6 && !_loading && !_isLockedOut;

  Future<void> _submit() async {
    final otp = _otpController.text.trim();
    setState(() {
      _loading = true;
      _errorMessage = null;
    });

    // Capture provider up front — `ref` is invalidated the moment this widget's
    // element is unmounted (BEFORE State.mounted flips), and this method
    // crosses several `await`s that race that window. See plan §"Bug fix"
    // Pattern 1.
    final auth = ref.read(authProvider);

    final error = await auth.verifyOtp(widget.email, otp);

    if (!mounted) return;

    if (error != null) {
      _failedAttempts++;
      if (_failedAttempts >= 5) {
        final prefs = await SharedPreferences.getInstance();
        final lockoutTime = DateTime.now().add(const Duration(minutes: 30));
        await prefs.setString(
          'otp_lockout_until',
          lockoutTime.toIso8601String(),
        );

        setState(() {
          _loading = false;
          _isLockedOut = true;
          _lockoutEndTime = lockoutTime;
          _errorMessage = 'Too many failed attempts. Locked for 30 minutes.';
          _otpController.clear();
        });
        _startLockoutTimer();
      } else {
        setState(() {
          _loading = false;
          _errorMessage = 'Invalid code. Please try again.';
          _otpController.clear();
        });
        _shakeKey.currentState?.shake();
      }
      return;
    }

    setState(() {
      _loading = false;
      _verified = true;
    });

    // Brief pause to show success state before navigating.
    await Future.delayed(const Duration(milliseconds: 800));
    if (!mounted) return;

    try {
      // Mark this session as email-authenticated (triggers second OTP after PIN).
      await auth.saveAuthMethod('email');

      // Resolve where to go now the email is verified. Shared with the Google
      // sign-in handler (auth_post_verify_route.dart) so the §7.2a account-scoping
      // and shared-till PIN rules live in one place and can't drift between the
      // two entry points. LoginRoute passes the OTP-authenticated user as
      // presetUser so the PIN screen binds THIS identity, not the last device
      // user (the wrong-user-PIN bug on a shared till).
      final route = await resolvePostVerifyRoute(
        auth,
        widget.email,
        isPinReset: widget.isPinReset,
      );
      if (!mounted) return;

      Navigator.of(context).pushReplacement(
        SmoothRoute(
          page: switch (route) {
            ExistingAccountRoute(:final account) => ExistingAccountScreen(
              email: widget.email,
              account: account,
            ),
            NoAccountFoundRoute() => NoAccountFoundScreen(email: widget.email),
            LoginRoute(:final user) => LoginScreen(presetUser: user),
            CreatePinRoute(:final user) => CreatePinScreen(user: user),
          },
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _verified = false;
        _otpController.clear();
      });
      AppNotification.showError(
        context,
        'Verified, but we could not load your account. Check your connection and try again.',
      );
    }
  }

  Future<void> _resend() async {
    if (_resendAttempts >= 3) {
      AppNotification.showError(
        context,
        'Maximum resend attempts reached. Please restart.',
      );
      Navigator.of(context).pop();
      return;
    }

    setState(() => _loading = true);
    final error = await ref.read(authProvider).sendOtp(widget.email);
    if (!mounted) return;
    setState(() => _loading = false);
    if (error != null) {
      AppNotification.showError(context, error);
    } else {
      _resendAttempts++;
      AppNotification.showSuccess(context, 'New code sent to ${widget.email}');
      _startResendTimer();
    }
  }

  String _maskEmail(String email) {
    if (!email.contains('@')) return email;
    final parts = email.split('@');
    final name = parts[0];
    final domain = parts[1];

    if (name.length <= 2) {
      return '${name.substring(0, 1)}**@$domain';
    }
    return '${name.substring(0, 2)}**@$domain';
  }

  @override
  Widget build(BuildContext context) {
    final textColor = authTextPrimary(context);

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      body: BrandedAuthBackground(
        child: SafeArea(
          child: Stack(
            children: [
              // Back button — pinned top-left so the content can centre.
              Align(
                alignment: Alignment.topLeft,
                child: IconButton(
                  icon: Icon(Icons.arrow_back_ios, color: textColor, size: 20),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ),
              AuthCenteredScroll(
                children: [
                  Text('Check your email', style: authTitleStyle(context)),
                  const SizedBox(height: 8),
                  Text(
                    'Enter the 6-digit code sent to\n${_maskEmail(widget.email)}',
                    style: authSubtitleStyle(context),
                  ),
                  const SizedBox(height: 28),

                  // OTP input — single invisible field driving 6 styled boxes
                  ShakeWidget(
                    key: _shakeKey,
                    child: OtpBoxRow(
                      controller: _otpController,
                      hasError: _errorMessage != null,
                      onSubmit: _canSubmit ? _submit : null,
                      ignorePointers: _isLockedOut,
                      readOnly: _loading,
                      textColor: textColor,
                    ),
                  ),
                  const SizedBox(height: 12),

                  Center(
                    child: Text(
                      'Code expires in 5 minutes',
                      style: TextStyle(
                        color: textColor.withValues(alpha: 0.5),
                        fontSize: 13,
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Center(child: AuthErrorText(_errorMessage)),
                  const SizedBox(height: 8),

                  if (_verified)
                    const AppButton(
                      text: 'Verified  ✓',
                      variant: AppButtonVariant.success,
                      onPressed: null,
                    )
                  else
                    AppButton(
                      text: 'Verify',
                      isLoading: _loading,
                      onPressed: _canSubmit ? _submit : null,
                    ),
                  const SizedBox(height: 16),

                  // Resend button with countdown
                  Center(
                    child: _resendCountdown > 0
                        ? Text(
                            'Resend code in 0:${_resendCountdown.toString().padLeft(2, '0')}',
                            style: TextStyle(
                              color: textColor.withValues(alpha: 0.5),
                              fontSize: 13,
                            ),
                          )
                        : TextButton(
                            onPressed: (_loading || _isLockedOut)
                                ? null
                                : _resend,
                            child: const Text('Resend code'),
                          ),
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

// ShakeWidget and OtpBoxRow extracted to:
//   lib/features/auth/widgets/shake_widget.dart
//   lib/features/auth/widgets/otp_input.dart
