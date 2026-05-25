import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';

import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/core/utils/notifications.dart';
import 'package:reebaplus_pos/features/auth/screens/email_entry_screen.dart';
import 'package:reebaplus_pos/features/auth/screens/otp_verification_screen.dart';
import 'dart:async';
import 'package:local_auth/local_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:reebaplus_pos/features/auth/widgets/auth_background.dart';
import 'package:reebaplus_pos/shared/services/auth_service.dart';

import 'package:reebaplus_pos/core/theme/app_decorations.dart';

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen>
    with SingleTickerProviderStateMixin {
  bool _checking = false;
  final ValueNotifier<String> _pinNotifier = ValueNotifier<String>('');
  bool _biometricsAvailable = false;
  final TextEditingController _emailController = TextEditingController();

  // ── Returning User & Lockout State ──────────────────────────────────────────
  UserData? _identifiedUser;
  int _failedAttempts = 0;
  DateTime? _lockoutUntil;
  Timer? _lockoutTimer;
  String? _pinWarning;

  // ── Success animation state ────────────────────────────────────────────────
  bool _loginSuccess = false;
  UserData? _loggedInUser;
  late final AnimationController _checkAnim;
  late final Animation<double> _checkScale;
  late final Animation<double> _checkFade;

  @override
  void initState() {
    super.initState();
    _checkAnim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 350),
    );
    // Scale goes from 0 → 1 with a bouncy feel
    _checkScale = CurvedAnimation(parent: _checkAnim, curve: Curves.elasticOut);
    // Fade goes from 0 → 1 in the first half of the animation
    _checkFade = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(
        parent: _checkAnim,
        curve: const Interval(0.0, 0.5, curve: Curves.easeIn),
      ),
    );

    _initUserAndLockoutState();
  }

  Future<void> _initUserAndLockoutState() async {
    final prefs = await SharedPreferences.getInstance();

    // Check lockout
    final lockoutMs = prefs.getInt('pin_lockout_until');
    if (lockoutMs != null) {
      final lockoutTime = DateTime.fromMillisecondsSinceEpoch(lockoutMs);
      if (lockoutTime.isAfter(DateTime.now())) {
        setState(() => _lockoutUntil = lockoutTime);
        _startLockoutTimer();
      } else {
        await prefs.remove('pin_lockout_until');
      }
    }

    // Identify user
    final auth = ref.read(authProvider);
    final db = ref.read(databaseProvider);
    final userId = await auth.getDeviceUserId();
    if (userId != null) {
      final user = await db.warehousesDao.getUserById(userId);
      if (mounted && user != null) {
        setState(() {
          _identifiedUser = user;
          if (user.email != null) _emailController.text = user.email!;
        });
      }
    }

    // Try prefilling email if _identifiedUser is null
    if (_emailController.text.isEmpty) {
      final lastEmail = await auth.getLastLoggedInEmail();
      if (mounted && lastEmail != null) {
        setState(() => _emailController.text = lastEmail);
      }
    }

    _checkBiometricAvailability();
  }

  void _startLockoutTimer() {
    _lockoutTimer?.cancel();
    _lockoutTimer = Timer.periodic(const Duration(seconds: 1), (timer) async {
      if (!mounted) {
        timer.cancel();
        return;
      }
      if (_lockoutUntil != null && DateTime.now().isAfter(_lockoutUntil!)) {
        timer.cancel();
        final prefs = await SharedPreferences.getInstance();
        await prefs.remove('pin_lockout_until');
        setState(() {
          _lockoutUntil = null;
          _failedAttempts = 0;
          _pinWarning = null;
        });
      } else {
        setState(() {}); // trigger rebuild for countdown
      }
    });
  }

  /// Checks whether the device supports biometrics and updates [_biometricsAvailable].
  /// Never shows a dialog — purely a capability check.
  Future<void> _checkBiometricAvailability() async {
    try {
      final auth = LocalAuthentication();
      final available =
          await auth.canCheckBiometrics || await auth.isDeviceSupported();
      final prefs = await SharedPreferences.getInstance();

      // One-time migration: old onboarding key → unified key
      final oldKey = prefs.getBool('use_biometrics');
      if (oldKey != null && !prefs.containsKey('biometrics_enabled')) {
        await prefs.setBool('biometrics_enabled', oldKey);
      }

      final isEnabled = prefs.getBool('biometrics_enabled') ?? false;
      if (mounted) {
        setState(() => _biometricsAvailable = available && isEnabled);
      }
    } catch (_) {}
  }

  /// Called when the user explicitly taps "Sign in with Biometrics".
  Future<void> _triggerBiometrics() async {
    final auth = LocalAuthentication();
    try {
      // Check if any biometrics are enrolled on the device
      final enrolled = await auth.getAvailableBiometrics();
      if (enrolled.isEmpty) {
        if (mounted) {
          AppNotification.showError(
            context,
            'No biometrics enrolled. Please set up fingerprint or Face ID in your device settings.',
          );
        }
        return;
      }

      final authenticated = await auth.authenticate(
        localizedReason: 'Please authenticate to log in',
        options: const AuthenticationOptions(
          stickyAuth: false,
          biometricOnly: false,
        ),
      );
      if (!mounted) return;
      if (authenticated) {
        final userId = await ref.read(authProvider).getDeviceUserId();
        if (userId != null) {
          final user = await ref
              .read(databaseProvider)
              .warehousesDao
              .getUserById(userId);
          if (user != null) {
            _enterApp(user);
            return;
          }
        }
        // If we reach here, biometrics worked but no user is registered on this device
        if (mounted) {
          AppNotification.showError(
            context,
            'Biometrics authenticated, but no user is registered on this device. Please log in with your PIN first.',
          );
        }
      } else {
        // User cancelled or biometric not recognised — show a hint
        AppNotification.showError(
          context,
          'Biometric not recognised. Please try again or use your PIN.',
        );
      }
    } on PlatformException catch (e) {
      if (!mounted) return;
      final message = switch (e.code) {
        'NotEnrolled' =>
          'No biometrics enrolled. Set up fingerprint or Face ID in device settings.',
        'NotAvailable' || 'HardwareUnavailable' =>
          'Biometric hardware is not available on this device.',
        'LockedOut' || 'PermanentlyLockedOut' =>
          'Biometrics locked out due to too many attempts. Use your PIN.',
        _ => 'Biometric authentication failed. Please use your PIN instead.',
      };
      AppNotification.showError(context, message);
    } catch (_) {
      if (mounted) {
        AppNotification.showError(
          context,
          'Biometric authentication failed. Please use your PIN instead.',
        );
      }
    }
  }

  @override
  void dispose() {
    _checkAnim.dispose();
    _lockoutTimer?.cancel();
    _emailController.dispose();
    _pinNotifier.dispose();
    super.dispose();
  }

  // ── PIN input helpers ──────────────────────────────────────────────────────

  void _onDigit(String digit) {
    if (_pinNotifier.value.length >= 6 ||
        _checking ||
        _loginSuccess ||
        _lockoutUntil != null) {
      return;
    }
    // Update value WITHOUT full screen rebuild to maintain 120fps input & retain ink ripple
    _pinNotifier.value += digit;

    if (_pinNotifier.value.length == 6) {
      // Defer so the 6th dot animates before heavy DB work begins.
      WidgetsBinding.instance.addPostFrameCallback((_) => _submit());
    }
  }

  void _onBackspace() {
    if (_pinNotifier.value.isEmpty || _checking || _loginSuccess) return;
    _pinNotifier.value = _pinNotifier.value.substring(
      0,
      _pinNotifier.value.length - 1,
    );
  }

  Future<void> _submit() async {
    setState(() => _checking = true);

    if (!mounted) return;

    List<UserData> matches;
    try {
      matches = await ref
          .read(authProvider)
          .getUsersByPin(
            _pinNotifier.value,
            email: _emailController.text.trim(),
          );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _checking = false;
      });
      _pinNotifier.value = '';
      if (mounted) {
        AppNotification.showError(context, 'Login failed. Please try again.');
      }
      return;
    }

    if (!mounted) return;

    if (matches.isEmpty) {
      HapticFeedback.heavyImpact();
      Future.delayed(const Duration(milliseconds: 150), () {
        HapticFeedback.heavyImpact();
      });

      _failedAttempts++;
      final prefs = await SharedPreferences.getInstance();

      setState(() {
        _checking = false;

        if (_failedAttempts >= 5) {
          _lockoutUntil = DateTime.now().add(const Duration(minutes: 15));
          prefs.setInt(
            'pin_lockout_until',
            _lockoutUntil!.millisecondsSinceEpoch,
          );
          _startLockoutTimer();
        } else if (_failedAttempts >= 3) {
          _pinWarning =
              '${5 - _failedAttempts} attempts remaining before lockout.';
        }
      });
      _pinNotifier.value = '';

      if (mounted && _lockoutUntil == null) {
        AppNotification.showError(context, 'Wrong PIN. Please try again.');
      }
      return;
    }

    // Success reset
    _failedAttempts = 0;
    _pinWarning = null;

    if (matches.length == 1) {
      _enterApp(matches.first);
      return;
    }

    // Multiple people share this PIN — ask which one is logging in
    setState(() => _checking = false);
    if (mounted) {
      _showUserPicker(matches);
    }
  }

  /// Plays the success animation then opens the app.
  Future<void> _enterApp(UserData user) async {
    if (!mounted) return;

    // Capture provider up front. setCurrentUser triggers navigator-key
    // regeneration which disposes this screen — by then the post-await
    // `ref` would be invalidated. See plan §"Bug fix" Pattern 1.
    final auth = ref.read(authProvider);

    // PIN matched a local row, but RLS + sync push need a Supabase JWT too.
    // If the SDK has no current session, try a silent refresh first — most
    // of the time the access token has just expired while the refresh token
    // is still valid, and the user shouldn't be bounced to OTP over that.
    // Only fall back to OTP when the refresh genuinely fails on an online
    // device (refresh token rejected / signed out elsewhere). Offline gets
    // a pass: the SDK auto-retries on reconnect, sync push self-gates on
    // auth, so cloud writes safely queue until the JWT comes back.
    if (!auth.hasSupabaseSession && (user.email ?? '').isNotEmpty) {
      final refreshResult = await auth.tryRefreshSupabaseSession();
      if (!mounted) return;

      if (refreshResult == SessionRefreshResult.failedAuth) {
        setState(() {
          _checking = false;
          _loginSuccess = false;
        });
        _pinNotifier.value = '';
        AppNotification.showError(
          context,
          'Your session expired. Please verify your email to continue.',
        );
        final error = await auth.sendOtp(user.email!);
        if (!mounted) return;
        if (error != null) {
          AppNotification.showError(context, error);
          return;
        }
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(
            builder: (_) =>
                OtpVerificationScreen(user: user, email: user.email!),
          ),
        );
        return;
      }
      // refreshed | alreadyValid | offline → continue into the app.
    }

    // Brief pause so the user sees all 6 dots filled before the overlay swap.
    await Future.delayed(const Duration(milliseconds: 100));
    if (!mounted) return;

    setState(() {
      _loginSuccess = true;
      _loggedInUser = user;
      _checking = false;
    });
    _checkAnim.forward();

    // Controlled delay (1.2s) to show the "Welcome" overlay and completion animation.
    await Future.delayed(const Duration(milliseconds: 1200));
    if (!mounted) return;

    // Users proceed directly to the app using PIN.
    auth.setCurrentUser(user);
    // Navigator key regeneration in main.dart handles routing automatically.
  }

  /// Clears device persistence and navigates to email entry so the user can
  /// log in with a different account or on a new device.
  Future<void> _switchToEmail() async {
    await ref.read(authProvider).clearDeviceUserId();
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      PageRouteBuilder(
        pageBuilder: (context, animation, secondaryAnimation) =>
            const EmailEntryScreen(),
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

  Future<void> _forgotPin() async {
    final email = _emailController.text.trim();
    if (email.isEmpty) {
      AppNotification.showError(
        context,
        'Please enter your email address first.',
      );
      return;
    }

    setState(() => _checking = true);
    final error = await ref.read(authProvider).sendOtp(email);
    if (!mounted) return;
    setState(() => _checking = false);

    if (error != null) {
      AppNotification.showError(context, error);
      return;
    }

    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => OtpVerificationScreen(
          user: _identifiedUser,
          email: _identifiedUser!.email!,
          isPinReset: true,
        ),
      ),
    );
  }

  void _showUserPicker(List<UserData> users) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => _UserPickerSheet(
        users: users,
        onSelected: (user) {
          Navigator.pop(context);
          _enterApp(user);
        },
      ),
    );
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final textColor = isDark ? Colors.white : Colors.black;
    final subtextColor = textColor.withValues(alpha: 0.7);
    final surface = isDark
        ? Colors.white.withValues(alpha: 0.1)
        : Colors.black.withValues(alpha: 0.05);

    return AuthBackground(
      resizeToAvoidBottomInset: false,
      child: SafeArea(
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 300),
          child: _loginSuccess
              ? _SuccessOverlay(
                  key: const ValueKey('success'),
                  user: _loggedInUser!,
                  checkScale: _checkScale,
                  checkFade: _checkFade,
                  bg: Colors.transparent,
                  textColor: textColor,
                  subtextColor: subtextColor,
                )
              : _PinPad(
                  pinNotifier: _pinNotifier,
                  emailController: _emailController,
                  checking: _checking,
                  identifiedUser: _identifiedUser,
                  lockoutUntil: _lockoutUntil,
                  warningText: _pinWarning,
                  bg: Colors.transparent,
                  surface: surface,
                  textColor: textColor,
                  subtextColor: subtextColor,
                  onDigit: _onDigit,
                  onBackspace: _onBackspace,
                  onSwitchToEmail: _switchToEmail,
                  onForgotPin: _forgotPin,
                  biometricsAvailable: _biometricsAvailable,
                  onBiometrics: _biometricsAvailable
                      ? _triggerBiometrics
                      : null,
                ),
        ),
      ),
    );
  }
}

