import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/features/subscription/read_only_store_gate.dart';
import 'package:reebaplus_pos/features/subscription/subscription_plan_providers.dart';

void main() {
  group('read-only store predicate', () {
    test('only stores in the set are read-only; null never is', () {
      const ids = {'b'};
      expect(isReadOnlyStore(ids, 'b'), isTrue);
      expect(isReadOnlyStore(ids, 'a'), isFalse);
      expect(isReadOnlyStore(ids, null), isFalse);
      expect(readOnlyStoreWriteBlock(ids, 'b'), kReadOnlyStoreMessage);
      expect(readOnlyStoreWriteBlock(ids, 'a'), isNull);
    });

    test('message tells the owner to upgrade to Premium', () {
      expect(kReadOnlyStoreMessage, contains('read-only'));
      expect(kReadOnlyStoreMessage, contains('Premium'));
    });
  });

  group('blockIfReadOnlyStore', () {
    Future<bool?> run(WidgetTester tester, Set<String> ro, String? id) async {
      bool? blocked;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [readOnlyStoreIdsProvider.overrideWithValue(ro)],
          child: MaterialApp(
            home: Scaffold(
              body: Consumer(
                builder: (context, ref, _) => TextButton(
                  onPressed: () => blocked = blockIfReadOnlyStore(
                    context,
                    ref,
                    id,
                  ),
                  child: const Text('go'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('go'));
      await tester.pump();
      return blocked;
    }

    testWidgets('blocks a read-only store and shows the message', (t) async {
      expect(await run(t, {'s2'}, 's2'), isTrue);
      expect(find.text(kReadOnlyStoreMessage), findsOneWidget);
      await t.pumpAndSettle(const Duration(seconds: 10));
    });

    testWidgets('lets a writable store through, no message', (t) async {
      expect(await run(t, {'s2'}, 's1'), isFalse);
      expect(find.text(kReadOnlyStoreMessage), findsNothing);
    });
  });
}
