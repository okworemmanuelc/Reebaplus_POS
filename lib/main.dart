import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:reebaplus_pos/core/data/currencies.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/theme/theme_notifier.dart';
import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/db_wipe.dart';
import 'package:reebaplus_pos/core/services/crash_reporter.dart';
import 'package:reebaplus_pos/shared/widgets/error_fallback.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/shared/services/secure_storage_service.dart';
import 'package:reebaplus_pos/features/auth/screens/login_screen.dart';
import 'package:reebaplus_pos/features/auth/screens/who_is_working_screen.dart';
import 'package:reebaplus_pos/features/auth/screens/welcome_screen.dart';
import 'package:reebaplus_pos/features/auth/screens/otp_verification_screen.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:reebaplus_pos/features/auth/widgets/auth_background.dart';
import 'package:reebaplus_pos/core/utils/notifications.dart';
import 'package:reebaplus_pos/shared/widgets/main_layout.dart';
import 'package:reebaplus_pos/shared/widgets/auto_lock_wrapper.dart';
import 'package:reebaplus_pos/shared/widgets/force_update_wrapper.dart';
import 'package:reebaplus_pos/shared/services/auth_service.dart';
import 'package:reebaplus_pos/features/auth/screens/success_dashboard_entry_screen.dart';
import 'package:reebaplus_pos/features/auth/screens/access_granted_screen.dart';
import 'package:reebaplus_pos/features/diagnostics/screens/schema_error_screen.dart';
import 'package:reebaplus_pos/features/sync/screens/first_sync_screen.dart';
import 'package:reebaplus_pos/features/subscription/subscription_access.dart';
import 'package:reebaplus_pos/features/subscription/subscription_thanks.dart';
import 'package:reebaplus_pos/features/subscription/screens/thank_you_subscription_screen.dart';
import 'package:reebaplus_pos/features/subscription/screens/subscription_locked_screen.dart';

import 'package:timezone/data/latest.dart' as tz;

/// Shared future — completes when Supabase client is ready for OTP calls.
late final Future<void> supabaseReady;

void main() {
  // Master plan §33 (Reliability and Crash Handling): run the whole app inside
  // a guarded zone so an uncaught async/zone error is recorded to the crash log
  // instead of tearing down to a blank screen.
  runZonedGuarded(_bootstrap, (error, stack) {
    CrashReporter.record(error, stack, isFatal: true);
  });
}

Future<void> _bootstrap() async {
  WidgetsFlutterBinding.ensureInitialized();

  // §33.2: install the global Flutter/platform error handlers and the friendly
  // fallback widget (replaces Flutter's red error box) before anything else can
  // throw.
  CrashReporter.install();
  ErrorWidget.builder = (details) => const ErrorFallback(compact: true);

  tz.initializeTimeZones();

  // DM Sans is bundled in assets/google_fonts/. Disable the network fallback
  // so a missing weight surfaces as an asset error instead of a fonts.gstatic
  // host-lookup failure when the device is offline.
  GoogleFonts.config.allowRuntimeFetching = false;

  // Must run before any code touches `database` (the warmup query below is the
  // first thing that opens the SQLite file via LazyDatabase). See
  // lib/core/database/db_wipe.dart for the rationale.
  await wipeLegacyDatabaseIfPresent();

  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(statusBarColor: Colors.transparent),
  );

  // Start Supabase in background — screens await supabaseReady before OTP calls.
  supabaseReady = Supabase.initialize(
    url: 'https://ewwyofbvfjyqqirrcaou.supabase.co',
    anonKey:
        'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImV3d3lvZmJ2Zmp5cXFpcnJjYW91Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzM1NzM0MTgsImV4cCI6MjA4OTE0OTQxOH0.McPYfcKMT_h7j9cEE7GiutREcluXo0x2SxdLP0YsP5Q',
  ).then((_) {}).catchError((_) {});

  try {
    await database
        .customSelect('SELECT 1')
        .get()
        .timeout(const Duration(seconds: 5));
  } catch (_) {}
  markDbReady();

  // Schema self-heal audit ran inside beforeOpen above. If it found drift it
  // could not repair (missing column whose ALTER TABLE failed, or a missing
  // table createTable couldn't restore), refuse to boot so DAO/sync code does
  // not run against a corrupt schema.
  final audit = database.lastSchemaAudit;
  if (audit != null && audit.fatal) {
    runApp(SchemaErrorScreen(audit: audit));
    return;
  }

  await themeController.init();

  // Migrate legacy SharedPreferences auth data to encrypted storage.
  await SecureStorageService.migrateFromSharedPreferences();

  runApp(const ProviderScope(child: ReebaplusPosApp()));
}