// ── Success overlay ────────────────────────────────────────────────────────

class _SuccessOverlay extends StatelessWidget {
  final UserData user;
  final Animation<double> checkScale;
  final Animation<double> checkFade;
  final Color bg;
  final Color textColor;
  final Color subtextColor;

  const _SuccessOverlay({
    super.key,
    required this.user,
    required this.checkScale,
    required this.checkFade,
    required this.bg,
    required this.textColor,
    required this.subtextColor,
  });

  Color _hexColor(BuildContext context, String hex) {
    try {
      return Color(int.parse(hex.replaceFirst('#', '0xFF')));
    } catch (_) {
      return Theme.of(context).colorScheme.primary;
    }
  }

  @override
  Widget build(BuildContext context) {
    final avatarColor = _hexColor(context, user.avatarColor);

    return Center(
      child: FadeTransition(
        opacity: checkFade,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // ── Bouncy checkmark circle ─────────────────────────────────
            ScaleTransition(
              scale: checkScale,
              child: Container(
                width: 96,
                height: 96,
                decoration: BoxDecoration(
                  color: avatarColor.withValues(alpha: 0.15),
                  shape: BoxShape.circle,
                  border: Border.all(color: avatarColor, width: 3),
                ),
                child: Icon(Icons.check_rounded, size: 52, color: avatarColor),
              ),
            ),
            const SizedBox(height: 24),

            // ── Welcome text ─────────────────────────────────────────────
            Text(
              'Welcome, ${user.name}',
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w700,
                color: textColor,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Opening Reebaplus POS...',
              style: TextStyle(fontSize: 14, color: subtextColor),
            ),
            const SizedBox(height: 32),

            // ── Small loading dots ────────────────────────────────────────
            _LoadingDots(color: avatarColor),
          ],
        ),
      ),
    );
  }
}

