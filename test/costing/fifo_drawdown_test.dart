import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/costing/fifo_drawdown.dart';

/// Pure FIFO draw-down (Epic 2 / ADR 0005, issue #38). No database, no widgets —
/// exactly the exhaustive costing-maths net the acceptance criteria ask for.
void main() {
  group('fifoDrawDown', () {
    test('single batch fully covers one line', () {
      final r = fifoDrawDown(
        [const FifoBatch(qtyRemaining: 10, costKobo: 100)],
        [4],
      );
      expect(r.lineCogsKobo, [400]);
      expect(r.lineShortfall, [0]);
      expect(r.batchConsumption, [4]);
    });

    test('partial split across a batch boundary weights each slice', () {
      // 6 units @100 then 4 units @150 = 600 + 600 = 1200.
      final r = fifoDrawDown(
        [
          const FifoBatch(qtyRemaining: 6, costKobo: 100),
          const FifoBatch(qtyRemaining: 10, costKobo: 150),
        ],
        [10],
      );
      expect(r.lineCogsKobo, [1200]);
      expect(r.lineShortfall, [0]);
      expect(r.batchConsumption, [6, 4]);
    });

    test('split spanning three batches', () {
      // 2@100 + 2@200 + 1@300 = 200 + 400 + 300 = 900.
      final r = fifoDrawDown(
        [
          const FifoBatch(qtyRemaining: 2, costKobo: 100),
          const FifoBatch(qtyRemaining: 2, costKobo: 200),
          const FifoBatch(qtyRemaining: 5, costKobo: 300),
        ],
        [5],
      );
      expect(r.lineCogsKobo, [900]);
      expect(r.batchConsumption, [2, 2, 1]);
      expect(r.lineShortfall, [0]);
    });

    test('oldest-first: a line smaller than the front batch never reaches the '
        'newer, dearer one', () {
      final r = fifoDrawDown(
        [
          const FifoBatch(qtyRemaining: 10, costKobo: 100), // oldest
          const FifoBatch(qtyRemaining: 10, costKobo: 999), // newer
        ],
        [3],
      );
      expect(r.lineCogsKobo, [300]);
      expect(r.batchConsumption, [3, 0]);
    });

    test('cost-0 (uncosted) batch contributes 0 but is still drawn down', () {
      final r = fifoDrawDown(
        [const FifoBatch(qtyRemaining: 5, costKobo: 0)],
        [5],
      );
      expect(r.lineCogsKobo, [0]);
      expect(r.batchConsumption, [5]);
      expect(r.lineShortfall, [0]);
    });

    test('split from an uncosted batch into a costed one', () {
      // 3 units @0 + 2 units @100 = 0 + 200 = 200.
      final r = fifoDrawDown(
        [
          const FifoBatch(qtyRemaining: 3, costKobo: 0),
          const FifoBatch(qtyRemaining: 5, costKobo: 100),
        ],
        [5],
      );
      expect(r.lineCogsKobo, [200]);
      expect(r.batchConsumption, [3, 2]);
    });

    test('multiple lines consume the shared queue sequentially', () {
      final r = fifoDrawDown(
        [const FifoBatch(qtyRemaining: 10, costKobo: 100)],
        [4, 3],
      );
      expect(r.lineCogsKobo, [400, 300]);
      expect(r.lineShortfall, [0, 0]);
      // Cumulative draw across both lines.
      expect(r.batchConsumption, [7]);
    });

    test('later line crosses a boundary the earlier line reached', () {
      // Line0 takes 4 of batch1(6@100). Line1 needs 4: 2 left @100 + 2 @150.
      final r = fifoDrawDown(
        [
          const FifoBatch(qtyRemaining: 6, costKobo: 100),
          const FifoBatch(qtyRemaining: 10, costKobo: 150),
        ],
        [4, 4],
      );
      expect(r.lineCogsKobo, [400, 500]); // 400 ; 200 + 300
      expect(r.batchConsumption, [6, 2]);
    });

    test('shortfall: a dry queue reports the uncovered units, costs the rest', () {
      final r = fifoDrawDown(
        [const FifoBatch(qtyRemaining: 3, costKobo: 100)],
        [5],
      );
      expect(r.lineCogsKobo, [300]);
      expect(r.lineShortfall, [2]);
      expect(r.batchConsumption, [3]);
    });

    test('empty queue: whole line is a shortfall, zero COGS', () {
      final r = fifoDrawDown([], [4]);
      expect(r.lineCogsKobo, [0]);
      expect(r.lineShortfall, [4]);
      expect(r.batchConsumption, isEmpty);
    });

    test('a 0-qty batch already at the front is skipped', () {
      final r = fifoDrawDown(
        [
          const FifoBatch(qtyRemaining: 0, costKobo: 100),
          const FifoBatch(qtyRemaining: 5, costKobo: 200),
        ],
        [3],
      );
      expect(r.lineCogsKobo, [600]);
      expect(r.batchConsumption, [0, 3]);
    });

    test('no lines: empty result, queue untouched', () {
      final r = fifoDrawDown(
        [const FifoBatch(qtyRemaining: 5, costKobo: 100)],
        [],
      );
      expect(r.lineCogsKobo, isEmpty);
      expect(r.lineShortfall, isEmpty);
      expect(r.batchConsumption, [0]);
    });
  });
}
