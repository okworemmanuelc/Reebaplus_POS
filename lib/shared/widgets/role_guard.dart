import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:reebaplus_pos/core/providers/app_providers.dart';

/// Gates [child] on the current user's role tier.
///
/// Renders [child] when `currentUser.roleTier >= minTier`, otherwise renders
/// [fallback] (or `SizedBox.shrink()` if no fallback is supplied). Defaults
/// fail-closed: an unauthenticated user (`currentUser == null`) is treated
/// as tier 0 and gated out of every guard.
///
/// Tier vocabulary (v9):
///   2 = Rider, 3 = Cashier, 4 = Stock Keeper, 5 = Manager, 6 = CEO.
///
/// Watches [authProvider] so the guard re-evaluates immediately on
/// login / logout / role change (e.g. after a domain RPC that promotes
/// a member, which flips the local row and ticks the notifier).
class RoleGuard extends ConsumerWidget {
  final int minTier;
  final Widget child;
  final Widget? fallback;

  const RoleGuard({
    super.key,
    required this.minTier,
    required this.child,
    this.fallback,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tier = ref.watch(authProvider).currentUser?.roleTier ?? 0;
    if (tier >= minTier) return child;
    return fallback ?? const SizedBox.shrink();
  }
}
