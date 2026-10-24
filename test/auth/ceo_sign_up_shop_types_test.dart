import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/industry/industry.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/features/auth/onboarding/onboarding_draft.dart';
import 'package:reebaplus_pos/features/auth/screens/ceo_sign_up_screen.dart';

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

  group('CeoSignUpScreen - Shop types & Other (#492)', () {
    late AppDatabase db;

    setUp(() {
      db = AppDatabase.forTesting(NativeDatabase.memory());
    });

    tearDown(() async {
      await db.close();
    });

    ProviderContainer createContainer() {
      return ProviderContainer(
        overrides: [databaseProvider.overrideWithValue(db)],
      );
    }

    Future<void> pumpStep1(
      WidgetTester tester,
      ProviderContainer container,
    ) async {
      container.read(onboardingDraftProvider.notifier).start();
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: CeoSignUpScreen(
              verifiedEmail: 'ceo@test.com',
              initialStep: 1,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('displays all 9 shop types plus Other', (tester) async {
      final container = createContainer();
      addTearDown(container.dispose);
      await pumpStep1(tester, container);

      for (final ind in Industry.catalogue) {
        expect(
          find.text(ind.label, skipOffstage: false),
          findsOneWidget,
          reason: '${ind.label} missing',
        );
      }
      expect(find.text('Other', skipOffstage: false), findsOneWidget);
    });

    testWidgets('selecting Restaurant does not show crate toggle', (
      tester,
    ) async {
      final container = createContainer();
      addTearDown(container.dispose);
      await pumpStep1(tester, container);

      await tester.tap(find.text('Restaurant'));
      await tester.pumpAndSettle();

      expect(find.text('Track empty crates'), findsNothing);
    });

    testWidgets('selecting Bar shows crate toggle', (tester) async {
      final container = createContainer();
      addTearDown(container.dispose);
      await pumpStep1(tester, container);

      await tester.tap(find.text('Bar'));
      await tester.pumpAndSettle();

      expect(find.text('Track empty crates'), findsOneWidget);
    });

    testWidgets(
      'selecting Other shows text box and requires text to continue',
      (tester) async {
        final container = createContainer();
        addTearDown(container.dispose);
        await pumpStep1(tester, container);

        // Initially Continue is disabled
        final continueBtn = find.widgetWithText(AppButton, 'Continue');
        await tester.ensureVisible(continueBtn);
        await tester.pumpAndSettle();
        expect(tester.widget<AppButton>(continueBtn).onPressed, isNull);

        // Scroll to Other and tap it
        await tester.ensureVisible(find.text('Other'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Other'));
        await tester.pumpAndSettle();

        // Text input appears
        expect(find.text('Business type'), findsOneWidget);
        expect(tester.widget<AppButton>(continueBtn).onPressed, isNull);

        // Type custom business type
        await tester.enterText(find.byType(TextField).last, 'Bakery');
        await tester.pumpAndSettle();

        // Now Continue is enabled
        await tester.ensureVisible(continueBtn);
        await tester.pumpAndSettle();
        expect(tester.widget<AppButton>(continueBtn).onPressed, isNotNull);

        // No crate toggle for Bakery
        expect(find.text('Track empty crates'), findsNothing);

        // Tap Continue
        await tester.tap(continueBtn);
        await tester.pumpAndSettle();

        // Draft has saved 'Bakery'
        final draft = container.read(onboardingDraftProvider);
        expect(draft?.businessType, 'Bakery');
        expect(draft?.tracksEmptyCrates, isTrue);
      },
    );
  });
}
