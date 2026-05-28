import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/shared/services/auth_service.dart';
import 'package:reebaplus_pos/core/utils/notifications.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:reebaplus_pos/features/auth/screens/create_pin_screen.dart';
import 'package:reebaplus_pos/features/auth/screens/existing_account_screen.dart';
import 'package:reebaplus_pos/features/auth/screens/login_screen.dart';
import 'package:reebaplus_pos/features/auth/screens/ceo_sign_up_screen.dart';
import 'package:reebaplus_pos/shared/widgets/smooth_route.dart';
import 'package:reebaplus_pos/features/auth/widgets/auth_background.dart';
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

    // Mark this session as email-authenticated (triggers second OTP after PIN).
    await auth.saveAuthMethod('email');

    // Look up the cloud account (if any) and the local user. On a fresh
    // device with an existing cloud account, we let the user confirm the
    // business before pulling data and seeding a local row.
    final account = await auth.fetchSupabaseAccount();
    var localUser = await auth.getUserByEmail(widget.email);

    if (!mounted) return;

    if (account != null && localUser == null) {
      Navigator.of(context).pushReplacement(
        SmoothRoute(page: ExistingAccountScreen(email: widget.email, account: account)),
      );
      return;
    }

    if (account != null && localUser != null) {
      // Returning device — sync silently and refresh the local row.
      await auth.syncOnLogin(account.businessId);
      await auth.upsertLocalUserFromProfile();
      localUser = await auth.getUserByEmail(widget.email) ?? localUser;
      if (!mounted) return;
    }

    // OTP verified — route based on whether the user exists locally.
    if (localUser == null) {
      // New email → the §5 CEO Sign Up flow (it re-collects email/OTP; the
      // old multi-screen flow was retired). §7.1 "no account found" handling
      // arrives with the login restructure (PIVOT_PLAN step 6).
      Navigator.of(context).pushReplacement(
        SmoothRoute(page: const CeoSignUpScreen()),
      );
    } else {
      final user = localUser;
      // A row seeded from the cloud profile has the sentinel PIN — the user
      // needs to set up a PIN on this device before they can sign in.
      final isSetupRequired = user.pin == AuthService.setupRequiredPin;
      final hasPin = user.pin.isNotEmpty && !isSetupRequired;
      if (hasPin && !widget.isPinReset) {
        // Existing user on a new device → enter their existing PIN.
        Navigator.of(context).pushReplacement(
          SmoothRoute(page: const LoginScreen()),
        );
      } else {
        // New staff OR resetting PIN — create their PIN for the first time.
        Navigator.of(context).pushReplacement(
          SmoothRoute(page: CreatePinScreen(user: user)),
        );
      }
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
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final textColor = isDark ? Colors.white : Colors.black;

    return AuthBackground(
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(28, 40, 28, 40),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Back button
              Align(
                alignment: Alignment.centerLeft,
                child: IconButton(
                  icon: Icon(Icons.arrow_back_ios, color: textColor, size: 20),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ),
              const SizedBox(height: 16),

              // Logo
              Center(
                child: Image.asset(
                  'assets/images/reebaplus_logo.png',
                  height: 72,
                  color: isDark ? null : theme.colorScheme.primary,
                  errorBuilder: (_, __, ___) =>
                      Icon(Icons.storefront, size: 72, color: textColor),
                ),
              ),
              const SizedBox(height: 20),

              Center(
                child: Text(
                  'Check your email',
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                    color: textColor,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Center(
                child: Text(
                  'Enter the 6-digit code sent to\n${_maskEmail(widget.email)}',
                  style: TextStyle(
                    fontSize: 13,
                    color: textColor.withValues(alpha: 0.7),
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
              const SizedBox(height: 36),

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
                  'Code expires in 10 minutes',
                  style: TextStyle(
                    color: textColor.withValues(alpha: 0.5),
                    fontSize: 13,
                  ),
                ),
              ),
              const SizedBox(height: 12),

              // Error message
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 200),
                child: _errorMessage != null
                    ? Padding(
                        key: const ValueKey('err'),
                        padding: const EdgeInsets.only(bottom: 4),
                        child: Text(
                          _errorMessage!,
                          style: TextStyle(
                            color: theme.colorScheme.error,
                            fontSize: 13,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      )
                    : const SizedBox(key: ValueKey('no-err'), height: 18),
              ),
              const SizedBox(height: 16),

              AnimatedSwitcher(
                duration: const Duration(milliseconds: 350),
                switchInCurve: Curves.easeOut,
                child: _verified
                    ? const AppButton(
                        key: ValueKey('verified'),
                        text: 'Verified  ✓',
                        variant: AppButtonVariant.success,
                        onPressed: null,
                      )
                    : AppButton(
                        key: const ValueKey('verify'),
                        text: 'Verify',
                        isLoading: _loading,
                        onPressed: _canSubmit ? _submit : null,
                      ),
              ),
              const SizedBox(height: 20),

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
                        onPressed: (_loading || _isLockedOut) ? null : _resend,
                        child: Text(
                          'Resend code',
                          style: TextStyle(
                            color: textColor.withValues(alpha: 0.75),
                            fontSize: 13,
                          ),
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

// ShakeWidget and OtpBoxRow extracted to:
//   lib/features/auth/widgets/shake_widget.dart
//   lib/features/auth/widgets/otp_input.dart