// ── Three animated loading dots ────────────────────────────────────────────

class _LoadingDots extends StatefulWidget {
  final Color color;
  const _LoadingDots({required this.color});

  @override
  State<_LoadingDots> createState() => _LoadingDotsState();
}

class _LoadingDotsState extends State<_LoadingDots>
    with TickerProviderStateMixin {
  final List<AnimationController> _controllers = [];

  @override
  void initState() {
    super.initState();
    for (int i = 0; i < 3; i++) {
      final ctrl = AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 600),
      );
      _controllers.add(ctrl);
      // Stagger each dot by 200ms
      Future.delayed(Duration(milliseconds: i * 200), () {
        if (mounted) {
          ctrl.repeat(reverse: true);
        }
      });
    }
  }

  @override
  void dispose() {
    for (final c in _controllers) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(3, (i) {
        return AnimatedBuilder(
          animation: _controllers[i],
          builder: (_, __) {
            return Container(
              margin: const EdgeInsets.symmetric(horizontal: 5),
              width: 8,
              height: 8 + _controllers[i].value * 8, // grows from 8 to 16
              decoration: BoxDecoration(
                color: widget.color.withValues(
                  alpha: 0.4 + _controllers[i].value * 0.6,
                ),
                borderRadius: BorderRadius.circular(4),
              ),
            );
          },
        );
      }),
    );
  }
}

