// crate_deposit_position_test.dart
//
// #212 / PRD #203, ADR 0023 rules 1, 2 and 4 — the ONE read seam for the crate
// deposit outflow, exercised with **no database at all**.
//
// `computeCrateDepositPosition` is the only place the arithmetic lives. Slices
// #213 (settlement), #214 (standing float), #215 (business worth + the
// reconciliation card), #216 and #217 all read through it, so if this file is
// green the figures on every one of those surfaces are green — and if it is
// red, none of them can be trusted. That is the whole reason for a pure seam,
// and it is why this suite spins up no `AppDatabase`, opens no connection and
// builds no widget: it takes rows and counts as values and checks the answer.
//
// It pins, in order:
//   1. THE RELEASE GATE — a `none` brand reads all zeros, always, no matter
//      what rows are handed to it.
//   2. The balance is the signed sum of an append-only ledger, and nothing
//      else. Money out raises the asset; money back lowers it.
//   3. Pending requests are NOT the balance. Nothing has moved yet.
//   4. The shortfall is `crates owed − empties on hand`, valued at the
//      manufacturer's rate, floored at 0 — a warning, never a loss.
//   5. The disclosure figures that let #215 show the two numbers ADR 0023
//      finding #3 says have never met, side by side.
//   6. The movement types #213 and #214 will write already compute correctly
//      here, which is what makes those slices code-only.

import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/crates/crate_deposit_ledger_types.dart';
import 'package:reebaplus_pos/core/crates/crate_deposit_position.dart';
import 'package:reebaplus_pos/core/crates/crate_money_arrangement.dart';