class ReebaplusPosApp extends ConsumerStatefulWidget {
  const ReebaplusPosApp({super.key});

  @override
  ConsumerState<ReebaplusPosApp> createState() => _ReebaplusPosAppState();
}

class _ReebaplusPosAppState extends ConsumerState<ReebaplusPosApp> {
  /// null = still checking SharedPreferences
  /// true  = a user has logged in on this device before → show PIN screen
  /// false = fresh device / first login → show email screen
  bool? _hasDeviceUser;

  /// Cold-start routing for a known device with MORE THAN ONE active staff:
  /// return to the Who Is Working picker instead of assuming the last device
  /// user's PIN (master plan §7.2 — identity is chosen, never inherited).
  /// null/false = single-staff device → personalized PIN (keeps biometric
  /// unlock). Computed once in [_checkDeviceUser].
  bool _deviceMultiStaff = false;

  /// Regenerated on auth-state changes to force MaterialApp's internal
  /// Navigator to rebuild its route stack (clears stale MainLayout).
  GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();

  // Captured at initState — the listeners below fire across element
  // lifecycle boundaries (auth notifier ticks during navigator-key
  // regeneration). Reading `ref` from a listener body would race the
  // riverpod invalidation.
  late final AuthService _auth;

  /// Tracks whether Supabase currently has an active JWT. Seeded `true`
  /// because Supabase.initialize is fire-and-forget and we'd otherwise
  /// false-positive during the cold-start restore window; the auth-state
  /// stream below flips it on the first `initialSession` / `signedIn` /
  /// `signedOut` event. Gates MainLayout — we never mount the logged-in
  /// shell when this is false.
  bool _supabaseHasSession = true;
  StreamSubscription<AuthState>? _supabaseAuthSub;

  /// Low-frequency tick that refreshes the PRO / FREE TRIAL name badges (§32).
  /// A trial expires by the device clock with no realtime event; without this an
  /// idle foreground app would keep showing FREE TRIAL until the next pull or
  /// rebuild. (The app is no longer locked on expiry — the gate overlay was
  /// removed; only these informational badges depend on the tick now.)
  Timer? _subscriptionClockTimer;

  @override
  void initState() {
    super.initState();
    _auth = ref.read(authProvider);

    _checkDeviceUser();
    _auth.deviceUserIdNotifier.addListener(_onDeviceUserChanged);
    _auth.addListener(_onAuthChanged);

    // Watch Supabase auth state so the home() gate flips when the JWT
    // appears (initialSession / signedIn / tokenRefreshed) or disappears
    // (signedOut, refresh-token rotation failure). Subscribed after
    // supabaseReady so we don't race the SDK's storage restore.
    supabaseReady.whenComplete(_subscribeToSupabaseAuth);

    // §32: nudge the subscription badges so a trial that crosses its deadline
    // while the app sits idle in the foreground is reflected within a minute,
    // and re-pull the businesses row so an admin-console status change (or a
    // missed realtime event) is picked up within a minute too — not only on the
    // next full pull. Drives the live lock/unlock + thank-you gate.
    _subscriptionClockTimer = Timer.periodic(const Duration(seconds: 60), (_) {
      if (!mounted) return;
      ref.read(subscriptionClockTickProvider.notifier).state++;
      final bizId = _auth.currentUser?.businessId;
      if (bizId != null) {
        unawaited(
          ref.read(supabaseSyncServiceProvider).refreshBusinessRow(bizId),
        );
      }
    });
  }

  void _subscribeToSupabaseAuth() {
    if (!mounted) return;
    final client = Supabase.instance.client;
    // Seed from the current state — initialSession also fires post-subscribe
    // but seeding here avoids one frame of stale UI if it has already fired.
    final has = client.auth.currentUser != null;
    if (has != _supabaseHasSession) {
      setState(() => _supabaseHasSession = has);
    }
    _supabaseAuthSub = client.auth.onAuthStateChange.listen(
      (state) {
        if (!mounted) return;
        final next = state.session != null;
        if (next != _supabaseHasSession) {
          // Diagnostic breadcrumb (release-visible via the synced `error_logs`
          // table): a session that disappears while a local user is still
          // active is exactly the condition that renders _SessionExpiredScreen.
          // Recording the AuthChangeEvent here lets us tell a genuine
          // server-side revocation (signedOut — single-active-device kick,
          // token-reuse detection, admin revoke) apart from a benign
          // initialSession/signedIn restore, without an attached debugger.
          if (!next) {
            // Capture the local user before any teardown nulls it, and scope
            // the row to its tenant so it survives a full-logout clear and
            // flushes on the next authenticated push (the resolver is cleared
            // on the kick path, which would otherwise drop it local-only).
            final lostUser = _auth.currentUser;
            CrashReporter.record(
              'auth session lost (event=${state.event.name}, '
                  'hadLocalUser=${lostUser != null})',
              StackTrace.current,
              context: 'auth.session_lost',
              businessId: lostUser?.businessId,
              userId: lostUser?.id,
            );
          }
          setState(() => _supabaseHasSession = next);
        }
      },
      // Token-refresh failures surface here as AuthRetryableFetchException
      // (offline, DNS hiccup). Swallow — supabase-flutter retries on
      // reconnect; bubbling would crash the app on transient blips.
      onError: (e) => debugPrint('[main] supabase auth stream error: $e'),
    );
  }

