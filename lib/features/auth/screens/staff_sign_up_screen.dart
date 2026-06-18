import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:reebaplus_pos/core/data/countries.dart';
import 'package:reebaplus_pos/core/data/nigerian_lgas.dart';
import 'package:reebaplus_pos/core/data/nigerian_states.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/theme/app_decorations.dart';
import 'package:reebaplus_pos/core/utils/notifications.dart';
import 'package:reebaplus_pos/features/auth/widgets/auth_form_kit.dart';
import 'package:reebaplus_pos/features/auth/widgets/branded_auth_background.dart';
import 'package:reebaplus_pos/features/auth/widgets/otp_input.dart';
import 'package:reebaplus_pos/features/auth/widgets/pin_keypad.dart';
import 'package:reebaplus_pos/features/auth/widgets/shake_widget.dart';
import 'package:reebaplus_pos/shared/services/auth_service.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';

/// Master plan §6 — Staff Sign Up. One screen, content fades between 9 steps
/// (invite code → email → OTP → full name → phone → address → create PIN →
/// confirm PIN → "Welcome to {business}"). A small dots indicator sits at the
/// top. State lives in [StaffSignUpDraft]; the redemption
/// (`redeem_invite_code` RPC + local mirror) runs after Confirm PIN, then
/// straight to Home.
///
/// The §6.2 "email already linked to another business → confirm existing PIN"
/// branch is deferred to Phase 2. This Phase 1 flow handles a fresh device
/// PIN setup.
class StaffSignUpScreen extends ConsumerStatefulWidget {
  const StaffSignUpScreen({super.key});

  @override
  ConsumerState<StaffSignUpScreen> createState() => _StaffSignUpScreenState();
}

/// Carries Staff Sign Up state across the step navigation.
class StaffSignUpDraft {
  String code = '';
  String email = '';
  String? businessName;
  String? roleName;

  // Resolved at redemption (from the redeem_invite_code response).
  String? userId;
  String? businessId;
  String? roleId;
  String? storeId;

  String pin = '';

  // Collected in steps 4 & 5.
  String? phone;
  String? streetAddress;
  String? lgaDistrict;
  String? cityState;
  String? country;

  /// Combines the structured location parts into a single address string
  /// matching the format used by [OnboardingDraft.locationCombined].
  String? get locationCombined {
    final parts = [
      streetAddress?.trim(),
      lgaDistrict?.trim(),
      cityState?.trim(),
      country?.trim(),
    ].where((p) => p != null && p.isNotEmpty).toList();
    if (parts.isEmpty) return null;
    return parts.join(', ');
  }
}

class _StaffSignUpScreenState extends ConsumerState<StaffSignUpScreen> {
  // Nine dots — invite code → email → OTP → full name → phone → address →
  // create PIN → confirm PIN → welcome (master plan §6.1).
  static const int _totalSteps = 9;

  // Obvious PINs to block (master plan §6.1). Mirrors ceo_sign_up_screen.dart.
  static const Set<String> _blockedPins = {
    '000000',
    '111111',
    '123456',
    '654321',
    '222222',
    '333333',
  };

  int _step = 0;

  final _draft = StaffSignUpDraft();

  // Step controllers (persist across step navigation so back keeps values).
  final _codeCtrl = TextEditingController();
  final _emailDisplayCtrl = TextEditingController();
  final _otpCtrl = TextEditingController();

  // Step 0 — invite code.
  bool _lookingUp = false;
  String? _codeError;

  // Step 1 — email.
  bool _sendingOtp = false;
  String? _otpSentForEmail; // guards against resending on back/forward

  // Step 3 — full name.
  final _nameCtrl = TextEditingController();
  String? _nameError;

  // Step 2 — OTP.
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

  // Step 4 — phone.
  final _phoneCtrl = TextEditingController();
  String? _phoneError;

  // Step 5 — address. Mirrors the CEO store-details step exactly.
  final _streetCtrl = TextEditingController();
  final _statePlainCtrl = TextEditingController();
  final _lgaPlainCtrl = TextEditingController();
  String _stateValue = '';
  String _lgaValue = '';
  String _countryValue = kDefaultCountry;
  String? _addressError;

