// Ban: lib/core must not import lib/features (dependency points one way,
// features -> core). Remaining offenders are allowlisted; shrink, never grow.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// TODO(#576): each needs a redesign (providers wiring feature services /
// a feature type used by a core provider); not a mechanical move.
const _allowlist = <String>{
  'lib/core/providers/app_providers.dart',
  'lib/core/providers/stream_providers.dart',
  'lib/core/online_orders/online_order_slip.dart',
};

void main() {
  test('lib/core does not import lib/features (except allowlist)', () {
    final pattern = RegExp(
      r'''^\s*(import|export)\s+['"](package:reebaplus_pos/features/|(\.\./)+features/)''',
      multiLine: true,
    );
    final offenders = <String>[];
    for (final e in Directory('lib/core').listSync(recursive: true)) {
      if (e is! File || !e.path.endsWith('.dart')) continue;
      if (_allowlist.contains(e.path)) continue;
      if (pattern.hasMatch(e.readAsStringSync())) offenders.add(e.path);
    }
    expect(offenders, isEmpty,
        reason: 'lib/core must not import lib/features: $offenders');
  });
}