  /// When the logged-in user changes (login or logout), regenerate the
  /// navigator key so the route stack resets to the correct auth screen.
  ///
  /// This is why AuthService.value stays null throughout onboarding — calling
  /// setCurrentUser here would destroy the in-progress onboarding stack.
  void _onAuthChanged() {
    if (mounted) {
      setState(() => _navigatorKey = GlobalKey<NavigatorState>());
    }
  }

  void _onDeviceUserChanged() {
    if (mounted) {
      setState(() {
        _hasDeviceUser = _auth.deviceUserIdNotifier.value != null;
        // Force MaterialApp's Navigator to rebuild its route stack so stale
        // screens (MainLayout) are replaced by the correct auth screen.
        _navigatorKey = GlobalKey<NavigatorState>();
      });
    }
  }

  Future<void> _checkDeviceUser() async {
    final userId = await _auth.getDeviceUserId();
    // Decide cold-start routing: a known device with >1 active staff returns
    // to the Who Is Working picker (master plan §7.2) rather than the last
    // device user's PIN. Computed before setState so both flags land together.
    bool multiStaff = false;
    if (userId != null) {
      final db = ref.read(databaseProvider);
      final user = await db.storesDao.getUserById(userId);
      if (user != null) {
        final count = await db.userBusinessesDao.countActiveStaffForBusiness(
          user.businessId,
        );
        multiStaff = count > 1;
      }
    }
    if (mounted) {
      _auth.deviceUserIdNotifier.value = userId;
      setState(() {
        _hasDeviceUser = userId != null;
        _deviceMultiStaff = multiStaff;
      });
    }
  }

