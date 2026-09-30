// crate_shortage_fold_test.dart
//
// #296 / PRD #284 decision 7 — the count-based Crate Shortage folded together
// with the write-offs and reversals taken against it. Pure: no database.

import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/crates/crate_ledger_movement_types.dart';
import 'package:reebaplus_pos/core/crates/crate_shortage.dart';

void main() {
  const store = 'store-1';
  const rate = 350000;
  final t0 = DateTime.utc(2026, 9, 1, 9);
  DateTime at(int hours) => t0.add(Duration(hours: hours));

  CrateCountMovement opening(int hours) => CrateCountMovement(
    storeId: store,
    movementType: kCrateMovementOpeningCount,
    quantityDelta: 0,
    createdAt: at(hours),
  );

  CrateCountMovement count(int delta, int hours) => CrateCountMovement(
    storeId: store,
    movementType: kCrateMovementCount,
    quantityDelta: delta,
    createdAt: at(hours),
  );

  CrateShortageWriteOffEvent writeOff(
    int crates,
    int hours, {
    int ratePerCrateKobo = rate,
  }) => CrateShortageWriteOffEvent(
    storeId: store,
    crateCount: crates,
    ratePerCrateKobo: ratePerCrateKobo,
    createdAt: at(hours),
  );

  group('a write-off inside the fold', () {
    test('reduces the open shortage and becomes an outstanding write-off', () {
      final s = foldCrateShortageStateForStore([
        opening(0),
        count(-10, 1),
        writeOff(6, 2),
      ]);
      expect(s.openCrates, 4);
      expect(s.writtenOffCrates, 6);
      expect(s.reversibleCrates, 0, reason: 'nothing has turned up yet');
    });

    test('a later count finding crates closes what is still open first', () {
      final s = foldCrateShortageStateForStore([
        opening(0),
        count(-10, 1),
        writeOff(6, 2),
        count(3, 3),
      ]);
      expect(s.openCrates, 1);
      expect(
        s.reversibleCrates,
        0,
        reason: 'the found crates went to the shortage still open',
      );
    });

    test('crates found beyond the open shortage become reversible, capped at '
        'what was written off', () {
      final s = foldCrateShortageStateForStore([
        opening(0),
        count(-10, 1),
        writeOff(10, 2),
        count(15, 3),
      ]);
      expect(s.openCrates, 0);
      expect(s.reversibleCrates, 10);
    });

    test('a later short count takes the found crates back out of reach', () {
      final s = foldCrateShortageStateForStore([
        opening(0),
        count(-10, 1),
        writeOff(10, 2),
        count(4, 3),
        count(-3, 4),
      ]);
      expect(s.reversibleCrates, 1);
      expect(s.openCrates, 3, reason: 'the new gap still opens a shortage');
    });

    test('a write-off larger than the open shortage floors it at zero', () {
      // Two offline tills each writing off the same crates must never turn the
      // shortage negative.
      final s = foldCrateShortageStateForStore([
        opening(0),
        count(-5, 1),
        writeOff(5, 2),
        writeOff(5, 2),
      ]);
      expect(s.openCrates, 0);
    });

    test('surplus before a shortage is still not banked', () {
      final s = foldCrateShortageStateForStore([
        opening(0),
        count(8, 1),
        count(-5, 2),
      ]);
      expect(s.openCrates, 5);
      expect(s.reversibleCrates, 0);
    });
  });

  group('a reversal', () {
    test('uses up reversible crates and the write-off it reverses', () {
      final s = foldCrateShortageStateForStore([
        opening(0),
        count(-10, 1),
        writeOff(10, 2),
        count(10, 3),
        writeOff(-4, 4),
      ]);
      expect(s.writtenOffCrates, 6);
      expect(s.reversibleCrates, 6);
      expect(s.openCrates, 0, reason: 'a reversal never reopens a shortage');
    });

    test('the plan takes the newest write-off first, at its own rate', () {
      final s = foldCrateShortageStateForStore([
        opening(0),
        count(-10, 1),
        writeOff(4, 2, ratePerCrateKobo: 300000),
        writeOff(6, 3, ratePerCrateKobo: 500000),
        count(10, 4),
      ]);
      final plan = planCrateWriteOffReversal(s, 8);
      expect(plan, [
        const CrateWriteOffLayer(crates: 6, ratePerCrateKobo: 500000),
        const CrateWriteOffLayer(crates: 2, ratePerCrateKobo: 300000),
      ]);
    });

    test('the plan is empty when asking for more than can be reversed', () {
      final s = foldCrateShortageStateForStore([
        opening(0),
        count(-10, 1),
        writeOff(10, 2),
        count(3, 3),
      ]);
      expect(s.reversibleCrates, 3);
      expect(planCrateWriteOffReversal(s, 4), isEmpty);
      expect(planCrateWriteOffReversal(s, 0), isEmpty);
      expect(planCrateWriteOffReversal(s, 3), [
        const CrateWriteOffLayer(crates: 3, ratePerCrateKobo: rate),
      ]);
    });

    test('nothing is reversible when no write-off was ever taken', () {
      final s = foldCrateShortageStateForStore([
        opening(0),
        count(12, 1),
      ]);
      expect(s.reversibleCrates, 0);
      expect(planCrateWriteOffReversal(s, 1), isEmpty);
    });
  });

  group('per store', () {
    test('write-offs only touch the store they were taken at', () {
      final states = foldCrateShortageStatesPerStore([
        opening(0),
        count(-5, 1),
        CrateCountMovement(
          storeId: 'store-2',
          movementType: kCrateMovementOpeningCount,
          quantityDelta: 0,
          createdAt: at(0),
        ),
        CrateCountMovement(
          storeId: 'store-2',
          movementType: kCrateMovementCount,
          quantityDelta: -3,
          createdAt: at(1),
        ),
        writeOff(5, 2),
      ]);
      expect(states[store]!.openCrates, 0);
      expect(states['store-2']!.openCrates, 3);
      expect(foldTotalCrateShortage([
        opening(0),
        count(-5, 1),
        writeOff(2, 2),
      ]), 3);
    });

    test('rows from the same second are ordered by their UUIDv7 id', () {
      // created_at is stored to the second, so a count and a write-off taken
      // in the same second tie; their ids still carry the millisecond.
      final second = at(1);
      final states = foldCrateShortageStatesPerStore([
        CrateCountMovement(
          id: '01920000-0000-7000-8000-000000000001',
          storeId: store,
          movementType: kCrateMovementOpeningCount,
          quantityDelta: 0,
          createdAt: second,
        ),
        CrateCountMovement(
          id: '01920000-0003-7000-8000-000000000001',
          storeId: store,
          movementType: kCrateMovementCount,
          quantityDelta: 4,
          createdAt: second,
        ),
        CrateCountMovement(
          id: '01920000-0001-7000-8000-000000000001',
          storeId: store,
          movementType: kCrateMovementCount,
          quantityDelta: -10,
          createdAt: second,
        ),
        CrateShortageWriteOffEvent(
          id: '01920000-0002-7000-8000-000000000001',
          storeId: store,
          crateCount: 10,
          ratePerCrateKobo: rate,
          createdAt: second,
        ),
      ]);
      expect(states[store]!.openCrates, 0);
      expect(
        states[store]!.reversibleCrates,
        4,
        reason: 'the +4 count came after the write-off',
      );
    });

    test('events are folded in time order, whatever order they arrive in', () {
      final states = foldCrateShortageStatesPerStore([
        writeOff(4, 2),
        count(-10, 1),
        opening(0),
      ]);
      expect(states[store]!.openCrates, 6);
    });
  });
}
