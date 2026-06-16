import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:reebaplus_pos/core/data/countries.dart';
import 'package:reebaplus_pos/core/data/nigerian_lgas.dart';
import 'package:reebaplus_pos/core/data/nigerian_states.dart';
import 'package:reebaplus_pos/core/data/currencies.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/theme/app_decorations.dart';
import 'package:reebaplus_pos/core/utils/notifications.dart';
import 'package:reebaplus_pos/features/auth/onboarding/onboarding_draft.dart';
import 'package:reebaplus_pos/features/auth/widgets/auth_form_kit.dart';
import 'package:reebaplus_pos/features/auth/widgets/branded_auth_background.dart';
import 'package:reebaplus_pos/features/auth/widgets/otp_input.dart';
import 'package:reebaplus_pos/features/auth/widgets/pin_keypad.dart';
import 'package:reebaplus_pos/features/auth/widgets/shake_widget.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';

/// Master plan §5 — CEO Sign Up. One screen, content fades between 9 steps
/// (business name → type → store details → full name → email → OTP →
/// create PIN → confirm PIN → "business is ready"). A small dots indicator
/// sits at the top. State lives in [onboardingDraftProvider]; the atomic
/// commit (`complete_onboarding` RPC + local mirror) runs after Confirm PIN,
/// followed by a roles-carrying pull, then straight to Home.
///
/// Biometric setup is no longer part of this flow (PIVOT_PLAN §10 will wire it
/// into CEO Settings › Security). The §5.2 "email already linked to another
/// business" branch is deferred — this flow handles new-email CEO sign-up.
class CeoSignUpScreen extends ConsumerStatefulWidget {
  /// When non-null, the email has already been verified upstream (the Login
  /// flow's OTP → "No account found" → Create path). The Supabase session
  /// already exists, so the flow skips its own email (step 4) and OTP (step 5)
  /// steps: business name → type → store → full name → create PIN → confirm
  /// PIN → ready (7 steps). When null (the Welcome path) the full 9-step flow
  /// runs and collects + verifies the email itself.
  final String? verifiedEmail;

  const CeoSignUpScreen({super.key, this.verifiedEmail});

  @override
  ConsumerState<CeoSignUpScreen> createState() => _CeoSignUpScreenState();
}

class _CeoSignUpScreenState extends ConsumerState<CeoSignUpScreen> {
  static const int _totalSteps = 9;

  /// All seven master-plan business types (§1.2). Only 'Beverage distributor'
  /// is selectable; the other six are visible but greyed-out as coming soon.
  static const List<({String label, IconData icon, bool comingSoon})>
  _businessTypes = [
    (label: 'Restaurant', icon: Icons.restaurant_rounded, comingSoon: true),
    (
      label: 'Supermarket',
      icon: Icons.local_grocery_store_rounded,
      comingSoon: true,
    ),
    (label: 'Bar', icon: Icons.local_bar_rounded, comingSoon: true),
    (
      label: 'Beverage distributor',
      icon: Icons.sports_bar_rounded,
      comingSoon: false,
    ),
    (label: 'Pharmacy', icon: Icons.local_pharmacy_rounded, comingSoon: true),
    (
      label: 'Building Materials',
      icon: Icons.foundation_rounded,
      comingSoon: true,
    ),
    (label: 'Boutique', icon: Icons.checkroom_rounded, comingSoon: true),
  ];

  // Obvious PINs to block (master plan §5.1). Mirrors create_pin_screen.dart.
  static const Set<String> _blockedPins = {
    '000000',
    '111111',
    '123456',
    '654321',
    '222222',
    '333333',
  };

  int _step = 0;
  bool _booting = true;

  /// True when the email was verified upstream — the email (4) and OTP (5)
  /// steps are skipped.
  bool get _emailSkipped => widget.verifiedEmail != null;

  /// Total dots to show: 7 when the email/OTP steps are skipped, else 9.
  int get _displayTotal => _emailSkipped ? _totalSteps - 2 : _totalSteps;

  /// Maps the internal step index (which keeps the email=4/OTP=5 slots even
  /// when skipped) onto the visible dot index.
  int get _displayStep {
    if (!_emailSkipped) return _step;
    return _step <= 3 ? _step : _step - 2; // 6→4, 7→5, 8→6
  }

  // Step controllers (persist across step navigation so back keeps values).
  final _businessNameCtrl = TextEditingController();
  final _storeNameCtrl = TextEditingController();
  final _storePhoneCtrl = TextEditingController();
  final _storeAddressCtrl = TextEditingController();
  // Plain-text fallback controllers for State and LGA when country ≠ Nigeria.
  final _statePlainCtrl = TextEditingController();
  final _lgaPlainCtrl = TextEditingController();
  final _fullNameCtrl = TextEditingController();
  final _emailCtrl = TextEditingController();
  final _otpCtrl = TextEditingController();

  String? _businessType;
  String _stateValue = '';
  String _lgaValue = '';
  String _countryValue = kDefaultCountry;