  @override
  void dispose() {
    _auth.deviceUserIdNotifier.removeListener(_onDeviceUserChanged);
    _auth.removeListener(_onAuthChanged);
    _supabaseAuthSub?.cancel();
    _subscriptionClockTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = ref.watch(themeProvider);
    final auth = ref.watch(authProvider);
    final user = auth.value;
    final localBusinessesAsync = ref.watch(localBusinessesProvider);

    // Apply the CEO-chosen business accent colour (synced) to this device.
    // Null = pre-login / unset → leave the device's themeController value alone
    // (amber default). setDesignSystem no-ops on an unchanged value, so the
    // CEO's own write doesn't loop back through the settings stream.
    ref.listen(businessDesignSystemProvider, (_, next) {
      final ds = next.valueOrNull;
      if (ds != null) themeController.setDesignSystem(ds);
    });

    // Live suspend → sign-out (master plan §9.5 / §8.3). When the signed-in
    // user is suspended on another device, the `user_businesses` realtime
    // update flips the local membership status; drop them to the Who's Working
    // picker immediately. The picker hides suspended staff (§8.3), so they
    // can't re-select themselves. lockApp() (UI-only, keeps the Supabase
    // session) once `value` is null re-emissions are ignored — the guard below
    // makes this fire exactly once per active session.
    ref.listen(currentUserMembershipStatusProvider, (_, next) {
      if (next == 'suspended' && _auth.value != null) {
        _auth.lockApp();
      }
    });

    // Keep the app-wide money formatter in sync with the CEO-chosen currency
    // (synced `default_currency`, §10.1). Watching here rebuilds MaterialApp
    // on change so every formatCurrency() re-renders with the new symbol;
    // setting the global synchronously means descendants in this same frame
    // already read the updated symbol (receipts, money labels).
    final currencyCode =
        ref.watch(currencyCodeProvider).valueOrNull ?? kDefaultCurrency;
    setActiveCurrencyCode(currencyCode);

    return ForceUpdateWrapper(
      child: AutoLockWrapper(
        child: MaterialApp(
          title: 'Reebaplus POS',
          debugShowCheckedModeBanner: false,
          builder: (context, child) {
            // Cap OS font-scaling so large system-text settings can't overflow
            // the dense POS layouts. responsive.dart already scales type by
            // screen width; this bounds the per-device accessibility multiplier
            // on top of that. Raise the cap if larger text is needed.
            final mq = MediaQuery.of(context);
            return MediaQuery(
              data: mq.copyWith(
                textScaler: mq.textScaler.clamp(maxScaleFactor: 1.3),
              ),
              child: GestureDetector(
                onTap: () => FocusManager.instance.primaryFocus?.unfocus(),
                behavior: HitTestBehavior.opaque,
                child: child,
              ),
            );
          },
          themeMode: theme.themeMode,
          theme: switch (theme.designSystem) {
            DesignSystem.purple => AppTheme.purpleLight(),
            DesignSystem.amber => AppTheme.amberLight(),
            DesignSystem.green => AppTheme.greenLight(),
            DesignSystem.bw => AppTheme.bwLight(),
            DesignSystem.blue => AppTheme.light(),
          },
          darkTheme: switch (theme.designSystem) {
            DesignSystem.purple => AppTheme.purpleDarkTheme(),
            DesignSystem.amber => AppTheme.amberDarkTheme(),
            DesignSystem.green => AppTheme.greenDarkTheme(),
            DesignSystem.bw => AppTheme.bwDarkTheme(),
            DesignSystem.blue => AppTheme.dark(),
          },
          navigatorKey: _navigatorKey,
          home: () {
            if (user == null) {
              // Still reading SharedPreferences — show branded splash.
              if (_hasDeviceUser == null) return const _BrandedSplash();
              // New device / fresh install → email entry flow.
              //
              // Legacy in-progress onboarding (a half-built business from
              // before the collect-first wizard) is no longer auto-resumed
              // — the new wizard commits atomically at PIN, so abandonment
              // can't leave a half-state to resume into. Users in that
              // transitional bucket re-enter via EmailEntry / LoginScreen.
              if (!_hasDeviceUser!) return const WelcomeScreen();
              // Known device. A lock / Switch User / auto-lock returns to the
              // Who Is Working picker (master plan §8.5). On a cold start, a
              // multi-staff shared till ALSO returns to the picker so the right
              // person is chosen explicitly (§7.2) — never assume the last
              // device user. A single-staff device goes straight to that user's
              // personalized PIN screen (keeps biometric unlock).
              if (_auth.showPickerOnUnlock || _deviceMultiStaff) {
                return const WhoIsWorkingScreen();
              }
              return const LoginScreen();
            }

            // Session-gate. Local user is set but Supabase has no JWT —
            // mounting MainLayout here would render a logged-in shell that
            // can't reach the cloud: every write would pile up in the queue
            // with `pushPending` skipping on "no auth session" and the Sync
            // Issues screen reporting "no profiles row for current
            // auth.uid()". Bounce through OTP instead so the JWT is
            // re-established before any tenant-scoped UI renders.
            if (!_supabaseHasSession) {
              return _SessionExpiredScreen(user: user);
            }

            // Gating the Business Reveal UX for brand-new logins on fresh devices:
            // If the user has authenticated but there is no business row locally in our Drift database yet,
            // show the FirstSyncScreen to perform the initial pull, keeping them out of empty screens.
            final localBusinesses = localBusinessesAsync.valueOrNull;
            if (localBusinesses == null || localBusinesses.isEmpty) {
              return FirstSyncScreen(businessId: user.businessId);
            }

            // Check for special post-login screens set by BiometricSetupScreen.
            final pendingRoute = auth.pendingPostLoginRoute;
            if (pendingRoute != PostLoginRoute.none) {
              auth.pendingPostLoginRoute = PostLoginRoute.none;
              switch (pendingRoute) {
                case PostLoginRoute.successDashboard:
                  return const SuccessDashboardEntryScreen();
                case PostLoginRoute.accessGranted:
                  final pendingUser = auth.pendingPostLoginUser ?? user;
                  auth.pendingPostLoginUser = null;
                  return AccessGrantedScreen(user: pendingUser);
                case PostLoginRoute.none:
                  break;
              }
            }

            // Subscription gate (master plan §32). The PRO / FREE TRIAL name
            // badges and Settings → Subscription surface status everywhere; here
            // the gate also (a) LOCKS the app on a known-expired trial or an
            // inactive subscription, and (b) shows a one-time Thank-You on a
            // fresh activation. Grace (unknown status / no deadline) never locks.
            final subAccess = ref.watch(currentBusinessSubscriptionProvider);
            if (subAccess.isLocked) {
              return SubscriptionLockedScreen(access: subAccess);
            }
            final subBusiness = ref.watch(currentBusinessProvider);
            if (subBusiness != null &&
                ref
                    .watch(subscriptionThanksProvider)
                    .shouldCelebrate(subBusiness)) {
              return ThankYouSubscriptionScreen(business: subBusiness);
            }

            return const MainLayout();
          }(),
        ),
      ),
    );
  }
}

