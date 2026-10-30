import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:reebaplus_pos/features/auth/staff_redeem_failure_message.dart';
import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:reebaplus_pos/core/data/countries.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/theme/app_decorations.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/theme/fixed_colors.dart';
import 'package:reebaplus_pos/core/utils/name_case.dart';
import 'package:reebaplus_pos/core/utils/notifications.dart';
import 'package:reebaplus_pos/features/auth/widgets/auth_form_kit.dart';
import 'package:reebaplus_pos/features/auth/widgets/branded_auth_background.dart';
import 'package:reebaplus_pos/features/auth/widgets/otp_input.dart';
import 'package:reebaplus_pos/features/auth/widgets/pin_keypad.dart';
import 'package:reebaplus_pos/features/auth/widgets/shake_widget.dart';
import 'package:reebaplus_pos/features/auth/widgets/sign_up_step_dots.dart';
import 'package:reebaplus_pos/features/settings/screens/settings_screen.dart'
    show kSettingsMaxContentWidth;
import 'package:reebaplus_pos/core/utils/responsive.dart';
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
  final int? initialStep;
  const StaffSignUpScreen({super.key, @visibleForTesting this.initialStep});

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
  String? country;

  /// Combines the structured location parts into a single address string
  /// matching the format used by [OnboardingDraft.locationCombined]
  /// ("street, country" — no state / LGA segments).
  String? get locationCombined {
    final parts = [
      streetAddress?.trim(),
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

  late int _step = widget.initialStep ?? 0;

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
  String _countryValue = '';

  /// The dial code for the resolved [_countryValue]. Renders as a read-only
  /// affix beside [_phoneCtrl].
  String _dialCode = '';
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
  }

  @override
  void dispose() {
    _codeCtrl.dispose();
    _emailDisplayCtrl.dispose();
    _otpCtrl.dispose();
    _nameCtrl.dispose();
    _phoneCtrl.dispose();
    _streetCtrl.dispose();
    _resendTimer?.cancel();
    _lockoutTimer?.cancel();
    super.dispose();
  }

  // ── Phone formatting ─────────────────────────────────────────────────────

  /// Mirrors `_CeoSignUpScreenState.formatPhoneNumber` exactly: joins the
  /// local digits to [dialCode], stripping only a leading trunk zero. It does
  /// not look for [dialCode] at the front of the input — see the CEO screen
  /// for why that detection was removed.
  String _formatPhoneNumber(String rawNumber, String dialCode) {
    var local = rawNumber.trim().replaceAll(RegExp(r'[\s\-()]+'), '');
    if (local.isEmpty) return '';
    if (local.startsWith('0')) local = local.substring(1);
    return '$dialCode$local';
  }

  /// Swaps the dial-code prefix when the country changes.
  ///
  /// The phone box holds only local digits, so swapping country updates the
  /// [_dialCode] affix without touching or wiping the typed digits.
  void _applyDialCode(String country) {
    final next = kCountryDialCodes[country.trim()] ?? '';
    if (next == _dialCode) return;
    _dialCode = next;
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
    final name = toNameCase(_nameCtrl.text);
    _nameCtrl.text = name;
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
    final country = _countryValue.trim();
    if (country.isEmpty || !kCountryDialCodes.containsKey(country)) {
      setState(() => _phoneError = 'Choose a valid country from the list.');
      return;
    }
    final dialCode = _dialCode;
    final formatted = _formatPhoneNumber(_phoneCtrl.text, dialCode);
    final digits = formatted.replaceAll(RegExp(r'\D'), '');
    if (digits.length < 8) {
      setState(
        () => _phoneError = 'Enter a valid phone number (at least 8 digits).',
      );
      return;
    }
    _draft.phone = formatted;
    _draft.country = country;
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
    if (_countryValue.trim().isEmpty) {
      setState(() => _addressError = 'Enter the country.');
      return;
    }
    _draft
      ..streetAddress = street
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
          'p_name': toNameCase(_nameCtrl.text),
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

      // §6.2 / invariant #9 — the signed-in email already belongs to ANOTHER
      // business. The server now rejects this cleanly (P0001) instead of
      // letting the INSERT violate the global users_auth_user_id_key (raw
      // 23505). Surface a clear message and do NOT run the cloud-hydrate
      // fallback below: that mirrors the user's *existing* (other-business)
      // profile and would FK-fail locally because this device never onboarded
      // that business. (The raw constraint name is matched too as a backstop in
      // case an older RPC without the guard is still deployed.)
      final msg = e.toString().toLowerCase();
      final alreadyLinkedElsewhere =
          msg.contains('already linked to another business') ||
          msg.contains('users_auth_user_id_key');
      if (alreadyLinkedElsewhere) {
        if (mounted) {
          setState(() {
            _committing = false;
            _pin = '';
            _firstPin = '';
            _pinError =
                'This email already belongs to another business. '
                'Use a different email to join this one.';
            _step = 6;
          });
        }
        return;
      }

      // #90: the plan's staff cap is full (server trigger plan_limit_staff).
      // Friendly upgrade message; no hydrate fallback (nothing was created).
      final planMsg = staffRedeemPlanLimitMessage(e);
      if (planMsg != null) {
        if (mounted) {
          setState(() {
            _committing = false;
            _pin = '';
            _firstPin = '';
            _pinError = planMsg;
            _step = 6;
          });
        }
        return;
      }

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
        // The hydrate path can also surface the cap (e.g. a queued membership
        // upsert refused by the server).
        final hydrateMsg = staffRedeemPlanLimitMessage(e2);
        if (hydrateMsg != null && mounted) {
          setState(() {
            _committing = false;
            _pin = '';
            _firstPin = '';
            _pinError = hydrateMsg;
            _step = 6;
          });
          return;
        }
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
    // The PIN steps go two-column when one column won't fit the measured
    // height (a phone sideways); everything else scrolls inside the 480 column.
    return LayoutBuilder(
      builder: (context, constraints) {
        final mq = MediaQuery.of(context);
        final bodyHeight = constraints.maxHeight - mq.padding.vertical;
        final isPinStep = _step == 6 || _step == 7;
        final twoColumn =
            isPinStep &&
            !_committing &&
            bodyHeight < _pinOneColumnHeight &&
            constraints.maxWidth - mq.padding.horizontal >= _pinTwoColumnWidth;
        return Scaffold(
          resizeToAvoidBottomInset: false,
          backgroundColor: Theme.of(context).scaffoldBackgroundColor,
          body: BrandedAuthBackground(
            maxWidth: twoColumn ? kSettingsMaxContentWidth : 480.0,
            child: SafeArea(
              child: Column(
                children: [
                  _buildTopBar(compact: bodyHeight < _compactBarHeight),
                  Expanded(
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 300),
                      child: KeyedSubtree(
                        key: ValueKey(_step),
                        child: _buildStepBody(twoColumn: twoColumn),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  /// Measured body height under which the top bar drops the dots for a
  /// one-line "Step n of N" label.
  static const double _compactBarHeight = 520;

  /// Measured body height under which the PIN steps need two columns.
  static const double _pinOneColumnHeight = 600;

  /// Measured body width a two-column PIN step needs.
  static const double _pinTwoColumnWidth = 560;

  Widget _buildTopBar({required bool compact}) {
    final showBack = _step != 8 && !_committing;
    final back = Opacity(
      opacity: showBack ? 1 : 0,
      child: IconButton(
        constraints: const BoxConstraints(
          minWidth: kMinInteractiveDimension,
          minHeight: kMinInteractiveDimension,
        ),
        icon: Icon(
          AppIcons.arrowBackIos,
          color: authTextPrimary(context),
          size: context.getRSize(20),
        ),
        onPressed: showBack ? _back : null,
      ),
    );
    if (compact) {
      return Padding(
        padding: EdgeInsets.symmetric(
          horizontal: context.getRSize(12),
          vertical: context.getRSize(4),
        ),
        child: SizedBox(
          height: kMinInteractiveDimension,
          child: Row(
            children: [
              back,
              Expanded(
                child: Text(
                  'Step ${_step + 1} of $_totalSteps',
                  textAlign: TextAlign.center,
                  style: context
                      .semiBoldStyle(13)
                      .copyWith(color: authTextMuted(context, 0.7)),
                ),
              ),
              const SizedBox(width: kMinInteractiveDimension),
            ],
          ),
        ),
      );
    }
    return Padding(
      padding: EdgeInsets.fromLTRB(
        context.getRSize(12),
        context.getRSize(8),
        context.getRSize(12),
        context.getRSize(4),
      ),
      child: Column(
        children: [
          SizedBox(
            height: kMinInteractiveDimension,
            child: Row(children: [back]),
          ),
          SignUpStepDots(current: _step, total: _totalSteps),
          SizedBox(height: context.getRSize(8)),
        ],
      ),
    );
  }

  Widget _buildStepBody({required bool twoColumn}) {
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
        return _buildPinStep(twoColumn: twoColumn);
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
            style: context
                .boldStyle(16)
                .copyWith(color: authTextPrimary(context), letterSpacing: 4),
            decoration: AppDecorations.authInputDecoration(
              context,
              label: 'Invite code',
              prefixIcon: AppIcons.discount,
            ).copyWith(counterText: ''),
          ),
        ),
        SizedBox(height: context.getRSize(4)),
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
            style: context
                .mediumStyle(16)
                .copyWith(color: authTextPrimary(context)),
            decoration: AppDecorations.authInputDecoration(
              context,
              label: 'Email address',
              prefixIcon: AppIcons.email,
            ),
          ),
        ),
        SizedBox(height: context.getRSize(8)),
        Text(
          "We'll send a code to ${_draft.email}",
          style: context
              .regularStyle(13)
              .copyWith(color: authTextMuted(context, 0.6)),
        ),
        SizedBox(height: context.getRSize(16)),
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
        Text('Check your email', style: authTitleStyle(context)),
        SizedBox(height: context.getRSize(8)),
        Text(
          'Enter the 6-digit code sent to\n${_draft.email}',
          style: authSubtitleStyle(context),
        ),
        SizedBox(height: context.getRSize(28)),
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: ShakeWidget(
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
          ),
        ),
        SizedBox(height: context.getRSize(12)),
        Center(
          child: Text(
            'Code expires in 5 minutes',
            style: context
                .regularStyle(13)
                .copyWith(color: authTextMuted(context, 0.5)),
          ),
        ),
        SizedBox(height: context.getRSize(8)),
        Center(child: AuthErrorText(_otpError)),
        SizedBox(height: context.getRSize(8)),
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
        SizedBox(height: context.getRSize(16)),
        Center(
          child: _resendCountdown > 0
              ? Text(
                  'Resend code in 0:${_resendCountdown.toString().padLeft(2, '0')}',
                  style: context
                      .regularStyle(13)
                      .copyWith(color: authTextMuted(context, 0.5)),
                )
              : TextButton(
                  style: TextButton.styleFrom(
                    minimumSize: const Size(
                      kMinInteractiveDimension,
                      kMinInteractiveDimension,
                    ),
                  ),
                  onPressed: (_sendingOtp || _otpLockedOut || _otpVerified)
                      ? null
                      : _resendOtp,
                  child: Text('Resend code', style: context.semiBoldStyle(14)),
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
            style: context
                .mediumStyle(16)
                .copyWith(color: authTextPrimary(context)),
            decoration: AppDecorations.authInputDecoration(
              context,
              label: 'Full name',
              prefixIcon: AppIcons.user,
            ),
          ),
        ),
        SizedBox(height: context.getRSize(4)),
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
          child: AutocompleteField(
            label: 'Country',
            icon: AppIcons.public,
            initial: _countryValue,
            options: kCountries,
            onChanged: (v) => setState(() {
              _countryValue = v;
              _applyDialCode(v);
            }),
          ),
        ),
        const SizedBox(height: 12),
        // Disabling the phone until a country resolves is also what stops a
        // half-typed country falling through to the default currency.
        // Anyone who later decides the disabled field is annoying and greys
        // it out instead will reopen a currency bug without realising the
        // two were connected.
        AuthInputCard(
          child: TextField(
            controller: _phoneCtrl,
            enabled: _dialCode.isNotEmpty,
            keyboardType: TextInputType.phone,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            textInputAction: TextInputAction.done,
            autofocus: false,
            onChanged: (_) {
              if (_phoneError != null) setState(() => _phoneError = null);
            },
            onSubmitted: (_) => _submitPhone(),
            style: context
                .mediumStyle(16)
                .copyWith(
                  color: _dialCode.isNotEmpty
                      ? authTextPrimary(context)
                      : authTextMuted(context, 0.4),
                ),
            decoration: AppDecorations.authInputDecoration(
              context,
              label: 'Phone number',
              prefixIcon: AppIcons.phone,
              enabled: _dialCode.isNotEmpty,
              prefixText: _dialCode.isNotEmpty ? '$_dialCode ' : null,
              helperText: _dialCode.isEmpty
                  ? 'Choose your country first'
                  : null,
            ),
          ),
        ),
        SizedBox(height: context.getRSize(4)),
        AuthErrorText(_phoneError),
        const SizedBox(height: 12),
        AppButton(text: 'Continue', onPressed: _submitPhone),
      ],
    );
  }

  /// Address step — street address only (country is already selected on the
  /// phone step above).
  Widget _buildAddressStep() {
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
            onSubmitted: (_) => _submitAddress(),
            style: context
                .mediumStyle(16)
                .copyWith(color: authTextPrimary(context)),
            decoration: AppDecorations.authInputDecoration(
              context,
              label: 'Street address',
              prefixIcon: AppIcons.location,
            ),
          ),
        ),
        SizedBox(height: context.getRSize(4)),
        AuthErrorText(_addressError),
        const SizedBox(height: 12),
        AppButton(text: 'Continue', onPressed: _submitAddress),
      ],
    );
  }

  Widget _buildPinStep({required bool twoColumn}) {
    if (_committing) {
      return AuthCenteredScroll(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [_buildCommitting()],
      );
    }
    final confirming = _step == 7;
    final heading = <Widget>[
      Text(
        confirming ? 'Confirm your PIN' : 'Create a PIN',
        textAlign: TextAlign.center,
        style: authTitleStyle(context),
      ),
      SizedBox(height: context.getRSize(8)),
      Text(
        confirming
            ? 'Re-enter the same 6-digit PIN to confirm.'
            : 'Choose a 6-digit PIN you\'ll use to log in.',
        textAlign: TextAlign.center,
        style: authSubtitleStyle(context),
      ),
      SizedBox(height: context.getRSize(28)),
      ShakeWidget(
        key: confirming ? _confirmPinShakeKey : _createPinShakeKey,
        child: PinDots(filled: _pin.length),
      ),
      SizedBox(height: context.getRSize(12)),
      AuthErrorText(_pinError),
    ];
    final keypad = PinKeypad(
      onDigit: _onPinDigit,
      onBackspace: _onPinBackspace,
    );
    if (twoColumn) {
      // A phone sideways: heading + dots on the left, keypad on the right.
      return LayoutBuilder(
        builder: (context, constraints) => SingleChildScrollView(
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                context.getRSize(28),
                context.getRSize(8),
                context.getRSize(28),
                context.getRSize(16),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: heading,
                    ),
                  ),
                  SizedBox(width: context.getRSize(24)),
                  Expanded(child: Center(child: keypad)),
                ],
              ),
            ),
          ),
        ),
      );
    }
    return AuthCenteredScroll(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        ...heading,
        SizedBox(height: context.getRSize(12)),
        keypad,
      ],
    );
  }

  Widget _buildCommitting() {
    final primary = Theme.of(context).colorScheme.primary;
    return Padding(
      padding: EdgeInsets.only(top: context.getRSize(60)),
      child: Column(
        children: [
          CircleAvatar(
            radius: context.getRSize(44),
            backgroundColor: primary.withValues(alpha: 0.12),
            child: Icon(
              AppIcons.check,
              size: context.getRSize(48),
              color: primary,
            ),
          ),
          SizedBox(height: context.getRSize(24)),
          Text(
            'Joining your team…',
            style: context
                .boldStyle(18)
                .copyWith(color: authTextPrimary(context)),
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
    final f =
        Theme.of(context).extension<AppFixedColors>() ?? AppFixedColors.light;
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: constraints.maxHeight),
          child: Center(
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: context.getRSize(40),
                vertical: context.getRSize(16),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    padding: EdgeInsets.all(context.getRSize(24)),
                    decoration: BoxDecoration(
                      color: f.greenTint,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      AppIcons.checkCircle,
                      color: f.green,
                      size: context.getRSize(80),
                    ),
                  ),
                  SizedBox(height: context.getRSize(32)),
                  Text(
                    business != null
                        ? 'Welcome to $business!'
                        : 'Welcome to the team!',
                    textAlign: TextAlign.center,
                    style: context
                        .extraBoldStyle(28)
                        .copyWith(color: authTextPrimary(context)),
                  ),
                  SizedBox(height: context.getRSize(12)),
                  Text(
                    'Taking you to Home…',
                    textAlign: TextAlign.center,
                    style: authSubtitleStyle(context),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
