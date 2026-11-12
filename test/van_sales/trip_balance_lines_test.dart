import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/core/van_sales/van_trip_position.dart';
import 'package:reebaplus_pos/features/van_sales/widgets/trip_balance_lines.dart';

// #800: the driver's balance split three ways wherever money is taken.

VanTripPosition _position(int outstandingKobo) => VanTripPosition(
  loadedUnits: 10,
  soldUnits: 10,
  goodReturnedUnits: 0,
  damagedUnits: 0,
  shortageUnits: 0,
  loadedValueKobo: 1000000,
  soldValueKobo: 1000000,
  rungValueKobo: 0,
  goodReturnValueKobo: 0,
  damageValueKobo: 0,
  shortageValueKobo: 0,
  remittedKobo: 1000000 - outstandingKobo,
  shortageWriteoffKobo: 0,
  damageWriteoffKobo: 0,
  balanceKobo: -outstandingKobo,
  outstandingKobo: outstandingKobo,
  unremittedCashKobo: outstandingKobo,
  shortageOwedKobo: 0,
  damageOwedKobo: 0,
  residualCreditKobo: 0,
  loadedCostKobo: 800000,
  goodReturnCostKobo: 0,
  cogsKobo: 800000,
  shortageLossKobo: 0,
  damageLossKobo: 0,
  recoveredKobo: 1000000 - outstandingKobo,
  profitKobo: 0,
  shellsOut: 0,
  shellsBack: 0,
  shortages: const [],
);

Future<void> _pump(
  WidgetTester tester, {
  required int totalBalanceKobo,
  required int tripOutstandingKobo,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        tripOwnerBalanceProvider('t1').overrideWith(
          (ref) => Stream.value(totalBalanceKobo),
        ),
        vanTripPositionProvider('t1').overrideWith(
          (ref) => Stream.value(_position(tripOutstandingKobo)),
        ),
      ],
      child: const MaterialApp(
        home: Scaffold(body: TripBalanceLines(tripId: 't1')),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  test('split: earlier debt plus this trip makes the total', () {
    final s = TripBalanceSplit(
      totalBalanceKobo: -101065000,
      tripOutstandingKobo: 40050000,
    );
    expect(s.beforeOwedKobo, 61015000);
    expect(s.tripOwedKobo, 40050000);
    expect(s.totalOwedKobo, 101065000);
  });

  test('split: a payment made on no trip shows as credit from before', () {
    final s = TripBalanceSplit(
      totalBalanceKobo: -30000000,
      tripOutstandingKobo: 40050000,
    );
    expect(s.beforeOwedKobo, -10050000);
    expect(owedLabel(s.beforeOwedKobo), contains('In credit'));
  });

  testWidgets('shows before, this trip and the total owed now', (tester) async {
    await _pump(
      tester,
      totalBalanceKobo: -101065000,
      tripOutstandingKobo: 40050000,
    );
    expect(find.text('Balance before this trip'), findsOneWidget);
    expect(find.text(formatCurrency(610150)), findsOneWidget);
    expect(find.text('This trip'), findsOneWidget);
    expect(find.text(formatCurrency(400500)), findsOneWidget);
    expect(find.text('Total owed now'), findsOneWidget);
    expect(find.text(formatCurrency(1010650)), findsOneWidget);
  });

  testWidgets('a driver with nothing from before shows zero, not a blank', (
    tester,
  ) async {
    await _pump(
      tester,
      totalBalanceKobo: -40050000,
      tripOutstandingKobo: 40050000,
    );
    expect(find.text(formatCurrency(0)), findsOneWidget);
    expect(find.text(formatCurrency(400500)), findsNWidgets(2));
  });
}
