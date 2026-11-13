/// How the running app must react when the CURRENT user's own membership status
/// changes underneath them (a shared-till peer or an admin acts on another
/// device, the `user_businesses` row is pulled / broadcast in, and the local
/// mirror flips). Consumed by the live guard in `main.dart`.
///
/// Kept as a pure mapping (no Flutter / provider dependency) so the branching is
/// unit-testable without a live Supabase session.
enum MembershipStatusReaction {
  /// `active` (or an unresolved / unknown status) — do nothing.
  none,

  /// `suspended` (master plan §9.5 / §8.3) — block the shop. The app router
  /// shows the Account Blocked screen instead of the shop while the status
  /// stays suspended (#812 — there is no PIN screen to lock to). The user stays
  /// bound, so sync keeps running and a reactivation reopens the shop by
  /// itself; the Supabase session and local data are kept.
  block,

  /// `removed` (#117 staff offboarding) — the user was removed by an admin (the
  /// `remove_staff_member` RPC) or resigned elsewhere. Run the same offboarding
  /// the drawer logout uses: the unsynced-data gate → log out, wiping the
  /// device's local business data.
  offboard,
}

/// Maps a raw `user_businesses.status` value to the device reaction. `status`
/// is stringly-typed (the column is a free-text CHECK, not a Dart enum), so a
/// default arm is required and correct for `active` / null / any future value.
MembershipStatusReaction membershipStatusReaction(String? status) =>
    switch (status) {
      'suspended' => MembershipStatusReaction.block,
      'removed' => MembershipStatusReaction.offboard,
      _ => MembershipStatusReaction.none,
    };

/// The Account Blocked screen's message for the signed-in member, or null when
/// they may use the shop (#812). Suspension wins over a plan pause. The wording
/// is the one the old PIN screen showed when it refused these members.
String? accountBlockedMessage({required bool suspended, required bool paused}) {
  if (suspended) {
    return 'Your account is suspended. Ask your manager to reactivate it.';
  }
  if (paused) {
    return 'Your account is paused because the plan allows fewer staff '
        'accounts. Ask the owner to upgrade.';
  }
  return null;
}
