import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:drift/native.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/features/pos/screens/checkout_page.dart';
import 'package:reebaplus_pos/features/customers/data/models/customer.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late AppDatabase db;

  setUpAll(() async {
    // Mock SharedPreferences for Supabase session storage
    SharedPreferences.setMockInitialValues({});

    // We need a basic Supabase initialization because some providers read it
    // during widget build/init in these tests.
    await Supabase.initialize(
      url: 'https://placeholder.supabase.co',
      anonKey: 'placeholder',
    );
  });

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    db.businessIdResolver = () => 'test-biz-id';
  });

  tearDown(() => db.close());

  // Skip: unblocks after PR 5 — walletBalancesKoboProvider stream deadlocks
  // with db.close in teardown; needs proper provider isolation.
  testWidgets('CheckoutPage renders correctly with different cart items', skip: true, (WidgetTester tester) async {
    final cart = [
      {
        'id': 1,
        'name': 'Test Beer',
        'subtitle': '600ml',
        'price': 1000.0,
        'qty': 2.0,
        'icon': FontAwesomeIcons.beerMugEmpty,
        'color': '#3B82F6',
      },
      {
        'id': 2,
        'name': 'Quick Sale Item',
        'subtitle': 'Quick Sale',
        'price': 500.0,
        'qty': 1.0,
        'icon': 0xf0e7, // bolt icon codepoint
        'color': '#3B82F6',
      }
    ];

    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
      ],
    );

    // Seed the auth state BEFORE pumping so CheckoutPage.initState sees it
    container.read(authProvider).value = UserData(
      id: 'test-user',
      businessId: 'test-biz-id',
      name: 'Test Admin',
      pin: '1234',
      createdAt: DateTime.now(),
      lastUpdatedAt: DateTime.now(),
      avatarColor: '#3B82F6',
      biometricEnabled: false,
    );

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            body: CheckoutPage(
              cart: cart,
              subtotal: 2500.0,
              crateDeposit: 0.0,
              total: 2500.0,
              customer: Customer.walkIn(),
            ),
          ),
        ),
      ),
    );

    expect(find.text('Checkout'), findsOneWidget);
    expect(find.text('Test Beer'), findsOneWidget);
    expect(find.text('Quick Sale Item'), findsOneWidget);
  });

  testWidgets('CheckoutPage handles null/malformed icon or color gracefully', skip: true, (WidgetTester tester) async {
    final cart = [
      {
        'id': 3,
        'name': 'Null Item',
        'subtitle': '',
        'price': 1000.0,
        'qty': 1.0,
        'icon': null,
        'color': null,
      },
      {
        'id': 4,
        'name': 'Malformed Item',
        'subtitle': '',
        'price': 'invalid', // String price in Map
        'qty': null,
        'icon': 'not_an_int_or_icon',
        'color': 'not_a_hex',
      }
    ];

    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
      ],
    );

    // Seed the auth state BEFORE pumping so CheckoutPage.initState sees it
    container.read(authProvider).value = UserData(
      id: 'test-user',
      businessId: 'test-biz-id',
      name: 'Test Admin',
      pin: '1234',
      createdAt: DateTime.now(),
      lastUpdatedAt: DateTime.now(),
      avatarColor: '#3B82F6',
      biometricEnabled: false,
    );

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            body: CheckoutPage(
              cart: cart,
              subtotal: 1000.0,
              crateDeposit: 0.0,
              total: 1000.0,
              customer: Customer.walkIn(),
            ),
          ),
        ),
      ),
    );

    expect(find.text('Null Item'), findsOneWidget);
    expect(find.text('Malformed Item'), findsOneWidget);
  });
}
