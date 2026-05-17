import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/features/auth/onboarding/onboarding_draft.dart';
import 'package:reebaplus_pos/features/auth/screens/biometric_setup_screen.dart';
import 'package:reebaplus_pos/features/auth/widgets/onboarding_step_indicator.dart';
import 'package:reebaplus_pos/features/auth/widgets/auth_background.dart';
import 'package:reebaplus_pos/core/theme/app_decorations.dart';
import 'package:flutter/services.dart';
import 'package:reebaplus_pos/shared/widgets/smooth_route.dart';

/// Two-phase PIN entry. Three callers:
///   * New-business onboarding wizard — [user] is null, [isNewBusinessSetup]
///     is true. The draft from [onboardingDraftProvider] is committed atomically
///     via [AuthService.completeOnboarding] on PIN confirm; the returned
///     persisted user is then assigned a PIN locally.
///   * Invite/join flow — [user] is the row created by the redeem RPC,
///     [isJoinFlow] is true. PIN write only.
///   * Returning user PIN reset — [user] non-null, both flags false. PIN
///     write only.
class CreatePinScreen extends ConsumerStatefulWidget {
  /// Required in join/reset paths. Null in the new-business path — the user
  /// row doesn't exist yet; the draft is committed inside [_advance].
  final UserData? user;
  final bool isNewBusinessSetup;
  final bool isJoinFlow;

  const CreatePinScreen({
    super.key,
    this.user,
    this.isNewBusinessSetup = false,
    this.isJoinFlow = false,
  }) : assert(
          user != null || isNewBusinessSetup,
          'CreatePinScreen needs either a user (join/reset) or '
          'isNewBusinessSetup=true (wizard, draft-driven)',
        );

  @override
  ConsumerState<CreatePinScreen> createState() => _CreatePinScreenState();
}

class _CreatePinScreenState extends ConsumerState<CreatePinScreen> {
  final GlobalKey<_ShakeWidgetState> _shakeKey = GlobalKey();
  String _pin = '';
  String _firstPin = '';
  String? _errorMessage;
  bool _confirming = false; // false = create phase, true = confirm phase
  bool _saving = false;

  static const _blockedPins = {
    '000000',
    '111111',
    '123456',
    '654321',
    '222222',
    '333333',
  };

  void _onDigit(String digit) {
    if (_pin.length >= 6 || _saving) return;
    setState(() {
      _pin += digit;
      _errorMessage = null;
    });
    if (_pin.length == 6) {
      // Defer so the 6th dot animates before heavy DB work begins.
      WidgetsBinding.instance.addPostFrameCallback((_) => _advance());
    }
  }

  void _onBackspace() {
    if (_pin.isEmpty || _saving) return;
    setState(() {
      _pin = _pin.substring(0, _pin.length - 1);
      _errorMessage = null;
    });
  }

