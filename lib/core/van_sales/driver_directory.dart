// Who belongs on the Drivers list, and how they are labelled (#146, PRD #139 as
// amended by #161 / ADR 0019, van-sales spec §9.5 #19).
//
// A pure function over four plain inputs. It is a separate file, and not a
// `where` clause inside the list screen, because the rule it encodes is a money
// rule rather than a presentation one: **offboarding must not be able to hide a
// debt.** A driver who leaves owing money stays on the list, badged, until the
// balance is settled or deliberately written off — and that has to be testable
// without a widget tree.
library;

import 'package:reebaplus_pos/core/database/app_database.dart';

/// Where a driver stands with the business right now.
///
/// Deliberately NOT the raw membership status string: [removed] is inferred
/// (see [buildDriversList]) because the local `user_businesses` row for a
/// removed member is filtered out of every scoped read, and a person whose role
/// was simply changed away from Driver is, for the money's purposes, gone too.
enum DriverStanding {
  /// A live Driver-role membership. Loadable, sellable, listed always.
  active,

  /// A suspended Driver-role membership. Still staff, still listed always —
  /// suspension is reversible and says nothing about what they owe.
  suspended,

  /// No live Driver-role membership, but the driver ledger still has a
  /// non-zero balance in their name (spec §9.5 #19). Listed, badged, and
  /// impossible to make disappear by offboarding them again.
  removed,
}

/// One row of the Drivers list.
class DriverListEntry {
  final UserData user;
  final DriverStanding standing;

  /// Cross-trip driver-ledger balance in kobo. **Negative = they owe.**
  final int balanceKobo;

  const DriverListEntry({
    required this.user,
    required this.standing,
    required this.balanceKobo,
  });

  String get userId => user.id;

  /// True when this driver still owes the business money.
  bool get owes => balanceKobo < 0;

  /// True when the business owes them (they over-remitted).
  bool get inCredit => balanceKobo > 0;

  bool get isSettled => balanceKobo == 0;

  /// True when the row is only on the list because of an unsettled debt.
  bool get isFormerDriver => standing == DriverStanding.removed;
}

/// The Drivers list, in display order (#146).
///
/// Three rules, in order of precedence:
///
///  1. **Every Driver-role membership is listed**, whatever its balance —
///     [DriverStanding.active] or [DriverStanding.suspended] from the
///     membership's own status. A driver at zero is still a driver.
///  2. **Any other user with a non-zero driver-ledger balance is listed**,
///     badged [DriverStanding.removed] (spec §9.5 #19). This is the rule that
///     survives offboarding: [removedMemberships] never reaches the client for
///     a removed member (the scoped read filters `removed` out), and a
///     role change away from Driver would drop them just as silently — so the
///     LEDGER, not the membership table, is what keeps them visible.
///  3. **A former driver at zero is not listed.** They owe nothing and are not
///     staff; keeping them would be clutter, not accountability.
///
/// Order: current drivers first (active before suspended, then by name), former
/// drivers last. A manager scanning the list sees their team, then the debts
/// that outlived it.
///
/// [driverRoleIds] is the set of role ids whose slug is `driver`;
/// [memberships] is every membership the client can see (removed rows are
/// already absent); [usersById] is every `users` row in the business — removed
/// members KEEP theirs as an attribution stub (#107), which is what makes rule 2
/// renderable at all; [balancesKobo] is `driverUserId → Σ signed_amount_kobo`,
/// with absent meaning zero.
List<DriverListEntry> buildDriversList({
  required List<UserBusinessData> memberships,
  required Set<String> driverRoleIds,
  required Map<String, UserData> usersById,
  required Map<String, int> balancesKobo,
}) {
  final entries = <String, DriverListEntry>{};

  // Rule 1 — everyone currently holding the Driver role.
  for (final m in memberships) {
    if (!driverRoleIds.contains(m.roleId)) continue;
    final user = usersById[m.userId];
    if (user == null) continue;
    // A membership row that reached the client with `removed` on it (a pull can
    // carry one even though the local scoped read filters it) is NOT a current
    // driver — fall through to rule 2 so it is badged rather than shown as staff.
    if (m.status == 'removed') continue;
    entries[m.userId] = DriverListEntry(
      user: user,
      standing: m.status == 'suspended'
          ? DriverStanding.suspended
          : DriverStanding.active,
      balanceKobo: balancesKobo[m.userId] ?? 0,
    );
  }

  // Rule 2 — anyone else the ledger still has a balance for.
  for (final id in balancesKobo.keys) {
    if (entries.containsKey(id)) continue;
    final balance = balancesKobo[id] ?? 0;
    if (balance == 0) continue; // rule 3
    final user = usersById[id];
    if (user == null) continue;
    entries[id] = DriverListEntry(
      user: user,
      standing: DriverStanding.removed,
      balanceKobo: balance,
    );
  }

  final out = entries.values.toList();
  out.sort((a, b) {
    final rank = a.standing.index.compareTo(b.standing.index);
    if (rank != 0) return rank;
    return a.user.name.toLowerCase().compareTo(b.user.name.toLowerCase());
  });
  return out;
}