void main() {
  // ₦3,500 a crate — a realistic Nigerian beer-crate deposit.
  const rate = 350000;

  CrateDepositMovement placed(int crates) => CrateDepositMovement(
    movementType: kCrateDepositMovementPlacement,
    signedAmountKobo: crates * rate,
    crateCount: crates,
  );

  CrateDepositMovement released(int crates, {int? amountKobo}) =>
      CrateDepositMovement(
        movementType: kCrateDepositMovementRelease,
        signedAmountKobo: -(amountKobo ?? crates * rate),
        crateCount: -crates,
      );

  group('THE RELEASE GATE — a `none` brand reads zero, whatever it is fed', () {
    test('an empty `none` brand is the zero position', () {
      final p = computeCrateDepositPosition(
        arrangement: CrateMoneyArrangement.none,
        ratePerCrateKobo: rate,
      );
      expect(p.placedDepositKobo, 0);
      expect(p.placedCrates, 0);
      expect(p.pendingDepositKobo, 0);
      expect(p.shortfallCrates, 0);
      expect(p.shortfallValueKobo, 0);
      expect(p.unbackedCrates, 0);
      expect(p.unbackedValueKobo, 0);
      expect(p.movesMoney, isFalse);
      expect(p.isSettled, isTrue);
    });

    test('a `none` brand carrying real ledger rows, real pending requests and '
        'a real crate debt STILL reads zero', () {
      // The residue case: a brand switched on, used, then switched back off.
      // The owner's stated arrangement wins over the leftover rows. Nothing is
      // deleted — switch it on again and every figure returns (see the next
      // test, which is the same input at `per_delivery`).
      final p = computeCrateDepositPosition(
        arrangement: CrateMoneyArrangement.none,
        ratePerCrateKobo: rate,
        movements: [placed(40)],
        pending: const [
          PendingCrateDeposit(
            kind: kCrateDepositMovementPlacement,
            requestedAmountKobo: 1400000,
            crateCount: 4,
          ),
        ],
        cratesOwed: 40,
        emptiesOnHand: 12,
      );
      expect(p.placedDepositKobo, 0);
      expect(p.pendingDepositKobo, 0);
      expect(p.shortfallCrates, 0);
      expect(p.shortfallValueKobo, 0);
      expect(p.cratesOwed, 0);
      expect(p.ratePerCrateKobo, 0);
    });

    test('the same rows at `per_delivery` produce real figures — so the zero '
        'above is the ARRANGEMENT talking, not empty inputs', () {
      final p = computeCrateDepositPosition(
        arrangement: CrateMoneyArrangement.perDelivery,
        ratePerCrateKobo: rate,
        movements: [placed(40)],
        pending: const [
          PendingCrateDeposit(
            kind: kCrateDepositMovementPlacement,
            requestedAmountKobo: 1400000,
            crateCount: 4,
          ),
        ],
        cratesOwed: 40,
        emptiesOnHand: 12,
      );
      expect(p.placedDepositKobo, 40 * rate);
      expect(p.pendingDepositKobo, 1400000);
      expect(p.shortfallCrates, 28);
      expect(p.shortfallValueKobo, 28 * rate);
    });
  });

  group('the balance is the signed sum of the ledger', () {
    test('one placement raises the asset by exactly what was paid', () {
      final p = computeCrateDepositPosition(
        arrangement: CrateMoneyArrangement.perDelivery,
        ratePerCrateKobo: rate,
        movements: [placed(20)],
      );
      expect(p.placedDepositKobo, 7000000); // ₦70,000
      expect(p.placedCrates, 20);
      expect(p.isSettled, isFalse);
    });

    test('placements accumulate; a release nets them down', () {
      final p = computeCrateDepositPosition(
        arrangement: CrateMoneyArrangement.perDelivery,
        ratePerCrateKobo: rate,
        movements: [placed(20), placed(15), released(10)],
      );
      expect(p.placedDepositKobo, 25 * rate);
      expect(p.placedCrates, 25);
    });

    test('every crate settled at the full rate returns the position to zero — '
        'the money was never a cost, it came back', () {
      final p = computeCrateDepositPosition(
        arrangement: CrateMoneyArrangement.perDelivery,
        ratePerCrateKobo: rate,
        movements: [placed(20), released(20)],
      );
      expect(p.placedDepositKobo, 0);
      expect(p.placedCrates, 0);
      expect(p.isSettled, isTrue);
    });

    test('#213 — a supplier who short-pays leaves the difference standing, and '
        'the crate count still clears', () {
      // 20 crates placed at ₦3,500 = ₦70,000; the depot hands back ₦60,000 for
      // all 20. The ₦10,000 is a real fact about a real settlement, not an
      // arithmetic error to be smoothed over. It stays on the books until
      // somebody deliberately writes it off (#216).
      final p = computeCrateDepositPosition(
        arrangement: CrateMoneyArrangement.perDelivery,
        ratePerCrateKobo: rate,
        movements: [placed(20), released(20, amountKobo: 6000000)],
      );
      expect(p.placedDepositKobo, 1000000); // ₦10,000 never came back
      expect(p.placedCrates, 0);
      expect(p.isSettled, isFalse);
    });

    test('a negative balance is surfaced, not clamped — more back than ever '
        'went out is a defect somebody has to see', () {
      final p = computeCrateDepositPosition(
        arrangement: CrateMoneyArrangement.perDelivery,
        ratePerCrateKobo: rate,
        movements: [placed(5), released(9)],
      );
      expect(p.placedDepositKobo, -4 * rate);
    });

    test('#214 — the standing-float movements sum in the same ledger and cover '
        'no crates', () {
      final p = computeCrateDepositPosition(
        arrangement: CrateMoneyArrangement.standingFloat,
        ratePerCrateKobo: rate,
        movements: const [
          CrateDepositMovement(
            movementType: kCrateDepositMovementFloatTopup,
            signedAmountKobo: 20000000, // ₦200,000 lump sum
          ),
          CrateDepositMovement(
            movementType: kCrateDepositMovementFloatPayout,
            signedAmountKobo: -5000000, // ₦50,000 paid back
          ),
        ],
      );
      expect(p.placedDepositKobo, 15000000);
      expect(p.placedCrates, 0);
      expect(p.movesMoney, isTrue);
    });

    test('a correction is a new opposite-signed row, and it just sums', () {
      final p = computeCrateDepositPosition(
        arrangement: CrateMoneyArrangement.perDelivery,
        ratePerCrateKobo: rate,
        movements: [
          placed(10),
          const CrateDepositMovement(
            movementType: kCrateDepositMovementAdjustment,
            signedAmountKobo: -500000,
          ),
        ],
      );
      expect(p.placedDepositKobo, 10 * rate - 500000);
    });
  });

  group('pending money is NOT placed money', () {
    test('a raised-but-undecided request moves the pending figure only', () {
      final p = computeCrateDepositPosition(
        arrangement: CrateMoneyArrangement.perDelivery,
        ratePerCrateKobo: rate,
        pending: const [
          PendingCrateDeposit(
            kind: kCrateDepositMovementPlacement,
            requestedAmountKobo: 2800000,
            crateCount: 8,
          ),
        ],
      );
      // Nothing has moved. A book entry appears only when money genuinely did.
      expect(p.placedDepositKobo, 0);
      expect(p.placedCrates, 0);
      expect(p.pendingDepositKobo, 2800000);
      expect(p.pendingCrates, 8);
      expect(p.hasPending, isTrue);
      expect(p.isSettled, isFalse);
    });

    test('several pending requests add up', () {
      final p = computeCrateDepositPosition(
        arrangement: CrateMoneyArrangement.perDelivery,
        ratePerCrateKobo: rate,
        pending: const [
          PendingCrateDeposit(
            kind: kCrateDepositMovementPlacement,
            requestedAmountKobo: 2800000,
            crateCount: 8,
          ),
          PendingCrateDeposit(
            kind: kCrateDepositMovementPlacement,
            requestedAmountKobo: 700000,
            crateCount: 2,
          ),
        ],
      );
      expect(p.pendingDepositKobo, 3500000);
      expect(p.pendingCrates, 10);
    });
  });

  group('the shortfall is a warning, not a loss (ADR 0023 rules 4 and 5)', () {
    test('crates owed beyond the empties on hand, at the brand rate', () {
      final p = computeCrateDepositPosition(
        arrangement: CrateMoneyArrangement.perDelivery,
        ratePerCrateKobo: rate,
        movements: [placed(50)],
        cratesOwed: 50,
        emptiesOnHand: 38,
      );
      expect(p.shortfallCrates, 12);
      expect(p.shortfallValueKobo, 12 * rate);
      expect(p.hasShortfall, isTrue);
    });

    test('more empties in the yard than we owe is not a negative shortfall', () {
      final p = computeCrateDepositPosition(
        arrangement: CrateMoneyArrangement.perDelivery,
        ratePerCrateKobo: rate,
        cratesOwed: 10,
        emptiesOnHand: 25,
      );
      expect(p.shortfallCrates, 0);
      expect(p.shortfallValueKobo, 0);
      expect(p.hasShortfall, isFalse);
    });

    test('a zero rate makes the shortfall worth nothing, and says so rather '
        'than guessing a rate', () {
      final p = computeCrateDepositPosition(
        arrangement: CrateMoneyArrangement.perDelivery,
        ratePerCrateKobo: 0,
        cratesOwed: 40,
        emptiesOnHand: 10,
      );
      expect(p.shortfallCrates, 30);
      expect(p.shortfallValueKobo, 0);
    });

    test('a negative rate is treated as no rate, never as a negative value', () {
      final p = computeCrateDepositPosition(
        arrangement: CrateMoneyArrangement.perDelivery,
        ratePerCrateKobo: -1,
        cratesOwed: 5,
      );
      expect(p.ratePerCrateKobo, 0);
      expect(p.shortfallValueKobo, 0);
    });
  });

  group('the disclosure figures ADR 0023 finding #3 exists for', () {
    test('a brand switched on today shows every pre-switch crate as unbacked, '
        'and does NOT restate them', () {
      // 120 crates were received under `none` over the years; the owner turns
      // `per_delivery` on and the next delivery of 10 places real money. The
      // 120 are NOT retroactively deposited (ADR 0021 — a setting changed today
      // never rewrites a closed day), and the gap is reported rather than
      // quietly folded into the balance.
      final p = computeCrateDepositPosition(
        arrangement: CrateMoneyArrangement.perDelivery,
        ratePerCrateKobo: rate,
        movements: [placed(10)],
        cratesOwed: 130,
        emptiesOnHand: 130,
      );
      expect(p.placedDepositKobo, 10 * rate);
      expect(p.unbackedCrates, 120);
      expect(p.unbackedValueKobo, 120 * rate);
      // Every crate is in the yard, so nothing is at risk — the unbacked figure
      // and the shortfall are different questions and must not be conflated.
      expect(p.shortfallCrates, 0);
    });

    test('a brand that has run under `per_delivery` since its first delivery '
        'ties out exactly', () {
      final p = computeCrateDepositPosition(
        arrangement: CrateMoneyArrangement.perDelivery,
        ratePerCrateKobo: rate,
        movements: [placed(30)],
        cratesOwed: 30,
        emptiesOnHand: 30,
      );
      expect(p.unbackedCrates, 0);
      expect(p.notionalDeltaKobo, 0);
    });

    test('the notional delta names the size of the gap, signed', () {
      final p = computeCrateDepositPosition(
        arrangement: CrateMoneyArrangement.perDelivery,
        ratePerCrateKobo: rate,
        movements: [placed(10)],
        cratesOwed: 130,
      );
      expect(p.notionalDeltaKobo, 10 * rate - 130 * rate);
    });
  });
}