  // Steps 6 & 7 — PIN. Distinct shake keys: the create (step 6) and confirm
  // (step 7) PIN bodies are both produced by _buildPinStep() and stay mounted
  // together during the AnimatedSwitcher cross-fade — one shared GlobalKey
  // across two live widgets crashes. One key per sub-step avoids the collision.
  String _pin = '';
  String _firstPin = '';
  String? _pinError;
  final GlobalKey<ShakeWidgetState> _createPinShakeKey = GlobalKey();
  final GlobalKey<ShakeWidgetState> _confirmPinShakeKey = GlobalKey();

  bool _committing = false;

  @override
  void initState() {
    super.initState();
    _otpCtrl.addListener(_onOtpChanged);
    // Pre-populate the phone prefix for the default country (Nigeria).
    _phoneCtrl.text = kCountryDialCodes[kDefaultCountry] ?? '';
  }

  @override
  void dispose() {
    _codeCtrl.dispose();
    _emailDisplayCtrl.dispose();
    _otpCtrl.dispose();
    _nameCtrl.dispose();
    _phoneCtrl.dispose();
    _streetCtrl.dispose();
    _statePlainCtrl.dispose();
    _lgaPlainCtrl.dispose();
    _resendTimer?.cancel();
    _lockoutTimer?.cancel();
    super.dispose();
  }

  // ── Phone formatting ─────────────────────────────────────────────────────

  /// Mirrors [_CeoSignUpScreenState.formatPhoneNumber] exactly.
  String _formatPhoneNumber(String rawNumber, String dialCode) {
    var cleaned = rawNumber.trim().replaceAll(RegExp(r'[\s\-()]+'), '');
    if (cleaned.isEmpty) return '';
    if (cleaned.startsWith('00')) cleaned = '+${cleaned.substring(2)}';
    final hasPlus = cleaned.startsWith('+');
    final digitsOnly = hasPlus ? cleaned.substring(1) : cleaned;
    final dialDigits = dialCode.replaceAll('+', '');
    if (digitsOnly.startsWith(dialDigits)) {
      var local = digitsOnly.substring(dialDigits.length);
      if (local.startsWith('0')) local = local.substring(1);
      return '$dialCode$local';
    } else {
      var local = digitsOnly;
      if (local.startsWith('0')) local = local.substring(1);
      return '$dialCode$local';
    }
  }

  // ── Connectivity ─────────────────────────────────────────────────────────

