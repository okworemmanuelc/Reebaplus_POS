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

  /// `suspended` (master plan §9.5 / §8.3) — lock the app. The PIN screen
  /// refuses a suspended member's PIN, so they can't unlock themselves again.
  /// UI-only lock: the Supabase session and local data are kept.
  lock,

  /// `removed` (#117 staff offboarding) — the user was removed by an admin (the
  /// `remove_staff_member` RPC) or resigned elsewhere. Run the same offboarding
  /// the drawer logout uses: the unsynced-data gate → log out, wiping local
  /// business data only if they were the sole member on this device.
  offboard,
}

/// Maps a raw `user_businesses.status` value to the device reaction. `status`
/// is stringly-typed (the column is a free-text CHECK, not a Dart enum), so a
/// default arm is required and correct for `active` / null / any future value.
MembershipStatusReaction membershipStatusReaction(String? status) =>
    switch (status) {
      'suspended' => MembershipStatusReaction.lock,
      'removed' => MembershipStatusReaction.offboard,
      _ => MembershipStatusReaction.none,
    };
