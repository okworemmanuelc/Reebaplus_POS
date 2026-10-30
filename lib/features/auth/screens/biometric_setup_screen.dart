import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:local_auth/local_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:reebaplus_pos/core/theme/app_decorations.dart'
    show authTextPrimary, authTextMuted;
import 'package:reebaplus_pos/features/settings/screens/settings_screen.dart'
    show kSettingsMaxContentWidth;
import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/theme/fixed_colors.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/features/auth/widgets/onboarding_step_indicator.dart';
import 'package:reebaplus_pos/features/auth/widgets/branded_auth_background.dart';
import 'package:reebaplus_pos/features/auth/widgets/auth_form_kit.dart';
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

  /// Height (base dp, at text scale 1) the one-column layout needs.
  static const double _oneColumnHeight = 640;

  /// Narrowest body that can hold two columns.
  static const double _twoColumnMinWidth = 560;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final textColor = authTextPrimary(context);
    final primary = theme.colorScheme.primary;
    final f = theme.extension<AppFixedColors>() ?? AppFixedColors.light;

    final steps = <Widget>[
      if (widget.isNewBusinessSetup) ...[
        const OnboardingStepIndicator(
          currentStep: 7,
          totalSteps: 7,
          stepLabels: OnboardingStepIndicator.pathALabels,
        ),
        SizedBox(height: context.getRSize(16)),
      ],
    ];
    final intro = <Widget>[
      Icon(AppIcons.biometrics, size: context.getRSize(80), color: primary),
      SizedBox(height: context.getRSize(24)),
      Text(
        'Speed up your login',
        style: context.boldStyle(24).copyWith(color: textColor),
        textAlign: TextAlign.center,
      ),
      SizedBox(height: context.getRSize(12)),
      Text(
        'Use Face ID or Fingerprint to log into Reebaplus POS instantly and securely instead of typing your PIN every time.',
        style: context
            .regularStyle(14)
            .copyWith(color: authTextMuted(context, 0.7), height: 1.5),
        textAlign: TextAlign.center,
      ),
    ];
    final actions = <Widget>[
      if (_errorMessage != null)
        Padding(
          padding: EdgeInsets.only(bottom: context.getRSize(24)),
          child: Text(
            _errorMessage!,
            style: context.regularStyle(13).copyWith(color: f.danger),
            textAlign: TextAlign.center,
          ),
        ),
      AppButton(
        text: 'Enable Biometrics',
        isLoading: _loading,
        onPressed: _enableBiometrics,
      ),
      SizedBox(height: context.getRSize(16)),
      AppButton(
        text: 'Skip for now',
        variant: AppButtonVariant.ghost,
        onPressed: _loading ? null : _skip,
      ),
    ];

    return Scaffold(
      // The body is measured AFTER the safe-area insets: one column when it
      // fits, two (message left, buttons right) only when the height is short
      // and the width can hold them, e.g. a phone sideways.
      body: LayoutBuilder(
        builder: (context, constraints) {
          final pad = MediaQuery.paddingOf(context);
          final availH = constraints.maxHeight - pad.top - pad.bottom;
          final availW = constraints.maxWidth - pad.left - pad.right;
          final scale = MediaQuery.textScalerOf(context).scale(1.0);
          final need = _oneColumnHeight * (scale > 1 ? scale : 1.0);
          final twoColumn = availW >= _twoColumnMinWidth && availH < need;

          return BrandedAuthBackground(
            maxWidth: twoColumn ? kSettingsMaxContentWidth : 480.0,
            child: SafeArea(
              child: twoColumn
                  ? Row(
                      children: [
                        Expanded(
                          child: AuthCenteredScroll(
                            padding: context.rPaddingSymmetric(
                              horizontal: 16,
                              vertical: 12,
                            ),
                            children: [...steps, ...intro],
                          ),
                        ),
                        Expanded(
                          child: AuthCenteredScroll(
                            padding: context.rPaddingSymmetric(
                              horizontal: 16,
                              vertical: 12,
                            ),
                            children: actions,
                          ),
                        ),
                      ],
                    )
                  : AuthCenteredScroll(
                      padding: context.rPaddingSymmetric(
                        horizontal: 28,
                        vertical: 24,
                      ),
                      children: [
                        ...steps,
                        ...intro,
                        SizedBox(height: context.getRSize(40)),
                        ...actions,
                      ],
                    ),
            ),
          );
        },
      ),
    );
  }
}
