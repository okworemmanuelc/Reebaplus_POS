import 'package:flutter/material.dart';
import 'package:reebaplus_pos/core/settings/settings_screen.dart'
    show kSettingsMaxContentWidth;
import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/theme/fixed_colors.dart';
import 'package:reebaplus_pos/core/theme/app_decorations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/features/auth/onboarding/onboarding_draft.dart';
import 'package:reebaplus_pos/features/auth/screens/biometric_setup_screen.dart';
import 'package:reebaplus_pos/features/auth/widgets/onboarding_step_indicator.dart';
import 'package:reebaplus_pos/features/auth/widgets/auth_form_kit.dart';
import 'package:reebaplus_pos/features/auth/widgets/branded_auth_background.dart';
import 'package:reebaplus_pos/features/auth/widgets/pin_keypad.dart';
import 'package:reebaplus_pos/features/auth/widgets/shake_widget.dart';
import 'package:reebaplus_pos/shared/widgets/smooth_route.dart';
import 'package:reebaplus_pos/shared/widgets/reebaplus_logo.dart';

/// Two-phase PIN entry. Two callers:
///   * New-business onboarding wizard — [user] is null, [isNewBusinessSetup]
///     is true. The draft from [onboardingDraftProvider] is committed atomically
///     via [AuthService.completeOnboarding] on PIN confirm; the returned
///     persisted user is then assigned a PIN locally.
///   * Returning user PIN reset / first-time PIN setup — [user] non-null,
///     [isNewBusinessSetup] is false. PIN write only.
class CreatePinScreen extends ConsumerStatefulWidget {
  /// Required in the reset/setup paths. Null in the new-business path — the
  /// user row doesn't exist yet; the draft is committed inside [_advance].
  final UserData? user;
  final bool isNewBusinessSetup;

  const CreatePinScreen({super.key, this.user, this.isNewBusinessSetup = false})
    : assert(
        user != null || isNewBusinessSetup,
        'CreatePinScreen needs either a user (reset/setup) or '
        'isNewBusinessSetup=true (wizard, draft-driven)',
      );

  @override
  ConsumerState<CreatePinScreen> createState() => _CreatePinScreenState();
}

class _CreatePinScreenState extends ConsumerState<CreatePinScreen> {
  final GlobalKey<ShakeWidgetState> _shakeKey = GlobalKey();
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