// ── PIN pad widget ─────────────────────────────────────────────────────────

class _PinPad extends StatelessWidget {
  final ValueNotifier<String> pinNotifier;
  final TextEditingController emailController;
  final bool checking;
  final UserData? identifiedUser;
  final DateTime? lockoutUntil;
  final String? warningText;
  final Color bg;
  final Color surface;
  final Color textColor;
  final Color subtextColor;
  final void Function(String) onDigit;
  final VoidCallback onBackspace;
  final VoidCallback? onSwitchToEmail;
  final VoidCallback? onForgotPin;
  final bool biometricsAvailable;
  final VoidCallback? onBiometrics;

  const _PinPad({
    required this.pinNotifier,
    required this.emailController,
    required this.checking,
    this.identifiedUser,
    this.lockoutUntil,
    this.warningText,
    required this.bg,
    required this.surface,
    required this.textColor,
    required this.subtextColor,
    required this.onDigit,
    required this.onBackspace,
    this.onSwitchToEmail,
    this.onForgotPin,
    this.biometricsAvailable = false,
    this.onBiometrics,
  });

  Color _hexColor(BuildContext context, String hex) {
    try {
      return Color(int.parse(hex.replaceFirst('#', '0xFF')));
    } catch (_) {
      return Theme.of(context).colorScheme.primary;
    }
  }

