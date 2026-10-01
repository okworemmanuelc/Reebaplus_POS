// scan_gate_test.dart
//
// #319 — the scan session's read gate (pure, injectable clock): reads while a
// code is handled are ignored, and the code just handled is ignored for the
// debounce window after resuming while any other code is accepted at once.
// Also the running "‹N› items in cart" label.

import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/features/pos/services/scan_gate.dart';
import 'package:reebaplus_pos/features/pos/widgets/scan_cart_count.dart';

void main() {
  late DateTime now;
  late ScanGate gate;

  setUp(() {
    now = DateTime(2026, 10, 1, 9);
    gate = ScanGate(now: () => now);
  });

  test('the debounce window is about 1.5 s', () {
    expect(sameCodeDebounce, const Duration(milliseconds: 1500));
    expect(ScanGate().window, sameCodeDebounce);
  });

  test('the first read is accepted and makes the gate busy', () {
    expect(gate.isBusy, isFalse);
    expect(gate.tryBegin('A'), isTrue);
    expect(gate.isBusy, isTrue);
  });

  test('every read is ignored while one is being handled', () {
    gate.tryBegin('A');
    expect(gate.tryBegin('A'), isFalse);
    expect(gate.tryBegin('B'), isFalse);
    now = now.add(const Duration(minutes: 1));
    expect(gate.tryBegin('B'), isFalse);
  });

  test('the same code is ignored inside the window after resuming', () {
    gate.tryBegin('A');
    // Handling took a while — the window counts from resuming, not the read.
    now = now.add(const Duration(seconds: 30));
    gate.finish();
    expect(gate.isBusy, isFalse);

    now = now.add(const Duration(milliseconds: 1499));
    expect(gate.tryBegin('A'), isFalse);
    expect(gate.isBusy, isFalse);
  });

  test('the same code is accepted once the window has passed', () {
    gate.tryBegin('A');
    gate.finish();
    now = now.add(sameCodeDebounce);
    expect(gate.tryBegin('A'), isTrue);
  });

  test('a different code is accepted immediately', () {
    gate.tryBegin('A');
    gate.finish();
    expect(gate.tryBegin('B'), isTrue);
  });

  test('after a different code, the earlier one is not debounced', () {
    gate.tryBegin('A');
    gate.finish();
    gate.tryBegin('B');
    gate.finish();
    expect(gate.tryBegin('A'), isTrue);
  });

  test('finish without a read in hand changes nothing', () {
    gate.finish();
    expect(gate.isBusy, isFalse);
    expect(gate.tryBegin('A'), isTrue);
  });

  group('running count label', () {
    test('whole units have no trailing .0', () {
      expect(scanCartCountLabel(0), '0 items in cart');
      expect(scanCartCountLabel(1), '1 item in cart');
      expect(scanCartCountLabel(4), '4 items in cart');
    });

    test('fractional units keep their fraction', () {
      expect(scanCartCountLabel(1.5), '1.5 items in cart');
    });
  });
}
