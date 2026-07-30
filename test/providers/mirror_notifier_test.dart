// Behaviour spec for the `mirrorNotifier` non-owning proxy (issue #153).
//
// `ChangeNotifierProvider<T>` disposes whatever `T` its body returns — on
// teardown AND on every rebuild. When `T` is a notifier a long-lived service
// owns (e.g. `AuthService.deviceUserIdNotifier`), Riverpod disposes a notifier
// the service still writes to, and the next write throws
// "used after being disposed". `mirrorNotifier` re-exposes a service-owned
// `ValueNotifier` through Riverpod WITHOUT taking ownership: Riverpod disposes a
// local proxy, the service's notifier is only ever listened to.
//
// These tests observe that contract through the public boundary (a
// `ProviderContainer`), never internals.

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/providers/mirror_notifier.dart';

void main() {
  group('mirrorNotifier', () {
    test('seeds the proxy with the original notifier\'s current value', () {
      final original = ValueNotifier<int>(7);
      addTearDown(original.dispose);
      final provider = mirrorNotifier<int>((ref) => original);
      final container = ProviderContainer();
      addTearDown(container.dispose);

      expect(container.read(provider).value, 7);
    });

    test('mirrors changes in both directions', () {
      final original = ValueNotifier<int>(0);
      addTearDown(original.dispose);
      final provider = mirrorNotifier<int>((ref) => original);
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final proxy = container.read(provider);

      original.value = 5;
      expect(proxy.value, 5, reason: 'original → proxy');

      proxy.value = 9;
      expect(original.value, 9, reason: 'proxy → original');
    });

    test('disposing the provider does NOT dispose the service-owned original',
        () {
      final original = ValueNotifier<String?>('a');
      addTearDown(original.dispose);
      final provider = mirrorNotifier<String?>((ref) => original);
      final container = ProviderContainer();
      container.read(provider); // materialise the proxy
      container.dispose(); // Riverpod disposes the proxy it owns

      // The bug: the original would now throw "used after being disposed".
      expect(() => original.value = 'b', returnsNormally);
    });

    test('rebuilding the provider disposes only the proxy, never the original',
        () {
      // Models AuthService notifying (every login/logout) while
      // deviceUserIdProvider is alive: the selector watches a dependency that
      // changes, so ChangeNotifierProvider recomputes and disposes its proxy.
      final original = ValueNotifier<String?>('a');
      addTearDown(original.dispose);
      final tick = StateProvider<int>((ref) => 0);
      final provider = mirrorNotifier<String?>((ref) {
        ref.watch(tick); // recompute when the "auth" signal ticks
        return original;
      });
      final container = ProviderContainer();
      addTearDown(container.dispose);
      // Keep the provider alive so the tick forces an eager recompute (and the
      // old proxy is disposed) rather than a lazy one.
      final sub = container.listen(provider, (_, __) {});
      addTearDown(sub.close);

      container.read(tick.notifier).state++; // recompute → old proxy disposed

      // The original survived the rebuild — this is the re-login crash repro.
      expect(() => original.value = 'b', returnsNormally);
      expect(container.read(provider).value, 'b',
          reason: 'the fresh proxy mirrors the still-alive original');
    });
  });
}