  /// Redemption writes go to Supabase first, so the whole flow needs the
  /// network. Surface a clear message before any cloud call.
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
            'Joining a business requires an active internet connection. '
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
          _step = 5;
          break;
        case 2:
          _otpCtrl.clear();
          _otpError = null;
          _step = 1;
          break;
        default:
          _step -= 1;
      }
    });
  }

  void _goTo(int step) => setState(() => _step = step);

  // ── Step 0: invite code ──────────────────────────────────────────────────

  Future<void> _submitCode() async {
    final code = _codeCtrl.text.trim().toUpperCase();
    if (!RegExp(r'^[A-Z0-9]{8}$').hasMatch(code)) {
      setState(() => _codeError = 'Enter the 8-character invite code.');
      return;
    }
    if (!await _ensureOnline()) return;
    if (!mounted) return;
    setState(() {
      _codeError = null;
      _lookingUp = true;
    });

    final supabase = ref.read(supabaseClientProvider);
    try {
      final result = await supabase.rpc(
        'lookup_invite_code',
        params: {'p_code': code},
      );
      if (!mounted) return;

      // RETURNS TABLE → a List of row maps. An invalid code still returns one
      // row: {valid: false, ...}. An empty list is treated as invalid too.
      final rows = result is List ? result : const [];
      final row = rows.isNotEmpty ? rows.first as Map<String, dynamic> : null;
      final valid = row != null && row['valid'] == true;

      if (!valid) {
        setState(() {
          _lookingUp = false;
          _codeError =
              'That code is invalid, expired, or already used. Try again.';
        });
        return;
      }

      _draft
        ..code = code
        ..businessName = row['business_name'] as String?
        ..roleName = row['role_name'] as String?
        ..email = (row['email'] as String? ?? '').trim().toLowerCase();
      _emailDisplayCtrl.text = _draft.email;

      setState(() {
        _lookingUp = false;
        _codeError = null;
        _step = 1;
      });
    } catch (e) {
      debugPrint('[StaffSignUp] lookup_invite_code failed: $e');
      if (!mounted) return;
      setState(() {
        _lookingUp = false;
        _codeError = "Couldn't check that code. Please try again.";
      });
    }
  }

  // ── Step 1: email (read-only, send OTP on advance) ───────────────────────

  Future<void> _confirmEmail() async {
    final email = _draft.email;
    if (email.isEmpty) {
      // Shouldn't happen — lookup returned a valid invite with an email.
      setState(() => _step = 0);
      return;
    }
    setState(() => _sendingOtp = true);
    final auth = ref.read(authProvider);
    // Skip the network round-trip if we already sent a code to this email
    // (user stepped back then forward).
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
    if (!mounted) return;
    setState(() => _sendingOtp = false);
    _goTo(2);
  }

  // ── Step 2: OTP ──────────────────────────────────────────────────────────

  void _onOtpChanged() {
    if (_otpError != null) setState(() => _otpError = null);
    if (_otpCtrl.text.trim().length == 6 &&
        !_otpVerifying &&
        !_otpLockedOut &&
        _step == 2) {
      _verifyOtp();
    }
  }

  void _startResendTimer() {
    _resendCountdown = 30; // master plan §6.1: resend after 30 seconds
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
    final error = await ref.read(authProvider).sendOtp(_draft.email);
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
    final error = await auth.verifyOtp(_draft.email, otp);
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
    // redemption at Confirm PIN can call redeem_invite_code. Advance to the
    // full-name step (3).
    await auth.saveAuthMethod('email');
    if (!mounted) return;
    setState(() {
      _otpVerifying = false;
      _otpVerified = true;
    });
    await Future.delayed(const Duration(milliseconds: 500));
    if (!mounted) return;
    setState(() => _otpVerified = false);
    _goTo(3);
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

  // ── Step 3: full name ────────────────────────────────────────────────────

  void _submitName() {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      setState(() => _nameError = 'Please enter your full name.');
      return;
    }
    setState(() {
      _nameError = null;
      _step = 4;
    });
  }

  // ── Step 4: phone ────────────────────────────────────────────────────────

  void _submitPhone() {
    final dialCode = kCountryDialCodes[_countryValue.trim()] ?? '';
    final formatted = _formatPhoneNumber(_phoneCtrl.text, dialCode);
    final digits = formatted.replaceAll(RegExp(r'\D'), '');
    if (digits.length < 8) {
      setState(
        () => _phoneError = 'Enter a valid phone number (at least 8 digits).',
      );
      return;
    }
    _phoneCtrl.text = formatted;
    _draft.phone = formatted;
    setState(() {
      _phoneError = null;
      _step = 5;
    });
  }

  // ── Step 5: address ──────────────────────────────────────────────────────

  void _submitAddress() {
    final street = _streetCtrl.text.trim();
    if (street.isEmpty) {
      setState(() => _addressError = 'Enter your street address.');
      return;
    }
    if (_stateValue.trim().isEmpty) {
      setState(() => _addressError = 'Enter the State / Region.');
      return;
    }
    if (_lgaValue.trim().isEmpty) {
      setState(() => _addressError = 'Enter the Local Government / District.');
      return;
    }
    _draft
      ..streetAddress = street
      ..lgaDistrict = _lgaValue.trim()
      ..cityState = _stateValue.trim()
      ..country = _countryValue.trim();
    setState(() {
      _addressError = null;
      _step = 6;
    });
  }

  // ── Steps 6 & 7: PIN ─────────────────────────────────────────────────────

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

  // ── Commit (redeem + local mirror) ───────────────────────────────────────

  Future<void> _commit() async {
    setState(() => _committing = true);
    _draft.pin = _firstPin;

    // Capture providers before the awaits — setCurrentUser at the end
    // regenerates the navigator key and tears this element down.
    final auth = ref.read(authProvider);
    final db = ref.read(databaseProvider);
    final sync = ref.read(supabaseSyncServiceProvider);
    final supabase = ref.read(supabaseClientProvider);
    final pin = _draft.pin;
    final code = _draft.code;

    try {
      if (!await _ensureOnline()) {
        if (mounted) {
          setState(() {
            _committing = false;
            _pin = '';
            _firstPin = '';
            _step = 6;
          });
        }
        return;
      }

      // Client-minted id so cloud + local Drift agree from the start (mirrors
      // CEO onboarding). The server may already have a users row for this
      // auth user in this business — it returns the canonical id, which we
      // trust over the minted one below.
      final mintedUserId = UuidV7.generate();
      final result = await supabase.rpc(
        'redeem_invite_code',
        params: {
          'p_code': code,
          'p_user_id': mintedUserId,
          'p_name': _nameCtrl.text.trim(),
          'p_phone': _draft.phone,
          'p_address': _draft.locationCombined,
        },
      );

      final rows = result is List ? result : const [];
      if (rows.isEmpty) {
        throw StateError('redeem_invite_code returned no row');
      }
      final row = rows.first as Map<String, dynamic>;
      final userId = row['id'] as String;
      final businessId = row['business_id'] as String;
      final authUserId = row['auth_user_id'] as String?;
      final name = row['name'] as String? ?? '';
      final email = row['email'] as String? ?? _draft.email;
      final phone = row['phone'] as String?;
      final address = row['address'] as String?;
      final storeId = row['store_id'] as String?;
      final roleId = row['role_id'] as String?;

      _draft
        ..userId = userId
        ..businessId = businessId
        ..roleId = roleId
        ..storeId = storeId;

      // Pull first so the parent rows the local mirror references via FK
      // (businesses, stores, roles) exist locally — a freshly-redeemed staff
      // device has an empty Drift DB. Redemption already made this user a
      // member, so tenant RLS now lets the pull read them. The pull also
      // brings down the cloud-canonical users / user_businesses / user_stores
      // rows; the direct writes below are an idempotent mirror over them.
      await sync.pullChanges(businessId);

      // §5 exception #7 — local mirror after a SECURITY DEFINER RPC. Direct
      // table writes (not enqueueUpsert) because AuthService.value is still
      // null here (the resolver returns null, so any DAO calling
      // requireBusinessId() would throw) AND the redeem RPC already wrote
      // canonical cloud state — pushing it back is a no-op round trip.
      // insertOnConflictUpdate keeps this idempotent over whatever the pull
      // already restored.
      // sync-exempt: §5 #7 — staff-sign-up local mirror after the redeem RPC.
      final now = DateTime.now();
      await db.transaction(() async {
        await db
            .into(db.users)
            .insertOnConflictUpdate(
              UsersCompanion.insert(
                id: Value(userId),
                businessId: businessId,
                authUserId: Value(authUserId),
                name: name,
                email: Value(email),
                phone: Value(phone),
                address: Value(address),
                pin: AuthService.setupRequiredPin,
                storeId: Value(storeId),
                lastUpdatedAt: Value(now),
              ),
            );

        if (roleId != null) {
          // Find-or-create the membership locally. UNIQUE (user_id,
          // business_id) — reuse an existing local row's id if the pull
          // already restored it.
          final existingMembership = await db.userBusinessesDao
              .getForUserInBusiness(userId, businessId);
          await db
              .into(db.userBusinesses)
              .insertOnConflictUpdate(
                UserBusinessesCompanion.insert(
                  id: Value(existingMembership?.id ?? UuidV7.generate()),
                  businessId: businessId,
                  userId: userId,
                  roleId: roleId,
                  status: const Value('active'),
                  lastUpdatedAt: Value(now),
                ),
              );
        }

        if (storeId != null) {
          // UNIQUE (user_id, store_id) — reuse the pulled row's id if present.
          final existingStores = await db.userStoresDao.getForUser(userId);
          String? existingStoreRowId;
          for (final s in existingStores) {
            if (s.storeId == storeId) {
              existingStoreRowId = s.id;
              break;
            }
          }
          await db
              .into(db.userStores)
              .insertOnConflictUpdate(
                UserStoresCompanion.insert(
                  id: Value(existingStoreRowId ?? UuidV7.generate()),
                  businessId: businessId,
                  userId: userId,
                  storeId: storeId,
                  lastUpdatedAt: Value(now),
                ),
              );
        }

        // Stamp the local invite_codes row used (used_by_user_id / used_at)
        // if it exists locally — on a fresh staff device the pull may not
        // carry it (it's no longer "active"), so this is best-effort.
        final localInvite = await db.inviteCodesDao.getByCode(code);
        if (localInvite != null) {
          await (db.update(
            db.inviteCodes,
          )..where((t) => t.id.equals(localInvite.id))).write(
            InviteCodesCompanion(
              usedByUserId: Value(userId),
              usedAt: Value(localInvite.usedAt ?? now),
              lastUpdatedAt: Value(now),
            ),
          );
        }
      });

      // Device-local PIN (§5 exception #4) on the canonical users row.
      await auth.setUserPin(userId, pin);

      final localUser = await db.storesDao.getUserById(userId);
      if (localUser == null) {
        throw StateError('local users row missing after redemption');
      }

      if (!mounted) return;
      setState(() => _step = 8);

      // Let the user read "Welcome to {business}" before landing on Home.
      await Future.delayed(const Duration(seconds: 3));
      auth.setCurrentUser(localUser);
    } catch (e, stack) {
      debugPrint('[StaffSignUp] redeem FAILED: ${e.runtimeType}: $e\n$stack');
      // Fall back to cloud hydrate exactly like completeOnboarding: the RPC
      // is idempotent, so on a retry the canonical rows are already cloud-side.
      try {
        final hydrated = await auth.upsertLocalUserFromProfile();
        if (hydrated != null) {
          await sync.pullChanges(hydrated.businessId);
          await auth.setUserPin(hydrated.id, pin);
          final refreshed = await db.storesDao.getUserById(hydrated.id);
          if (refreshed != null) {
            if (!mounted) return;
            setState(() => _step = 8);
            await Future.delayed(const Duration(seconds: 3));
            auth.setCurrentUser(refreshed);
            return;
          }
        }
      } catch (e2, stack2) {
        debugPrint('[StaffSignUp] cloud-hydrate fallback FAILED: $e2\n$stack2');
      }
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
          child: Column(
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
          _StepDots(current: _step, total: _totalSteps),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  Widget _buildStepBody() {
    switch (_step) {
      case 0:
        return _buildCodeStep();
      case 1:
        return _buildEmailStep();
      case 2:
        return _buildOtpStep();
      case 3:
        return _buildNameStep();
      case 4:
        return _buildPhoneStep();
      case 5:
        return _buildAddressStep();
      case 6:
      case 7:
        return _buildPinStep();
      case 8:
        return _buildSuccessStep();
      default:
        return const SizedBox.shrink();
    }
  }

  // ── Step bodies ────────────────────────────────────────────────────────

  Widget _buildCodeStep() {
    return AuthFormShell(
      title: 'Enter your invite code',
      subtitle: 'Your manager shared an 8-character code with you.',
      children: [
        AuthInputCard(
          child: TextField(
            controller: _codeCtrl,
            textCapitalization: TextCapitalization.characters,
            textInputAction: TextInputAction.done,
            autofocus: true,
            maxLength: 8,
            onSubmitted: (_) => _lookingUp ? null : _submitCode(),
            style: TextStyle(
              color: authTextPrimary(context),
              letterSpacing: 4,
              fontWeight: FontWeight.w700,
            ),
            decoration: AppDecorations.authInputDecoration(
              context,
              label: 'Invite code',
              prefixIcon: Icons.confirmation_number_outlined,
            ).copyWith(counterText: ''),
          ),
        ),
        const SizedBox(height: 4),
        AuthErrorText(_codeError),
        const SizedBox(height: 12),
        AppButton(
          text: 'Continue',
          isLoading: _lookingUp,
          onPressed: _lookingUp ? null : _submitCode,
        ),
      ],
    );
  }

  Widget _buildEmailStep() {
    final role = _draft.roleName;
    final business = _draft.businessName;
    return AuthFormShell(
      title: 'Confirm your email',
      subtitle: business != null
          ? "You're joining $business${role != null ? ' as $role' : ''}."
          : 'Confirm the email this invite was sent to.',
      children: [
        AuthInputCard(
          child: TextField(
            controller: _emailDisplayCtrl,
            readOnly: true,
            enabled: false,
            style: TextStyle(color: authTextPrimary(context)),
            decoration: AppDecorations.authInputDecoration(
              context,
              label: 'Email address',
              prefixIcon: Icons.email_outlined,
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          "We'll send a code to ${_draft.email}",
          style: TextStyle(
            fontSize: 13,
            color: authTextPrimary(context).withValues(alpha: 0.6),
          ),
        ),
        const SizedBox(height: 16),
        AppButton(
          text: 'Send code',
          isLoading: _sendingOtp,
          onPressed: _sendingOtp ? null : _confirmEmail,
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
          'Enter the 6-digit code sent to\n${_draft.email}',
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

  Widget _buildNameStep() {
    return AuthFormShell(
      title: 'What should we call you?',
      subtitle: 'Enter your full name — this is how your team will see you.',
      children: [
        AuthInputCard(
          child: TextField(
            controller: _nameCtrl,
            textCapitalization: TextCapitalization.words,
            textInputAction: TextInputAction.done,
            autofocus: true,
            onChanged: (_) {
              if (_nameError != null) setState(() => _nameError = null);
            },
            onSubmitted: (_) => _submitName(),
            style: TextStyle(color: authTextPrimary(context)),
            decoration: AppDecorations.authInputDecoration(
              context,
              label: 'Full name',
              prefixIcon: Icons.person_outline,
            ),
          ),
        ),
        const SizedBox(height: 4),
        AuthErrorText(_nameError),
        const SizedBox(height: 12),
        AppButton(text: 'Continue', onPressed: _submitName),
      ],
    );
  }

  Widget _buildPhoneStep() {
    return AuthFormShell(
      title: 'Your phone number',
      subtitle: 'Enter the number your manager can reach you on.',
      children: [
        AuthInputCard(
          child: TextField(
            controller: _phoneCtrl,
            keyboardType: TextInputType.phone,
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'[0-9+]')),
            ],
            textInputAction: TextInputAction.done,
            autofocus: true,
            onChanged: (_) {
              if (_phoneError != null) setState(() => _phoneError = null);
            },
            onSubmitted: (_) => _submitPhone(),
            style: TextStyle(color: authTextPrimary(context)),
            decoration: AppDecorations.authInputDecoration(
              context,
              label: 'Phone number',
              prefixIcon: Icons.phone_outlined,
            ),
          ),
        ),
        const SizedBox(height: 4),
        AuthErrorText(_phoneError),
        const SizedBox(height: 12),
        AppButton(text: 'Continue', onPressed: _submitPhone),
      ],
    );
  }

  Widget _buildAddressStep() {
    final isNigeria = _countryValue.trim().toLowerCase() == 'nigeria';
    final lgaOptions = isNigeria
        ? (kNigerianLgas[_stateValue] ?? <String>[])
        : <String>[];
    return AuthFormShell(
      title: 'Your address',
      subtitle: 'Where are you based?',
      children: [
        AuthInputCard(
          child: TextField(
            controller: _streetCtrl,
            textCapitalization: TextCapitalization.words,
            autofocus: true,
            onChanged: (_) {
              if (_addressError != null) setState(() => _addressError = null);
            },
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
          child: AutocompleteField(
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
              if (dialCode.isNotEmpty) _phoneCtrl.text = dialCode;
            }),
          ),
        ),
        const SizedBox(height: 12),
        AuthInputCard(
          child: isNigeria
              ? AutocompleteField(
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
              ? AutocompleteField(
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
        const SizedBox(height: 4),
        AuthErrorText(_addressError),
        const SizedBox(height: 12),
        AppButton(text: 'Continue', onPressed: _submitAddress),
      ],
    );
  }

  Widget _buildPinStep() {
    final confirming = _step == 7;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(28, 12, 28, 24),
      child: Column(
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
      ),
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
            'Joining your team…',
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
    // Prefer the live business name (the local row pulled right after invite
    // redemption) so a CEO rename after the invite was generated reflects here;
    // fall back to the name the invite carried.
    final live = ref.watch(currentBusinessNameProvider);
    final business = live.isNotEmpty ? live : _draft.businessName;
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
              business != null
                  ? 'Welcome to $business!'
                  : 'Welcome to the team!',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 28,
                fontWeight: FontWeight.w800,
                color: authTextPrimary(context),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'Taking you to Home…',
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

/// Nine small dots indicating progress (master plan §6: "small dots progress
/// indicator", fading between steps). Mirrors the CEO sign-up indicator.
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
