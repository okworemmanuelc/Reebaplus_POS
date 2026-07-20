// Static enforcement seam (issue #153). A source scan that bans handing a
// FOREIGN, service-owned notifier to a `ChangeNotifierProvider` anywhere in
// `lib/`. Riverpod disposes whatever notifier a `ChangeNotifierProvider` body
// returns — on teardown AND every rebuild — so a provider that returns a
// notifier owned by a long-lived service disposes it out from under its owner,
// and the next write throws "used after being disposed". Such providers must go
// through the non-owning factory `mirrorNotifier`
// (`lib/core/providers/mirror_notifier.dart`). Prior art:
// test/providers/business_scoped_stream_ban_test.dart and
// test/permissions/gate_static_ban_test.dart.
//
// The ban targets the *behaviour* (a body that RETURNS `ref.watch(…)` /
// `ref.read(…)` — a borrowed notifier), not a type, so it catches a foreign
// notifier of ANY `ChangeNotifier` subtype, not only `ValueNotifier`. A provider
// that CONSTRUCTS and owns its notifier (`=> SomeService(…)`, `=> ValueNotifier(0)`)
// is a correct use of `ChangeNotifierProvider` and is left alone.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The factory itself contains `ChangeNotifierProvider<ValueNotifier<T>>` — the
/// one place the raw primitive is correct. Never scanned.
const _factoryFile = 'lib/core/providers/mirror_notifier.dart';

/// Matches a top-level `final xProvider = ChangeNotifierProvider<…>(…)` whose
/// body immediately RETURNS a borrowed notifier — `(ref) => ref.watch(…` /
/// `ref.read(…`, or `(ref) { return ref.watch(…`. A body that returns a
/// constructor (`=> SomeService(…)`, `=> ValueNotifier(0)`) does not match, and
/// neither does the sanctioned `= mirrorNotifier<…>(…)`. Dart's `\s` and the
/// negated class span newlines, so a split-across-lines declaration and the
/// `.autoDispose` variant are still caught.
final _foreignNotifierReturn = RegExp(
  r'final\s+(\w+)\s*=\s*ChangeNotifierProvider(?:\.autoDispose)?\s*<[^(]*>\s*\(\s*\(\s*ref\s*\)\s*(?:=>\s*|\{\s*return\s+)ref\.(?:watch|read)\s*\(',
);

void main() {
  test(
      'no ChangeNotifierProvider returns a foreign, service-owned notifier '
      '(they must go through mirrorNotifier)', () {
    final offenders = <String>[]; // "name  (path)"
    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File) continue;
      final path = entity.path;
      if (!path.endsWith('.dart') || path.endsWith('.g.dart')) continue;
      if (path == _factoryFile) continue;
      for (final m
          in _foreignNotifierReturn.allMatches(entity.readAsStringSync())) {
        offenders.add('${m.group(1)}  ($path)');
      }
    }

    expect(
      offenders,
      isEmpty,
      reason:
          'A ChangeNotifierProvider returns a borrowed notifier (ref.watch/read). '
          'Riverpod disposes whatever the body returns — on teardown AND every '
          'rebuild — so a service-owned notifier gets disposed out from under its '
          'owner (use-after-dispose). Declare it through the factory instead: '
          'mirrorNotifier<T>((ref) => ref.watch(service).theNotifier) '
          '(lib/core/providers/mirror_notifier.dart, issue #153).\n'
          '${offenders.join('\n')}',
    );
  });

  test('the scan is strict — a planted foreign return is caught for ANY notifier '
      'type; owned + migrated forms are not', () {
    // A foreign-owned ValueNotifier return is caught…
    const plantedValueNotifier =
        'final xProvider = ChangeNotifierProvider<ValueNotifier<int>>('
        '(ref) => ref.watch(svcProvider).someNotifier);';
    expect(_foreignNotifierReturn.hasMatch(plantedValueNotifier), isTrue,
        reason: 'a re-introduced foreign ValueNotifier return must be caught');

    // …a foreign-owned NON-ValueNotifier ChangeNotifier return is ALSO caught —
    // the same use-after-dispose class the AC names, which a `<ValueNotifier`
    // type-only ban would have missed…
    const plantedOtherNotifier =
        'final xProvider = ChangeNotifierProvider<FooController>('
        '(ref) => ref.watch(svcProvider).fooController);';
    expect(_foreignNotifierReturn.hasMatch(plantedOtherNotifier), isTrue,
        reason: 'a foreign notifier of any ChangeNotifier subtype must be caught');

    // …a block body, `ref.read`, and a split-across-lines / autoDispose form…
    const plantedBlockMultiline =
        'final xProvider =\n    ChangeNotifierProvider<FooController>((ref) {\n'
        '  return ref.read(svcProvider).fooController;\n});';
    expect(_foreignNotifierReturn.hasMatch(plantedBlockMultiline), isTrue,
        reason: 'a block/ref.read/multiline declaration must still be caught');
    const plantedAutoDispose =
        'final xProvider = ChangeNotifierProvider.autoDispose<ValueNotifier<int>>('
        '(ref) => ref.watch(s).n);';
    expect(_foreignNotifierReturn.hasMatch(plantedAutoDispose), isTrue,
        reason: 'the autoDispose variant must still be caught');

    // …a provider that CONSTRUCTS and OWNS its notifier is NOT flagged (a
    // correct use of ChangeNotifierProvider — the bug is only borrowed notifiers)…
    const ownedService =
        'final xProvider = ChangeNotifierProvider<CartService>('
        '(ref) => CartService(ref.read(a), ref.read(b)));';
    expect(_foreignNotifierReturn.hasMatch(ownedService), isFalse,
        reason: 'a provider that constructs+owns its notifier must not be flagged');
    const ownedValueNotifier =
        'final xProvider = ChangeNotifierProvider<ValueNotifier<int>>('
        '(ref) => ValueNotifier(0));';
    expect(_foreignNotifierReturn.hasMatch(ownedValueNotifier), isFalse,
        reason: 'a self-constructed ValueNotifier must not be forced onto '
            'mirrorNotifier (that would leak it — the helper never disposes the '
            'original)');

    // …and the sanctioned factory form never trips the ban.
    const migrated =
        'final xProvider = mirrorNotifier<int>((ref) => ref.watch(svc).n);';
    expect(_foreignNotifierReturn.hasMatch(migrated), isFalse,
        reason: 'a factory-built provider must not trip the ban');
  });
}