  Future<void> _advance() async {
    if (!_confirming) {
      if (_blockedPins.contains(_pin)) {
        setState(() {
          _errorMessage = "Please choose a stronger PIN.";
          _pin = '';
        });
        _shakeKey.currentState?.shake();
        return;
      }

      // Move to confirmation phase
      setState(() {
        _firstPin = _pin;
        _pin = '';
        _confirming = true;
      });
      return;
    }

    // Confirm phase — check match
    if (_pin != _firstPin) {
      setState(() {
        _pin = '';
        _firstPin = '';
        _confirming = false;
        _errorMessage = "PINs don't match. Try again.";
      });
      _shakeKey.currentState?.shake();
      return;
    }

    // PINs match — show success state, then commit + save PIN.
    setState(() => _saving = true);

    // Capture providers up front — this method crosses several `await`s and
    // ends in a navigator-key regenerating push. Touching `ref` after any
    // of those awaits would race the riverpod element-unmount invalidation.
    // See plan §"Bug fix" Pattern 1.
    final auth = ref.read(authProvider);
    final db = ref.read(databaseProvider);
    final draftNotifier = ref.read(onboardingDraftProvider.notifier);

    // Allow AnimatedSwitcher to begin its cross-fade before heavy work.
    await Future.delayed(const Duration(milliseconds: 150));
    if (!mounted) return;

    try {
      // New-business path: commit the wizard draft atomically NOW. The
      // complete_onboarding RPC creates businesses + profiles + warehouses
      // + settings server-side with onboarding_complete=true, then mirrors
      // them locally in one Drift transaction. Returns the persisted user.
      //
      // Join/reset paths: widget.user is already the persisted row.
      final UserData persistedUser;
      if (widget.user == null) {
        final draft = draftNotifier.require();
        persistedUser = await auth.completeOnboarding(draft);
        // Wizard is done — drop the draft so a future onboarding starts
        // fresh and so abandoned drafts don't leak across sessions.
        draftNotifier.clear();
      } else {
        persistedUser = widget.user!;
      }

      await auth.setUserPin(persistedUser.id, _pin);

      final updatedUser = await db.warehousesDao.getUserById(persistedUser.id);

      if (!mounted) return;

      if (updatedUser == null) {
        setState(() {
          _saving = false;
          _errorMessage = 'Unexpected error. Please try again.';
        });
        return;
      }

      // Controlled delay (1.2s) to let the user feel the success
      // before transitioning to the main dashboard.
      await Future.delayed(const Duration(milliseconds: 1200));

      // Transition to biometric setup screen, passing updatedUser
      if (mounted) {
        Navigator.of(context).pushReplacement(
          SmoothRoute(
            page: BiometricSetupScreen(
              user: updatedUser,
              isNewBusinessSetup: widget.isNewBusinessSetup,
              isJoinFlow: widget.isJoinFlow,
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _errorMessage = 'Failed to save PIN. Please try again.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final primary = theme.colorScheme.primary;

    return AuthBackground(
      child: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: context.rPaddingSymmetric(horizontal: 32, vertical: 24),
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 500),
              child: _saving
                  ? _buildSavingState(primary)
                  : _buildInputState(primary),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSavingState(Color primary) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textColor = isDark ? Colors.white : Colors.black;

    return Column(
      key: const ValueKey('saving'),
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        CircleAvatar(
          radius: context.getRSize(44),
          backgroundColor: primary.withValues(alpha: 0.1),
          child: Icon(
            Icons.check_rounded,
            size: context.getRSize(48),
            color: primary,
          ),
        ),
        SizedBox(height: context.getRSize(24)),
        Text(
          'PIN Setup Complete',
          style: TextStyle(
            fontSize: context.getRFontSize(22),
            fontWeight: FontWeight.w700,
            color: textColor,
          ),
        ),
        SizedBox(height: context.getRSize(8)),
        Text(
          'Securing your account...',
          style: TextStyle(
            fontSize: context.getRFontSize(14),
            color: textColor.withValues(alpha: 0.6),
          ),
        ),
      ],
    );
  }

  bool get _isOnboarding => widget.isNewBusinessSetup || widget.isJoinFlow;

  Widget _buildInputState(Color primary) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final textColor = isDark ? Colors.white : Colors.black;

    return Column(
      key: const ValueKey('input'),
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (_isOnboarding)
          OnboardingStepIndicator(
            currentStep: widget.isNewBusinessSetup ? 6 : 6,
            totalSteps: widget.isNewBusinessSetup ? 7 : 7,
            stepLabels: widget.isNewBusinessSetup
                ? OnboardingStepIndicator.pathALabels
                : OnboardingStepIndicator.pathBLabels,
          ),
        if (_isOnboarding) SizedBox(height: context.getRSize(16)),
        // Logo
        Image.asset(
          'assets/images/reebaplus_logo.png',
          height: context.getRSize(60),
          color: isDark ? null : primary,
          errorBuilder: (_, __, ___) => Icon(
            Icons.storefront,
            size: context.getRSize(60),
            color: textColor,
          ),
        ),
        SizedBox(height: context.getRSize(12)),

        Text(
          _confirming ? 'Confirm your PIN' : 'Create a PIN',
          style: TextStyle(
            fontSize: context.getRFontSize(22),
            fontWeight: FontWeight.w700,
            color: textColor,
          ),
        ),
        SizedBox(height: context.getRSize(6)),
        Text(
          'Welcome, ${widget.user?.name ?? ref.read(onboardingDraftProvider)?.ownerName ?? "there"}!',
          style: TextStyle(
            fontSize: context.getRFontSize(15),
            color: textColor.withValues(alpha: 0.8),
            fontWeight: FontWeight.w500,
          ),
        ),
        SizedBox(height: context.getRSize(4)),
        Text(
          _confirming
              ? 'Re-enter the same PIN to confirm'
              : 'Choose a 6-digit PIN for quick login',
          style: TextStyle(
            fontSize: context.getRFontSize(13),
            color: textColor.withValues(alpha: 0.6),
          ),
          textAlign: TextAlign.center,
        ),
        SizedBox(
          height: context.getRSize(20), // Exact height for the line + spacing
          child: Opacity(
            opacity: _confirming ? 0.0 : 1.0,
            child: Text(
              'You\'ll use this PIN every time you log in',
              style: TextStyle(
                fontSize: context.getRFontSize(12),
                color: _errorMessage != null
                    ? Colors.transparent
                    : textColor.withValues(alpha: 0.4),
                fontStyle: FontStyle.italic,
              ),
              textAlign: TextAlign.center,
            ),
          ),
        ),
        SizedBox(height: context.getRSize(24)),

        // Six dots
        _ShakeWidget(
          key: _shakeKey,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: List.generate(6, (i) {
              final filled = i < _pin.length;
              return AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                margin: context.rPaddingSymmetric(horizontal: 6),
                width: context.getRSize(14),
                height: context.getRSize(14),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: filled ? primary : textColor.withValues(alpha: 0.05),
                  border: Border.all(
                    color: filled ? primary : textColor.withValues(alpha: 0.2),
                    width: 2,
                  ),
                ),
              );
            }),
          ),
        ),
        SizedBox(height: context.getRSize(12)),

        // Error feedback
        SizedBox(
          height: context.getRSize(20),
          child: _errorMessage != null
              ? Text(
                  _errorMessage!,
                  style: TextStyle(
                    color: const Color(0xFFFF6B6B),
                    fontSize: context.getRFontSize(13),
                  ),
                  textAlign: TextAlign.center,
                )
              : null,
        ),
        SizedBox(height: context.getRSize(16)),

        // Numpad
        ConstrainedBox(
          constraints: BoxConstraints(maxWidth: context.getRSize(240)),
          child: Column(
            children: [
              _buildKeyRow(['1', '2', '3']),
              SizedBox(height: context.getRSize(8)),
              _buildKeyRow(['4', '5', '6']),
              SizedBox(height: context.getRSize(8)),
              _buildKeyRow(['7', '8', '9']),
              SizedBox(height: context.getRSize(8)),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  SizedBox(
                    width: context.getRSize(64),
                    height: context.getRSize(64),
                  ),
                  SizedBox(width: context.getRSize(12)),
                  _KeyBtn(label: '0', onTap: () => _onDigit('0')),
                  SizedBox(width: context.getRSize(12)),
                  _KeyBtn(icon: Icons.backspace_outlined, onTap: _onBackspace),
                ],
              ),
            ],
          ),
        ),