  // Per-step inline validation messages.
  String? _businessNameError;
  String? _storeError;
  String? _fullNameError;
  String? _emailError;

  // Email / OTP.
  bool _sendingOtp = false;
  String? _otpSentForEmail; // guards against resending on back/forward
  bool _otpVerifying = false;
  bool _otpVerified = false;
  String? _otpError;
  final GlobalKey<ShakeWidgetState> _otpShakeKey = GlobalKey();
  Timer? _resendTimer;
  int _resendCountdown = 0;
  int _resendAttempts = 0;
  int _otpFailedAttempts = 0;
  bool _otpLockedOut = false;
  DateTime? _lockoutEndTime;
  Timer? _lockoutTimer;

  // PIN.
  String _pin = '';
  String _firstPin = '';
  String? _pinError;
  // Distinct keys: the create (step 6) and confirm (step 7) PIN bodies are
  // both produced by _buildPinStep() and stay mounted together during the
  // AnimatedSwitcher cross-fade — one shared GlobalKey across two live widgets
  // crashes. One key per sub-step avoids the collision.
  final GlobalKey<ShakeWidgetState> _createPinShakeKey = GlobalKey();
  final GlobalKey<ShakeWidgetState> _confirmPinShakeKey = GlobalKey();

  bool _committing = false;

