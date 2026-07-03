/// The Gate algebra — a small, **pure** predicate language over the resolved
/// permission set and role tier (ADR 0002, CONTEXT.md glossary → *Gate*).
///
/// A [Gate] is a yes/no rule. Atoms (`key`, `anyKey`, `allKeys`, `tierAtLeast`,
/// `ceo`) compose with [Gate.and] / [Gate.or] into the composite rules the app
/// needs. Evaluation is a pure function of a [GateContext] — **no Riverpod, no
/// Flutter** — so every gate's semantics are unit-testable without pumping a
/// widget (issue #16, user story 19). The registry ([Gates]) names each rule
/// once; call sites cite the name and never re-derive the rule.
///
/// **Fails closed while the role is unresolved.** A fresh login (or the
/// post-login background pull) leaves the permission set empty and the role
/// rank null; every atom then evaluates false, so a gate denies until grants
/// land — money and gated actions never flash in for an unresolved role
/// (§19.3). **CEO is all-on** in practice because the CEO role is seeded with
/// every grant, so [KeyGate] passes for the owner; the explicit [CeoGate] atom
/// covers the composite cases where the owner should pass *without* holding the
/// specific grant (e.g. Sync Issues).
library;

/// Role seniority ranks, mirroring `roleRank()` in `role_display.dart` (lower =
/// more senior). Kept here as plain ints so the algebra stays Flutter-free; the
/// widget glue maps the live role slug onto these when building a [GateContext].
abstract final class GateTier {
  static const int ceo = 0;
  static const int manager = 1;
  static const int cashier = 2;
  static const int stockKeeper = 3;
}

/// The resolved inputs a [Gate] evaluates against: the effective permission
/// keys, the role's seniority rank (null ⇒ role not resolved yet), and whether
/// the permission set has finished resolving locally (drives the screen guard's
/// no-flash policy — inline gates only need the fail-closed empties).
class GateContext {
  const GateContext({
    required this.grantedKeys,
    required this.roleRank,
    required this.isReady,
  });

  /// The effective permission keys for the current user (User > Store >
  /// Business resolution, CEO all-on) — i.e. `currentUserPermissionsProvider`.
  final Set<String> grantedKeys;

  /// The current role's rank per [GateTier] (0 = CEO … 4 = unknown), or null
  /// while the role row has not resolved locally. Null makes every tier atom
  /// fail closed.
  final int? roleRank;

  /// Whether the permission set has finished resolving locally
  /// (`currentUserPermissionsReadyProvider`). Only the screen guard consults
  /// this — inline gates hide-while-loading via the fail-closed empties.
  final bool isReady;

  /// A fail-closed context: nothing granted, role unresolved. The value an
  /// unresolved session presents; every gate denies against it.
  static const GateContext unresolved = GateContext(
    grantedKeys: <String>{},
    roleRank: null,
    isReady: false,
  );
}

/// A pure yes/no permission rule. Build with the atom factories
/// ([Gate.key], [Gate.anyKey], [Gate.allKeys], [Gate.tierAtLeast], [Gate.ceo])
/// and compose with [and] / [or]. Evaluate with [evaluate].
sealed class Gate {
  const Gate();

  /// Grants iff the effective permission set contains [key].
  const factory Gate.key(String key) = KeyGate;

  /// Grants iff the effective permission set contains **any** of [keys]
  /// (the any-of gate, e.g. Receive Stock = `stock.add` OR `products.add`).
  const factory Gate.anyKey(List<String> keys) = AnyKeyGate;

  /// Grants iff the effective permission set contains **all** of [keys].
  const factory Gate.allKeys(List<String> keys) = AllKeysGate;

  /// Grants iff the role rank is at least [minRank] (i.e. `rank <= minRank`,
  /// since lower is more senior). Convention-bound — reserved for verbatim
  /// legacy lifts and the §19.3 money-visibility class (ADR 0002).
  const factory Gate.tierAtLeast(int minRank) = TierAtLeastGate;

  /// Grants iff the current role is the CEO (owner). Used for composite gates
  /// where the owner passes without holding the specific grant.
  const factory Gate.ceo() = CeoGate;

  /// Pure evaluation against [ctx]. Fails closed for an unresolved role.
  bool evaluate(GateContext ctx);

  /// This gate AND [other].
  Gate and(Gate other) => AndGate(this, other);

  /// This gate OR [other].
  Gate or(Gate other) => OrGate(this, other);
}

/// Grants iff the permission set contains [key].
final class KeyGate extends Gate {
  const KeyGate(this.key);
  final String key;

  @override
  bool evaluate(GateContext ctx) => ctx.grantedKeys.contains(key);
}

/// Grants iff the permission set contains any of [keys].
final class AnyKeyGate extends Gate {
  const AnyKeyGate(this.keys);
  final List<String> keys;

  @override
  bool evaluate(GateContext ctx) => keys.any(ctx.grantedKeys.contains);
}

/// Grants iff the permission set contains all of [keys].
final class AllKeysGate extends Gate {
  const AllKeysGate(this.keys);
  final List<String> keys;

  @override
  bool evaluate(GateContext ctx) => keys.every(ctx.grantedKeys.contains);
}

/// Grants iff the role rank is at least [minRank] (rank <= minRank).
final class TierAtLeastGate extends Gate {
  const TierAtLeastGate(this.minRank);
  final int minRank;

  @override
  bool evaluate(GateContext ctx) {
    final rank = ctx.roleRank;
    return rank != null && rank <= minRank;
  }
}

/// Grants iff the current role is the CEO.
final class CeoGate extends Gate {
  const CeoGate();

  @override
  bool evaluate(GateContext ctx) => ctx.roleRank == GateTier.ceo;
}

/// Grants iff both [left] and [right] grant.
final class AndGate extends Gate {
  const AndGate(this.left, this.right);
  final Gate left;
  final Gate right;

  @override
  bool evaluate(GateContext ctx) => left.evaluate(ctx) && right.evaluate(ctx);
}

/// Grants iff [left] or [right] grants.
final class OrGate extends Gate {
  const OrGate(this.left, this.right);
  final Gate left;
  final Gate right;

  @override
  bool evaluate(GateContext ctx) => left.evaluate(ctx) || right.evaluate(ctx);
}

/// Thrown by the imperative gate check (`Gates.x.require(ref)`) when the current
/// user is denied. Carries the gate's [gateName] (stable id, for telemetry) and
/// its human-readable [action] (for denial feedback). A flow-level call site
/// catches it into the standard denial feedback; an **uncaught** one reaches the
/// §33 global error net and lands in the synced `error_logs`, carrying the gate
/// name — so a missed enforcement layer surfaces as data, not a silent leak
/// (ADR 0002).
class GateDeniedError implements Exception {
  const GateDeniedError({required this.gateName, required this.action});

  /// Stable registry id of the denied gate (e.g. `receiveStock`).
  final String gateName;

  /// Human-readable action name (e.g. `Receive Stock`).
  final String action;

  @override
  String toString() => 'GateDeniedError(gate: $gateName, action: "$action")';
}
