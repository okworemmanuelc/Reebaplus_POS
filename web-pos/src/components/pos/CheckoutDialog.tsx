'use client';

import { useMemo, useState } from 'react';

import { useSession } from '@/components/providers/SessionProvider';
import { useCurrency } from '@/hooks/useCurrency';
import {
  checkoutOrder,
  lineUnitPriceKobo,
  paymentMethodMeta,
  paymentMethodsInGroup,
  type CheckoutResult,
  type PaymentMethod,
} from '@/lib/checkout';
import { crateSummary, operatorTracksCrates } from '@/lib/crate';
import { useCart } from './CartProvider';

// Checkout for all Slice 3 paths. Walk-in ⇒ Cash/Transfer only (Slice 2). With a
// registered customer attached ⇒ also Pay-with-Credit (draw from their balance)
// and Register-as-Credit-Sale (they owe the balance). The debt limit is enforced
// server-side by checkout_order; this dialog mirrors that decision client-side
// (hide-don't-block) so the operator sees the block before hitting Complete. The
// write itself stays the server-authoritative RPC — this only gathers inputs.
export function CheckoutDialog({
  onCancel,
  onComplete,
}: {
  onCancel: () => void;
  onComplete: (result: CheckoutResult) => void;
}) {
  const { supabase, operator } = useSession();
  const { kobo } = useCurrency();
  const { lines, subtotalKobo, totalKobo, customer } = useCart();

  const [method, setMethod] = useState<PaymentMethod>('cash');
  // Amount tendered (cash/transfer), in major units; defaults to the exact total.
  const [tendered, setTendered] = useState<string>(
    String(Math.round(totalKobo / 100)),
  );
  // Partial cash taken now on a Register-as-Credit-Sale (major units).
  const [creditPaid, setCreditPaid] = useState<string>('0');
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const isCashLike = method === 'cash' || method === 'transfer';
  const balanceKobo = customer?.balanceKobo ?? 0;
  const limitKobo = customer?.debtLimitKobo ?? 0;

  const tenderedKobo = useMemo(
    () => Math.round((Number.parseFloat(tendered) || 0) * 100),
    [tendered],
  );
  const creditPaidKobo = useMemo(
    () =>
      Math.min(
        Math.max(Math.round((Number.parseFloat(creditPaid) || 0) * 100), 0),
        totalKobo,
      ),
    [creditPaid, totalKobo],
  );

  // The cash that actually settles, by path (mirrors the RPC's v_cash_paid).
  const cashPaidKobo =
    method === 'wallet' ? 0 : method === 'credit' ? creditPaidKobo : totalKobo;

  const changeKobo = Math.max(0, tenderedKobo - totalKobo);
  const discountAppliedKobo = subtotalKobo - totalKobo;
  const cashUnderpaid = isCashLike && tenderedKobo < totalKobo;

  // Projected balance after the sale, and the debt-limit block (mirrors the
  // server's rule: a fully-cash-settled sale never books debt; otherwise the
  // projected balance must stay ≥ −limit, and limit 0 means no credit at all).
  const projectedKobo = balanceKobo + cashPaidKobo - totalKobo;
  const booksNewDebt = cashPaidKobo < totalKobo && projectedKobo < 0;
  const overDebtLimit =
    booksNewDebt && (limitKobo <= 0 || projectedKobo < -limitKobo);

  const storeId = operator?.stores?.[0]?.id ?? null;
  const businessId = operator?.businessId ?? null;

  const canSubmit =
    !submitting &&
    totalKobo > 0 &&
    !cashUnderpaid &&
    !overDebtLimit &&
    // credit/wallet require a customer to post the wallet legs against
    (isCashLike || customer != null);

  async function submit() {
    if (!businessId || !storeId) {
      setError('No store is set up for this business yet.');
      return;
    }
    setSubmitting(true);
    setError(null);
    try {
      const result = await checkoutOrder(supabase, {
        businessId,
        storeId,
        paymentMethod: method,
        amountPaidKobo: cashPaidKobo,
        discountKobo: discountAppliedKobo,
        customerId: customer?.id ?? null,
        customerName: customer?.name ?? null,
        lines: lines.map((l) => ({
          productId: l.product.id,
          quantity: l.quantity,
          unitPriceKobo: lineUnitPriceKobo(l.product),
          name: l.product.name,
        })),
      });
      // Empty-crate summary for the receipt (Slice 4): the returnable crates the
      // customer takes and their deposit value, shown only when the business
      // tracks crates. The crate LEDGER itself was posted server-side by the RPC.
      const crateOn = operatorTracksCrates(operator);
      const empties = crateSummary(lines, crateOn);
      const crate = {
        crateCount: empties.crates,
        crateDepositKobo: empties.depositValueKobo,
      };
      onComplete(
        isCashLike
          ? { ...result, tenderedKobo, changeKobo, ...crate }
          : { ...result, ...crate },
      );
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Checkout failed.');
    } finally {
      setSubmitting(false);
    }
  }

  const completeLabel =
    method === 'wallet'
      ? 'Pay with credit'
      : method === 'credit'
        ? 'Register credit sale'
        : `Complete ${method} sale`;

  return (
    <div className="modal-overlay" role="dialog" aria-modal="true" aria-label="Checkout">
      <div className="modal">
        <div className="modal__head">
          <h2 className="modal__title">Checkout</h2>
          <button className="modal__close" onClick={onCancel} aria-label="Close">
            ✕
          </button>
        </div>

        <div className="modal__body">
          <div className="checkout__total-line">
            <span>Amount due</span>
            <strong>{kobo(totalKobo)}</strong>
          </div>

          {customer && (
            <div className="checkout__customer">
              <span className="checkout__customer-name">{customer.name}</span>
              <span
                className={
                  balanceKobo < 0
                    ? 'checkout__customer-balance checkout__customer-balance--owed'
                    : 'checkout__customer-balance checkout__customer-balance--credit'
                }
              >
                {balanceKobo < 0
                  ? `Owes ${kobo(-balanceKobo)}`
                  : `${kobo(balanceKobo)} credit`}
              </span>
            </div>
          )}

          <div className="field">
            <span className="field__label">Payment method</span>
            <div className="segmented segmented--wrap" role="group" aria-label="Payment method">
              {paymentMethodsInGroup('tender').map((m) => (
                <button
                  key={m}
                  type="button"
                  className={`segmented__opt${method === m ? ' segmented__opt--active' : ''}`}
                  onClick={() => setMethod(m)}
                >
                  {paymentMethodMeta[m].label}
                </button>
              ))}
              {customer &&
                paymentMethodsInGroup('credit').map((m) => (
                  <button
                    key={m}
                    type="button"
                    className={`segmented__opt${method === m ? ' segmented__opt--active' : ''}`}
                    onClick={() => setMethod(m)}
                  >
                    {paymentMethodMeta[m].label}
                  </button>
                ))}
            </div>
          </div>

          {isCashLike && (
            <>
              <div className="field">
                <label className="field__label" htmlFor="tendered">
                  Amount paid
                </label>
                <input
                  id="tendered"
                  className="input"
                  type="number"
                  min={0}
                  inputMode="decimal"
                  value={tendered}
                  onChange={(e) => setTendered(e.target.value)}
                />
              </div>
              <div className="checkout__change">
                <span>Change</span>
                <span>{kobo(changeKobo)}</span>
              </div>
            </>
          )}

          {method === 'credit' && (
            <div className="field">
              <label className="field__label" htmlFor="credit-paid">
                Paid now (optional)
              </label>
              <input
                id="credit-paid"
                className="input"
                type="number"
                min={0}
                inputMode="decimal"
                value={creditPaid}
                onChange={(e) => setCreditPaid(e.target.value)}
              />
              <p className="field__hint">
                {creditPaidKobo > 0
                  ? `${kobo(creditPaidKobo)} now, ${kobo(totalKobo - creditPaidKobo)} on credit.`
                  : 'The whole total is booked to the customer as debt.'}
              </p>
            </div>
          )}

          {method === 'wallet' && (
            <p className="field__hint">
              {kobo(totalKobo)} is drawn from {customer?.name}&rsquo;s credit
              balance — no cash changes hands.
            </p>
          )}

          {customer && !isCashLike && (
            <div className="checkout__projected">
              <span>Balance after sale</span>
              <span
                className={
                  projectedKobo < 0
                    ? 'checkout__customer-balance--owed'
                    : 'checkout__customer-balance--credit'
                }
              >
                {projectedKobo < 0
                  ? `Owes ${kobo(-projectedKobo)}`
                  : `${kobo(projectedKobo)} credit`}
              </span>
            </div>
          )}

          {overDebtLimit && (
            <div className="banner banner--error">
              {limitKobo <= 0
                ? `${customer?.name} has no credit limit set — they can’t take goods on credit. Take the full amount or set a limit on mobile.`
                : `This would push ${customer?.name} to ${kobo(-projectedKobo)} owed, past their ${kobo(limitKobo)} limit. Take a payment or lower the amount.`}
            </div>
          )}

          {error && <div className="banner banner--error">{error}</div>}
        </div>

        <div className="modal__foot">
          <button className="btn btn--outline" onClick={onCancel} disabled={submitting}>
            Cancel
          </button>
          <button
            className="btn btn--primary"
            onClick={() => void submit()}
            disabled={!canSubmit}
          >
            {submitting ? 'Settling…' : completeLabel}
          </button>
        </div>
      </div>
    </div>
  );
}