/// Branded loading screen shown while SharedPreferences is being read.
class _BrandedSplash extends StatelessWidget {
  const _BrandedSplash();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Image.asset(
              'assets/images/reebaplus_logo.png',
              height: 90,
              errorBuilder: (_, __, ___) =>
                  const Icon(Icons.storefront, size: 90, color: Colors.white),
            ),
            const SizedBox(height: 16),
            const Text(
              'Reebaplus POS',
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w700,
                color: Colors.white,
              ),
            ),
            const SizedBox(height: 24),
            const SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(
                strokeWidth: 2.5,
                color: Colors.white,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Shown when a local user is loaded but the Supabase JWT is missing. Triggers
/// a fresh OTP to the user's email so the session can be re-established without
/// destroying the device session (PIN, biometrics, local data all preserved).
class _SessionExpiredScreen extends ConsumerStatefulWidget {
  final UserData user;
  const _SessionExpiredScreen({required this.user});

  @override
  ConsumerState<_SessionExpiredScreen> createState() =>
      _SessionExpiredScreenState();
}

class _SessionExpiredScreenState extends ConsumerState<_SessionExpiredScreen> {
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    // Diagnostic breadcrumb (release-visible via the synced `error_logs`
    // table): record that the session-expired gate actually rendered, tagged
    // with the stored auth method so the Supabase console shows whether expired
    // sessions correlate with Google vs email/OTP logins. This is the read-out
    // for the "did Google end the session?" investigation — the device-kick
    // (signOut(scope: others)) can never revoke the current device's own
    // session, so any correlation here is the single-active-device policy
    // revoking THIS device because the same account signed in elsewhere.
    final auth = ref.read(authProvider);
    // The JWT is gone by definition on this screen, so the row can't push until
    // the OTP re-auth below restores it. Scope it to the in-hand local user so
    // it's durably enqueued now and flushes on that re-auth, rather than being
    // dropped local-only by the (cleared) business resolver. See [logError].
    final bid = widget.user.businessId;
    final uid = widget.user.id;
    unawaited(
      auth.getAuthMethod().then((method) {
        CrashReporter.record(
          'session-expired gate rendered (authMethod=${method ?? 'unknown'})',
          StackTrace.current,
          context: 'auth.session_expired_gate',
          businessId: bid,
          userId: uid,
        );
      }).catchError((Object _) {
        CrashReporter.record(
          'session-expired gate rendered (authMethod lookup failed)',
          StackTrace.current,
          context: 'auth.session_expired_gate',
          businessId: bid,
          userId: uid,
        );
      }),
    );
  }

  Future<void> _resendOtp() async {
    final email = widget.user.email;
    if (email == null || email.isEmpty) {
      AppNotification.showError(
        context,
        'No email on file for this account. Please sign out and start over.',
      );
      return;
    }
    setState(() => _sending = true);
    final auth = ref.read(authProvider);
    final error = await auth.sendOtp(email);
    if (!mounted) return;
    setState(() => _sending = false);
    if (error != null) {
      AppNotification.showError(context, error);
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => OtpVerificationScreen(user: widget.user, email: email),
      ),
    );
  }

  Future<void> _signOut() async {
    await ref.read(authProvider).fullLogout();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final textColor = isDark ? Colors.white : Colors.black;
    final email = widget.user.email ?? '';

    return AuthBackground(
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Spacer(),
              Icon(
                Icons.lock_clock_outlined,
                size: 72,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(height: 20),
              Text(
                'Session expired',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 26,
                  fontWeight: FontWeight.w700,
                  color: textColor,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                email.isEmpty
                    ? "Your sign-in has expired. Verify your email to keep your changes syncing."
                    : "Your sign-in has expired. We'll send a code to $email to restore your session — your PIN and local data stay intact.",
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 14,
                  height: 1.4,
                  color: textColor.withValues(alpha: 0.75),
                ),
              ),
              const Spacer(),
              AppButton(
                text: _sending ? 'Sending…' : 'Verify email',
                onPressed: _sending ? null : _resendOtp,
              ),
              const SizedBox(height: 12),
              TextButton(
                onPressed: _sending ? null : _signOut,
                child: Text(
                  'Sign out instead',
                  style: TextStyle(color: textColor.withValues(alpha: 0.65)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
