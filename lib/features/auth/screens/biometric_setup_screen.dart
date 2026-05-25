import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:local_auth/local_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/features/auth/widgets/onboarding_step_indicator.dart';
import 'package:reebaplus_pos/features/auth/widgets/auth_background.dart';
import 'package:reebaplus_pos/shared/services/auth_service.dart';

class BiometricSetupScreen extends ConsumerStatefulWidget {
  final UserData user;
  final bool isNewBusinessSetup;

  const BiometricSetupScreen({
    super.key,
    required this.user,
    this.isNewBusinessSetup = false,
  });

  @override
  ConsumerState<BiometricSetupScreen> createState() =>
      _BiometricSetupScreenState();
}

class _BiometricSetupScreenState extends ConsumerState<BiometricSetupScreen> {
  final LocalAuthentication auth = LocalAuthentication();
  bool _loading = false;
  String? _errorMessage;

  // Captured at initState — `_done` runs after `await prefs.setBool(...)`
  // and `setCurrentUser` schedules navigator-key regeneration which
  // disposes this screen. Touching `ref` post-await would race the
  // riverpod invalidation. See plan §"Bug fix" Pattern 1.
  late final AuthService _auth;

  @override
  void initState() {
    super.initState();
    _auth = ref.read(authProvider);
  }

  Future<void> _enableBiometrics() async {
    setState(() {
      _loading = true;
      _errorMessage = null;
    });

    try {
      final canAuthenticateWithBiometrics = await auth.canCheckBiometrics;
      final canAuthenticate =
          canAuthenticateWithBiometrics || await auth.isDeviceSupported();

      if (!canAuthenticate) {
        setState(() {
          _errorMessage =
              "Biometric authentication is not supported on this device.";
          _loading = false;
        });
        return;
      }

      final authenticated = await auth.authenticate(
        localizedReason: 'Enable biometrics for quick login',
        options: const AuthenticationOptions(
          stickyAuth: true,
          biometricOnly: true,
        ),
      );

      if (authenticated) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setBool('biometrics_enabled', true);
        _done();
      } else {
        setState(() {
          _errorMessage = "Authentication failed or canceled.";
          _loading = false;
        });
      }
    } catch (e) {
      setState(() {
        _errorMessage = "An error occurred during biometric setup.";
        _loading = false;
      });
    }
  }

  void _skip() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('biometrics_enabled', false);
    _done();
  }

  void _done() {
    if (widget.isNewBusinessSetup) {
      _auth.pendingPostLoginRoute = PostLoginRoute.successDashboard;
    }
    _auth.setCurrentUser(widget.user, freshSignIn: true);
    // Navigator key regeneration in main.dart handles routing automatically.
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final textColor = isDark ? Colors.white : Colors.black;
    final primary = theme.colorScheme.primary;

    return AuthBackground(
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 40),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (widget.isNewBusinessSetup)
                const OnboardingStepIndicator(
                  currentStep: 7,
                  totalSteps: 7,
                  stepLabels: OnboardingStepIndicator.pathALabels,
                ),
              if (widget.isNewBusinessSetup) const SizedBox(height: 16),
              Icon(Icons.fingerprint, size: 80, color: primary),
              const SizedBox(height: 24),
              Text(
                'Speed up your login',
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w700,
                  color: textColor,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              Text(
                'Use Face ID or Fingerprint to log into Reebaplus POS instantly and securely instead of typing your PIN every time.',
                style: TextStyle(
                  fontSize: 14,
                  color: textColor.withValues(alpha: 0.7),
                  height: 1.5,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 48),

              if (_errorMessage != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 24),
                  child: Text(
                    _errorMessage!,
                    style: const TextStyle(
                      color: Color(0xFFFF6B6B),
                      fontSize: 13,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ),

              AppButton(
                text: 'Enable Biometrics',
                isLoading: _loading,
                onPressed: _enableBiometrics,
              ),
              const SizedBox(height: 16),

              AppButton(
                text: 'Skip for now',
                variant: AppButtonVariant.ghost,
                onPressed: _loading ? null : _skip,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
