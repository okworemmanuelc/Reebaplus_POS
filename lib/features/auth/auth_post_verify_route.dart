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
Future<PostVerifyRoute> resolvePostVerifyRoute(
  AuthService auth,
  String email, {
  bool isPinReset = false,
}) async {
  final account = await auth.fetchSupabaseAccount();
  var localUser = await auth.getUserByEmail(
    email,
    preferredBusinessId: account?.businessId,
  );

  // Cloud confirms this auth identity has no business, yet a local row for
  // this email survives from a previous business on this device — most
  // commonly: the same email re-registered after "Delete Business & Account"
  // (§10.3) and the device's wipe never ran/completed. A confirmed
  // `deleted_businesses` tombstone for the stale row's business wipes this
  // device and clears `localUser`, so the email is treated as brand-new
  // rather than logging into the dead tenant (tenant_mismatch / RLS errors
  // on pull and push). Ambiguous results (offline, no tombstone) leave
  // `localUser` untouched — offline PIN login must keep working.
  if (account == null && localUser != null) {
    if (await auth.wipeOrphanedLocalBusiness(localUser.businessId)) {
      localUser = null;
    }
  }

  if (account != null && localUser == null) {
    return ExistingAccountRoute(account);
  }

  if (account != null && localUser != null) {
    // Returning device — sync silently and refresh the local row.
    await auth.syncOnLogin(account.businessId);
    await auth.upsertLocalUserFromProfile();
    localUser = await auth.getUserByEmail(
          email,
          preferredBusinessId: account.businessId,
        ) ??
        localUser;
  }

  if (localUser == null) {
    return const NoAccountFoundRoute();
  }

  final user = localUser;
  // A row seeded from the cloud profile carries the sentinel PIN — the user
  // must set up a PIN on this device before they can sign in.
  final isSetupRequired = user.pin == AuthService.setupRequiredPin;
  final hasPin = user.pin.isNotEmpty && !isSetupRequired;
  if (hasPin && !isPinReset) {
    return LoginRoute(user);
  }
  return CreatePinRoute(user);
}
