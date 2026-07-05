'use client';

import { useCallback, useState } from 'react';

import { useSession } from '@/components/providers/SessionProvider';
import { useCurrency } from '@/hooks/useCurrency';
import { formatKobo } from '@/lib/currency';
import type { CheckoutResult } from '@/lib/checkout';

// The receipt shown after a successful checkout: order number, lines, totals,
// and the actions — Print (browser print with the receipt-only print stylesheet),
// Share/Download (Web Share where available, else a downloaded text receipt), and
// "Done — back to POS" which clears the cart and returns to the grid.
export function Receipt({
  result,
  onDone,
}: {
  result: CheckoutResult;
  onDone: () => void;
}) {
  const { operator } = useSession();
  const { kobo, code } = useCurrency();
  const [shareNote, setShareNote] = useState<string | null>(null);

  const businessName = operator?.business?.name ?? 'Receipt';
  const when = new Date(result.createdAt).toLocaleString();

  // The amount still owed on this sale (0 unless it was a credit / partial sale).
  const onCreditKobo = Math.max(0, result.netAmountKobo - result.amountPaidKobo);

  const plainText = useCallback(() => {
    const lines = result.lines
      .map(
        (l) =>
          `${l.quantity} x ${l.name}  ${formatKobo(l.unitPriceKobo * l.quantity, code)}`,
      )
      .join('\n');
    return [
      businessName,
      `Order ${result.orderNumber}`,
      when,
      result.customerName ? `Customer: ${result.customerName}` : null,
      '',
      lines,
      '',
      `Subtotal: ${formatKobo(result.totalAmountKobo, code)}`,
      result.discountKobo > 0
        ? `Discount: -${formatKobo(result.discountKobo, code)}`
        : null,
      `Total: ${formatKobo(result.netAmountKobo, code)}`,
      result.paymentMethod === 'wallet'
        ? `Paid with credit: ${formatKobo(result.netAmountKobo, code)}`
        : `Paid (${result.paymentMethod}): ${formatKobo(result.tenderedKobo ?? result.amountPaidKobo, code)}`,
      (result.changeKobo ?? 0) > 0
        ? `Change: ${formatKobo(result.changeKobo ?? 0, code)}`
        : null,
      onCreditKobo > 0 ? `On credit: ${formatKobo(onCreditKobo, code)}` : null,
      result.customerName && result.customerBalanceKobo != null
        ? `Balance: ${
            result.customerBalanceKobo < 0
              ? `owes ${formatKobo(-result.customerBalanceKobo, code)}`
              : `${formatKobo(result.customerBalanceKobo, code)} credit`
          }`
        : null,
      (result.crateCount ?? 0) > 0
        ? `Empties (returnable): ${result.crateCount} crate${result.crateCount === 1 ? '' : 's'}${
            (result.crateDepositKobo ?? 0) > 0
              ? ` — ${formatKobo(result.crateDepositKobo ?? 0, code)} deposit`
              : ''
          }`
        : null,
    ]
      .filter(Boolean)
      .join('\n');
  }, [result, businessName, when, code, onCreditKobo]);

  const onShare = useCallback(async () => {
    setShareNote(null);
    const text = plainText();
    const filename = `receipt-${result.orderNumber}.txt`;
    try {
      if (typeof navigator !== 'undefined' && 'share' in navigator) {
        const file = new File([text], filename, { type: 'text/plain' });
        const canFiles =
          'canShare' in navigator &&
          (navigator as Navigator).canShare?.({ files: [file] });
        if (canFiles) {
          await (navigator as Navigator).share({ files: [file], title: `Order ${result.orderNumber}` });
          return;
        }
        await (navigator as Navigator).share({ title: `Order ${result.orderNumber}`, text });
        return;
      }
    } catch {
      // Fall through to download on cancel/failure.
    }
    // Fallback: download the receipt as a text file.
    const blob = new Blob([text], { type: 'text/plain' });
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = filename;
    a.click();
    URL.revokeObjectURL(url);
    setShareNote('Receipt downloaded.');
  }, [plainText, result.orderNumber]);

  return (
    <div className="modal-overlay" role="dialog" aria-modal="true" aria-label="Receipt">
      <div className="modal modal--receipt">
        <div className="receipt" id="receipt-printable">
          <div className="receipt__brand">{businessName}</div>
          <div className="receipt__muted">Order {result.orderNumber}</div>
          <div className="receipt__muted">{when}</div>
          {result.customerName && (
            <div className="receipt__muted">Customer: {result.customerName}</div>
          )}

          <div className="receipt__divider" />

          <ul className="receipt__lines">
            {result.lines.map((l, i) => (
              <li key={i} className="receipt__line">
                <span className="receipt__line-qty">{l.quantity}×</span>
                <span className="receipt__line-name">{l.name}</span>
                <span className="receipt__line-amt">
                  {kobo(l.unitPriceKobo * l.quantity)}
                </span>
              </li>
            ))}
          </ul>

          <div className="receipt__divider" />

          <div className="receipt__row">
            <span>Subtotal</span>
            <span>{kobo(result.totalAmountKobo)}</span>
          </div>
          {result.discountKobo > 0 && (
            <div className="receipt__row receipt__row--muted">
              <span>Discount</span>
              <span>−{kobo(result.discountKobo)}</span>
            </div>
          )}
          <div className="receipt__row receipt__row--total">
            <span>Total</span>
            <span>{kobo(result.netAmountKobo)}</span>
          </div>
          {result.paymentMethod === 'wallet' ? (
            <div className="receipt__row receipt__row--muted">
              <span>Paid with credit</span>
              <span>{kobo(result.netAmountKobo)}</span>
            </div>
          ) : (
            <div className="receipt__row receipt__row--muted">
              <span>Paid ({result.paymentMethod})</span>
              <span>{kobo(result.tenderedKobo ?? result.amountPaidKobo)}</span>
            </div>
          )}
          {(result.changeKobo ?? 0) > 0 && (
            <div className="receipt__row receipt__row--muted">
              <span>Change</span>
              <span>{kobo(result.changeKobo ?? 0)}</span>
            </div>
          )}
          {onCreditKobo > 0 && (
            <div className="receipt__row receipt__row--muted">
              <span>On credit</span>
              <span>{kobo(onCreditKobo)}</span>
            </div>
          )}
          {result.customerName && result.customerBalanceKobo != null && (
            <div className="receipt__row receipt__row--muted">
              <span>Balance</span>
              <span>
                {result.customerBalanceKobo < 0
                  ? `owes ${kobo(-result.customerBalanceKobo)}`
                  : `${kobo(result.customerBalanceKobo)} credit`}
              </span>
            </div>
          )}
          {(result.crateCount ?? 0) > 0 && (
            <div className="receipt__row receipt__row--muted">
              <span>Empties (returnable)</span>
              <span>
                {result.crateCount} crate{result.crateCount === 1 ? '' : 's'}
                {(result.crateDepositKobo ?? 0) > 0 &&
                  ` · ${kobo(result.crateDepositKobo ?? 0)}`}
              </span>
            </div>
          )}

          <div className="receipt__thanks">Thank you!</div>
        </div>

        {shareNote && <div className="banner banner--info receipt__note">{shareNote}</div>}

        <div className="modal__foot receipt__actions">
          <button className="btn btn--outline" onClick={() => window.print()} type="button">
            Print
          </button>
          <button className="btn btn--outline" onClick={() => void onShare()} type="button">
            Share / Download
          </button>
          <button className="btn btn--primary" onClick={onDone} type="button">
            Done — back to POS
          </button>
        </div>
      </div>
    </div>
  );
}
