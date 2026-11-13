import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:reebaplus_pos/core/data/currencies.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/theme/theme_notifier.dart';
import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/db_wipe.dart';
import 'package:reebaplus_pos/core/services/backup_exclusion_service.dart';
import 'package:reebaplus_pos/core/services/crash_reporter.dart';
import 'package:reebaplus_pos/core/services/db_worker_switch_watcher.dart';
import 'package:reebaplus_pos/core/diagnostics/overflow_route_reporter.dart';
import 'package:reebaplus_pos/shared/widgets/error_fallback.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/storefront/browse_switch.dart';
import 'package:reebaplus_pos/core/storefront/online_ordering_switch.dart';
import 'package:reebaplus_pos/shared/services/secure_storage_service.dart';
import 'package:reebaplus_pos/features/auth/screens/welcome_screen.dart';
import 'package:reebaplus_pos/features/browse/screens/browse_screen.dart';
import 'package:reebaplus_pos/features/auth/screens/otp_verification_screen.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:reebaplus_pos/core/theme/app_decorations.dart'
    show authTextPrimary, authTextMuted;
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/features/auth/widgets/auth_form_kit.dart';
import 'package:reebaplus_pos/features/auth/widgets/branded_auth_background.dart';
import 'package:reebaplus_pos/core/utils/notifications.dart';
import 'package:reebaplus_pos/shared/widgets/main_layout.dart';
import 'package:reebaplus_pos/shared/widgets/app_resume_sync.dart';
import 'package:reebaplus_pos/features/payroll/widgets/daily_allowance_runner.dart';
import 'package:reebaplus_pos/shared/widgets/force_update_wrapper.dart';
import 'package:reebaplus_pos/core/services/browser_last_used_service.dart';
import 'package:reebaplus_pos/shared/services/auth_service.dart';
import 'package:reebaplus_pos/shared/services/push_notification_service.dart';
import 'package:reebaplus_pos/shared/widgets/notifications_modal.dart';
import 'package:reebaplus_pos/features/orders/screens/online_order_detail_screen.dart';
import 'package:reebaplus_pos/features/orders/screens/orders_screen.dart';
import 'package:reebaplus_pos/shared/services/online_order_push_route.dart';
import 'package:reebaplus_pos/features/auth/membership_status_reaction.dart';
import 'package:reebaplus_pos/features/sync/widgets/resolve_unsynced_data_dialog.dart';
import 'package:reebaplus_pos/features/auth/screens/success_dashboard_entry_screen.dart';
import 'package:reebaplus_pos/features/auth/screens/access_granted_screen.dart';
import 'package:reebaplus_pos/features/van_sales/screens/driver_terminal_screen.dart';
import 'package:reebaplus_pos/features/diagnostics/screens/schema_error_screen.dart';

import 'package:reebaplus_pos/features/subscription/subscription_plan_providers.dart';
import 'package:reebaplus_pos/shared/widgets/reebaplus_logo.dart';

import 'package:timezone/data/latest.dart' as tz;

/// Shared future — completes when Supabase client is ready for OTP calls.
late final Future<void> supabaseReady;

/// Google Web OAuth Client ID (serverClientId) backing the Supabase Google provider.
/// Paste the client ID from Google Cloud Console that matches the Supabase Auth Google Provider.
const String googleWebClientId =
    '807123945489-048eug40i2jn7novlblidott50sqcl7b.apps.googleusercontent.com';

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
  // PRD #239 / #241: tag layout overflows with the screen they fired on.
  // Debug builds only — install() is a no-op in release.
  OverflowRouteReporter.install();
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

  // #608: edge-to-edge on Android 10–14 too (Android 15+ forces it).
  // MainActivity calls enableEdgeToEdge(); this mode stops Flutter from
  // re-applying its old window flags on every resume, which would undo it.
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
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

  // #687: remember the cloud off switch for the next app open. Not awaited, and
  // it does not need the database, so a phone whose worker failed can still
  // receive the "off" answer.
  // The browser (#812) has no off-switch file: drift's web worker always runs.
  if (!kIsWeb) DbWorkerSwitchWatcher().start();

  // #285: the database file now exists, so mark it (and its WAL sidecars) as
  // excluded from iCloud backup. Android does the same declaratively in the
  // manifest. Fire-and-forget — a backup attribute must never delay the till.
  unawaited(BackupExclusionService.excludeLocalDatabase());

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

