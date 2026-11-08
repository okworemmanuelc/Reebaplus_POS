import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/services/crash_reporter.dart';

void main() {
  test('kAppVersion matches the version in pubspec.yaml (#771)', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final match =
        RegExp(r'^version:\s*(\S+)', multiLine: true).firstMatch(pubspec);
    expect(match, isNotNull);
    expect(kAppVersion, match!.group(1));
  });
}
