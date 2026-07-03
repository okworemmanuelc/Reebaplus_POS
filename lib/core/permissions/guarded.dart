import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:reebaplus_pos/core/permissions/gate.dart';
import 'package:reebaplus_pos/core/permissions/gate_registry.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/utils/notifications.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/shared/utils/role_display.dart';

/// The live [GateContext] for the current user — the single Riverpod seam
/// between the pure Gate algebra and the app's permission providers. Watches
/// the effective permission set, the role tier, and the permissions-ready
/// signal; every [Guarded], [GateEvaluation.allows], and `require` reads it.
final gateContextProvider = Provider<GateContext>((ref) {
  final role = ref.watch(currentUserRoleProvider);
  return GateContext(
    grantedKeys: ref.watch(currentUserPermissionsProvider),
    roleRank: role == null ? null : roleRank(role.slug),
    isReady: ref.watch(currentUserPermissionsReadyProvider),
  );
});

/// Evaluate a named gate against the live permission set. The three forms map
/// to the three enforcement layers (ADR 0002): [allows] render-gates in a
/// `build` (reactive — live revocation removes the child), [allowsNow]
/// re-checks once at a callback's fire time, and [require] throws at the top of
/// a multi-step flow. All three cite the named gate — none re-derive the rule.
extension GateEvaluation on NamedGate {
  /// Reactive check for a `build` method — rebuilds when the permission set
  /// changes. The drop-in for `hasPermission(ref, key)` in a build.
  bool allows(WidgetRef ref) => rule.evaluate(ref.watch(gateContextProvider));

  /// One-shot check for a callback or flow — the current decision without
  /// subscribing. Use in tap handlers and domain sequences.
  bool allowsNow(WidgetRef ref) => rule.evaluate(ref.read(gateContextProvider));

  /// Imperative write-boundary guard: throws [GateDeniedError] (carrying this
  /// gate's name) when denied. Flow call sites catch it into the standard
  /// denial feedback; an uncaught one becomes error-log telemetry.
  void require(WidgetRef ref) {
    if (!allowsNow(ref)) {
      throw GateDeniedError(gateName: name, action: action);
    }
  }
}

/// Show the one standard "you no longer have access" denial feedback for a
/// gate. Used by the [GateAllow] fire-time wrapper; a single message shape so
/// every denied tap reads the same (issue #16, user story 14).
void showGateDenied(BuildContext context, NamedGate gate) {
  AppNotification.showError(
    context,
    'You no longer have access to ${gate.action}.',
  );
}

/// The wrapper handed to a [Guarded] builder. Its [call] takes the child's
/// action callback and returns a callback that **re-checks the live permission
/// set at fire time** — so a stale button (a frame before revocation removes
/// it) can't execute a revoked action; the tap is blocked with the standard
/// denial feedback instead. The action callback only ever exists wrapped, so
/// the write-boundary re-check is inseparable from rendering (ADR 0002).
class GateAllow {
  const GateAllow._(this._gate, this._ref, this._context);

  final NamedGate _gate;
  final WidgetRef _ref;
  final BuildContext _context;

  /// Wrap [action] with the fire-time re-check.
  VoidCallback call(VoidCallback action) {
    return () {
      if (_gate.rule.evaluate(_ref.read(gateContextProvider))) {
        action();
      } else {
        showGateDenied(_context, _gate);
      }
    };
  }
}

/// Signature of a [Guarded] builder: builds the gated child, wiring its action
/// callbacks through [allow] so they carry the fire-time re-check.
typedef GuardedBuilder = Widget Function(BuildContext context, GateAllow allow);

/// Render-gate a gated action (ADR 0002 — the render + write layers as one
/// widget contract). While the gate denies (incl. while permissions are still
/// loading — fail-closed) it renders [fallback] (default: nothing) — **hide,
/// don't disable** (hard rule #7). When granted it renders `builder(context,
/// allow)`, and the builder must route its action callback through `allow` so
/// the tap re-checks live at fire time. Reactive: a mid-session revocation
/// removes the child immediately.
///
/// For a full-screen body-guard (wait-for-ready, standard no-access scaffold),
/// use [Guarded.screen].
class Guarded extends ConsumerWidget {
  const Guarded({
    super.key,
    required this.gate,
    required this.builder,
    this.fallback,
  });

  final NamedGate gate;
  final GuardedBuilder builder;

  /// Rendered while the gate denies. Defaults to nothing (hide).
  final Widget? fallback;

  /// Full-screen body-guard for a route: waits for permissions to resolve (no
  /// denial flash), then renders [builder] when granted or a standard
  /// no-access scaffold (naming the gate's action) when denied. Replaces
  /// hand-rolled per-screen denial scaffolds.
  static Widget screen({
    Key? key,
    required NamedGate gate,
    required WidgetBuilder builder,
    Widget? loading,
    Widget? denied,
  }) {
    return _GuardedScreen(
      key: key,
      gate: gate,
      builder: builder,
      loading: loading,
      denied: denied,
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ctx = ref.watch(gateContextProvider);
    if (!gate.rule.evaluate(ctx)) {
      return fallback ?? const SizedBox.shrink();
    }
    return builder(context, GateAllow._(gate, ref, context));
  }
}

class _GuardedScreen extends ConsumerWidget {
  const _GuardedScreen({
    super.key,
    required this.gate,
    required this.builder,
    this.loading,
    this.denied,
  });

  final NamedGate gate;
  final WidgetBuilder builder;
  final Widget? loading;
  final Widget? denied;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ctx = ref.watch(gateContextProvider);
    // Wait for the permission set to resolve before deciding, so a screen the
    // user IS allowed on never flashes "no access" during grant resolution
    // (the CEO-lands-on-POS flash).
    if (!ctx.isReady) {
      return loading ?? const _GateResolvingScaffold();
    }
    if (!gate.rule.evaluate(ctx)) {
      return denied ?? GateNoAccessScaffold(gate: gate);
    }
    return builder(context);
  }
}

/// Neutral hold shown by [Guarded.screen] while permissions resolve — a plain
/// surface, never a denial, so there is no no-access flash.
class _GateResolvingScaffold extends StatelessWidget {
  const _GateResolvingScaffold();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Theme.of(context).colorScheme.surface,
      body: const SizedBox.shrink(),
    );
  }
}

/// The one standard no-access scaffold rendered by [Guarded.screen] when a
/// route is definitively denied — names the gate's [NamedGate.action] so the
/// user understands what they can't reach (issue #16, user stories 4 & 14).
class GateNoAccessScaffold extends StatelessWidget {
  const GateNoAccessScaffold({super.key, required this.gate});

  final NamedGate gate;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: theme.colorScheme.surface,
      appBar: AppBar(
        title: Text(gate.action),
        backgroundColor: theme.colorScheme.surface,
        elevation: 0,
        centerTitle: true,
      ),
      body: Center(
        child: Padding(
          padding: EdgeInsets.all(context.getRSize(24)),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.lock_outline,
                size: context.getRSize(48),
                color: theme.disabledColor,
              ),
              SizedBox(height: context.getRSize(16)),
              Text(
                "You don't have access to ${gate.action}.",
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
