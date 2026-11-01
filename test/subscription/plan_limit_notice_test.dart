import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/utils/notifications.dart';
import 'package:reebaplus_pos/features/subscription/subscription_plan.dart';
import 'package:reebaplus_pos/features/subscription/widgets/plan_limit_widgets.dart';

// A plan limit is explained only when an action is refused, then goes away
// after 3 seconds; it is never a standing banner.
void main() {
  tearDown(AppNotification.hide);

  testWidgets('limit notice offers Upgrade and disappears after 3 seconds',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => showPlanLimitNotice(
                  context,
                  PlanLimitKind.stores,
                  plan: kPlanFree,
                ),
                child: const Text('Add store'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Add store'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    final message = planLimitMessage(PlanLimitKind.stores, plan: kPlanFree);
    expect(find.text(message), findsOneWidget);
    expect(find.text('Upgrade'), findsOneWidget);

    await tester.pump(const Duration(seconds: 3));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text(message), findsNothing);
  });
}
