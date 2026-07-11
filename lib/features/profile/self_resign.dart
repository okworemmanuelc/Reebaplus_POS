import 'package:reebaplus_pos/core/database/app_database.dart';

/// Whether the current user may self-resign (#117 staff offboarding). Any
/// non-owner staff member can "Leave / delete my account" from Profile — no
/// permission is required. The business OWNER (the CEO — one owner per business,
/// CLAUDE.md) can NOT: their exit is Delete Business (the `delete_business` RPC
/// flow), so the Profile action for them is Delete Business instead.
///
/// Returns `false` while the role is still resolving (`null`) so the resign
/// action never flashes on screen before ownership is known — the server RPC
/// rejects the owner regardless (`cannot_resign_owner`), this is the UI belt to
/// that server suspenders.
bool canSelfResign(RoleData? role) => role != null && role.slug != 'ceo';

/// Whether the Profile screen should offer the owner's Delete Business action
/// instead of the resign action. True only once the role has resolved to the
/// CEO (owner); false while unresolved so nothing flashes before ownership is
/// known.
bool isOwnerRole(RoleData? role) => role != null && role.slug == 'ceo';
