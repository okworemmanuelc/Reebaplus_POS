import 'package:flutter_test/flutter_test.dart';

import '../../../tool/legacy_import/src/history_layers.dart';

/// The cloud `fifo_assign` queue walk: each line draws the oldest layers.
List<double> replayCosts(List<HistoryLayer> layers, List<ReplayLine> lines) {
  final queue = layers.map((l) => [l.qty, l.costKobo.toDouble()]).toList();
  var pointer = 0;
  final costs = <double>[];
  for (final line in lines) {
    var need = line.qty;
    var total = 0.0;
    while (need > 0 && pointer < queue.length) {
      if (queue[pointer][0] <= 0) {
        pointer++;
        continue;
      }
      final take = need < queue[pointer][0] ? need : queue[pointer][0];
      queue[pointer][0] -= take;
      total += take * queue[pointer][1];
      need -= take;
    }
    costs.add(total / line.qty);
  }
  return costs;
}

void main() {
  final cutover = DateTime.utc(2026, 3, 1);

  ReplayLine line(
    String id,
    int day,
    double qty,
    int cost, {
    String order = 'o1',
    int milli = 0,
  }) => ReplayLine(
    lineId: id,
    orderId: order,
    soldAt: DateTime.utc(2026, 1, day, 0, 0, 0, milli),
    qty: qty,
    costKobo: cost,
  );

  List<HistoryLayer> build(List<ReplayLine> lines) =>
      buildHistoryLayers(lines: lines, cutover: cutover);

  group('buildHistoryLayers', () {
    test('no lines, no layers', () {
      expect(build(const []), isEmpty);
    });

    test('consecutive lines at one cost share a layer', () {
      final layers = build([
        line('l1', 1, 2, 100),
        line('l2', 2, 0.5, 100),
        line('l3', 3, 1, 200),
      ]);

      expect(layers.map((l) => l.qty), [2.5, 1]);
      expect(layers.map((l) => l.costKobo), [100, 200]);
    });

    test('a cost that comes back starts a new layer', () {
      final layers = build([
        line('l1', 1, 1, 100),
        line('l2', 2, 1, 200),
        line('l3', 3, 1, 100),
      ]);

      expect(layers.map((l) => l.costKobo), [100, 200, 100]);
    });

    test('the replay hands every line back its own cost', () {
      final lines = replayOrder([
        line('l1', 1, 0.5, 100),
        line('l2', 2, 1.5, 100),
        line('l3', 3, 0.25, 250),
        line('l4', 4, 2, 0),
        line('l5', 5, 3, 300),
      ]);

      final costs = replayCosts(build(lines), lines);

      expect(costs, lines.map((l) => l.costKobo.toDouble()));
    });

    test('layers hold exactly what was sold, leaving the opening layer', () {
      final lines = [line('l1', 1, 1.25, 100), line('l2', 2, 2.5, 200)];

      final total = build(lines).fold<double>(0, (sum, l) => sum + l.qty);

      expect(total, 3.75);
    });

    test('equal sale times still give strictly rising received_at', () {
      final layers = build([
        line('l1', 1, 1, 100),
        line('l2', 1, 1, 200),
        line('l3', 1, 1, 300),
      ]);

      expect(layers[1].receivedAt.isAfter(layers[0].receivedAt), isTrue);
      expect(layers[2].receivedAt.isAfter(layers[1].receivedAt), isTrue);
    });

    test('runs follow replay order, not input order', () {
      final layers = build([line('l2', 2, 1, 200), line('l1', 1, 1, 100)]);

      expect(layers.map((l) => l.costKobo), [100, 200]);
    });

    test('same order and time sorts by order id then line id', () {
      final sorted = replayOrder([
        line('b', 1, 1, 100, order: 'o2'),
        line('z', 1, 1, 100, order: 'o1'),
        line('a', 1, 1, 100, order: 'o1'),
      ]);

      expect(sorted.map((l) => l.lineId), ['a', 'z', 'b']);
    });

    test('refuses a layer at or after the opening layer', () {
      expect(
        () => buildHistoryLayers(
          lines: [line('l1', 1, 1, 100)],
          cutover: DateTime.utc(2026, 1, 1),
        ),
        throwsStateError,
      );
    });
  });
}
