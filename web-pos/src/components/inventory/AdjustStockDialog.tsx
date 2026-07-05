'use client';

import { useState } from 'react';

import { useSession } from '@/components/providers/SessionProvider';
import { requestStockAdjustment } from '@/lib/stockAdjustments';
import type { ProductWithStock } from '@/lib/types';

// Raise a stock adjustment for one product. The server decides the outcome from
// the caller's role: a manager/CEO's change applies immediately; a stock keeper's
// becomes a pending request. We surface whichever happened.
export function AdjustStockDialog({
  product,
  onSaved,
  onCancel,
}: {
  product: ProductWithStock;
  onSaved: () => void;
  onCancel: () => void;
}) {
  const { supabase, operator } = useSession();
  const [mode, setMode] = useState<'add' | 'remove'>('add');
  const [qty, setQty] = useState('');
  const [reason, setReason] = useState('');
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);

  const businessId = operator?.businessId ?? null;
  const stores = operator?.stores ?? [];
  const [storeId, setStoreId] = useState<string | null>(stores[0]?.id ?? null);
  const amount = parseInt(qty, 10) || 0;
  const delta = mode === 'add' ? amount : -amount;

  async function onSubmit(e: React.FormEvent) {
    e.preventDefault();
    if (!businessId || !storeId) {
      setError('Your session is not linked to a business/store.');
      return;
    }
    if (amount <= 0) {
      setError('Enter a quantity of one or more.');
      return;
    }
    if (!reason.trim()) {
      setError('Enter a reason for the adjustment.');
      return;
    }
    setSubmitting(true);
    setError(null);
    try {
      const result = await requestStockAdjustment(supabase, {
        businessId,
        storeId,
        productId: product.id,
        quantityDiff: delta,
        reason: reason.trim(),
      });
      if (result.applied) {
        onSaved();
      } else {
        // Stock keeper path: a pending request was created — tell them, then close.
        setNotice('Sent for a manager to approve.');
        setSubmitting(false);
        setTimeout(onSaved, 900);
      }
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Could not submit the adjustment.');
      setSubmitting(false);
    }
  }

  return (
    <div className="modal-overlay" role="dialog" aria-modal="true" aria-label="Adjust stock">
      <div className="modal">
        <div className="modal__head">
          <h2 className="modal__title">Adjust stock</h2>
          <button className="modal__close" onClick={onCancel} aria-label="Close">
            ✕
          </button>
        </div>

        <form onSubmit={onSubmit}>
          <div className="modal__body">
            {error && <div className="banner banner--error">{error}</div>}
            {notice && <div className="banner banner--info">{notice}</div>}

            <div className="adjust__product">
              <span className="inventory__name">{product.name}</span>
              <span className="muted">In stock: {product.onHand}</span>
            </div>

            <div className="field">
              <span className="field__label">Change</span>
              <div className="segmented" role="group" aria-label="Adjustment direction">
                <button
                  type="button"
                  className={`segmented__opt${mode === 'add' ? ' segmented__opt--active' : ''}`}
                  onClick={() => setMode('add')}
                >
                  Add
                </button>
                <button
                  type="button"
                  className={`segmented__opt${mode === 'remove' ? ' segmented__opt--active' : ''}`}
                  onClick={() => setMode('remove')}
                >
                  Remove
                </button>
              </div>
            </div>

            <div className="form-row">
              <div className="field">
                <label className="field__label" htmlFor="adj-qty">
                  Quantity
                </label>
                <input
                  id="adj-qty"
                  className="input"
                  type="number"
                  min={1}
                  step={1}
                  inputMode="numeric"
                  value={qty}
                  onChange={(e) => setQty(e.target.value)}
                  autoFocus
                />
              </div>
              <div className="field">
                <span className="field__label">New count</span>
                <div className="adjust__preview">{product.onHand + delta}</div>
              </div>
            </div>

            {stores.length > 1 && (
              <div className="field">
                <label className="field__label" htmlFor="adj-store">
                  Store
                </label>
                <select
                  id="adj-store"
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
              </div>
            )}

            <div className="field">
              <label className="field__label" htmlFor="adj-reason">
                Reason
              </label>
              <input
                id="adj-reason"
                className="input"
                value={reason}
                onChange={(e) => setReason(e.target.value)}
                placeholder="Recount, breakage, correction…"
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
            <button type="submit" className="btn btn--primary" disabled={submitting || !!notice}>
              {submitting ? 'Submitting…' : 'Submit adjustment'}
            </button>
          </div>
        </form>
      </div>
    </div>
  );
}