class _ReebaplusPosAppState extends ConsumerState<ReebaplusPosApp>
    with WidgetsBindingObserver {
  /// null = still checking SharedPreferences
  /// true  = a user has logged in on this device before → show PIN screen
  /// false = fresh device / first login → show email screen
  bool? _hasDeviceUser;

  /// Regenerated on auth-state changes to force MaterialApp's internal
  /// Navigator to rebuild its route stack (clears stale MainLayout).
  GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();

  // Captured at initState — the listeners below fire across element
  // lifecycle boundaries (auth notifier ticks during navigator-key
  // regeneration). Reading `ref` from a listener body would race the
  // riverpod invalidation.
  late final AuthService _auth;

  // Push (#138 Slice 2) — captured up front (same reason as `_auth`): the
  // auth/device-user listeners drive token register/clear and must not touch
  // `ref` from their bodies. The notification service is deliberately NOT
  // captured here — reading `notificationProvider` builds NotificationService,
  // whose `_init` runs a business-scoped `NotificationsDao.watchAll` that
  // throws before a business is bound (cold-start crash). It is read lazily at
  // the guarded tap site instead, so it's only constructed post-login.
  late final PushNotificationService _pushService;

  /// Business bound for push registration, tracked to detect the sign-in edge
  /// (`_onAuthChanged`) and the full-logout edge (`_onDeviceUserChanged`).
  /// Only a full logout (device-user cleared → Welcome) nulls the token.
  String? _pushBusinessId;

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

  /// Re-entrancy guard for the admin-removed offboarding (#117). The membership
  /// listener can re-emit `removed` while the gate is mid-flight; without this
  /// the offboarding could stack (double dialogs / double wipe).
  bool _handlingSelfRemoved = false;

  @override
  void initState() {
    super.initState();
    _auth = ref.read(authProvider);
    _pushService = ref.read(pushNotificationServiceProvider);

    if (kIsWeb) WidgetsBinding.instance.addObserver(this);
    _checkDeviceUser();
    _auth.deviceUserIdNotifier.addListener(_onDeviceUserChanged);
    _auth.addListener(_onAuthChanged);

    // Push (#138 Slice 2): start the FCM port + bind tap actions after the
    // first frame. Never blocks app entry (invariant #11) — Firebase init is a
    // local read; the token upsert is fire-and-forget behind supabaseReady.
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => unawaited(_bootstrapPush()),
    );

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
    _syncPushSignIn();
    if (mounted) {
      setState(() => _navigatorKey = GlobalKey<NavigatorState>());
    }
  }

  /// Admin-removed offboarding (#117). Runs when the current user's own
  /// membership flips to `removed` (an admin ran `remove_staff_member` on
  /// another device; the change arrives via the next pull / broadcast). Reuses
  /// [AuthService.logOutCurrentUser] — the exact drawer-logout path — so the
  /// unsynced-data gate runs before the device is wiped. Surfaces the gate's
  /// two-tier outcome exactly as
  /// the drawer does: retryable rows → error toast ("connect and sync first");
  /// orphans only → the Resolve-unsynced-data flow. The admin already detached
  /// them server-side, so the plain (non-resign) terminals apply here.
  Future<void> _handleSelfRemoved() async {
    if (_handlingSelfRemoved) return;
    _handlingSelfRemoved = true;
    try {
      await _auth.logOutCurrentUser();
    } on LogoutBlockedByUnsyncedDataException catch (e) {
      final ctx = _navigatorKey.currentContext;
      if (ctx != null && ctx.mounted) {
        await showResolveUnsyncedDataDialog(
          ctx,
          ref,
          pendingCount: e.pendingCount,
          orphanCount: e.orphanCount,
          photoCount: e.photoCount,
        );
      }
    } on LogoutWipeException catch (e) {
      final ctx = _navigatorKey.currentContext;
      if (ctx != null && ctx.mounted) {
        AppNotification.showError(ctx, e.message);
      }
    } catch (e) {
      debugPrint('[main] _handleSelfRemoved error: $e');
    } finally {
      _handlingSelfRemoved = false;
    }
  }

  void _onDeviceUserChanged() {
    _syncPushSignOut();
    if (mounted) {
      setState(() {
        _hasDeviceUser = _auth.deviceUserIdNotifier.value != null;
        // Force MaterialApp's Navigator to rebuild its route stack so stale
        // screens (MainLayout) are replaced by the correct auth screen.
        _navigatorKey = GlobalKey<NavigatorState>();
      });
    }
  }

  // ── Push notifications (#138 Slice 2) ───────────────────────────────────────
  /// Start the FCM port and bind the tap actions the app shell supplies (open
  /// the in-app bell + mark the row read). Binding is synchronous so a
  /// cold-start tap replayed from [MainLayout] always finds the callbacks; the
  /// port start awaits [supabaseReady] so the token upsert has a live session.
  Future<void> _bootstrapPush() async {
    _pushService.bindTapActions(
      openNotifications: () {
        // Only over the app shell — never over the PIN/lock screen.
        if (_auth.currentUser == null) return;
        final ctx = _navigatorKey.currentContext;
        if (ctx != null) NotificationsModal.show(ctx);
      },
      markRead: (id) {
        // Read lazily — constructing NotificationService runs a
        // business-scoped DAO query, only safe once a business is bound
        // (guaranteed here by the signed-in guard above).
        if (_auth.currentUser == null) return;
        unawaited(ref.read(notificationProvider).markAsRead(id));
      },
    );
    // #433: a "New online order" tap opens that order if it is already local,
    // else the Online tab. Never waits on a pull and never throws.
    _pushService.bindOnlineOrderTapAction((onlineOrderId) {
      if (_auth.currentUser == null || !isOnlineOrderingEnabled()) return;
      unawaited(routeOnlineOrderTap(
        onlineOrderId: onlineOrderId,
        isLocal: (id) => ref.read(databaseProvider).onlineOrdersDao.existsById(id),
        openDetail: (id) {
          final nav = _navigatorKey.currentState;
          nav?.push(MaterialPageRoute<void>(
            builder: (_) => OnlineOrderDetailScreen(onlineOrderId: id),
          ));
        },
        openOnlineTab: () {
          final nav = _navigatorKey.currentState;
          nav?.push(MaterialPageRoute<void>(
            builder: (_) => const OrdersScreen(initialIndex: 1),
          ));
        },
      ));
    });
    await supabaseReady;
    if (!mounted) return;
    await _pushService.start();
    // Seed registration from the already-signed-in state (warm launch).
    _syncPushSignIn();
    // #426: a Shopper-only phone (no business user) restored its persisted
    // Shopper session — register its push token by auth user (#476).
    if (await _auth.getDeviceUserId() == null &&
        Supabase.instance.client.auth.currentUser != null) {
      unawaited(_pushService.onShopperSignedIn());
    }
  }

  /// The sign-in edge: a business became bound (login or cold-start restore).
  /// Registers the FCM token if OS permission is already granted.
  void _syncPushSignIn() {
    final businessId = _auth.currentUser?.businessId;
    if (businessId != null && businessId != _pushBusinessId) {
      _pushBusinessId = businessId;
      unawaited(_pushService.onSignedIn(businessId));
    }
  }

  /// The full-logout edge: the device user was cleared (→ Welcome). Null the
  /// token client-side + in `devices`.
  void _syncPushSignOut() {
    if (_auth.deviceUserIdNotifier.value == null && _pushBusinessId != null) {
      final previous = _pushBusinessId!;
      _pushBusinessId = null;
      unawaited(_pushService.onSignedOut(previous));
    }
  }

  /// Cold start (#812): there is no PIN unlock, so a device with a signed-in
  /// user is restored straight into the shop before the splash lifts. Local
  /// reads only — never the network (invariant #11).
  Future<void> _checkDeviceUser() async {
    try {
      if (kIsWeb) {
        // #812 S5: a browser copy unused for 30+ days is wiped (after one push
        // attempt for unsent work) BEFORE a user is bound.
        final wiped = await _auth.wipeStaleBrowserCopy();
        // Kept-because-unsent: leave the old date so the next open retries.
        if (wiped || !BrowserLastUsedService.shouldWipe(
              now: DateTime.now(),
              lastUsed: await BrowserLastUsedService.read(),
            )) {
          await BrowserLastUsedService.touch(force: true);
        }
      }
      await _auth.restoreSignedInUser();
    } catch (e, stack) {
      // Never trap the app on the splash: fall through to the sign-in screen.
      debugPrint('[main] cold-start restore failed: $e\n$stack');
    }
    final userId = await _auth.getDeviceUserId();
    if (mounted) {
      _auth.deviceUserIdNotifier.value = userId;
      setState(() => _hasDeviceUser = userId != null);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // #812 S5: browser "last used" date, debounced inside the service.
    if (kIsWeb && state == AppLifecycleState.resumed) {
      unawaited(BrowserLastUsedService.touch());
    }
  }

  @override
  void dispose() {
    if (kIsWeb) WidgetsBinding.instance.removeObserver(this);
    _auth.deviceUserIdNotifier.removeListener(_onDeviceUserChanged);
    _auth.removeListener(_onAuthChanged);
    _supabaseAuthSub?.cancel();
    _subscriptionClockTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = ref.watch(themeProvider);

    // Apply the CEO-chosen business accent colour (synced) to this device.
    // Null = pre-login / unset → leave the device's themeController value alone
    // (blue default). setDesignSystem no-ops on an unchanged value, so the
    // CEO's own write doesn't loop back through the settings stream.
    ref.listen(businessDesignSystemProvider, (_, next) {
      final ds = next.valueOrNull;
      if (ds != null) themeController.setDesignSystem(ds);
    });

    // Live membership-status reactions (master plan §9.5 / §8.3 + #117). When
    // the signed-in user's own membership changes on another device — a peer
    // suspends them, or an admin removes them (the `remove_staff_member` RPC) —
    // the `user_businesses` realtime/broadcast pull flips the local status and
    // this provider re-emits. Guard on `value != null` so a null (logged-out)
    // re-emission is ignored.
    //   • suspended → nothing here: [_HomeRouter] shows the Account Blocked
    //     screen instead of the shop while the status stays suspended (#812 —
    //     there is no PIN screen to lock to any more). A plan-paused user
    //     (reebaplus-web#90) is blocked the same way.
    //   • removed → run the SAME offboarding the drawer logout uses (unsynced-
    //     data gate → log out and wipe the device).
    ref.listen(currentUserMembershipStatusProvider, (_, next) {
      if (_auth.value == null) return;
      switch (membershipStatusReaction(next)) {
        case MembershipStatusReaction.none:
        case MembershipStatusReaction.block:
          break;
        case MembershipStatusReaction.offboard:
          unawaited(_handleSelfRemoved());
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
      child: AppResumeSync(
        // #669 — posts the automatic Daily Allowance on open / resume, offline.
        child: DailyAllowanceRunner(
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
            home: _HomeRouter(
              hasDeviceUser: _hasDeviceUser,
              supabaseHasSession: _supabaseHasSession,
            ),
          ),
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
    // Drawn before the saved theme is read, so it follows the device's
    // light/dark setting (matching the native launch screen and icon).
    final brightness = MediaQuery.platformBrightnessOf(context);
    final dark = brightness == Brightness.dark;
    final fg = dark ? Colors.white : Colors.black;
    return Scaffold(
      backgroundColor: dark ? Colors.black : Colors.white,
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ReebaplusLogo(height: 90, brightness: brightness),
            const SizedBox(height: 16),
            Text(
              'Reebaplus POS',
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w700,
                color: fg,
              ),
            ),
            const SizedBox(height: 24),
            SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 2.5, color: fg),
            ),
          ],
        ),
      ),
    );
  }
}

