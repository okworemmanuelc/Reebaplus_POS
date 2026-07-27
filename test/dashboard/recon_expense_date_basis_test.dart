import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/business_scoped_stream.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/stores/van_store.dart';
import 'package:reebaplus_pos/features/dashboard/reconciliation/recon_data.dart';

/// #155 US 34 / #198 — the two expense date bases, pinned.
///
/// An expense carries two dates: `expense_date`, the day the shop owner says the
/// money was spent (the §20.2 picker), and `created_at`, the moment the row was
/// keyed in. Reporting (Expenses screen, monthly budget, Home, and — after #198
/// — the reconciliation P&L) is on the PICKED date. The cash-flow card is the
/// one deliberate exception: it counts the drawer movement on its own record
/// time, because that is when the cash physically left.
void main() {
  // The reporting period under test: Mon 13 Jul → Sun 19 Jul 2026 inclusive
  // (exclusive end Mon 20 Jul), mirroring `computeReconData`'s `inSpan`.
  final periodStart = DateTime(2026, 7, 13);
  final periodEndExclusive = DateTime(2026, 7, 20);
  bool inSpan(DateTime t) =>
      !t.isBefore(periodStart) && t.isBefore(periodEndExclusive);
  bool inScope(String? storeId) => storeId == 'store-1';

  ExpenseData expense({
    required DateTime expenseDate,
    required DateTime createdAt,
    int amountKobo = 500000,
    String status = 'approved',
    bool isDeleted = false,
    String? storeId = 'store-1',
  }) {
    return ExpenseData(
      id: 'exp-1',
      businessId: 'biz-1',
      amountKobo: amountKobo,
      description: 'Diesel for the generator',
      storeId: storeId,
      status: status,
      expenseDate: expenseDate,
      isDeleted: isDeleted,
      createdAt: createdAt,
      lastUpdatedAt: createdAt,
    );
  }

  PaymentTransactionData cashOut(DateTime createdAt) {
    return PaymentTransactionData(
      id: 'pay-1',
      businessId: 'biz-1',
      storeId: 'store-1',
      amountKobo: 500000,
      method: 'cash',
      type: 'expense',
      expenseId: 'exp-1',
      createdAt: createdAt,
      lastUpdatedAt: createdAt,
    );
  }

  group('recon P&L expenses follow the picked date (#155 US 34 / #198)', () {
    test('a backdated expense counts in the period its PICKED date falls in, '
        'not the period it was keyed in', () {
      // Saturday's diesel, only keyed in the following Tuesday.
      final e = expense(
        expenseDate: DateTime(2026, 7, 18), // Sat — inside the period
        createdAt: DateTime(2026, 7, 21, 9), // Tue — outside the period
      );
      final pl = approvedExpensesInPeriod(
        [e],
        inSpan: inSpan,
        inScope: inScope,
      );
      // Before #198 this summed on `created_at`, so the week the money was
      // actually spent showed ₦0 of diesel.
      expect(pl.totalKobo, 500000);
      expect(pl.count, 1);
    });

    test('the mirror: an expense PICKED outside the period is excluded even '
        'though it was keyed in inside it', () {
      final e = expense(
        expenseDate: DateTime(2026, 7, 11), // Sat before — outside
        createdAt: DateTime(2026, 7, 15, 9), // Wed — inside
      );
      final pl = approvedExpensesInPeriod(
        [e],
        inSpan: inSpan,
        inScope: inScope,
      );
      // Under the old record-time basis this leaked ₦5,000 into the wrong week.
      expect(pl.totalKobo, 0);
      expect(pl.count, 0);
    });

    test('an expense picked and keyed inside the period is unaffected', () {
      final e = expense(
        expenseDate: DateTime(2026, 7, 15),
        createdAt: DateTime(2026, 7, 15, 14),
      );
      final pl = approvedExpensesInPeriod(
        [e],
        inSpan: inSpan,
        inScope: inScope,
      );
      expect(pl.totalKobo, 500000);
      expect(pl.count, 1);
    });

    test('a soft-deleted expense is excluded on either basis', () {
      final byPicked = expense(
        expenseDate: DateTime(2026, 7, 15),
        createdAt: DateTime(2026, 7, 15),
        isDeleted: true,
      );
      final byRecorded = expense(
        expenseDate: DateTime(2026, 7, 11),
        createdAt: DateTime(2026, 7, 15),
        isDeleted: true,
      );
      expect(
        approvedExpensesInPeriod(
          [byPicked, byRecorded],
          inSpan: inSpan,
          inScope: inScope,
        ),
        (totalKobo: 0, count: 0),
      );
    });

    test('pending and rejected expenses never count (§20.1 approved-only)', () {
      final rows = [
        expense(
          expenseDate: DateTime(2026, 7, 15),
          createdAt: DateTime(2026, 7, 15),
          status: 'pending',
        ),
        expense(
          expenseDate: DateTime(2026, 7, 15),
          createdAt: DateTime(2026, 7, 15),
          status: 'rejected',
        ),
      ];
      expect(
        approvedExpensesInPeriod(rows, inSpan: inSpan, inScope: inScope),
        (totalKobo: 0, count: 0),
      );
    });

    test('an out-of-scope store is excluded even when the picked date is in '
        'the period', () {
      final e = expense(
        expenseDate: DateTime(2026, 7, 15),
        createdAt: DateTime(2026, 7, 15),
        storeId: 'store-2',
      );
      expect(
        approvedExpensesInPeriod([e], inSpan: inSpan, inScope: inScope),
        (totalKobo: 0, count: 0),
      );
    });
  });

  group('the cash card keeps custody timing (#198 documented exception)', () {
    test('the backdated expense moves the P&L figure but NOT the cash figure', () {
      final pickedDate = DateTime(2026, 7, 18); // Sat — inside the period
      final keyedAt = DateTime(2026, 7, 21, 9); // Tue — outside the period
      final e = expense(expenseDate: pickedDate, createdAt: keyedAt);
      // The cash payment row is written when the expense is recorded, so its
      // record time is the Tuesday the money actually left the drawer.
      final payment = cashOut(keyedAt);

      expect(
        approvedExpensesInPeriod([e], inSpan: inSpan, inScope: inScope).totalKobo,
        500000,
        reason: 'the P&L books the spend in the week it was spent',
      );
      expect(
        inSpan(cashMovementDate(payment)),
        isFalse,
        reason: 'the drawer only emptied the following Tuesday — the cash card '
            'must not restate a week whose cash never moved',
      );
    });

    test('the mirror: cash counts inside the period the drawer moved, while '
        'the P&L does not', () {
      final pickedDate = DateTime(2026, 7, 11); // outside the period
      final keyedAt = DateTime(2026, 7, 15, 9); // inside the period
      final e = expense(expenseDate: pickedDate, createdAt: keyedAt);
      final payment = cashOut(keyedAt);

      expect(
        approvedExpensesInPeriod([e], inSpan: inSpan, inScope: inScope).totalKobo,
        0,
      );
      expect(inSpan(cashMovementDate(payment)), isTrue);
    });

    test('cashMovementDate is the record time for every cash tender type', () {
      final at = DateTime(2026, 7, 15, 10);
      expect(cashMovementDate(cashOut(at)), at);
    });
  });

  group('expenseReportingDate', () {
    test('is the user-picked expense date, never the record time', () {
      final e = expense(
        expenseDate: DateTime(2026, 7, 18),
        createdAt: DateTime(2026, 7, 21, 9),
      );
      expect(expenseReportingDate(e), DateTime(2026, 7, 18));
      expect(expenseReportingDate(e), isNot(e.createdAt));
    });
  });

  // ── The claim at the level that matters: the two MONEY FIGURES ─────────────
  //
  // The helper tests above pin the filter; these pin what the CEO actually
  // reads off the reconciliation. Method borrowed from
  // `recon_van_sale_exclusion_test.dart`: overriding `currentBusinessIdProvider`
  // with null makes every business-scoped provider emit its `whenAbsent` value
  // without touching a database, so only the expense feed, the payment feed and
  // the store-filter inputs need real values.
  StoreData store(String id) => StoreData(
    id: id,
    businessId: 'biz-1',
    name: 'Store $id',
    location: null,
    kind: kStoreKindStore,
    isDeleted: false,
    createdAt: DateTime.utc(2026, 1, 1),
    lastUpdatedAt: DateTime.utc(2026, 1, 1),
  );

  Future<ReconData> computeWith(
    WidgetTester tester, {
    required List<ExpenseData> expenses,
    required List<PaymentTransactionData> payments,
  }) async {
    // Tear the previous scope down first so two computes in one test can't
    // share a container (and pass vacuously off the first one's stream value).
    await tester.pumpWidget(const SizedBox.shrink());
    late ReconData out;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          currentBusinessIdProvider.overrideWithValue(null),
          allExpensesProvider.overrideWith(
            (ref) => Stream.value([
              for (final e in expenses) ExpenseWithCategory(expense: e),
            ]),
          ),
          allPaymentTransactionsProvider.overrideWith(
            (ref) => Stream.value(payments),
          ),
          // reconStoreFilter's four inputs.
          selectableStoresProvider.overrideWithValue([store('store-1')]),
          canViewAllStoresProvider.overrideWithValue(true),
          lockedStoreProvider.overrideWith(
            (ref) => ValueNotifier<String?>(null),
          ),
          vanStoresProvider.overrideWithValue(VanStores.of([store('store-1')])),
        ],
        child: Consumer(
          builder: (_, ref, _) {
            out = computeReconData(
              ref,
              start: periodStart,
              endExclusive: periodEndExclusive,
              isCeo: true,
            );
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    await tester.pump();
    return out;
  }

  group('the reconciliation figures (All Stores, CEO) — #198', () {
    testWidgets('a backdated expense lands in the P&L figure and moves the '
        'cash figure NOT AT ALL', (tester) async {
      // Saturday's diesel (inside the period), keyed in the following Tuesday
      // (outside it) — so the cash left the drawer outside the period.
      final keyedAt = DateTime(2026, 7, 21, 9);
      final d = await computeWith(
        tester,
        expenses: [
          expense(expenseDate: DateTime(2026, 7, 18), createdAt: keyedAt),
        ],
        payments: [cashOut(keyedAt)],
      );

      expect(d.expensesKobo, 500000, reason: 'booked in the week it was spent');
      expect(d.expensesCount, 1);
      expect(
        d.cashExpensesKobo,
        0,
        reason: 'the drawer only emptied the following Tuesday — a backdated '
            'receipt cannot un-empty a till that was already counted',
      );
    });

    testWidgets('the mirror: an expense picked before the period moves the cash '
        'figure only', (tester) async {
      final keyedAt = DateTime(2026, 7, 15, 9); // inside the period
      final d = await computeWith(
        tester,
        expenses: [
          expense(expenseDate: DateTime(2026, 7, 11), createdAt: keyedAt),
        ],
        payments: [cashOut(keyedAt)],
      );

      // Before #198 this summed on `created_at` and reported ₦5,000 of profit
      // eaten by a bill that belongs to the previous week.
      expect(d.expensesKobo, 0);
      expect(d.expensesCount, 0);
      expect(d.cashExpensesKobo, 500000);
    });

    testWidgets('an expense picked and paid inside the period shows on BOTH '
        'figures — the bases only diverge when the dates do', (tester) async {
      final at = DateTime(2026, 7, 15, 9);
      final d = await computeWith(
        tester,
        expenses: [expense(expenseDate: at, createdAt: at)],
        payments: [cashOut(at)],
      );

      expect(d.expensesKobo, 500000);
      expect(d.cashExpensesKobo, 500000);
    });
  });
}
