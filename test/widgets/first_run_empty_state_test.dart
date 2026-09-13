// first_run_empty_state_test.dart
//
// Widget test for [FirstRunEmptyState] verifying empty state renderings across:
//   - createStoreCta (owner with 0 stores)
//   - neutralEmpty (non-owner with 0 stores / 0 products)
//   - addProductCta (owner/manager with stores but 0 products)

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:reebaplus_pos/core/providers/first_run_surface_state.dart';
import 'package:reebaplus_pos/shared/services/navigation_service.dart';
import 'package:reebaplus_pos/shared/widgets/first_run_empty_state.dart';

Widget _wrap(Widget child, {required FirstRunSurfaceState state}) {
  return ProviderScope(
    overrides: [
      firstRunSurfaceStateProvider.overrideWithValue(state),
    ],
    child: MaterialApp(
      home: Scaffold(
        body: child,
      ),
    ),
  );
}

void main() {
  testWidgets('renders createStoreCta with icon, copy, and button navigating to stores tab', (tester) async {
    NavigationService().currentIndex.value = 0;

    await tester.pumpWidget(_wrap(
      const FirstRunEmptyState(),
      state: FirstRunSurfaceState.createStoreCta,
    ));

    expect(find.text('No stores yet'), findsOneWidget);
    expect(
      find.text('Create a store to start adding products and selling.'),
      findsOneWidget,
    );
    expect(find.byIcon(FontAwesomeIcons.store.data), findsOneWidget);

    final buttonFinder = find.text('Create a store');
    expect(buttonFinder, findsOneWidget);

    await tester.tap(buttonFinder);
    await tester.pumpAndSettle();

    expect(NavigationService().currentIndex.value, NavigationService.storesTab);
    expect(NavigationService().currentIndex.value, 7);
  });

  testWidgets('createStoreCta pops pushed route back to root before selecting stores tab', (tester) async {
    NavigationService().currentIndex.value = 0;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          firstRunSurfaceStateProvider.overrideWithValue(FirstRunSurfaceState.createStoreCta),
        ],
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => const Scaffold(
                          body: FirstRunEmptyState(),
                        ),
                      ),
                    );
                  },
                  child: const Text('Push Route'),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    // Push the child route containing FirstRunEmptyState
    await tester.tap(find.text('Push Route'));
    await tester.pumpAndSettle();

    expect(find.text('No stores yet'), findsOneWidget);

    // Tap "Create a store"
    await tester.tap(find.text('Create a store'));
    await tester.pumpAndSettle();

    // Pushed route should have popped back to home
    expect(find.text('Push Route'), findsOneWidget);
    expect(find.text('No stores yet'), findsNothing);
    expect(NavigationService().currentIndex.value, NavigationService.storesTab);
  });

  testWidgets('renders neutralEmpty with no button and no mention of the owner', (tester) async {
    await tester.pumpWidget(_wrap(
      const FirstRunEmptyState(),
      state: FirstRunSurfaceState.neutralEmpty,
    ));

    expect(find.text('No products yet'), findsOneWidget);
    expect(find.text('A manager can add them.'), findsOneWidget);
    expect(find.text('Create a store'), findsNothing);
    expect(find.textContaining('Add your first'), findsNothing);
    expect(find.textContaining(RegExp(r'owner', caseSensitive: false)), findsNothing);
  });

  testWidgets('renders addProductCta with Add your first product button', (tester) async {
    await tester.pumpWidget(_wrap(
      const FirstRunEmptyState(),
      state: FirstRunSurfaceState.addProductCta,
    ));

    expect(find.text('No products yet'), findsOneWidget);
    expect(find.text('Add your first product to start selling.'), findsOneWidget);
    expect(find.text('Add your first product'), findsOneWidget);
  });
}
