// Owner decision on #402: an order paid by transfer badges "Transfer" and a
// part payment (some now, the rest on credit) badges "Partial" — both used to
// read "Cash".

import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/features/orders/screens/orders_screen.dart';

import '../helpers/screen_harness.dart';
import 'orders_fixture.dart';

void main() {
  late ScreenTestEnvironment env;

  setUp(() async {
    env = await setupScreenTestEnvironment(
      productCount: 3,
      manufacturerCount: 1,
      businessType: 'Bar',
    );
    await seedOrdersSample(env);
  });
  tearDown(() async => env.dispose());

  testWidgets('a part payment badges "Partial"', (tester) async {
    await pumpOrders(tester, env: env, screen: const OrdersScreen());
    expect(find.text('Partial'), findsOneWidget);
    await disposeScreen(tester);
  });

  testWidgets('a transfer badges "Transfer"', (tester) async {
    await pumpOrders(
      tester,
      env: env,
      screen: const OrdersScreen(initialIndex: 1),
    );
    expect(find.text('Transfer'), findsOneWidget);
    expect(find.text('Cash'), findsOneWidget); // the plain cash sale
    await disposeScreen(tester);
  });
}
