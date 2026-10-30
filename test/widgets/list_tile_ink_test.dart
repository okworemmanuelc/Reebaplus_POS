import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/features/settings/screens/settings_page_parts.dart';

void main() {
  testWidgets('a SwitchListTile inside SettingsCard raises no ink warning (#62)', (
    tester,
  ) async {
    final errors = <FlutterErrorDetails>[];
    final original = FlutterError.onError;
    FlutterError.onError = errors.add;
    try {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SettingsCard(
              child: SwitchListTile(
                value: true,
                onChanged: (_) {},
                title: const Text('Track empty crates'),
              ),
            ),
          ),
        ),
      );
    } finally {
      FlutterError.onError = original;
    }
    expect(errors, isEmpty);
  });
}