  String _formatDuration(Duration d) {
    String twoDigits(int n) => n.toString().padLeft(2, "0");
    String twoDigitMinutes = twoDigits(d.inMinutes.remainder(60));
    String twoDigitSeconds = twoDigits(d.inSeconds.remainder(60));
    return "$twoDigitMinutes:$twoDigitSeconds";
  }

  @override
  Widget build(BuildContext context) {
    final isLockedOut = lockoutUntil != null;

    return Center(
      child: SingleChildScrollView(
        padding: context.rPaddingSymmetric(horizontal: 32, vertical: 16),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // ── Header/Avatar ──────────────────────────────────────────
            if (identifiedUser != null) ...[
              CircleAvatar(
                radius: context.getRSize(32),
                backgroundColor: _hexColor(
                  context,
                  identifiedUser!.avatarColor,
                ).withValues(alpha: 0.2),
                child: Text(
                  identifiedUser!.name.isNotEmpty
                      ? identifiedUser!.name[0].toUpperCase()
                      : '?',
                  style: TextStyle(
                    fontSize: context.getRFontSize(26),
                    fontWeight: FontWeight.bold,
                    color: _hexColor(context, identifiedUser!.avatarColor),
                  ),
                ),
              ),
              SizedBox(height: context.getRSize(12)),
              Text(
                'Welcome back, ${identifiedUser!.name.split(' ').first}',
                style: TextStyle(
                  fontSize: context.getRFontSize(20),
                  fontWeight: FontWeight.w700,
                  color: textColor,
                ),
              ),
            ] else ...[
              Image.asset(
                'assets/images/reebaplus_logo.png',
                height: context.getRSize(60),
              ),
              SizedBox(height: context.getRSize(12)),
            ],

            SizedBox(height: context.getRSize(16)),
            // ── Email Input ──────────────────────────────────────────
            Padding(
              padding: EdgeInsets.only(bottom: context.getRSize(16)),
              child: TextFormField(
                controller: emailController,
                style: TextStyle(color: textColor),
                decoration: AppDecorations.authInputDecoration(
                  context,
                  label: 'Email Address',
                  prefixIcon: Icons.email_outlined,
                ),
                keyboardType: TextInputType.emailAddress,
                textInputAction: TextInputAction.next,
              ),
            ),
            Text(
              isLockedOut
                  ? 'Device locked due to multiple failed attempts'
                  : 'Enter your 6-digit PIN to continue',
              style: TextStyle(
                fontSize: context.getRFontSize(14),
                color: isLockedOut ? Colors.redAccent : subtextColor,
              ),
              textAlign: TextAlign.center,
            ),
            SizedBox(height: context.getRSize(20)),

            if (isLockedOut) ...[
              // ── Lockout State ─────────────────────────────────────────────
              Container(
                padding: context.rPaddingSymmetric(
                  horizontal: 24,
                  vertical: 32,
                ),
                decoration: BoxDecoration(
                  color: Colors.redAccent.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(context.getRSize(20)),
                  border: Border.all(
                    color: Colors.redAccent.withValues(alpha: 0.3),
                  ),
                ),
                child: Column(
                  children: [
                    Icon(
                      Icons.lock_clock_rounded,
                      color: Colors.redAccent,
                      size: context.getRSize(48),
                    ),
                    SizedBox(height: context.getRSize(16)),
                    Text(
                      _formatDuration(lockoutUntil!.difference(DateTime.now())),
                      style: TextStyle(
                        fontSize: context.getRFontSize(36),
                        fontWeight: FontWeight.bold,
                        color: Colors.redAccent,
                        letterSpacing: 2,
                      ),
                    ),
                    SizedBox(height: context.getRSize(8)),
                    const Text(
                      'Try again later',
                      style: TextStyle(color: Colors.redAccent),
                    ),
                  ],
                ),
              ),
              SizedBox(height: context.getRSize(24)),
              TextButton.icon(
                onPressed: onSwitchToEmail,
                icon: Icon(Icons.email_rounded, size: context.getRSize(18)),
                label: const Text('Reset PIN with Email'),
                style: TextButton.styleFrom(foregroundColor: textColor),
              ),
            ] else ...[
              // ── Six dots ────────────────────────────────────────────────
              ValueListenableBuilder<String>(
                valueListenable: pinNotifier,
                builder: (context, currentPin, _) {
                  return Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: List.generate(6, (i) {
                      final filled = i < currentPin.length;
                      return AnimatedContainer(
                        duration: const Duration(milliseconds: 150),
                        margin: context.rPaddingSymmetric(horizontal: 6),
                        width: context.getRSize(12),
                        height: context.getRSize(12),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: filled
                              ? Theme.of(context).colorScheme.primary
                              : textColor.withValues(alpha: 0.1),
                          border: Border.all(
                            color: filled
                                ? Theme.of(context).colorScheme.primary
                                : textColor.withValues(alpha: 0.3),
                            width: 2,
                          ),
                        ),
                      );
                    }),
                  );
                },
              ),

              // ── Warning Message ────────────────────────────────────────────
              SizedBox(
                height: context.getRSize(24),
                child: warningText != null
                    ? Center(
                        child: Text(
                          warningText!,
                          style: TextStyle(
                            color: Colors.orangeAccent,
                            fontSize: context.getRFontSize(13),
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      )
                    : const SizedBox.shrink(),
              ),

              // ── Numeric keypad ───────────────────────────────────────────
              ConstrainedBox(
                constraints: BoxConstraints(maxWidth: context.getRSize(240)),
                child: Column(
                  children: [
                    _buildKeyRow(context, ['1', '2', '3'], surface, textColor),
                    SizedBox(height: context.getRSize(8)),
                    _buildKeyRow(context, ['4', '5', '6'], surface, textColor),
                    SizedBox(height: context.getRSize(8)),
                    _buildKeyRow(context, ['7', '8', '9'], surface, textColor),
                    SizedBox(height: context.getRSize(8)),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        biometricsAvailable && onBiometrics != null
                            ? _KeyButton(
                                icon: Icons.fingerprint_rounded,
                                surface: surface,
                                textColor: textColor,
                                onTap: onBiometrics!,
                              )
                            : SizedBox(
                                width: context.getRSize(64),
                                height: context.getRSize(64),
                              ),
                        SizedBox(width: context.getRSize(8)),
                        _KeyButton(
                          label: '0',
                          surface: surface,
                          textColor: textColor,
                          onTap: () => onDigit('0'),
                        ),
                        SizedBox(width: context.getRSize(8)),
                        _KeyButton(
                          icon: Icons.backspace_outlined,
                          surface: surface,
                          textColor: textColor,
                          onTap: onBackspace,
                        ),
                      ],
                    ),
                  ],
                ),
              ),

              SizedBox(height: context.getRSize(20)),

              // ── Switch-account / Not You link ──────────────────────────────
              if (onSwitchToEmail != null)
                TextButton(
                  onPressed: onSwitchToEmail,
                  child: Text(
                    identifiedUser != null
                        ? 'Not ${identifiedUser!.name.split(' ').first}? Switch account'
                        : 'Login with a different account',
                    style: TextStyle(
                      color: textColor.withValues(alpha: 0.65),
                      fontSize: context.getRFontSize(14),
                      decoration: TextDecoration.underline,
                    ),
                  ),
                ),

              // ── Forgot PIN link ──────────────────────────────────────────
              if (identifiedUser != null && onForgotPin != null)
                TextButton(
                  onPressed: onForgotPin,
                  child: Text(
                    'Forgot PIN?',
                    style: TextStyle(
                      color: textColor.withValues(alpha: 0.5),
                      fontSize: context.getRFontSize(13),
                    ),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildKeyRow(
    BuildContext context,
    List<String> digits,
    Color surface,
    Color textColor,
  ) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: digits.map((d) {
        return Padding(
          padding: context.rPaddingSymmetric(horizontal: 6),
          child: _KeyButton(
            label: d,
            surface: surface,
            textColor: textColor,
            onTap: () => onDigit(d),
          ),
        );
      }).toList(),
    );
  }
}

// ── Single keypad button ────────────────────────────────────────────────────

class _KeyButton extends StatelessWidget {
  final String? label;
  final IconData? icon;
  final Color surface;
  final Color textColor;
  final VoidCallback onTap;

  const _KeyButton({
    this.label,
    this.icon,
    required this.surface,
    required this.textColor,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration:
          AppDecorations.glassCard(
            context,
            radius: context.getRSize(16),
          ).copyWith(
            boxShadow: [
              BoxShadow(
                color: textColor.withValues(alpha: 0.05),
                blurRadius: 10,
                spreadRadius: 2,
              ),
            ],
          ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onHighlightChanged: (isHighlighted) {
            if (isHighlighted) {
              HapticFeedback.lightImpact();
            }
          },
          onTap: onTap,
          borderRadius: BorderRadius.circular(context.getRSize(16)),
          child: SizedBox(
            width: context.getRSize(64),
            height: context.getRSize(64),
            child: Center(
              child: icon != null
                  ? Icon(icon, color: textColor, size: context.getRSize(22))
                  : Text(
                      label!,
                      style: TextStyle(
                        fontSize: context.getRFontSize(24),
                        fontWeight: FontWeight.w600,
                        color: textColor,
                      ),
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

// ── Bottom sheet when multiple users share the same PIN ────────────────────

class _UserPickerSheet extends StatelessWidget {
  final List<UserData> users;
  final ValueChanged<UserData> onSelected;

  const _UserPickerSheet({required this.users, required this.onSelected});

  @override
  Widget build(BuildContext context) {
    final surface = Theme.of(context).colorScheme.surface;
    final textColor = Theme.of(context).colorScheme.onSurface;
    final subtextColor =
        Theme.of(context).textTheme.bodySmall?.color ??
        Theme.of(context).iconTheme.color!;

    return Container(
      decoration: BoxDecoration(
        color: surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      padding: EdgeInsets.fromLTRB(24, 16, 24, context.bottomInset + 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: subtextColor.withValues(alpha: 0.4),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 20),
          Text(
            'Who is logging in?',
            style: TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w700,
              color: textColor,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Multiple accounts share this PIN. Tap your name.',
            style: TextStyle(fontSize: 13, color: subtextColor),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 20),
          ...users.map(
            (u) => ListTile(
              contentPadding: EdgeInsets.zero,
              leading: CircleAvatar(
                backgroundColor: _hexColor(context, u.avatarColor),
                child: Text(
                  u.name.isNotEmpty ? u.name[0].toUpperCase() : '?',
                  style: TextStyle(
                    color:
                        u.avatarColor.toLowerCase().contains('ff') &&
                            u.avatarColor.length >= 8
                        ? Colors.white
                        : Colors
                              .white, // Simplification, usually avatar text is white
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              title: Text(
                u.name,
                style: TextStyle(fontWeight: FontWeight.w600, color: textColor),
              ),
              subtitle: Text(
                'Owner',
                style: TextStyle(fontSize: 12, color: subtextColor),
              ),
              onTap: () => onSelected(u),
            ),
          ),
        ],
      ),
    );
  }

  Color _hexColor(BuildContext context, String hex) {
    try {
      return Color(int.parse(hex.replaceFirst('#', '0xFF')));
    } catch (_) {
      return Theme.of(context).colorScheme.primary;
    }
  }
}
