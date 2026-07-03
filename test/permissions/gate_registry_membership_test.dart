// Registry membership seam (issue #17, ADR 0002). Asserts every declared gate
// is cited somewhere in the app (no dead entries) and that each entry's stable
// `name` matches the `Gates.<name>` field that holds it (so a citation grep is
// meaningful, and telemetry ids line up with the registry). Prior art: the
// sync-registry membership test.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/permissions/gate_registry.dart';

void main() {
  late String appBlob; // all of lib/ except the registry + barrel
  late String registrySource;

  setUpAll(() {
    final buffer = StringBuffer();
    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File) continue;
      final path = entity.path;
      if (!path.endsWith('.dart')) continue;
      if (path.endsWith('gate_registry.dart') ||
          path.endsWith('permissions.dart')) {
        continue;
      }
      buffer.writeln(entity.readAsStringSync());
    }
    appBlob = buffer.toString();
    registrySource =
        File('lib/core/permissions/gate_registry.dart').readAsStringSync();
  });

  test('every registry gate is cited at least once in the app', () {
    final uncited = <String>[];
    for (final gate in Gates.all) {
      if (!appBlob.contains('Gates.${gate.name}')) uncited.add(gate.name);
    }
    expect(
      uncited,
      isEmpty,
      reason:
          'These registry gates are declared but never cited (dead entries): '
          '$uncited. Cite them or remove them.',
    );
  });

  test('each gate.name matches its Gates.<name> declaration field', () {
    final mismatched = <String>[];
    for (final gate in Gates.all) {
      final decl = RegExp('NamedGate\\s+${gate.name}\\s*=');
      if (!decl.hasMatch(registrySource)) mismatched.add(gate.name);
    }
    expect(
      mismatched,
      isEmpty,
      reason: 'These gate names have no matching `NamedGate <name> =` field, so '
          'their citations and telemetry ids would not line up: $mismatched.',
    );
  });

  test('registry gate names are unique', () {
    final names = Gates.all.map((g) => g.name).toList();
    expect(names.toSet().length, names.length,
        reason: 'Duplicate gate name(s) in Gates.all: $names');
  });
}
