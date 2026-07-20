/// Non-owning bridge from a service-owned `ValueNotifier` into Riverpod
/// (issue #153).
///
/// **The bug this retires.** `ChangeNotifierProvider<T>` *takes ownership of,
/// and disposes,* whatever `T` its body returns — on the provider being torn
/// down AND on every rebuild. Returning a notifier owned by a long-lived
/// service is therefore unsafe: Riverpod disposes a notifier the service still
/// writes to, and the next `notifier.value = …` throws
/// `A ValueNotifier<…> was used after being disposed`. It bites readily when the
/// selected service is itself a `ChangeNotifier` (e.g. `AuthService`), because
/// every notify rebuilds the provider and re-disposes the same foreign notifier.
///
/// ```dart
/// // UNSAFE — Riverpod disposes a notifier AuthService owns and keeps writing to.
/// final deviceUserIdProvider = ChangeNotifierProvider<ValueNotifier<String?>>(
///   (ref) => ref.watch(authProvider).deviceUserIdNotifier,
/// );
/// ```
///
/// **The fix.** [mirrorNotifier] makes the bug unrepresentable: it constructs a
/// local *proxy* `ValueNotifier` (the only thing Riverpod owns and disposes) and
/// two-way-mirrors it to the [select]ed service notifier with listeners that are
/// removed on dispose. The original is only ever listened to — never disposed —
/// so it survives every rebuild and teardown. Consumers see identical values in
/// both directions, so behaviour is unchanged.
///
/// The static ban test (`test/providers/mirror_notifier_ban_test.dart`) keeps
/// every `ChangeNotifierProvider<ValueNotifier<…>>` on this factory so the
/// anti-pattern cannot re-enter.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Selects the service-owned [ValueNotifier] to mirror. Receives the provider
/// [ref] so the selection can `ref.watch`/`ref.read` the owning service (the
/// mirror stays correct even when that watch rebuilds the provider).
typedef NotifierSelector<T> = ValueNotifier<T> Function(Ref ref);

/// Re-exposes the service-owned [ValueNotifier] returned by [select] through a
/// `ChangeNotifierProvider` **without taking ownership of it**. Riverpod owns and
/// disposes only the local proxy; the selected notifier is never disposed here.
///
/// Use this for any provider that lifts a notifier owned by another object into
/// Riverpod. A provider that *constructs and owns* its notifier does not need it.
ChangeNotifierProvider<ValueNotifier<T>> mirrorNotifier<T>(
  NotifierSelector<T> select,
) {
  return ChangeNotifierProvider<ValueNotifier<T>>((ref) {
    final original = select(ref);
    final proxy = ValueNotifier<T>(original.value);

    void originalListener() {
      if (proxy.value != original.value) proxy.value = original.value;
    }

    void proxyListener() {
      if (original.value != proxy.value) original.value = proxy.value;
    }

    original.addListener(originalListener);
    proxy.addListener(proxyListener);
    // Only detach from the original — Riverpod disposes the proxy itself, which
    // clears the proxy's own listeners. The original is left untouched.
    ref.onDispose(() => original.removeListener(originalListener));

    return proxy;
  });
}
