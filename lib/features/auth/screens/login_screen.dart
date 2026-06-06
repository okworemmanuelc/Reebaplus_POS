import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';

import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/shared/utils/role_display.dart';
import 'package:reebaplus_pos/core/utils/notifications.dart';
import 'package:reebaplus_pos/features/auth/screens/email_entry_screen.dart';
import 'package:reebaplus_pos/features/auth/screens/otp_verification_screen.dart';
import 'package:reebaplus_pos/features/auth/screens/who_is_working_screen.dart';
import 'dart:async';
import 'package:local_auth/local_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:reebaplus_pos/features/auth/widgets/branded_auth_background.dart';
import 'package:reebaplus_pos/features/auth/widgets/pin_keypad.dart';
import 'package:reebaplus_pos/shared/services/auth_service.dart';

import 'package:reebaplus_pos/core/theme/app_decorations.dart';

class LoginScreen extends ConsumerStatefulWidget {
  /// When set (e.g. routed from the Who Is Working picker, master plan §8.4),
  /// the screen identifies this exact staff member instead of reading the
  /// device user — so the name, avatar, and PIN-scoping email all match the
  /// tapped card rather than whoever first set up the device.
  final UserData? presetUser;

  const LoginScreen({super.key, this.presetUser});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  bool _checking = false;
  final ValueNotifier<String> _pinNotifier = ValueNotifier<String>('');
  bool _biometricsAvailable = false;
  final TextEditingController _emailController = TextEditingController();

