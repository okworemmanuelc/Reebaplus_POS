import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/features/auth/onboarding/onboarding_draft.dart';
import 'package:reebaplus_pos/features/auth/screens/ceo_sign_up_screen.dart';
import 'package:reebaplus_pos/features/auth/screens/staff_sign_up_screen.dart';
import 'package:reebaplus_pos/features/auth/widgets/auth_form_kit.dart';

const _connectivityChannel = MethodChannel(
  'dev.fluttercommunity.plus/connectivity',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          _connectivityChannel,
          (call) async => call.method == 'check' ? <String>['wifi'] : null,
        );
  });

  group('CeoSignUpScreen - Country and Phone behavior (#230)', () {
    late AppDatabase db;

    setUp(() {
      db = AppDatabase.forTesting(NativeDatabase.memory());
    });

    tearDown(() async {
      await db.close();
    });

    Future<void> navigateToStep2(WidgetTester tester, ProviderContainer container) async {
      container.read(onboardingDraftProvider.notifier).start();
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: CeoSignUpScreen(
              verifiedEmail: 'ceo@test.com',
              initialStep: 2,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Now on Step 2: "Your first store"
      expect(find.text('Your first store'), findsOneWidget);
    }

    ProviderContainer createContainer() {
      return ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
        ],
      );
    }

    testWidgets('Country is blank on first paint and renders above phone field', (tester) async {
      final container = createContainer();
      addTearDown(container.dispose);

      await navigateToStep2(tester, container);

      final countryFinder = find.widgetWithText(AutocompleteField, 'Country');
      final phoneFinder = find.widgetWithText(TextField, 'Store phone number');

      expect(countryFinder, findsOneWidget);
      expect(phoneFinder, findsOneWidget);

      // Verify country is physically above phone
      final countryDy = tester.getTopLeft(countryFinder).dy;
      final phoneDy = tester.getTopLeft(phoneFinder).dy;
      expect(countryDy, lessThan(phoneDy));

      // Verify country starts blank
      final countryTextField = find.descendant(
        of: countryFinder,
        matching: find.byType(TextField),
      );
      expect(tester.widget<TextField>(countryTextField).controller?.text, isEmpty);

      // Verify phone input is disabled on first paint
      final phoneWidget = tester.widget<TextField>(phoneFinder);
      expect(phoneWidget.enabled, isFalse);
      expect(find.text('Choose your country first'), findsOneWidget);

      // Verify currency displays placeholder '—', not falling through to NGN
      expect(find.text('Currency: —'), findsOneWidget);
    });

    testWidgets('Half-typed country does not resolve dial code or currency, and blocks submit', (tester) async {
      final container = createContainer();
      addTearDown(container.dispose);

      await navigateToStep2(tester, container);

      final countryTextField = find.descendant(
        of: find.widgetWithText(AutocompleteField, 'Country'),
        matching: find.byType(TextField),
      );

      // Type a partial country name
      await tester.enterText(countryTextField, 'Nig');
      await tester.pump();

      // Phone must remain disabled
      final phoneFinder = find.widgetWithText(TextField, 'Store phone number');
      expect(tester.widget<TextField>(phoneFinder).enabled, isFalse);
      expect(find.text('Choose your country first'), findsOneWidget);

      // Currency must stay placeholder '—'
      expect(find.text('Currency: —'), findsOneWidget);

      // Fill in Store Name and Address so only Country is invalid
      final storeNameFinder = find.widgetWithText(TextField, 'Store name');
      final addressFinder = find.widgetWithText(TextField, 'Street address');
      await tester.enterText(storeNameFinder, 'Main Branch');
      await tester.enterText(addressFinder, '123 Main St');

      // Attempt submit
      await tester.ensureVisible(find.text('Continue'));
      await tester.tap(find.text('Continue'));
      await tester.pump();

      // Submit is blocked with error message
      expect(find.text('Choose a valid country from the list.'), findsOneWidget);
    });

    testWidgets('Selecting valid country enables phone, shows affix, and formats phone on submit', (tester) async {
      final container = createContainer();
      addTearDown(container.dispose);

      await navigateToStep2(tester, container);

      final storeNameFinder = find.widgetWithText(TextField, 'Store name');
      final addressFinder = find.widgetWithText(TextField, 'Street address');
      final countryTextField = find.descendant(
        of: find.widgetWithText(AutocompleteField, 'Country'),
        matching: find.byType(TextField),
      );
      final phoneFinder = find.widgetWithText(TextField, 'Store phone number');

      await tester.enterText(storeNameFinder, 'Main Branch');
      await tester.enterText(addressFinder, '123 Main St');

      // Select Nigeria
      await tester.enterText(countryTextField, 'Nigeria');
      await tester.pumpAndSettle();

      // Phone is now enabled with '+234 ' affix
      final phoneWidget = tester.widget<TextField>(phoneFinder);
      expect(phoneWidget.enabled, isTrue);
      expect(phoneWidget.decoration?.prefixText, '+234 ');
      expect(find.text('Choose your country first'), findsNothing);

      // Currency resolves to NGN
      expect(find.text('Currency: NGN'), findsOneWidget);

      // Enter phone with leading zero
      await tester.enterText(phoneFinder, '08135216317');
      await tester.pump();

      // Submit step 2
      await tester.ensureVisible(find.text('Continue'));
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();

      // Verified: advanced to Step 3 ("What's your name?")
      expect(find.text("What's your name?"), findsOneWidget);

      // Verify draft holds full international number
      final draft = container.read(onboardingDraftProvider)!;
      expect(draft.businessPhone, '+2348135216317');
      expect(draft.country, 'Nigeria');
      expect(draft.currency, 'NGN');
    });

    testWidgets('Changing country preserves typed phone digits and updates dial code affix', (tester) async {
      final container = createContainer();
      addTearDown(container.dispose);

      await navigateToStep2(tester, container);

      final storeNameFinder = find.widgetWithText(TextField, 'Store name');
      final addressFinder = find.widgetWithText(TextField, 'Street address');
      final countryTextField = find.descendant(
        of: find.widgetWithText(AutocompleteField, 'Country'),
        matching: find.byType(TextField),
      );
      final phoneFinder = find.widgetWithText(TextField, 'Store phone number');

      await tester.enterText(storeNameFinder, 'Main Branch');
      await tester.enterText(addressFinder, '123 Main St');

      // First select Nigeria
      await tester.enterText(countryTextField, 'Nigeria');
      await tester.pumpAndSettle();

      // Type local phone number
      await tester.enterText(phoneFinder, '08135216317');
      await tester.pump();

      // Change country to Ghana (+233)
      await tester.enterText(countryTextField, 'Ghana');
      await tester.pumpAndSettle();

      // Digits must be preserved untouched
      expect(tester.widget<TextField>(phoneFinder).controller?.text, '08135216317');
      // Affix must update to Ghana's dial code
      expect(tester.widget<TextField>(phoneFinder).decoration?.prefixText, '+233 ');
      // Currency must update to GHS
      expect(find.text('Currency: GHS'), findsOneWidget);

      // Submit
      await tester.ensureVisible(find.text('Continue'));
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();

      // Advances and formats with Ghana prefix
      expect(find.text("What's your name?"), findsOneWidget);
      final draft = container.read(onboardingDraftProvider)!;
      expect(draft.businessPhone, '+2338135216317');
      expect(draft.country, 'Ghana');
      expect(draft.currency, 'GHS');
    });
  });

  group('StaffSignUpScreen - Country and Phone behavior (#230)', () {
    testWidgets('Step 4 renders country above phone, blank on paint, disables phone until country resolves', (tester) async {
      await tester.pumpWidget(
        const ProviderScope(
          child: MaterialApp(
            home: StaffSignUpScreen(initialStep: 4),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Your phone number'), findsOneWidget);

      final countryFinder = find.widgetWithText(AutocompleteField, 'Country');
      final phoneFinder = find.widgetWithText(TextField, 'Phone number');

      expect(countryFinder, findsOneWidget);
      expect(phoneFinder, findsOneWidget);

      // Verify country is physically above phone
      expect(
        tester.getTopLeft(countryFinder).dy,
        lessThan(tester.getTopLeft(phoneFinder).dy),
      );

      // Verify country is blank on first paint
      final countryTextField = find.descendant(
        of: countryFinder,
        matching: find.byType(TextField),
      );
      expect(tester.widget<TextField>(countryTextField).controller?.text, isEmpty);

      // Verify phone is disabled with helper text
      final phoneWidget = tester.widget<TextField>(phoneFinder);
      expect(phoneWidget.enabled, isFalse);
      expect(find.text('Choose your country first'), findsOneWidget);

      // Tapping Continue without country is blocked
      await tester.tap(find.text('Continue'));
      await tester.pump();
      expect(find.text('Choose a valid country from the list.'), findsOneWidget);
    });

    testWidgets('Selecting country on Step 4 enables phone input, preserves digits, and submits', (tester) async {
      await tester.pumpWidget(
        const ProviderScope(
          child: MaterialApp(
            home: StaffSignUpScreen(initialStep: 4),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final countryTextField = find.descendant(
        of: find.widgetWithText(AutocompleteField, 'Country'),
        matching: find.byType(TextField),
      );
      final phoneFinder = find.widgetWithText(TextField, 'Phone number');

      // Select Nigeria
      await tester.enterText(countryTextField, 'Nigeria');
      await tester.pumpAndSettle();

      // Phone is now enabled with prefix affix
      expect(tester.widget<TextField>(phoneFinder).enabled, isTrue);
      expect(tester.widget<TextField>(phoneFinder).decoration?.prefixText, '+234 ');
      expect(find.text('Choose your country first'), findsNothing);

      // Enter phone number
      await tester.enterText(phoneFinder, '08135216317');
      await tester.pump();

      // Change country to United Kingdom (+44)
      await tester.enterText(countryTextField, 'United Kingdom');
      await tester.pumpAndSettle();

      // Digits preserved, dial code updated
      expect(tester.widget<TextField>(phoneFinder).controller?.text, '08135216317');
      expect(tester.widget<TextField>(phoneFinder).decoration?.prefixText, '+44 ');

      // Submit step 4
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();

      // Advances to Step 5: "Your address"
      expect(find.text('Your address'), findsOneWidget);
    });
  });
}