    // Step tracker so the catch block below can report exactly which
    // await threw. Updated immediately before each step starts; the
    // value left in `step` when an exception bubbles into the catch
    // names the call that failed.
    var step = 'start';
    try {
      // New-business path: commit the wizard draft atomically NOW. The
      // complete_onboarding RPC creates businesses + profiles + settings
      // server-side with onboarding_complete=true, then mirrors them locally
      // in one Drift transaction. Returns the persisted user. No Store is
      // created on either side (#232) — the owner creates their first one
      // in the app.
      //
      // Join/reset paths: widget.user is already the persisted row.
      final UserData persistedUser;
      if (widget.user == null) {
        final draft = draftNotifier.require();
        step = 'completeOnboarding';
        debugPrint(
          '[CreatePinScreen] new-business path: calling '
          'auth.completeOnboarding(businessId=${draft.businessId}, '
          'userId=${draft.userId})',
        );
        persistedUser = await auth.completeOnboarding(draft);
        debugPrint(
          '[CreatePinScreen] completeOnboarding ok: '
          'persistedUser.id=${persistedUser.id}',
        );
        // Wizard is done — drop the draft so a future onboarding starts
        // fresh and so abandoned drafts don't leak across sessions.
        draftNotifier.clear();
      } else {
        persistedUser = widget.user!;
        debugPrint(
          '[CreatePinScreen] join/reset path: '
          'persistedUser.id=${persistedUser.id}',
        );
      }

      step = 'setUserPin';
      debugPrint(
        '[CreatePinScreen] calling auth.setUserPin(${persistedUser.id})',
      );
      await auth.setUserPin(persistedUser.id, _pin);
      debugPrint('[CreatePinScreen] setUserPin ok');

      step = 'getUserById';
      final updatedUser = await db.storesDao.getUserById(persistedUser.id);

      if (!mounted) return;

      if (updatedUser == null) {
        debugPrint(
          '[CreatePinScreen] getUserById returned null for '
          'id=${persistedUser.id} — local users row missing after PIN save',
        );
        setState(() {
          _saving = false;
          _errorMessage = 'Unexpected error. Please try again.';
        });
        return;
      }

      debugPrint('[CreatePinScreen] PIN save flow complete');

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
            ),
          ),
        );
      }
    } catch (e, stack) {
      // Make the user-visible "Failed to save PIN" error trace back to
      // the exact step + exception. Without this log the failure is
      // invisible to anyone reading logs because the catch swallows e.
      debugPrint(
        '[CreatePinScreen] PIN save FAILED at step="$step": '
        '${e.runtimeType}: $e\n$stack',
      );
      if (mounted) {
        setState(() {
          _saving = false;
          _errorMessage = 'Failed to save PIN. Please try again.';
        });
      }
    }
  }

  /// Height (base dp, at text scale 1) the one-column layout needs.
  static const double _oneColumnHeight = 760;

  /// Narrowest body that can hold two columns.
  static const double _twoColumnMinWidth = 560;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      // The body is measured AFTER the safe-area insets: one column when it
      // fits, two (steps and title left, keypad right) only when the height is
      // short and the width can hold them, e.g. a phone sideways.
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
              child: Center(
                child: SingleChildScrollView(
                  padding: twoColumn
                      ? context.rPaddingSymmetric(horizontal: 16, vertical: 8)
                      : context.rPaddingSymmetric(horizontal: 32, vertical: 24),
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 500),
                    child: _saving
                        ? _buildSavingState()
                        : _buildInputState(twoColumn),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildSavingState() {
    final primary = Theme.of(context).colorScheme.primary;
    final textColor = authTextPrimary(context);

    return Column(
      key: const ValueKey('saving'),
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        CircleAvatar(
          radius: context.getRSize(44),
          backgroundColor: primary.withValues(alpha: 0.1),
          child: Icon(
            AppIcons.check,
            size: context.getRSize(48),
            color: primary,
          ),
        ),
        SizedBox(height: context.getRSize(24)),
        Text(
          'PIN Setup Complete',
          style: context.boldStyle(22).copyWith(color: textColor),
        ),
        SizedBox(height: context.getRSize(8)),
        Text(
          'Securing your account...',
          style: context
              .regularStyle(14)
              .copyWith(color: authTextMuted(context, 0.6)),
        ),
      ],
    );
  }

  bool get _isOnboarding => widget.isNewBusinessSetup;

  void _backToCreate() => setState(() {
    _pin = '';
    _firstPin = '';
    _confirming = false;
    _errorMessage = null;
  });

  Widget _stepIndicator() => const OnboardingStepIndicator(
    currentStep: 6,
    totalSteps: 7,
    stepLabels: OnboardingStepIndicator.pathALabels,
  );

  Widget _title() => Text(
    _confirming ? 'Confirm your PIN' : 'Create a PIN',
    textAlign: TextAlign.center,
    style: authTitleStyle(context),
  );

  Widget _welcome() => Text(
    'Welcome, ${widget.user?.name ?? ref.read(onboardingDraftProvider)?.ownerName ?? "there"}!',
    textAlign: TextAlign.center,
    style: context.mediumStyle(15).copyWith(color: authTextMuted(context, 0.8)),
  );

  Widget _subtitle() => Text(
    _confirming
        ? 'Re-enter the same PIN to confirm'
        : 'Choose a 6-digit PIN for quick login',
    style: context
        .regularStyle(13)
        .copyWith(color: authTextMuted(context, 0.6)),
    textAlign: TextAlign.center,
  );

  /// Reserves its height so the layout doesn't jump between phases.
  Widget _reassurance() => SizedBox(
    height: context.getRSize(20),
    child: Opacity(
      opacity: _confirming ? 0.0 : 1.0,
      child: Text(
        'You\'ll use this PIN every time you log in',
        style: context
            .regularStyle(12)
            .copyWith(
              color: _errorMessage != null
                  ? Colors.transparent
                  : authTextMuted(context, 0.4),
              fontStyle: FontStyle.italic,
            ),
        textAlign: TextAlign.center,
      ),
    ),
  );

  Widget _dots() => ShakeWidget(
    key: _shakeKey,
    child: PinDots(filled: _pin.length),
  );

  Widget _error() {
    final f =
        Theme.of(context).extension<AppFixedColors>() ?? AppFixedColors.light;
    return SizedBox(
      height: context.getRSize(20),
      child: _errorMessage != null
          ? Text(
              _errorMessage!,
              style: context.regularStyle(13).copyWith(color: f.danger),
              textAlign: TextAlign.center,
            )
          : null,
    );
  }

  Widget _keypad() => Center(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 280),
      child: PinKeypad(onDigit: _onDigit, onBackspace: _onBackspace),
    ),
  );

  Widget _backLink() => Visibility(
    visible: _confirming,
    maintainSize: true,
    maintainAnimation: true,
    maintainState: true,
    child: TextButton(
      onPressed: _backToCreate,
      style: TextButton.styleFrom(
        minimumSize: const Size(48, kMinInteractiveDimension),
      ),
      child: Text(
        '← Back to create PIN',
        style: context
            .regularStyle(13)
            .copyWith(color: authTextMuted(context, 0.55)),
      ),
    ),
  );

  Widget _buildInputState(bool twoColumn) {
    // One key for both layouts so a rotation doesn't cross-fade two copies of
    // the shake widget (they share a GlobalKey).
    if (twoColumn) {
      return Row(
        key: const ValueKey('input'),
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // Left: where you are and what to do.
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_isOnboarding) ...[
                  _stepIndicator(),
                  SizedBox(height: context.getRSize(12)),
                ],
                _title(),
                SizedBox(height: context.getRSize(4)),
                _welcome(),
                SizedBox(height: context.getRSize(4)),
                _subtitle(),
                SizedBox(height: context.getRSize(12)),
                _dots(),
                SizedBox(height: context.getRSize(8)),
                _error(),
                _backLink(),
              ],
            ),
          ),
          SizedBox(width: context.getRSize(16)),
          // Right: the keypad.
          Expanded(child: _keypad()),
        ],
      );
    }

    return Column(
      key: const ValueKey('input'),
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (_isOnboarding) ...[
          _stepIndicator(),
          SizedBox(height: context.getRSize(16)),
        ],
        ReebaplusLogo(height: context.getRSize(60)),
        SizedBox(height: context.getRSize(12)),
        _title(),
        SizedBox(height: context.getRSize(6)),
        _welcome(),
        SizedBox(height: context.getRSize(4)),
        _subtitle(),
        _reassurance(),
        SizedBox(height: context.getRSize(24)),
        _dots(),
        SizedBox(height: context.getRSize(12)),
        _error(),
        SizedBox(height: context.getRSize(16)),
        _keypad(),
        SizedBox(height: context.getRSize(20)),
        _backLink(),
      ],
    );
  }
}
