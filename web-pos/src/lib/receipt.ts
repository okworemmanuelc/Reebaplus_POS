// The receipt's money summary, built ONCE (Slice 2–4 follow-up, #57). Both the
// on-screen receipt (Receipt.tsx JSX) and the printed / shared plain-text receipt
// derive their subtotal→empties rows from `receiptRows`, so the two renderings
// can't drift. `format` is the active-currency formatter (formatKobo bound to the
// operator's code) supplied by the caller, keeping this module free of the
// currency hook. Product lines render differently plain vs JSX, so they stay in
// Receipt.tsx; this is the shared summary.

import type { CheckoutResult } from './checkout';

export type ReceiptRowKind = 'normal' | 'muted' | 'total';

export interface ReceiptRow {
  label: string;
  value: string;
  kind: ReceiptRowKind;
}

// The summary rows for a completed checkout, in display order. Rows that don't
// apply (no discount, fully-cash sale, walk-in, no crates) are simply omitted, so
// callers render the list as-is.
export function receiptRows(
  result: CheckoutResult,
  format: (kobo: number) => string,
): ReceiptRow[] {
  // The amount still owed on this sale (0 unless it was a credit / partial sale).
  const onCreditKobo = Math.max(0, result.netAmountKobo - result.amountPaidKobo);
  const rows: ReceiptRow[] = [
    { label: 'Subtotal', value: format(result.totalAmountKobo), kind: 'normal' },
  ];
  if (result.discountKobo > 0) {
    rows.push({
      label: 'Discount',
      value: `−${format(result.discountKobo)}`,
      kind: 'muted',
    });
  }
  rows.push({ label: 'Total', value: format(result.netAmountKobo), kind: 'total' });
  if (result.paymentMethod === 'wallet') {
    rows.push({
      label: 'Paid with credit',
      value: format(result.netAmountKobo),
      kind: 'muted',
    });
  } else {
    rows.push({
      label: `Paid (${result.paymentMethod})`,
      value: format(result.tenderedKobo ?? result.amountPaidKobo),
      kind: 'muted',
    });
  }
  if ((result.changeKobo ?? 0) > 0) {
    rows.push({ label: 'Change', value: format(result.changeKobo ?? 0), kind: 'muted' });
  }
  if (onCreditKobo > 0) {
    rows.push({ label: 'On credit', value: format(onCreditKobo), kind: 'muted' });
  }
  if (result.customerName && result.customerBalanceKobo != null) {
    rows.push({
      label: 'Balance',
      value:
        result.customerBalanceKobo < 0
          ? `owes ${format(-result.customerBalanceKobo)}`
          : `${format(result.customerBalanceKobo)} credit`,
      kind: 'muted',
    });
  }
  const crateCount = result.crateCount ?? 0;
  if (crateCount > 0) {
    const deposit = result.crateDepositKobo ?? 0;
    rows.push({
      label: 'Empties (returnable)',
      value: `${crateCount} crate${crateCount === 1 ? '' : 's'}${
        deposit > 0 ? ` · ${format(deposit)} deposit` : ''
      }`,
      kind: 'muted',
    });
  }
  return rows;
}

// The CSS class for a summary row, matching the receipt stylesheet.
export function receiptRowClass(kind: ReceiptRowKind): string {
  if (kind === 'total') return 'receipt__row receipt__row--total';
  if (kind === 'muted') return 'receipt__row receipt__row--muted';
  return 'receipt__row';
}
