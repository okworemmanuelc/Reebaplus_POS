'use client';

import { useMemo, useState } from 'react';

import { useSession } from '@/components/providers/SessionProvider';
import { useCurrency } from '@/hooks/useCurrency';
import {
  receiveStock,
  RECEIVE_PAYMENT_METHODS,
  type ReceivePaymentMethod,
} from '@/lib/inventory';
import type { ProductWithStock, SupplierRow } from '@/lib/types';

function toKobo(naira: string): number {
  const n = parseFloat(naira);
  return Number.isFinite(n) && n > 0 ? Math.round(n * 100) : 0;
}
function fromKobo(kobo: number | null | undefined): string {
  return kobo && kobo > 0 ? (kobo / 100).toString() : '';
}

interface DraftLine {
  productId: string;
  name: string;
  quantity: string;
  buying: string; // Naira
}

// Log a supplier delivery: increases stock, posts the supplier invoice (debit) +
// an optional payment (credit), and pushes a receipt-dated Cost Batch per line at
// the delivery cost. Mirrors the mobile Receive Stock flow; the receive_stock RPC
// does it all atomically server-side and re-checks the permission.
export function ReceiveStockDialog({
  products,
  suppliers,
  onSaved,
  onCancel,
}: {
  products: ProductWithStock[];
  suppliers: SupplierRow[];
  onSaved: () => void;
  onCancel: () => void;
}) {
  const { supabase, operator } = useSession();
  const { code, kobo } = useCurrency();

  const today = new Date().toISOString().slice(0, 10);
  const [supplierId, setSupplierId] = useState(suppliers[0]?.id ?? '');
  const [receivedAt, setReceivedAt] = useState(today);
  const [lines, setLines] = useState<DraftLine[]>([]);
  const [picker, setPicker] = useState('');
  const [method, setMethod] = useState<ReceivePaymentMethod>('cash');
  const [amountPaid, setAmountPaid] = useState('');
  const [note, setNote] = useState('');
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const businessId = operator?.businessId ?? null;
  const stores = operator?.stores ?? [];
  const [storeId, setStoreId] = useState<string | null>(stores[0]?.id ?? null);

  const available = useMemo(
    () => products.filter((p) => !lines.some((l) => l.productId === p.id)),
    [products, lines],
  );

  const invoiceTotalKobo = useMemo(
    () =>
      lines.reduce(
        (sum, l) => sum + (parseInt(l.quantity, 10) || 0) * toKobo(l.buying),
        0,
      ),
    [lines],
  );

  function addLine(productId: string) {
    const p = products.find((x) => x.id === productId);
    if (!p) return;
    setLines((prev) => [
      ...prev,
      {
        productId: p.id,
        name: p.name,
        quantity: '1',
        buying: fromKobo(p.buying_price_kobo),
      },
    ]);
    setPicker('');
  }

  function updateLine(productId: string, patch: Partial<DraftLine>) {
    setLines((prev) =>
      prev.map((l) => (l.productId === productId ? { ...l, ...patch } : l)),
    );
  }

  function removeLine(productId: string) {
    setLines((prev) => prev.filter((l) => l.productId !== productId));
  }

  async function onSubmit(e: React.FormEvent) {
    e.preventDefault();
    if (!businessId || !storeId) {
      setError('Your session is not linked to a business/store.');
      return;
    }
    if (!supplierId) {
      setError('Choose a supplier for this delivery.');
      return;
    }
    const cleaned = lines
      .map((l) => ({
        productId: l.productId,
        quantity: parseInt(l.quantity, 10) || 0,
        buyingPriceKobo: toKobo(l.buying),
      }))
      .filter((l) => l.quantity > 0);
    if (cleaned.length === 0) {
      setError('Add at least one line with a quantity of one or more.');
      return;
    }
    setSubmitting(true);
    setError(null);
    try {
      await receiveStock(supabase, {
        businessId,
        supplierId,
        storeId,
        receivedAt: new Date(receivedAt).toISOString(),
        lines: cleaned,
        amountPaidKobo: toKobo(amountPaid),
        paymentMethod: method,
        note: note.trim() || null,
      });
      onSaved();
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Could not record the delivery.');
      setSubmitting(false);
    }
  }

  const noSuppliers = suppliers.length === 0;

  return (
    <div
      className="modal-overlay"
      role="dialog"
      aria-modal="true"
      aria-label="Receive stock"
    >
      <div className="modal modal--wide">
        <div className="modal__head">
          <h2 className="modal__title">Receive stock</h2>
          <button className="modal__close" onClick={onCancel} aria-label="Close">
            ✕
          </button>
        </div>

        <form onSubmit={onSubmit}>
          <div className="modal__body">
            {error && <div className="banner banner--error">{error}</div>}
            {noSuppliers && (
              <div className="banner">
                No suppliers yet — add a supplier on the mobile app first, then
                record the delivery here.
              </div>
            )}

            <div className="form-row">
              <div className="field">
                <label className="field__label" htmlFor="r-supplier">
                  Supplier
                </label>
                <select
                  id="r-supplier"
                  className="input"
                  value={supplierId}
                  onChange={(e) => setSupplierId(e.target.value)}
                  disabled={noSuppliers}
                >
                  <option value="">Choose a supplier…</option>
                  {suppliers.map((s) => (
                    <option key={s.id} value={s.id}>
                      {s.name ?? 'Unnamed supplier'}
                    </option>
                  ))}
                </select>
              </div>
              <div className="field">
                <label className="field__label" htmlFor="r-date">
                  Date received
                </label>
                <input
                  id="r-date"
                  className="input"
                  type="date"
                  value={receivedAt}
                  max={today}
                  onChange={(e) => setReceivedAt(e.target.value)}
                />
              </div>
            </div>

            {stores.length > 1 && (
              <div className="field">
                <label className="field__label" htmlFor="r-store">
                  Store
                </label>
                <select
                  id="r-store"
                  className="input"
                  value={storeId ?? ''}
                  onChange={(e) => setStoreId(e.target.value || null)}
                >
                  {stores.map((s) => (
                    <option key={s.id} value={s.id}>
                      {s.name}
                    </option>
                  ))}
                </select>
                <span className="field__hint">Stock is received into this store.</span>
              </div>
            )}

            <div className="field">
              <span className="field__label">Products received</span>
              {lines.length === 0 ? (
                <p className="muted">No lines yet — add a product below.</p>
              ) : (
                <div className="receive-lines">
                  {lines.map((l) => (
                    <div key={l.productId} className="receive-line">
                      <span className="receive-line__name">{l.name}</span>
                      <input
                        className="input receive-line__qty"
                        type="number"
                        min={1}
                        step={1}
                        inputMode="numeric"
                        aria-label={`Quantity of ${l.name}`}
                        value={l.quantity}
                        onChange={(e) =>
                          updateLine(l.productId, { quantity: e.target.value })
                        }
                      />
                      <input
                        className="input receive-line__cost"
                        type="number"
                        min={0}
                        step="0.01"
                        inputMode="decimal"
                        aria-label={`Unit cost of ${l.name} in ${code}`}
                        value={l.buying}
                        onChange={(e) =>
                          updateLine(l.productId, { buying: e.target.value })
                        }
                      />
                      <span className="receive-line__total">
                        {kobo((parseInt(l.quantity, 10) || 0) * toKobo(l.buying))}
                      </span>
                      <button
                        type="button"
                        className="btn btn--outline btn--sm"
                        onClick={() => removeLine(l.productId)}
                        aria-label={`Remove ${l.name}`}
                      >
                        ✕
                      </button>
                    </div>
                  ))}
                </div>
              )}

              {available.length > 0 && (
                <select
                  className="input"
                  value={picker}
                  onChange={(e) => e.target.value && addLine(e.target.value)}
                >
                  <option value="">+ Add a product…</option>
                  {available.map((p) => (
                    <option key={p.id} value={p.id}>
                      {p.name}
                    </option>
                  ))}
                </select>
              )}
            </div>

            <div className="receive-invoice">
              <span>Invoice total</span>
              <strong>{kobo(invoiceTotalKobo)}</strong>
            </div>

            <div className="form-row">
              <div className="field">
                <label className="field__label" htmlFor="r-paid">
                  Amount paid now ({code})
                </label>
                <input
                  id="r-paid"
                  className="input"
                  type="number"
                  min={0}
                  step="0.01"
                  inputMode="decimal"
                  value={amountPaid}
                  onChange={(e) => setAmountPaid(e.target.value)}
                  placeholder="0"
                />
              </div>
              <div className="field">
                <label className="field__label" htmlFor="r-method">
                  Payment method
                </label>
                <select
                  id="r-method"
                  className="input"
                  value={method}
                  onChange={(e) =>
                    setMethod(e.target.value as ReceivePaymentMethod)
                  }
                >
                  {RECEIVE_PAYMENT_METHODS.map((m) => (
                    <option key={m} value={m}>
                      {m[0].toUpperCase() + m.slice(1)}
                    </option>
                  ))}
                </select>
              </div>
            </div>

            <div className="field">
              <label className="field__label" htmlFor="r-note">
                Note / reference (optional)
              </label>
              <input
                id="r-note"
                className="input"
                value={note}
                onChange={(e) => setNote(e.target.value)}
                placeholder="Invoice number, bank reference…"
              />
            </div>
          </div>

          <div className="modal__foot">
            <button
              type="button"
              className="btn btn--outline"
              onClick={onCancel}
              disabled={submitting}
            >
              Cancel
            </button>
            <button
              type="submit"
              className="btn btn--primary"
              disabled={submitting || noSuppliers || lines.length === 0}
            >
              {submitting ? 'Recording…' : 'Record delivery'}
            </button>
          </div>
        </form>
      </div>
    </div>
  );
}
