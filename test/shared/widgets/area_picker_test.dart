import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/data/area_selection.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/shared/widgets/app_input.dart';
import 'package:reebaplus_pos/shared/widgets/area_picker.dart';

Future<void> _open(
  WidgetTester tester, {
  AreaSelection? initial,
  bool wholeState = false,
  ValueChanged<AreaSelection?>? onResult,
  Size size = const Size(390, 844),
  double textScale = 1,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    theme: AppTheme.light(),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
      child: child!,
    ),
    home: Scaffold(body: Builder(builder: (context) => TextButton(
      onPressed: () async {
        final result = await showAreaPicker(
          context, initialValue: initial, allowWholeState: wholeState,
        );
        onResult?.call(result);
      },
      child: const Text('Open'),
    ))),
  ));
  await tester.tap(find.text('Open'));
  await tester.pumpAndSettle();
}

Future<void> _search(WidgetTester tester, String text) async {
  final input = find.byType(AppInput).first;
  await tester.ensureVisible(input);
  await tester.enterText(find.descendant(of: input, matching: find.byType(TextFormField)), text);
  await tester.pumpAndSettle();
}

Future<void> _choose(WidgetTester tester, String option) async {
  final tile = find.byKey(ValueKey('area-option-$option'));
  await tester.ensureVisible(tile);
  await tester.tap(tile);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('searches state then only that state\'s LGAs and returns a choice', (tester) async {
    AreaSelection? selected;
    await _open(tester, onResult: (area) => selected = area);
    await _search(tester, 'nasa');
    expect(find.byKey(const ValueKey('area-option-Lagos')), findsNothing);
    await _choose(tester, 'Nasarawa');
    await _search(tester, 'LAF');
    await _choose(tester, 'Lafia');
    expect(selected?.country, 'Nigeria');
    expect(selected?.state, 'Nasarawa');
    expect(selected?.lga, 'Lafia');
    expect(find.byType(AreaPicker), findsNothing);
  });

  testWidgets('changing state clears the old search and never returns a stale LGA', (tester) async {
    AreaSelection? selected;
    await _open(tester,
      initial: const AreaSelection(country: 'Nigeria', state: 'Nasarawa', lga: 'Lafia'),
      onResult: (area) => selected = area,
    );
    await _search(tester, 'Lafia');
    await tester.ensureVisible(find.text('Nasarawa'));
    await tester.tap(find.text('Nasarawa'));
    await tester.pumpAndSettle();
    await _search(tester, 'Lagos');
    await _choose(tester, 'Lagos');
    expect(find.byKey(const ValueKey('area-option-Lafia')), findsNothing);
    await _search(tester, 'Ikeja');
    await _choose(tester, 'Ikeja');
    expect(selected?.state, 'Lagos');
    expect(selected?.lga, 'Ikeja');
  });

  for (final allowed in [false, true]) {
    testWidgets('whole state is available only when allowed: $allowed', (tester) async {
      AreaSelection? selected;
      await _open(tester,
        initial: const AreaSelection(country: 'Nigeria', state: 'Nasarawa'),
        wholeState: allowed, onResult: (area) => selected = area,
      );
      final whole = find.byKey(const Key('area-whole-state'));
      expect(whole, allowed ? findsOneWidget : findsNothing);
      if (allowed) {
        await tester.tap(whole);
        await tester.pumpAndSettle();
        expect(selected?.isWholeState, isTrue);
        expect(selected?.state, 'Nasarawa');
      }
    });
  }

  testWidgets('unknown country allows trimmed, required region and district', (tester) async {
    AreaSelection? selected;
    await _open(tester, onResult: (area) => selected = area);
    await tester.tap(find.text('Nigeria'));
    await tester.pumpAndSettle();
    await _search(tester, '  Australia  ');
    final useCountry = find.text('Use this country');
    await tester.ensureVisible(useCountry);
    await tester.tap(useCountry);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Use this area'));
    await tester.tap(find.text('Use this area'));
    await tester.pumpAndSettle();
    expect(find.text('Enter a value'), findsNWidgets(2));
    const fields = {
      'area-foreign-state': ' Victoria ',
      'area-foreign-lga': ' Melbourne ',
    };
    for (final entry in fields.entries) {
      final field = find.descendant(
        of: find.byKey(Key(entry.key)), matching: find.byType(TextFormField),
      );
      await tester.ensureVisible(field);
      await tester.enterText(field, entry.value);
    }
    await tester.ensureVisible(find.text('Use this area'));
    await tester.tap(find.text('Use this area'));
    await tester.pumpAndSettle();
    expect(selected?.country, 'Australia');
    expect(selected?.state, 'Victoria');
    expect(selected?.lga, 'Melbourne');
  });

  testWidgets('foreign delivery area can cover a whole state when allowed', (tester) async {
    AreaSelection? selected;
    await _open(tester,
      initial: const AreaSelection(country: 'Ghana', state: 'Greater Accra', lga: 'Accra'),
      wholeState: true, onResult: (area) => selected = area,
    );
    await tester.ensureVisible(find.byType(CheckboxListTile));
    await tester.tap(find.byType(CheckboxListTile));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('area-foreign-lga')), findsNothing);
    await tester.ensureVisible(find.text('Use this area'));
    await tester.tap(find.text('Use this area'));
    await tester.pumpAndSettle();
    expect(selected?.country, 'Ghana');
    expect(selected?.state, 'Greater Accra');
    expect(selected?.isWholeState, isTrue);
  });

  testWidgets('cancel preserves saved value; invalid initial state is not offered', (tester) async {
    const original = AreaSelection(country: 'Nigeria', state: 'Invalid', lga: 'Lafia');
    var returned = false;
    await _open(tester, initial: original, onResult: (area) {
      returned = true;
      expect(area, isNull);
    });
    expect(find.byKey(const ValueKey('area-search-state')), findsOneWidget);
    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();
    expect(returned, isTrue);
    expect(original.state, 'Invalid');
  });

  testWidgets('no search matches shows a recovery message', (tester) async {
    await _open(tester);
    await _search(tester, 'does not exist');
    expect(find.text('No areas found. Try a different spelling.'), findsOneWidget);
  });

  for (final size in [const Size(360, 640), const Size(390, 844), const Size(844, 390)]) {
    testWidgets('keyboard-up selection stays reachable at $size', (tester) async {
      AreaSelection? selected;
      await _open(tester, size: size, textScale: 1.3,
        onResult: (area) => selected = area,
      );
      await _search(tester, 'Nasarawa');
      await _choose(tester, 'Nasarawa');
      final input = find.byType(TextFormField);
      await tester.ensureVisible(input);
      await tester.showKeyboard(input);
      tester.view.viewInsets = FakeViewPadding(bottom: size.height < 400 ? 170 : 280);
      await tester.enterText(input, 'Lafia');
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final tile = find.byKey(const ValueKey('area-option-Lafia'));
      await tester.ensureVisible(tile);
      expect(tile.hitTestable(), findsOneWidget);
      await tester.tap(tile);
      await tester.pumpAndSettle();
      expect(selected?.lga, 'Lafia');
      expect(tester.takeException(), isNull);
    });
  }
}
