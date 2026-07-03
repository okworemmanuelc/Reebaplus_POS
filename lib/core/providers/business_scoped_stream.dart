/// Business-scoped stream providers via a guarded factory (ADR 0003).
///
/// **The bug this retires.** A `StreamProvider` that calls a business-scoped DAO
/// `watch*()` bakes the session businessId into its Drift query once, at first
/// build, via `requireBusinessId()` — which THROWS when no business is bound.
/// Because such a provider's only dependency is the never-changing
/// `databaseProvider`, a first subscribe during the brief null-businessId window
/// (the create-business handoff, where `setCurrentUser` binds the id only after
/// the post-onboarding pull) errors and STICKS for the whole session — every
/// store picker renders empty until a cold restart. A quieter sibling that reads
/// `db.currentBusinessId` synchronously silent-empty-sticks the same way.
///
/// **The fix.** Declaring a stream through [businessScopedStream] (or its family
/// / autoDispose variants) makes the bug unrepresentable: the factory *owns the
/// declaration*. It watches [currentBusinessIdProvider], emits the required
/// [BusinessScopedCreate]-paired `whenAbsent` value while the id is null, and
/// passes the resolved NON-NULL businessId into the closure — so the closure is
/// total (`requireBusinessId()` can never throw from a factory-built provider),
/// it rebuilds the instant a business binds, and it re-queries on a business
/// switch (a free property of watching the seam). The static ban test
/// (`test/providers/business_scoped_stream_ban_test.dart`) keeps every new
/// business-scoped stream on the factory.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';

/// The single watchable source of the current session's businessId (ADR 0003 —
/// the *Current Business Id* seam). Null until a business binds (login, or the
/// create-business handoff). Nothing else re-derives "who is the current
/// tenant"; the factory watches this, and tests flip it via `overrideWith` to
/// drive the guard without spinning up a database. Non-reactive
/// `db.currentBusinessId` reads behind a stream are the anti-pattern this
/// replaces — they bake the id at build time and stick stale/empty.
final currentBusinessIdProvider = Provider<String?>((ref) {
  return ref.watch(authProvider.select((a) => a.currentUser?.businessId));
});

/// Builds the real, business-scoped stream once an id is bound. Receives the
/// provider [ref] (so a scoped stream can still compose sibling providers —
/// e.g. the active-store `lockedStoreProvider` — which several store-scoped
/// feeds need), the [AppDatabase], and the resolved **non-null** [businessId].
/// A DAO-watch closure ignores the id (the DAO reads it from the session); a
/// custom-SQL closure uses it directly (`WHERE business_id = ?`).
typedef BusinessScopedCreate<T> =
    Stream<T> Function(Ref ref, AppDatabase db, String businessId);

/// The keyed ([Arg]) counterpart of [BusinessScopedCreate].
typedef BusinessScopedFamilyCreate<T, Arg> =
    Stream<T> Function(Ref ref, AppDatabase db, String businessId, Arg arg);

/// A guarded, keep-alive business-scoped [StreamProvider]. Emits [whenAbsent]
/// while no business is bound, then swaps in `create(...)` the instant one binds.
StreamProvider<T> businessScopedStream<T>(
  BusinessScopedCreate<T> create, {
  required T whenAbsent,
}) {
  return StreamProvider<T>((ref) {
    final businessId = ref.watch(currentBusinessIdProvider);
    if (businessId == null) return Stream<T>.value(whenAbsent);
    return create(ref, ref.watch(databaseProvider), businessId);
  });
}

/// The `autoDispose` variant of [businessScopedStream] — same guard, torn down
/// when no longer watched.
AutoDisposeStreamProvider<T> businessScopedStreamAutoDispose<T>(
  BusinessScopedCreate<T> create, {
  required T whenAbsent,
}) {
  return StreamProvider.autoDispose<T>((ref) {
    final businessId = ref.watch(currentBusinessIdProvider);
    if (businessId == null) return Stream<T>.value(whenAbsent);
    return create(ref, ref.watch(databaseProvider), businessId);
  });
}

/// The keyed ([Arg]) variant. Riverpod cannot emit both plain and family
/// providers from one function, so keyed business-scoped streams get their own
/// guarded front door rather than a hand-written carve-out.
StreamProviderFamily<T, Arg> businessScopedStreamFamily<T, Arg>(
  BusinessScopedFamilyCreate<T, Arg> create, {
  required T whenAbsent,
}) {
  return StreamProvider.family<T, Arg>((ref, arg) {
    final businessId = ref.watch(currentBusinessIdProvider);
    if (businessId == null) return Stream<T>.value(whenAbsent);
    return create(ref, ref.watch(databaseProvider), businessId, arg);
  });
}

/// The `autoDispose` keyed variant of [businessScopedStreamFamily].
AutoDisposeStreamProviderFamily<T, Arg>
businessScopedStreamAutoDisposeFamily<T, Arg>(
  BusinessScopedFamilyCreate<T, Arg> create, {
  required T whenAbsent,
}) {
  return StreamProvider.autoDispose.family<T, Arg>((ref, arg) {
    final businessId = ref.watch(currentBusinessIdProvider);
    if (businessId == null) return Stream<T>.value(whenAbsent);
    return create(ref, ref.watch(databaseProvider), businessId, arg);
  });
}