  @override
  void initState() {
    super.initState();
    _otpCtrl.addListener(_onOtpChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) => _bootstrap());
  }

  @override
  void dispose() {
    _businessNameCtrl.dispose();
    _storeNameCtrl.dispose();
    _storePhoneCtrl.dispose();
    _storeAddressCtrl.dispose();
    _statePlainCtrl.dispose();
    _lgaPlainCtrl.dispose();
    _fullNameCtrl.dispose();
    _emailCtrl.dispose();
    _otpCtrl.dispose();
    _resendTimer?.cancel();
    _lockoutTimer?.cancel();
    super.dispose();
  }

  String formatPhoneNumber(String rawNumber, String dialCode) {
    var cleaned = rawNumber.trim().replaceAll(RegExp(r'[\s\-()]+'), '');
    if (cleaned.isEmpty) return '';
    if (cleaned.startsWith('00')) {
      cleaned = '+${cleaned.substring(2)}';
    }
    final hasPlus = cleaned.startsWith('+');
    final digitsOnly = hasPlus ? cleaned.substring(1) : cleaned;

    final dialDigits = dialCode.replaceAll('+', '');

    if (digitsOnly.startsWith(dialDigits)) {
      var local = digitsOnly.substring(dialDigits.length);
      if (local.startsWith('0')) {
        local = local.substring(1);
      }
      return '$dialCode$local';
    } else {
      var local = digitsOnly;
      if (local.startsWith('0')) {
        local = local.substring(1);
      }
      return '$dialCode$local';
    }
  }

  // ── Bootstrap ──────────────────────────────────────────────────────────

  /// Onboarding writes go to Supabase first, so the whole flow needs the
  /// network. Fail-fast before the user fills anything in.
  Future<bool> _ensureOnline() async {
    final result = await Connectivity().checkConnectivity();
    final online =
        !(result.isEmpty || result.every((r) => r == ConnectivityResult.none));
    if (!online && mounted) {
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Internet required'),
          content: const Text(
            'Setting up a business requires an active internet connection. '
            'Please connect and try again.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('OK'),
            ),
          ],
        ),
      );
    }
    return online;
  }

  Future<void> _bootstrap() async {
    final db = ref.read(databaseProvider);
    final draftNotifier = ref.read(onboardingDraftProvider.notifier);
    if (!await _ensureOnline()) {
      if (mounted) Navigator.of(context).pop();
      return;
    }
    // Start from an empty local DB and a fresh draft. Overwrites any prior
    // abandoned draft. clearAllData wipes only Drift tables — the Supabase
    // session (set by the upstream verify on the verifiedEmail path) lives in
    // the SDK and survives, so the commit can still call complete_onboarding.
    await db.clearAllData();
    draftNotifier.start();
    final verified = widget.verifiedEmail;
    if (verified != null) {
      // Email already verified upstream — pre-fill the draft and the field so
      // the commit (which reads draft.email) and any back-nav stay consistent.
      _emailCtrl.text = verified;
      draftNotifier.update((d) => d.email = verified);
    }
    // Pre-populate the phone prefix for Nigeria
    _storePhoneCtrl.text = kCountryDialCodes[kDefaultCountry] ?? '';
    if (mounted) setState(() => _booting = false);
  }

  // ── Navigation ─────────────────────────────────────────────────────────

  void _back() {
    if (_committing || _step == 8) return;
    if (_step == 0) {
      Navigator.of(context).maybePop();
      return;
    }
    setState(() {
      switch (_step) {
        case 7:
          _pin = '';
          _firstPin = '';
          _pinError = null;
          _step = 6;
          break;
        case 6:
          _pin = '';
          _pinError = null;
          // When email/OTP were skipped, step 6 follows full name (step 3).
          _step = _emailSkipped ? 3 : 5;
          break;
        case 5:
          _otpCtrl.clear();
          _otpError = null;
          _step = 4;
          break;
        default:
          _step -= 1;
      }
    });
  }

  void _goTo(int step) => setState(() => _step = step);

  // ── Step 1: business name ────────────────────────────────────────────────

  void _submitBusinessName() {
    final name = _businessNameCtrl.text.trim();
    if (name.length < 2) {
      setState(() => _businessNameError = 'Enter at least 2 characters.');
      return;
    }
    if (!RegExp(r'^[A-Za-z][A-Za-z &-]*$').hasMatch(name)) {
      setState(
        () => _businessNameError =
            'Letters, spaces, "&" and "-" only — no numbers or symbols.',
      );
      return;
    }
    ref
        .read(onboardingDraftProvider.notifier)
        .update((d) => d.businessName = name);
    setState(() => _businessNameError = null);
    _goTo(1);
  }

  // ── Step 2: business type ────────────────────────────────────────────────

  void _submitBusinessType() {
    if (_businessType == null) return;
    // 'Beverage distributor' is the display label; DB canonical is 'Beer distributor'
    // (existing rows use that string — preserves crate gating without a migration).
    final dbType = _businessType == 'Beverage distributor'
        ? 'Beer distributor'
        : _businessType;
    ref
        .read(onboardingDraftProvider.notifier)
        .update((d) => d.businessType = dbType);
    _goTo(2);
  }

  // ── Step 3: store details ────────────────────────────────────────────────

  void _submitStoreDetails() {
    final storeName = _storeNameCtrl.text.trim();
    final phone = _storePhoneCtrl.text.trim();
    final address = _storeAddressCtrl.text.trim();
    if (storeName.length < 2) {
      setState(
        () => _storeError = 'Enter a store name (at least 2 characters).',
      );
      return;
    }
    final dialCode = kCountryDialCodes[_countryValue.trim()] ?? '';
    final formattedPhone = formatPhoneNumber(phone, dialCode);
    final phoneDigits = formattedPhone.replaceAll(RegExp(r'\D'), '');
    if (phoneDigits.length < 8) {
      setState(
        () => _storeError = 'Enter a valid phone number (at least 8 digits).',
      );
      return;
    }
    if (address.isEmpty) {
      setState(() => _storeError = 'Enter the store address.');
      return;
    }
    if (_stateValue.trim().isEmpty) {
      setState(() => _storeError = 'Enter the State / Region.');
      return;
    }
    if (_lgaValue.trim().isEmpty) {
      setState(() => _storeError = 'Enter the Local Government / District.');
      return;
    }
    _storePhoneCtrl.text = formattedPhone;
    ref.read(onboardingDraftProvider.notifier).update((d) {
      d.locationName = storeName;
      d.businessPhone = formattedPhone;
      d.streetAddress = address;
      d.lgaDistrict = _lgaValue.trim();
      d.cityState = _stateValue.trim();
      d.country = _countryValue.trim();
      d.currency = currencyForCountry(_countryValue.trim());
    });
    setState(() => _storeError = null);
    _goTo(3);
  }

  // ── Step 4: full name ────────────────────────────────────────────────────

  void _submitFullName() {
    final name = _fullNameCtrl.text.trim();
    if (name.length < 2) {
      setState(() => _fullNameError = 'Enter at least 2 characters.');
      return;
    }
    if (!RegExp(r"^[A-Za-z][A-Za-z '-]*$").hasMatch(name)) {
      setState(() => _fullNameError = 'Letters only — no numbers or symbols.');
      return;
    }
    if (RegExp(r'(.)\1\1').hasMatch(name)) {
      setState(() => _fullNameError = 'That doesn\'t look like a real name.');
      return;
    }
    ref
        .read(onboardingDraftProvider.notifier)
        .update((d) => d.ownerName = name);
    setState(() => _fullNameError = null);
    // Skip email (4) + OTP (5) when the email was verified upstream.
    _goTo(_emailSkipped ? 6 : 4);
  }

  // ── Step 5: email (send OTP on advance) ──────────────────────────────────

  Future<void> _submitEmail() async {
    final email = _emailCtrl.text.trim().toLowerCase();
    if (!RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(email)) {
      setState(() => _emailError = 'Enter a valid email address.');
      return;
    }
    setState(() {
      _emailError = null;
      _sendingOtp = true;
    });
    final auth = ref.read(authProvider);
    // Skip the network round-trip if we already sent a code to this exact
    // email (user stepped back then forward without changing it).
    if (_otpSentForEmail != email) {
      final error = await auth.sendOtp(email);
      if (!mounted) return;
      if (error != null) {
        setState(() => _sendingOtp = false);
        AppNotification.showError(context, error);
        return;
      }
      _otpSentForEmail = email;
      _startResendTimer();
    }
    ref.read(onboardingDraftProvider.notifier).update((d) => d.email = email);
    if (!mounted) return;
    setState(() => _sendingOtp = false);
    _goTo(5);
  }

  // ── Step 6: OTP ──────────────────────────────────────────────────────────

  void _onOtpChanged() {
    if (_otpError != null) setState(() => _otpError = null);
    if (_otpCtrl.text.trim().length == 6 &&
        !_otpVerifying &&
        !_otpLockedOut &&
        _step == 5) {
      _verifyOtp();
    }
  }

  void _startResendTimer() {
    _resendCountdown = 30; // master plan §5.1: resend after 30 seconds
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

  Future<void> _resendOtp() async {
    if (_resendAttempts >= 3) {
      AppNotification.showError(
        context,
        'Maximum resend attempts reached. Please go back and try again.',
      );
      return;
    }
    setState(() => _sendingOtp = true);
    final error = await ref.read(authProvider).sendOtp(_emailCtrl.text.trim());
    if (!mounted) return;
    setState(() => _sendingOtp = false);
    if (error != null) {
      AppNotification.showError(context, error);
    } else {
      _resendAttempts++;
      AppNotification.showSuccess(context, 'New code sent.');
      _startResendTimer();
    }
  }

  Future<void> _verifyOtp() async {
    final otp = _otpCtrl.text.trim();
    setState(() {
      _otpVerifying = true;
      _otpError = null;
    });
    final auth = ref.read(authProvider);
    final error = await auth.verifyOtp(_emailCtrl.text.trim(), otp);
    if (!mounted) return;

    if (error != null) {
      _otpFailedAttempts++;
      if (_otpFailedAttempts >= 5) {
        final prefs = await SharedPreferences.getInstance();
        final lockoutTime = DateTime.now().add(const Duration(minutes: 30));
        await prefs.setString(
          'otp_lockout_until',
          lockoutTime.toIso8601String(),
        );
        if (!mounted) return;
        setState(() {
          _otpVerifying = false;
          _otpLockedOut = true;
          _lockoutEndTime = lockoutTime;
          _otpError = 'Too many failed attempts. Locked for 30 minutes.';
          _otpCtrl.clear();
        });
        _startLockoutTimer();
      } else {
        setState(() {
          _otpVerifying = false;
          _otpError = 'Invalid code. Please try again.';
          _otpCtrl.clear();
        });
        _otpShakeKey.currentState?.shake();
      }
      return;
    }

    // Verified — Supabase now has an authenticated session, so the
    // commit at Confirm PIN can call complete_onboarding.
    await auth.saveAuthMethod('email');
    if (!mounted) return;
    setState(() {
      _otpVerifying = false;
      _otpVerified = true;
    });
    await Future.delayed(const Duration(milliseconds: 500));
    if (!mounted) return;
    setState(() => _otpVerified = false);
    _goTo(6);
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
          _otpLockedOut = false;
          _otpFailedAttempts = 0;
          _otpError = null;
        });
        t.cancel();
      } else {
        setState(() {});
      }
    });
  }

  // ── Steps 7 & 8: PIN ─────────────────────────────────────────────────────

  void _onPinDigit(String digit) {
    if (_committing || _pin.length >= 6) return;
    setState(() {
      _pin += digit;
      _pinError = null;
    });
    if (_pin.length == 6) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _onPinComplete());
    }
  }

  void _onPinBackspace() {
    if (_committing || _pin.isEmpty) return;
    setState(() {
      _pin = _pin.substring(0, _pin.length - 1);
      _pinError = null;
    });
  }

  void _onPinComplete() {
    if (_step == 6) {
      if (_blockedPins.contains(_pin)) {
        setState(() {
          _pinError = 'Please choose a stronger PIN.';
          _pin = '';
        });
        // Stay on step 6 — the create body is mounted, shake synchronously.
        _createPinShakeKey.currentState?.shake();
        return;
      }
      setState(() {
        _firstPin = _pin;
        _pin = '';
        _step = 7;
      });
      return;
    }
    // Confirm phase (step 7).
    if (_pin != _firstPin) {
      setState(() {
        _pin = '';
        _firstPin = '';
        _pinError = "PINs don't match. Try again.";
        _step = 6;
      });
      // We just switched back to step 6; the create body isn't mounted yet at
      // this synchronous point, so shake it after the frame lands.
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _createPinShakeKey.currentState?.shake(),
      );
      return;
    }
    _commit();
  }

  // ── Commit ───────────────────────────────────────────────────────────────

  Future<void> _commit() async {
    setState(() => _committing = true);

    // Capture providers before the awaits — setCurrentUser at the end
    // regenerates the navigator key and tears this element down.
    final auth = ref.read(authProvider);
    final db = ref.read(databaseProvider);
    final sync = ref.read(supabaseSyncServiceProvider);
    final nav = ref.read(navigationProvider);
    final draftNotifier = ref.read(onboardingDraftProvider.notifier);
    final pin = _firstPin;

    try {
      final draft = draftNotifier.require();
      // Feed the §5-dropped fields safe defaults before the commit. Currency
      // and businessPhone were set from step 3.
      draft.businessEmail = draft.email;
      draft.timezone = 'Africa/Lagos';
      draft.taxRegNumber = null;

      final persistedUser = await auth.completeOnboarding(draft);
      await auth.setUserPin(persistedUser.id, pin);
      final updatedUser = await db.storesDao.getUserById(persistedUser.id);
      if (updatedUser == null) {
        throw StateError('local users row missing after PIN save');
      }
      // Only drop the draft once all critical work has landed. The commit is
      // idempotent (ON CONFLICT), so a mid-failure retry can safely re-run it
      // as long as the draft survives.
      draftNotifier.clear();

      // Post-onboarding pull so the 4 seeded roles (+ permissions/settings/
      // memberships) land locally before Home renders. Non-fatal: if it
      // fails, setCurrentUser fires another background pull anyway.
      try {
        await sync.pullChanges(updatedUser.businessId);
      } catch (e) {
        debugPrint('[CeoSignUp] post-onboarding pull failed (non-fatal): $e');
      }

      if (!mounted) return;
      setState(() => _step = 8);

      // Let the user read "your business is ready" before landing on Home.
      await Future.delayed(const Duration(seconds: 3));
      // Auto-open the Add Product sheet on first Home frame (preserved from
      // the old success screen), then hand off to the authed shell.
      nav.requestAutoShowAddProductSheet();
      auth.setCurrentUser(updatedUser);
    } catch (e, stack) {
      debugPrint('[CeoSignUp] commit FAILED: ${e.runtimeType}: $e\n$stack');
      if (mounted) {
        setState(() {
          _committing = false;
          _pin = '';
          _firstPin = '';
          _pinError = 'Something went wrong. Please re-enter your PIN.';
          _step = 6;
        });
      }
    }
  }

  // ── Build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      body: BrandedAuthBackground(
        child: SafeArea(
          child: _booting
              ? const SizedBox.shrink()
              : Column(
                  children: [
                    _buildTopBar(),
                    Expanded(
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 300),
                        child: KeyedSubtree(
                          key: ValueKey(_step),
                          child: _buildStepBody(),
                        ),
                      ),
                    ),
                  ],
                ),
        ),
      ),
    );
  }

  Widget _buildTopBar() {
    final showBack = _step != 8 && !_committing;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Column(
        children: [
          SizedBox(
            height: 40,
            child: Row(
              children: [
                Opacity(
                  opacity: showBack ? 1 : 0,
                  child: IconButton(
                    icon: Icon(
                      Icons.arrow_back_ios,
                      color: authTextPrimary(context),
                      size: 20,
                    ),
                    onPressed: showBack ? _back : null,
                  ),
                ),
              ],
            ),
          ),
          _StepDots(current: _displayStep, total: _displayTotal),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  Widget _buildStepBody() {
    switch (_step) {
      case 0:
        return _buildBusinessNameStep();
      case 1:
        return _buildBusinessTypeStep();
      case 2:
        return _buildStoreDetailsStep();
      case 3:
        return _buildFullNameStep();
      case 4:
        return _buildEmailStep();
      case 5:
        return _buildOtpStep();
      case 6:
      case 7:
        return _buildPinStep();
      case 8:
        return _buildSuccessStep();
      default:
        return const SizedBox.shrink();
    }
  }

  // Shared scrollable shell for form-style steps.
  // ── Step bodies ──────────────────────────────────────────────────────────

  Widget _buildBusinessNameStep() {
    return AuthFormShell(
      title: "What's your business called?",
      subtitle: 'This is the name your customers will see on receipts.',
      children: [
        AuthInputCard(
          child: TextField(
            controller: _businessNameCtrl,
            textCapitalization: TextCapitalization.words,
            textInputAction: TextInputAction.done,
            autofocus: true,
            onSubmitted: (_) => _submitBusinessName(),
            style: TextStyle(color: authTextPrimary(context)),
            decoration: AppDecorations.authInputDecoration(
              context,
              label: 'Business name',
              prefixIcon: Icons.storefront_outlined,
            ),
          ),
        ),
        const SizedBox(height: 4),
        AuthErrorText(_businessNameError),
        const SizedBox(height: 12),
        AppButton(text: 'Continue', onPressed: _submitBusinessName),
      ],
    );
  }

  Widget _buildBusinessTypeStep() {
    return AuthFormShell(
      title: 'What type of business?',
      subtitle: 'Pick the one that fits best.',
      children: [
        ..._businessTypes.map((t) {
          final selected = _businessType == t.label;
          return Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: _TypeCard(
              label: t.label,
              icon: t.icon,
              selected: selected,
              comingSoon: t.comingSoon,
              onTap: t.comingSoon
                  ? null
                  : () => setState(() => _businessType = t.label),
            ),
          );
        }),
        const SizedBox(height: 8),
        AppButton(
          text: 'Continue',
          onPressed: _businessType == null ? null : _submitBusinessType,
        ),
      ],
    );
  }

  Widget _buildStoreDetailsStep() {
    final currency = currencyForCountry(_countryValue.trim());
    final isNigeria = _countryValue.trim().toLowerCase() == 'nigeria';
    final lgaOptions = isNigeria
        ? (kNigerianLgas[_stateValue] ?? <String>[])
        : <String>[];
    return AuthFormShell(
      title: 'Your first store',
      subtitle: 'You can add more stores later.',
      children: [
        AuthInputCard(
          child: TextField(
            controller: _storeNameCtrl,
            textCapitalization: TextCapitalization.words,
            style: TextStyle(color: authTextPrimary(context)),
            decoration:
                AppDecorations.authInputDecoration(
                  context,
                  label: 'Store name',
                  prefixIcon: Icons.store_mall_directory_outlined,
                ).copyWith(
                  hintText: 'Abuja Branch',
                  hintStyle: TextStyle(
                    color: authTextPrimary(context).withValues(alpha: 0.35),
                  ),
                ),
          ),
        ),
        const SizedBox(height: 12),
        AuthInputCard(
          child: TextField(
            controller: _storePhoneCtrl,
            keyboardType: TextInputType.phone,
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'[0-9+]')),
            ],
            style: TextStyle(color: authTextPrimary(context)),
            decoration: AppDecorations.authInputDecoration(
              context,
              label: 'Store phone number',
              prefixIcon: Icons.phone_outlined,
            ),
          ),
        ),
        const SizedBox(height: 12),
        AuthInputCard(
          child: TextField(
            controller: _storeAddressCtrl,
            textCapitalization: TextCapitalization.words,
            style: TextStyle(color: authTextPrimary(context)),
            decoration: AppDecorations.authInputDecoration(
              context,
              label: 'Street address',
              prefixIcon: Icons.location_on_outlined,
            ),
          ),
        ),
        const SizedBox(height: 12),
        AuthInputCard(
          child: _AutocompleteField(
            label: 'Country',
            icon: Icons.public_outlined,
            initial: _countryValue,
            options: kCountries,
            onChanged: (v) => setState(() {
              _countryValue = v;
              _stateValue = '';
              _lgaValue = '';
              _statePlainCtrl.clear();
              _lgaPlainCtrl.clear();
              final dialCode = kCountryDialCodes[v] ?? '';
              _storePhoneCtrl.text = dialCode;
            }),
          ),
        ),
        const SizedBox(height: 12),
        AuthInputCard(
          child: isNigeria
              ? _AutocompleteField(
                  key: const ValueKey('state_ng'),
                  label: 'State / Region',
                  icon: Icons.map_outlined,
                  initial: _stateValue,
                  options: kNigerianStates,
                  onChanged: (v) => setState(() {
                    _stateValue = v;
                    _lgaValue = '';
                    _lgaPlainCtrl.clear();
                  }),
                )
              : TextField(
                  controller: _statePlainCtrl,
                  textCapitalization: TextCapitalization.words,
                  style: TextStyle(color: authTextPrimary(context)),
                  onChanged: (v) => setState(() {
                    _stateValue = v;
                    _lgaValue = '';
                  }),
                  decoration: AppDecorations.authInputDecoration(
                    context,
                    label: 'State / Region',
                    prefixIcon: Icons.map_outlined,
                  ),
                ),
        ),
        const SizedBox(height: 12),
        AuthInputCard(
          child: isNigeria
              ? _AutocompleteField(
                  key: ValueKey('lga_$_stateValue'),
                  label: 'Local Government / District',
                  icon: Icons.account_balance_outlined,
                  initial: _lgaValue,
                  options: lgaOptions,
                  onChanged: (v) => _lgaValue = v,
                )
              : TextField(
                  controller: _lgaPlainCtrl,
                  textCapitalization: TextCapitalization.words,
                  style: TextStyle(color: authTextPrimary(context)),
                  onChanged: (v) => _lgaValue = v,
                  decoration: AppDecorations.authInputDecoration(
                    context,
                    label: 'District (optional)',
                    prefixIcon: Icons.account_balance_outlined,
                  ),
                ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Icon(
              Icons.payments_outlined,
              size: 18,
              color: authTextPrimary(context).withValues(alpha: 0.6),
            ),
            const SizedBox(width: 8),
            Text(
              'Currency: $currency',
              style: TextStyle(
                color: authTextPrimary(context).withValues(alpha: 0.75),
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(width: 6),
            Text(
              '(editable later in Business Info)',
              style: TextStyle(
                color: authTextPrimary(context).withValues(alpha: 0.45),
                fontSize: 12,
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        AuthErrorText(_storeError),
        const SizedBox(height: 12),
        AppButton(text: 'Continue', onPressed: _submitStoreDetails),
      ],
    );
  }

  Widget _buildFullNameStep() {
    return AuthFormShell(
      title: "What's your name?",
      subtitle: "You'll be set up as the CEO of this business.",
      children: [
        AuthInputCard(
          child: TextField(
            controller: _fullNameCtrl,
            textCapitalization: TextCapitalization.words,
            textInputAction: TextInputAction.done,
            autofocus: true,
            onSubmitted: (_) => _submitFullName(),
            style: TextStyle(color: authTextPrimary(context)),
            decoration: AppDecorations.authInputDecoration(
              context,
              label: 'Full name',
              prefixIcon: Icons.person_outline,
            ),
          ),
        ),
        const SizedBox(height: 4),
        AuthErrorText(_fullNameError),
        const SizedBox(height: 12),
        AppButton(text: 'Continue', onPressed: _submitFullName),
      ],
    );
  }

  Widget _buildEmailStep() {
    return AuthFormShell(
      title: 'Your email',
      subtitle: "We'll send a 6-digit code to confirm it's you.",
      children: [
        AuthInputCard(
          child: TextField(
            controller: _emailCtrl,
            keyboardType: TextInputType.emailAddress,
            textInputAction: TextInputAction.done,
            autofocus: true,
            onSubmitted: (_) => _sendingOtp ? null : _submitEmail(),
            style: TextStyle(color: authTextPrimary(context)),
            decoration: AppDecorations.authInputDecoration(
              context,
              label: 'Email address',
              prefixIcon: Icons.email_outlined,
            ),
          ),
        ),
        const SizedBox(height: 4),
        AuthErrorText(_emailError),
        const SizedBox(height: 12),
        AppButton(
          text: 'Send code',
          isLoading: _sendingOtp,
          onPressed: _sendingOtp ? null : _submitEmail,
        ),
      ],
    );
  }

  Widget _buildOtpStep() {
    return AuthCenteredScroll(
      children: [
        Text(
          'Check your email',
          style: TextStyle(
            fontSize: 26,
            fontWeight: FontWeight.w800,
            color: authTextPrimary(context),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'Enter the 6-digit code sent to\n${_emailCtrl.text.trim()}',
          style: TextStyle(
            fontSize: 15,
            height: 1.4,
            color: authTextPrimary(context).withValues(alpha: 0.65),
          ),
        ),
        const SizedBox(height: 28),
        ShakeWidget(
          key: _otpShakeKey,
          child: OtpBoxRow(
            controller: _otpCtrl,
            hasError: _otpError != null,
            ignorePointers: _otpLockedOut,
            readOnly: _otpVerifying,
            textColor: authTextPrimary(context),
            onSubmit: () {
              if (_otpCtrl.text.trim().length == 6) _verifyOtp();
            },
          ),
        ),
        const SizedBox(height: 12),
        Center(
          child: Text(
            'Code expires in 5 minutes',
            style: TextStyle(
              color: authTextPrimary(context).withValues(alpha: 0.5),
              fontSize: 13,
            ),
          ),
        ),
        const SizedBox(height: 8),
        Center(child: AuthErrorText(_otpError)),
        const SizedBox(height: 8),
        if (_otpVerified)
          const AppButton(
            text: 'Verified  ✓',
            variant: AppButtonVariant.success,
            onPressed: null,
          )
        else
          AppButton(
            text: 'Verify',
            isLoading: _otpVerifying,
            onPressed: _otpCtrl.text.trim().length == 6 && !_otpLockedOut
                ? _verifyOtp
                : null,
          ),
        const SizedBox(height: 16),
        Center(
          child: _resendCountdown > 0
              ? Text(
                  'Resend code in 0:${_resendCountdown.toString().padLeft(2, '0')}',
                  style: TextStyle(
                    color: authTextPrimary(context).withValues(alpha: 0.5),
                    fontSize: 13,
                  ),
                )
              : TextButton(
                  onPressed: (_sendingOtp || _otpLockedOut) ? null : _resendOtp,
                  child: const Text('Resend code'),
                ),
        ),
      ],
    );
  }

  Widget _buildPinStep() {
    final confirming = _step == 7;
    return AuthCenteredScroll(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        if (_committing)
          _buildCommitting()
        else ...[
          Text(
            confirming ? 'Confirm your PIN' : 'Create a PIN',
            style: TextStyle(
              fontSize: 26,
              fontWeight: FontWeight.w800,
              color: authTextPrimary(context),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            confirming
                ? 'Re-enter the same 6-digit PIN to confirm.'
                : 'Choose a 6-digit PIN you\'ll use to log in.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 15,
              color: authTextPrimary(context).withValues(alpha: 0.65),
            ),
          ),
          const SizedBox(height: 28),
          ShakeWidget(
            key: confirming ? _confirmPinShakeKey : _createPinShakeKey,
            child: PinDots(filled: _pin.length),
          ),
          const SizedBox(height: 12),
          AuthErrorText(_pinError),
          const SizedBox(height: 12),
          PinKeypad(onDigit: _onPinDigit, onBackspace: _onPinBackspace),
        ],
      ],
    );
  }

  Widget _buildCommitting() {
    return Padding(
      padding: const EdgeInsets.only(top: 60),
      child: Column(
        children: [
          CircleAvatar(
            radius: 44,
            backgroundColor: Theme.of(
              context,
            ).colorScheme.primary.withValues(alpha: 0.12),
            child: Icon(
              Icons.check_rounded,
              size: 48,
              color: Theme.of(context).colorScheme.primary,
            ),
          ),
          const SizedBox(height: 24),
          Text(
            'Setting up your business…',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w700,
              color: authTextPrimary(context),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSuccessStep() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: Colors.greenAccent.withValues(alpha: 0.15),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.check_circle_rounded,
                color: Colors.greenAccent,
                size: 80,
              ),
            ),
            const SizedBox(height: 32),
            Text(
              'Welcome, your business is ready!',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 28,
                fontWeight: FontWeight.w800,
                color: authTextPrimary(context),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'Taking you to your dashboard…',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 15,
                color: authTextPrimary(context).withValues(alpha: 0.65),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Small private widgets ────────────────────────────────────────────────

/// Nine small dots indicating progress (master plan §5: "small dots progress
/// indicator", fading between steps).
class _StepDots extends StatelessWidget {
  final int current;
  final int total;

  const _StepDots({required this.current, required this.total});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(total, (i) {
        final active = i <= current;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          margin: const EdgeInsets.symmetric(horizontal: 3),
          width: i == current ? 22 : 8,
          height: 8,
          decoration: BoxDecoration(
            color: active
                ? Theme.of(context).colorScheme.primary
                : authTextPrimary(context).withValues(alpha: 0.18),
            borderRadius: BorderRadius.circular(4),
          ),
        );
      }),
    );
  }
}

class _TypeCard extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool selected;
  final bool comingSoon;
  final VoidCallback? onTap;

  const _TypeCard({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
    this.comingSoon = false,
  });

  @override
  Widget build(BuildContext context) {
    final card = Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: selected
                ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.12)
                : Theme.of(context).colorScheme.surface.withValues(alpha: 0.6),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: selected
                  ? Theme.of(context).colorScheme.primary
                  : authTextPrimary(context).withValues(alpha: 0.12),
              width: selected ? 2 : 1,
            ),
          ),
          child: Row(
            children: [
              Icon(
                icon,
                color: selected
                    ? Theme.of(context).colorScheme.primary
                    : authTextPrimary(context),
                size: 26,
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(
                    color: authTextPrimary(context),
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (selected)
                Icon(
                  Icons.check_circle_rounded,
                  color: Theme.of(context).colorScheme.primary,
                  size: 22,
                ),
              if (comingSoon)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: authTextPrimary(context).withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    'Coming soon',
                    style: TextStyle(
                      color: authTextPrimary(context).withValues(alpha: 0.55),
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );

    if (comingSoon) return Opacity(opacity: 0.5, child: card);
    return card;
  }
}

/// A searchable text field backed by Flutter's native [Autocomplete]. Used for
/// the state and country fields (master plan §5.1). Accepts free text too —
/// the options are suggestions, not a hard constraint.
class _AutocompleteField extends StatelessWidget {
  final String label;
  final IconData icon;
  final String initial;
  final List<String> options;
  final ValueChanged<String> onChanged;

  const _AutocompleteField({
    super.key,
    required this.label,
    required this.icon,
    required this.initial,
    required this.options,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Autocomplete<String>(
      initialValue: TextEditingValue(text: initial),
      optionsBuilder: (value) {
        final q = value.text.trim().toLowerCase();
        if (q.isEmpty) return options;
        return options.where((o) => o.toLowerCase().contains(q));
      },
      onSelected: onChanged,
      fieldViewBuilder: (context, controller, focusNode, onFieldSubmitted) {
        return TextField(
          controller: controller,
          focusNode: focusNode,
          textCapitalization: TextCapitalization.words,
          onChanged: onChanged,
          onSubmitted: (_) => onFieldSubmitted(),
          style: TextStyle(color: authTextPrimary(context)),
          decoration: AppDecorations.authInputDecoration(
            context,
            label: label,
            prefixIcon: icon,
          ),
        );
      },
      optionsViewBuilder: (context, onSelected, opts) {
        return Align(
          alignment: Alignment.topLeft,
          child: Material(
            color: Theme.of(context).colorScheme.surface,
            elevation: 4,
            borderRadius: BorderRadius.circular(10),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 220, maxWidth: 320),
              child: ListView(
                padding: EdgeInsets.zero,
                shrinkWrap: true,
                children: opts
                    .map(
                      (o) => InkWell(
                        onTap: () => onSelected(o),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 12,
                          ),
                          child: Text(
                            o,
                            style: TextStyle(color: authTextPrimary(context)),
                          ),
                        ),
                      ),
                    )
                    .toList(),
              ),
            ),
          ),
        );
      },
    );
  }
}
