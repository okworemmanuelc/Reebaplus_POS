import 'package:reebaplus_pos/core/database/app_database.dart' show UserData;
import 'package:reebaplus_pos/shared/services/auth_service.dart';

/// Where to send a user once their email is verified — either by the OTP code
/// or by a Google sign-in. The two entry screens build the actual destination
/// (each with its own page transition); this only decides *which* one.
sealed class PostVerifyRoute {
  const PostVerifyRoute();
}

/// Fresh device, existing cloud account, no local row yet — confirm the
/// business before pulling data and seeding a local row.
class ExistingAccountRoute extends PostVerifyRoute {
  final SupabaseAccountInfo account;
  const ExistingAccountRoute(this.account);
}

/// No cloud account and no local user — brand-new email. Master plan §7.1:
/// offer the two real entry points (create a business / join with a code).
class NoAccountFoundRoute extends PostVerifyRoute {
  const NoAccountFoundRoute();
}

/// Known user who already has a PIN on this device — enter their PIN.
class LoginRoute extends PostVerifyRoute {
  final UserData user;
  const LoginRoute(this.user);
}

/// Known user with no PIN yet (sentinel PIN from a cloud-seeded row, or a
/// reset) — create their PIN before they can sign in.
class CreatePinRoute extends PostVerifyRoute {
  final UserData user;
  const CreatePinRoute(this.user);
}

/// The cloud could not be reached, and this device holds no local row to fall
/// back on, so which business this login belongs to is simply unknown (#285).
/// The screen shows the network message and stays put — routing to sign-up
/// here would offer to create a second business for an email that already has
/// one (invariant #9).
class AccountLookupUnavailableRoute extends PostVerifyRoute {
  const AccountLookupUnavailableRoute();
}

/// The user declined to clear an older business's un-uploaded work off this
/// phone (#285 decision 3). The sign-in is abandoned and the phone is left
/// exactly as it was found.
class SignInCancelledRoute extends PostVerifyRoute {
  const SignInCancelledRoute();
}

/// Resolves the post-verification destination for [email], shared by the
/// email/OTP screen and the Google sign-in handler so the master-plan §7.2a
/// rules live in exactly one place. Drift between two copies of this logic was
/// the original Google sign-in bug (see BUILD_LOG Session 99).
///
/// The lookup is scoped to the business the sign-in authenticated for — a
/// multi-business email holds one local row per business, and binding the
/// wrong tenant's row is a cross-business leak (§7.2a).
///
/// [isPinReset] is true only on the Forgot-PIN flow, where a user who already
/// has a PIN must still be routed to create a new one. Google sign-in is never
/// a reset, so it leaves this false.
///
/// [confirmClearOtherBusiness] is asked once per older business that still
/// holds un-uploaded work, and is required rather than optional so neither
/// entry screen can silently destroy a shop's unsent sales (#285).
Future<PostVerifyRoute> resolvePostVerifyRoute(
  AuthService auth,
  String email, {
  required StaleBusinessConfirm confirmClearOtherBusiness,
  bool isPinReset = false,
}) async {
  final lookup = await auth.fetchSupabaseAccount();

  // Decision 2: act only on a clear cloud answer. A network failure clears
  // nothing — a local row still unlocks with its PIN; with none, say so rather
  // than guessing.
  if (lookup is SupabaseAccountUnavailable) {
    final offlineUser = await auth.getUserByEmail(email);
    if (offlineUser == null) return const AccountLookupUnavailableRoute();
    return _pinRouteFor(offlineUser, isPinReset: isPinReset);
  }

  final account = switch (lookup) {
    SupabaseAccountFound(:final account) => account,
    SupabaseAccountNone() => null,
    SupabaseAccountUnavailable() => null,
  };

  // Decision 1: the cloud has named this login's business (or positively said
  // it has none). Anything else on this phone belongs to a business this login
  // has left behind — a deleted tenant, or one the same Supabase identity was
  // reused away from — and must go before the pull runs, or the stale `users`
  // row's `auth_user_id` collides with the incoming one (SQLite 2067) and
  // aborts the whole minimum-login pull.
  final outcome = await auth.clearOtherLocalBusinesses(
    keepBusinessId: account?.businessId,
    confirm: confirmClearOtherBusiness,
  );
  if (outcome == StaleBusinessClearOutcome.cancelled) {
    await auth.abandonSignIn();
    return const SignInCancelledRoute();
  }

  var localUser = await auth.getUserByEmail(
    email,
    preferredBusinessId: account?.businessId,
  );

  if (account != null && localUser == null) {
    return ExistingAccountRoute(account);
  }

  if (account != null && localUser != null) {
    // Returning device — sync silently and refresh the local row.
    await auth.syncOnLogin(account.businessId);
    await auth.upsertLocalUserFromProfile();
    localUser =
        await auth.getUserByEmail(
          email,
          preferredBusinessId: account.businessId,
        ) ??
        localUser;
  }

  if (localUser == null) {
    return const NoAccountFoundRoute();
  }

  return _pinRouteFor(localUser, isPinReset: isPinReset);
}

/// PIN screen or PIN setup, depending on whether [user] already holds a real
/// PIN on this device. A row seeded from the cloud profile carries the sentinel
/// PIN — the user must set up a PIN here before they can sign in.
PostVerifyRoute _pinRouteFor(UserData user, {required bool isPinReset}) {
  final isSetupRequired = user.pin == AuthService.setupRequiredPin;
  final hasPin = user.pin.isNotEmpty && !isSetupRequired;
  if (hasPin && !isPinReset) {
    return LoginRoute(user);
  }
  return CreatePinRoute(user);
}