        // Phase indicator / Back button
        SizedBox(height: context.getRSize(20)),
        Visibility(
          visible: _confirming,
          maintainSize: true,
          maintainAnimation: true,
          maintainState: true,
          child: TextButton(
            onPressed: () => setState(() {
              _pin = '';
              _firstPin = '';
              _confirming = false;
              _errorMessage = null;
            }),
            child: Text(
              '← Back to create PIN',
              style: TextStyle(
                color: textColor.withValues(alpha: 0.55),
                fontSize: context.getRFontSize(13),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildKeyRow(List<String> digits) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: digits.map((d) {
        return Padding(
          padding: context.rPaddingSymmetric(horizontal: 6),
          child: _KeyBtn(label: d, onTap: () => _onDigit(d)),
        );
      }).toList(),
    );
  }
}

// ── Keypad button ─────────────────────────────────────────────────────────────

class _KeyBtn extends StatelessWidget {
  final String? label;
  final IconData? icon;
  final VoidCallback onTap;

  const _KeyBtn({this.label, this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final textColor = isDark ? Colors.white : Colors.black;

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

// ── Shake Animation Widget ──────────────────────────────────────────────

class _ShakeWidget extends StatefulWidget {
  final Widget child;
  const _ShakeWidget({required Key key, required this.child}) : super(key: key);

  @override
  _ShakeWidgetState createState() => _ShakeWidgetState();
}

class _ShakeWidgetState extends State<_ShakeWidget>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _animation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 400),
      vsync: this,
    );
    _animation = TweenSequence<double>([
      TweenSequenceItem(tween: Tween(begin: 0, end: -10), weight: 1),
      TweenSequenceItem(tween: Tween(begin: -10, end: 10), weight: 2),
      TweenSequenceItem(tween: Tween(begin: 10, end: -10), weight: 2),
      TweenSequenceItem(tween: Tween(begin: -10, end: 10), weight: 2),
      TweenSequenceItem(tween: Tween(begin: 10, end: 0), weight: 1),
    ]).animate(_controller);
  }

  void shake() {
    _controller.forward(from: 0);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _animation,
      builder: (context, child) => Transform.translate(
        offset: Offset(_animation.value, 0),
        child: child,
      ),
      child: widget.child,
    );
  }
}
