// Unit tests for the business-scoped stream factory (ADR 0003, issue #24).
//
// The module under test is the factory itself, driven through the
// [currentBusinessIdProvider] seam: null → bound → switched → unbound. We assert
// what the provider EMITS (whenAbsent → data → re-queried data), not how it is
// wired. No database is required — the `databaseProvider` override is an inert
// in-memory handle the closures ignore, and all data comes from
// `StreamController`s keyed by the resolved businessId. Prior art:
// test/permissions/guarded_test.dart (override a context provider with a
// flippable source and assert the consequence).

import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/business_scoped_stream.dart';

/// Flippable source of the current businessId; [currentBusinessIdProvider] is
/// overridden to read it, so a test drives `null → id → other-id → null`.
final _businessId = StateProvider<String?>((ref) => null);

/// Per-businessId stream sources — a business SWITCH is shown re-querying the
/// new tenant's data by handing back a different controller.
late Map<String, StreamController<String>> _emitters;

StreamController<String> _emitterFor(String key) =>
    _emitters.putIfAbsent(key, () => StreamController<String>.broadcast());

/// A plain guarded stream under test. The closure ignores `db` and returns the
/// controller keyed by the resolved (non-null) businessId.
final _probe = businessScopedStream<String>(
  (ref, db, businessId) => _emitterFor(businessId).stream,
  whenAbsent: 'ABSENT',
);

/// A guarded stream whose closure THROWS if ever run — proving the factory never
/// invokes it in the null window (the exact build-time poison a raw provider
/// hits via `requireBusinessId()`).
final _throwIfUnguarded = businessScopedStream<String>(
  (ref, db, businessId) => throw StateError('closure ran while unbound'),
  whenAbsent: 'SAFE',
);

/// The keyed front door gets the same guard.
final _familyProbe = businessScopedStreamFamily<String, String>(
  (ref, db, businessId, arg) => _emitterFor('$businessId/$arg').stream,
  whenAbsent: 'ABSENT',
);

void main() {
  late ProviderContainer container;
  late AppDatabase db;

  setUp(() {
    _emitters = {};
    db = AppDatabase.forTesting(NativeDatabase.memory());
    container = ProviderContainer(
      overrides: [
        currentBusinessIdProvider.overrideWith((ref) => ref.watch(_businessId)),
        databaseProvider.overrideWithValue(db),
      ],
    );
  });

  tearDown(() async {
    for (final c in _emitters.values) {
      await c.close();
    }
    container.dispose();
    await db.close();
  });

  void setBusiness(String? id) =>
      container.read(_businessId.notifier).state = id;

  // Let the event loop deliver Stream.value / controller events into the
  // AsyncValue state.
  Future<void> pump() async {
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
  }

  test('null window: emits whenAbsent and never runs the closure', () async {
    container.listen(_throwIfUnguarded, (_, __) {});
    container.listen(_probe, (_, __) {});
    await pump();

    final guarded = container.read(_throwIfUnguarded);
    expect(guarded, isA<AsyncData<String>>());
    expect(guarded.value, 'SAFE');
    // The throwing closure was never invoked — no poison in the null window.
    expect(guarded.hasError, isFalse);

    expect(container.read(_probe).value, 'ABSENT');
  });

  test('binds: swaps whenAbsent for the tenant stream when an id binds',
      () async {
    container.listen(_probe, (_, __) {});
    await pump();
    expect(container.read(_probe).value, 'ABSENT');

    setBusiness('biz-1');
    await pump();
    _emitterFor('biz-1').add('DATA-1');
    await pump();
    expect(container.read(_probe).value, 'DATA-1');
  });

  test('switches: re-queries the NEW tenant on a business switch', () async {
    container.listen(_probe, (_, __) {});
    setBusiness('biz-1');
    await pump();
    _emitterFor('biz-1').add('DATA-1');
    await pump();
    expect(container.read(_probe).value, 'DATA-1');

    setBusiness('biz-2'); // switch
    await pump();
    _emitterFor('biz-2').add('DATA-2');
    await pump();
    expect(
      container.read(_probe).value,
      'DATA-2',
      reason: 'the switch re-subscribed to biz-2, never leaking biz-1 data',
    );
  });

  test('unbinds: returns to whenAbsent when the business unbinds', () async {
    container.listen(_probe, (_, __) {});
    setBusiness('biz-1');
    await pump();
    _emitterFor('biz-1').add('DATA-1');
    await pump();
    expect(container.read(_probe).value, 'DATA-1');

    setBusiness(null);
    await pump();
    expect(container.read(_probe).value, 'ABSENT');
  });

  group('family variant', () {
    test('emits whenAbsent for a keyed provider in the null window', () async {
      container.listen(_familyProbe('k'), (_, __) {});
      await pump();
      expect(container.read(_familyProbe('k')).value, 'ABSENT');
    });

    test('binds per key when an id binds', () async {
      container.listen(_familyProbe('k'), (_, __) {});
      setBusiness('biz-1');
      await pump();
      _emitterFor('biz-1/k').add('DATA-1');
      await pump();
      expect(container.read(_familyProbe('k')).value, 'DATA-1');
    });
  });
}