  // ── Returning User & PIN-attempt State ──────────────────────────────────────
  UserData? _identifiedUser;
  // 5 wrong PINs forces the Forgot-PIN (email OTP) flow — master plan §7.1.
  // There is no time-based lockout; email/OTP access is the recovery gate.
  int _failedAttempts = 0;
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
    WidgetsBinding.instance.addObserver(this);
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

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Re-check on resume so the biometric button recovers if the first check
    // hit a transient platform error, and so it reflects Security Settings
    // changes made while this screen was in the background.
    if (state == AppLifecycleState.resumed) {
      _checkBiometricAvailability();
    }
  }

  Future<void> _initUserAndLockoutState() async {
    // Identify user
    final auth = ref.read(authProvider);
    final db = ref.read(databaseProvider);

    // Picker-driven entry (master plan §8.4): the staff member is already
    // chosen, so use it verbatim and skip the device-user / last-email
    // lookups — that's what fixes the carried-over device email showing on
    // another staff member's PIN screen.
    if (widget.presetUser != null) {
      final user = widget.presetUser!;
      _identifiedUser = user;
      if (user.email != null) _emailController.text = user.email!;
      _checkBiometricAvailability();
      return;
    }

    final userId = await auth.getDeviceUserId();
    if (userId != null) {
      final user = await db.storesDao.getUserById(userId);
      if (mounted && user != null) {
        setState(() {
          _identifiedUser = user;
          if (user.email != null) _emailController.text = user.email!;
        });
      }
    }

    // Deliberately NOT prefilling from getLastLoggedInEmail() here: on a shared
    // till the last user's email must not seed another signer's PIN screen
    // (master plan §7.2a). The email is shown only when an identity is actually
    // resolved (presetUser or device user, above). If neither resolved, the
    // field stays empty and _submit refuses an unscoped PIN match.
    _checkBiometricAvailability();
  }

  /// Checks whether the device supports biometrics and updates [_biometricsAvailable].
  /// Never shows a dialog — purely a capability check.
  Future<void> _checkBiometricAvailability() async {
    try {
      final auth = LocalAuthentication();
      // Evaluate the two capability checks independently. canCheckBiometrics can
      // transiently throw or return false (cold start, temporary lockout); if it
      // threw it would abort before isDeviceSupported() — the stable signal on a
      // device with a secure lock screen — and the silent catch below would then
      // leave the button hidden for the rest of this screen's life. Guarding each
      // call keeps a flake on one from masking the other.
      bool canCheck = false;
      try {
        canCheck = await auth.canCheckBiometrics;
      } catch (_) {}
      bool deviceSupported = false;
      try {
        deviceSupported = await auth.isDeviceSupported();
      } catch (_) {}
      final available = canCheck || deviceSupported;
      final prefs = await SharedPreferences.getInstance();

      // One-time migration: old onboarding key → unified key
      final oldKey = prefs.getBool('use_biometrics');
      if (oldKey != null && !prefs.containsKey('biometrics_enabled')) {
        await prefs.setBool('biometrics_enabled', oldKey);
      }

      final isEnabled = prefs.getBool('biometrics_enabled') ?? false;

      // _triggerBiometrics enters the app as getDeviceUserId(), so biometrics is
      // only safe — and only correct — when the identified account IS this
      // device's owner: the account that was created here, whose PIN and
      // biometrics were set up on this device. That holds whether we arrived
      // with no preset (the device user) or via the Who Is Working picker with
      // the device owner's own card tapped. A picker-selected staff member who
      // is NOT the device owner must use a PIN — offering biometrics would
      // silently unlock the device owner instead (master plan §7.2a, §8.4).
      // pinHash != null also gates out a post-Log-Out owner whose PIN was reset
      // to setup-required (clearUserPin), until they re-establish a PIN.
      final deviceUserId = await ref.read(authProvider).getDeviceUserId();
      final isDeviceOwner = _identifiedUser != null &&
          deviceUserId != null &&
          _identifiedUser!.id == deviceUserId &&
          _identifiedUser!.pinHash != null;
      if (mounted) {
        setState(() =>
            _biometricsAvailable = available && isEnabled && isDeviceOwner);
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
              .storesDao
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
    WidgetsBinding.instance.removeObserver(this);
    _checkAnim.dispose();
    _emailController.dispose();
    _pinNotifier.dispose();
    super.dispose();
  }

  // ── PIN input helpers ──────────────────────────────────────────────────────

  void _onDigit(String digit) {
    if (_pinNotifier.value.length >= 6 || _checking || _loginSuccess) {
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

    // Scope the PIN check to the identified user as tightly as possible. When
    // the signer was already identified (picker card or post-OTP preset), pin
    // to their exact user id so no other local row — even one sharing this
    // email or PIN on a different business — can match. Fall back to the typed
    // email only when no identity is known. Master plan §7.2a.
    final identified = _identifiedUser;
    final scopeEmail = identified?.email ?? _emailController.text.trim();

    // Never run an unscoped PIN match: with no resolved identity AND no typed
    // email, getUsersByPin would match ANY local user's PIN — a cross-user
    // leak on a shared till. Make them identify by email first (§7.2a).
    if (identified == null && scopeEmail.isEmpty) {
      setState(() => _checking = false);
      _pinNotifier.value = '';
      if (mounted) {
        AppNotification.showError(
          context,
          'Enter your email above to continue.',
        );
      }
      return;
    }

    List<UserData> matches;
    try {
      matches = await ref
          .read(authProvider)
          .getUsersByPin(
            _pinNotifier.value,
            userId: identified?.id,
            email: scopeEmail,
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
      _pinNotifier.value = '';

      // 5 wrong PINs → force the Forgot-PIN flow (master plan §7.1). Email/OTP
      // access is the recovery gate; there is no time-based lockout.
      if (_failedAttempts >= 5) {
        setState(() {
          _checking = false;
          _pinWarning = null;
        });
        if (mounted) {
          AppNotification.showError(
            context,
            'Too many wrong PINs. Reset your PIN by email to continue.',
          );
          await _forgotPin();
        }
        return;
      }

      setState(() {
        _checking = false;
        if (_failedAttempts >= 3) {
          _pinWarning =
              '${5 - _failedAttempts} attempts remaining before PIN reset.';
        }
      });

      if (mounted) {
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

  /// Returns to the "Who's working?" picker (master plan §8) so a different
  /// staff member of the same business can sign in. Only offered when another
  /// active staff member exists (see [build]). When the picker is still on the
  /// stack below (multi-staff entry pushed this screen), pop back to that live
  /// instance; otherwise — picker-replaced shortcut or cold-start root login —
  /// replace this screen with a fresh picker.
  void _switchAccount() {
    final navigator = Navigator.of(context);
    if (navigator.canPop()) {
      navigator.pop();
    } else {
      navigator.pushReplacement(
        MaterialPageRoute(builder: (_) => const WhoIsWorkingScreen()),
      );
    }
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
          email: email,
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
    // Offer "Switch account" (→ Who's working) only when the same business has
    // another active staff member to switch to — otherwise there's no one to
    // pick (master plan §8).
    final identified = _identifiedUser;
    bool showSwitch = false;
    if (!_loginSuccess && identified != null) {
      final staff =
          ref.watch(activeStaffProvider(identified.businessId)).valueOrNull;
      showSwitch =
          staff != null && staff.any((e) => e.user.id != identified.id);
    }

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      resizeToAvoidBottomInset: false,
      body: BrandedAuthBackground(
        child: SafeArea(
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 300),
            child: _loginSuccess
                ? _SuccessOverlay(
                    key: const ValueKey('success'),
                    user: _loggedInUser!,
                    checkScale: _checkScale,
                    checkFade: _checkFade,
                  )
                : _PinPad(
                    pinNotifier: _pinNotifier,
                    emailController: _emailController,
                    checking: _checking,
                    identifiedUser: _identifiedUser,
                    warningText: _pinWarning,
                    onDigit: _onDigit,
                    onBackspace: _onBackspace,
                    onSwitchToEmail: _switchToEmail,
                    onForgotPin: _forgotPin,
                    showSwitchAccount: showSwitch,
                    onSwitchAccount: _switchAccount,
                    biometricsAvailable: _biometricsAvailable,
                    onBiometrics: _biometricsAvailable
                        ? _triggerBiometrics
                        : null,
                  ),
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

  const _SuccessOverlay({
    super.key,
    required this.user,
    required this.checkScale,
    required this.checkFade,
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
    final textColor = authTextPrimary(context);
    final subtextColor = authTextPrimary(context).withValues(alpha: 0.65);
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
  final String? warningText;
  final void Function(String) onDigit;
  final VoidCallback onBackspace;
  final VoidCallback? onSwitchToEmail;
  final VoidCallback? onForgotPin;
  final bool showSwitchAccount;
  final VoidCallback? onSwitchAccount;
  final bool biometricsAvailable;
  final VoidCallback? onBiometrics;

  const _PinPad({
    required this.pinNotifier,
    required this.emailController,
    required this.checking,
    this.identifiedUser,
    this.warningText,
    required this.onDigit,
    required this.onBackspace,
    this.onSwitchToEmail,
    this.onForgotPin,
    this.showSwitchAccount = false,
    this.onSwitchAccount,
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

  @override
  Widget build(BuildContext context) {
    final textColor = authTextPrimary(context);
    final subtextColor = authTextPrimary(context).withValues(alpha: 0.65);
    return Stack(
      children: [
        // ── Back to "Who's working?" picker (only when another staff exists) ─
        if (showSwitchAccount && onSwitchAccount != null)
          Align(
            alignment: Alignment.topLeft,
            child: TextButton.icon(
              onPressed: onSwitchAccount,
              icon: Icon(
                Icons.arrow_back_rounded,
                size: context.getRFontSize(18),
                color: textColor.withValues(alpha: 0.75),
              ),
              label: Text(
                'Switch account',
                style: TextStyle(
                  color: textColor.withValues(alpha: 0.75),
                  fontSize: context.getRFontSize(14),
                  fontWeight: FontWeight.w600,
                ),
              ),
              style: TextButton.styleFrom(
                padding: context.rPaddingSymmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
              ),
            ),
          ),
        Center(
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
                // When we already know who's signing in (returning device user
                // or a picker-selected staff member), the email is fixed — it
                // scopes the PIN check, so editing it would let it drift away
                // from the identified user. Switch accounts via the link below.
                readOnly: identifiedUser != null,
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
              'Enter your 6-digit PIN to continue',
              style: TextStyle(
                fontSize: context.getRFontSize(14),
                color: subtextColor,
              ),
              textAlign: TextAlign.center,
            ),
            SizedBox(height: context.getRSize(20)),

            ...[
              // ── Six dots ────────────────────────────────────────────────
              ValueListenableBuilder<String>(
                valueListenable: pinNotifier,
                builder: (context, currentPin, _) =>
                    PinDots(filled: currentPin.length),
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

              // ── Numeric keypad (biometric fills the bottom-left slot) ─────
              PinKeypad(
                onDigit: onDigit,
                onBackspace: onBackspace,
                leadingKey: biometricsAvailable && onBiometrics != null
                    ? PinKey(
                        icon: Icons.fingerprint_rounded,
                        onTap: onBiometrics!,
                      )
                    : null,
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
        ),
      ],
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
              subtitle: Consumer(
                builder: (context, ref, _) {
                  final role = ref.watch(userRoleProvider(u.id));
                  return Text(
                    role?.name ?? 'Member',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: role == null
                          ? subtextColor
                          : roleTagColor(role.slug),
                    ),
                  );
                },
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