/// Shown when a local user is loaded but the Supabase JWT is missing. Triggers
/// a fresh OTP to the user's email so the session can be re-established without
/// destroying the device session (local data preserved).
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
    final textColor = authTextPrimary(context);
    final email = widget.user.email ?? '';

    return Scaffold(
      body: BrandedAuthBackground(
        child: SafeArea(
          // Centred and scrollable: it fits a phone sideways and a big text
          // size by scrolling, never by overflowing.
          child: AuthCenteredScroll(
            padding: context.rPaddingSymmetric(horizontal: 28, vertical: 32),
            children: [
              Icon(
                AppIcons.lockClock,
                size: context.getRSize(72),
                color: theme.colorScheme.primary,
              ),
              SizedBox(height: context.getRSize(20)),
              Text(
                'Session expired',
                textAlign: TextAlign.center,
                style: context.boldStyle(26).copyWith(color: textColor),
              ),
              SizedBox(height: context.getRSize(12)),
              Text(
                email.isEmpty
                    ? "Your sign-in has expired. Verify your email to keep your changes syncing."
                    : "Your sign-in has expired. We'll send a code to $email to restore your session — your local data stays intact.",
                textAlign: TextAlign.center,
                style: context
                    .regularStyle(14)
                    .copyWith(height: 1.4, color: authTextMuted(context, 0.75)),
              ),
              SizedBox(height: context.getRSize(32)),
              AppButton(
                text: _sending ? 'Sending…' : 'Verify email',
                onPressed: _sending ? null : _resendOtp,
              ),
              SizedBox(height: context.getRSize(12)),
              TextButton(
                onPressed: _sending ? null : _signOut,
                style: TextButton.styleFrom(
                  minimumSize: const Size(48, kMinInteractiveDimension),
                ),
                child: Text(
                  'Sign out instead',
                  style: context
                      .mediumStyle(14)
                      .copyWith(color: authTextMuted(context)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Test seam: lets widget tests mount the private [_SessionExpiredScreen].
@visibleForTesting
Widget buildSessionExpiredScreenForTest(UserData user) =>
    _SessionExpiredScreen(user: user);

/// Shown instead of the shop while the signed-in member is suspended or
/// paused by the plan (#812). It replaces the old PIN lock: there is no PIN
/// screen to drop them to any more. The user stays bound, so sync keeps running
/// and a reactivation (or an upgrade) reopens the shop by itself. Log out runs
/// the normal drawer logout — the unsynced-data gate, then the wipe.
class _AccountBlockedScreen extends ConsumerWidget {
  final String message;
  const _AccountBlockedScreen({required this.message});

  Future<void> _logOut(BuildContext context, WidgetRef ref) async {
    try {
      await ref.read(authProvider).logOutCurrentUser();
    } on LogoutBlockedByUnsyncedDataException catch (e) {
      if (context.mounted) {
        await showResolveUnsyncedDataDialog(
          context,
          ref,
          pendingCount: e.pendingCount,
          orphanCount: e.orphanCount,
          photoCount: e.photoCount,
        );
      }
    } on LogoutWipeException catch (e) {
      if (context.mounted) AppNotification.showError(context, e.message);
    } catch (e) {
      debugPrint('[main] blocked-screen logout error: $e');
      if (context.mounted) {
        AppNotification.showError(
          context,
          'An unexpected error occurred during logout.',
        );
      }
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return Scaffold(
      body: BrandedAuthBackground(
        child: SafeArea(
          child: AuthCenteredScroll(
            padding: context.rPaddingSymmetric(horizontal: 28, vertical: 32),
            children: [
              Icon(
                AppIcons.block,
                size: context.getRSize(72),
                color: theme.colorScheme.error,
              ),
              SizedBox(height: context.getRSize(20)),
              Text(
                'Account on hold',
                textAlign: TextAlign.center,
                style: context
                    .boldStyle(26)
                    .copyWith(color: authTextPrimary(context)),
              ),
              SizedBox(height: context.getRSize(12)),
              Text(
                message,
                textAlign: TextAlign.center,
                style: context
                    .regularStyle(14)
                    .copyWith(height: 1.4, color: authTextMuted(context, 0.75)),
              ),
              SizedBox(height: context.getRSize(32)),
              AppButton(
                text: 'Log out',
                onAsyncPressed: () => _logOut(context, ref),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Test seam: lets widget tests mount the private [_AccountBlockedScreen].
@visibleForTesting
Widget buildAccountBlockedScreenForTest(String message) =>
    _AccountBlockedScreen(message: message);

/// The entry screen while no user is signed in on this run (#425, #812):
/// a phone that still holds a business user pointer but could not restore it
/// (its local row is missing) gets the Welcome screen to sign in again — never
/// Browse, it is a business phone; a phone without one gets Browse when the
/// Browse-first switch is on, otherwise today's Welcome screen. A device whose
/// user restores at cold start never reaches here: it opens straight into the
/// shop (no PIN screen any more).
@visibleForTesting
Widget entryScreenWithoutSignedInUser({
  required bool hasDeviceUser,
  bool? browseFirst,
}) {
  if (hasDeviceUser) return const WelcomeScreen();
  return (browseFirst ?? isBrowseFirstEnabled())
      ? const BrowseScreen()
      : const WelcomeScreen();
}

/// #812: the Account Blocked screen's message while the signed-in member is
/// suspended or paused by the plan, else null. Replaces the old PIN lock.
final _accountBlockedMessageProvider = Provider<String?>((ref) {
  final userId = ref.watch(authProvider).currentUser?.id;
  if (userId == null) return null;
  final status = ref.watch(currentUserMembershipStatusProvider);
  return accountBlockedMessage(
    suspended:
        membershipStatusReaction(status) == MembershipStatusReaction.block,
    paused: ref.watch(pausedStaffIdsProvider).contains(userId),
  );
});

// ---------------------------------------------------------------------------
// Home routing widget — extracted from _ReebaplusPosAppState so all
// ref.watch calls live at the top of a dedicated build() (code-standards.md)
// and the AnimatedSwitcher persists across rebuilds for smooth transitions.
// ---------------------------------------------------------------------------

class _HomeRouter extends ConsumerWidget {
  final bool? hasDeviceUser;
  final bool supabaseHasSession;

  const _HomeRouter({
    required this.hasDeviceUser,
    required this.supabaseHasSession,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authProvider);
    final user = auth.value;
    final localBusinessesAsync = ref.watch(localBusinessesProvider);

    final blockedMessage = ref.watch(_accountBlockedMessageProvider);

    final screen = _resolve(
      auth: auth,
      user: user,
      blockedMessage: blockedMessage,
      localBusinessesAsync: localBusinessesAsync,
      // #142 — resolved here (in `build`) so the router rebuilds when the
      // driver's permissions land, rather than reading a stale one-shot.
      isDriverTerminal: ref.watch(driverTerminalActiveProvider),
    );

    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 350),
      transitionBuilder: (child, anim) =>
          FadeTransition(opacity: anim, child: child),
      child: KeyedSubtree(
        key: ValueKey(screen.runtimeType),
        child: screen,
      ),
    );
  }

  Widget _resolve({
    required AuthService auth,
    required UserData? user,
    required String? blockedMessage,
    required AsyncValue<List<BusinessData>> localBusinessesAsync,
    required bool isDriverTerminal,
  }) {
    if (user == null) {
      // Still reading SharedPreferences — show branded splash.
      if (hasDeviceUser == null) return const _BrandedSplash();
      // New device / fresh install → email entry flow.
      //
      // Legacy in-progress onboarding (a half-built business from
      // before the collect-first wizard) is no longer auto-resumed
      // — the new wizard commits atomically, so abandonment can't leave
      // a half-state to resume into. Users in that transitional bucket
      // re-enter via EmailEntry.
      //
      // #425: with the Browse-first switch on, a phone with no business user
      // (fresh install, or after a logout — logout always wipes) opens on
      // Browse instead; its "Sell on Reebaplus" pushes today's Welcome.
      //
      // Known device — the cold-start restore (`_checkDeviceUser`) binds the
      // device user before the splash lifts, so it opens straight into the
      // shop (#812: no PIN screen). Another staff member on a shared till
      // logs out (which wipes) and signs in with their own email code.
      return entryScreenWithoutSignedInUser(hasDeviceUser: hasDeviceUser!);
    }

    // Session-gate. Local user is set but Supabase has no JWT —
    // mounting MainLayout here would render a logged-in shell that
    // can't reach the cloud: every write would pile up in the queue
    // with `pushPending` skipping on "no auth session" and the Sync
    // Issues screen reporting "no profiles row for current
    // auth.uid()". Bounce through OTP instead so the JWT is
    // re-established before any tenant-scoped UI renders.
    if (!supabaseHasSession) {
      return _SessionExpiredScreen(user: user);
    }

    // Offline-first entry (Invariant #1): a logged-in device ALWAYS reaches
    // MainLayout — entry is never gated on a network pull. We only wait for the
    // local `businesses` query to RESOLVE (a SQLite read that completes in
    // milliseconds, never a network call) so MainLayout doesn't flash before
    // the local read lands; while it's still loading show the branded splash.
    //
    // We deliberately do NOT block on whether a `businesses` row or any
    // products exist yet. A fresh sign-in's data streams in live: the minimum
    // pull (4 tables) runs at the sign-in boundary (`syncOnLogin`) and the full
    // pull fires non-blocking from `setCurrentUser`. MainLayout renders an
    // empty-but-functional shell that reactively fills as rows land — exactly
    // the same way a returning device opens instantly offline. No "Syncing Your
    // Store" loader ever holds the user out; sync progress/failures surface
    // non-blockingly (online indicator + Sync Issues screen).
    if (!localBusinessesAsync.hasValue && !localBusinessesAsync.hasError) {
      return const _BrandedSplash();
    }

    // A suspended / plan-paused member never sees the shop (#812).
    if (blockedMessage != null) {
      return _AccountBlockedScreen(message: blockedMessage);
    }

    // Special post-login screens. Nothing sets these since the PIN screens
    // went (#812); kept until the screens themselves are retired.
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

    // #586: the app never locks. A lapsed plan drops to Free; owner banners
    // (main_layout) explain it.

    // #142 (PRD #139 / ADR 0019, van-sales spec §9.2) — a DRIVER never sees the
    // shop. They get the stripped terminal INSTEAD of [MainLayout], not a mode
    // of it: that is what makes "no store picker, no registered customer, no
    // credit, no discount, no crate surfaces" structural rather than a set of
    // hidden widgets someone can un-hide. It also means a driver cannot reach
    // Load Van, the reconcile screen or Record Payment — there is no drawer and
    // no tab bar to reach them from, on top of `Gates.vanManage` refusing them.
    //
    // Placed AFTER the subscription gate deliberately: a locked business locks
    // for everyone, drivers included.
    if (isDriverTerminal) {
      return const DriverTerminalScreen();
    }

    return const MainLayout();
  }
}
