'use client';

import { useState } from 'react';

import { useSession } from '@/components/providers/SessionProvider';
import { useCurrency } from '@/hooks/useCurrency';
import {
  addProduct,
  updateProduct,
  PRODUCT_UNITS,
  type ProductUnit,
} from '@/lib/inventory';
import type { CategoryRow, ProductWithStock } from '@/lib/types';

// Naira (major-unit) input → kobo (bigint). Empty / invalid ⇒ 0.
function toKobo(naira: string): number {
  const n = parseFloat(naira);
  return Number.isFinite(n) && n > 0 ? Math.round(n * 100) : 0;
}
function fromKobo(kobo: number | null | undefined): string {
  return kobo && kobo > 0 ? (kobo / 100).toString() : '';
}

const SIZES = ['', 'big', 'medium', 'small'] as const;

// Add or edit a product. Add creates the product + opening stock + opening Cost
// Batch via add_product; Edit changes details/prices via update_product (stock
// and Cost Batches are untouched — use Receive Stock to add units). Both RPCs
// re-check products.add server-side.
export function ProductFormDialog({
  product,
  categories,
  onSaved,
  onCancel,
}: {
  product: ProductWithStock | null;
  categories: CategoryRow[];
  onSaved: () => void;
  onCancel: () => void;
}) {
  const { supabase, operator } = useSession();
  const { code } = useCurrency();
  const isEdit = product != null;

  const [name, setName] = useState(product?.name ?? '');
  const [unit, setUnit] = useState<ProductUnit>(
    (product?.unit as ProductUnit) ?? 'Piece',
  );
  const [size, setSize] = useState(product?.size ?? '');
  const [categoryId, setCategoryId] = useState(product?.category_id ?? '');
  const [retail, setRetail] = useState(fromKobo(product?.retailer_price_kobo));
  const [wholesale, setWholesale] = useState(
    fromKobo(product?.wholesaler_price_kobo),
  );
  const [buying, setBuying] = useState(fromKobo(product?.buying_price_kobo));
  const [openingStock, setOpeningStock] = useState('');
  const [lowStock, setLowStock] = useState(
    (product?.low_stock_threshold ?? 5).toString(),
  );
  const [trackEmpties, setTrackEmpties] = useState(
    product?.track_empties ?? false,
  );

  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const businessId = operator?.businessId ?? null;
  const stores = operator?.stores ?? [];
  const [storeId, setStoreId] = useState<string | null>(stores[0]?.id ?? null);

  async function onSubmit(e: React.FormEvent) {
    e.preventDefault();
    if (!businessId) {
      setError('Your session is not linked to a business.');
      return;
    }
    if (!name.trim()) {
      setError('Enter a product name.');
      return;
    }
    setSubmitting(true);
    setError(null);
    try {
      if (isEdit && product) {
        await updateProduct(supabase, {
          businessId,
          productId: product.id,
          name: name.trim(),
          categoryId: categoryId || null,
          unit,
          size: size || null,
          retailerPriceKobo: toKobo(retail),
          wholesalerPriceKobo: toKobo(wholesale),
          buyingPriceKobo: toKobo(buying),
          trackEmpties,
          lowStockThreshold: parseInt(lowStock, 10) || 5,
        });
      } else {
        if (!storeId) {
          setError('This account has no store set up yet.');
          setSubmitting(false);
          return;
        }
        await addProduct(supabase, {
          businessId,
          storeId,
          name: name.trim(),
          categoryId: categoryId || null,
          unit,
          size: size || null,
          retailerPriceKobo: toKobo(retail),
          wholesalerPriceKobo: toKobo(wholesale),
          buyingPriceKobo: toKobo(buying),
          openingStock: parseInt(openingStock, 10) || 0,
          trackEmpties,
          lowStockThreshold: parseInt(lowStock, 10) || 5,
        });
      }
      onSaved();
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Could not save the product.');
      setSubmitting(false);
    }
  }

  return (
    <div
      className="modal-overlay"
      role="dialog"
      aria-modal="true"
      aria-label={isEdit ? 'Edit product' : 'Add product'}
    >
      <div className="modal">
        <div className="modal__head">
          <h2 className="modal__title">{isEdit ? 'Edit product' : 'Add product'}</h2>
          <button className="modal__close" onClick={onCancel} aria-label="Close">
            ✕
          </button>
        </div>

        <form onSubmit={onSubmit}>
          <div className="modal__body">
            {error && <div className="banner banner--error">{error}</div>}

            <div className="field">
              <label className="field__label" htmlFor="p-name">
                Name
              </label>
              <input
                id="p-name"
                className="input"
                value={name}
                onChange={(e) => setName(e.target.value)}
                autoFocus
                required
              />
            </div>

            <div className="form-row">
              <div className="field">
                <label className="field__label" htmlFor="p-unit">
                  Unit
                </label>
                <select
                  id="p-unit"
                  className="input"
                  value={unit}
                  onChange={(e) => setUnit(e.target.value as ProductUnit)}
                >
                  {PRODUCT_UNITS.map((u) => (
                    <option key={u} value={u}>
                      {u}
                    </option>
                  ))}
                </select>
              </div>
              <div className="field">
                <label className="field__label" htmlFor="p-size">
                  Size
                </label>
                <select
                  id="p-size"
                  className="input"
                  value={size}
                  onChange={(e) => setSize(e.target.value)}
                >
                  {SIZES.map((s) => (
                    <option key={s} value={s}>
                      {s === '' ? '—' : s}
                    </option>
                  ))}
                </select>
              </div>
            </div>

            <div className="field">
              <label className="field__label" htmlFor="p-category">
                Category
              </label>
              <select
                id="p-category"
                className="input"
                value={categoryId}
                onChange={(e) => setCategoryId(e.target.value)}
              >
                <option value="">Uncategorised</option>
                {categories.map((c) => (
                  <option key={c.id} value={c.id}>
                    {c.name ?? 'Unnamed'}
                  </option>
                ))}
              </select>
            </div>

            <div className="form-row">
              <div className="field">
                <label className="field__label" htmlFor="p-retail">
                  Retail price ({code})
                </label>
                <input
                  id="p-retail"
                  className="input"
                  type="number"
                  min={0}
                  step="0.01"
                  inputMode="decimal"
                  value={retail}
                  onChange={(e) => setRetail(e.target.value)}
                />
              </div>
              <div className="field">
                <label className="field__label" htmlFor="p-wholesale">
                  Wholesale price ({code})
                </label>
                <input
                  id="p-wholesale"
                  className="input"
                  type="number"
                  min={0}
                  step="0.01"
                  inputMode="decimal"
                  value={wholesale}
                  onChange={(e) => setWholesale(e.target.value)}
                />
              </div>
            </div>

            <div className="form-row">
              <div className="field">
                <label className="field__label" htmlFor="p-buying">
                  Cost price ({code})
                </label>
                <input
                  id="p-buying"
                  className="input"
                  type="number"
                  min={0}
                  step="0.01"
                  inputMode="decimal"
                  value={buying}
                  onChange={(e) => setBuying(e.target.value)}
                />
                <span className="field__hint">
                  {isEdit
                    ? 'Applies to future stock; past batches keep their cost.'
                    : 'The opening stock is valued at this cost.'}
                </span>
              </div>
              {!isEdit && (
                <div className="field">
                  <label className="field__label" htmlFor="p-opening">
                    Opening stock
                  </label>
                  <input
                    id="p-opening"
                    className="input"
                    type="number"
                    min={0}
                    step="1"
                    inputMode="numeric"
                    value={openingStock}
                    onChange={(e) => setOpeningStock(e.target.value)}
                    placeholder="0"
                  />
                </div>
              )}
            </div>

            {!isEdit && stores.length > 1 && (
              <div className="field">
                <label className="field__label" htmlFor="p-store">
                  Store
                </label>
                <select
                  id="p-store"
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
                <span className="field__hint">
                  Opening stock lands in this store.
                </span>
              </div>
            )}

            <div className="form-row">
              <div className="field">
                <label className="field__label" htmlFor="p-lowstock">
                  Low-stock alert at
                </label>
                <input
                  id="p-lowstock"
                  className="input"
                  type="number"
                  min={0}
                  step="1"
                  inputMode="numeric"
                  value={lowStock}
                  onChange={(e) => setLowStock(e.target.value)}
                />
              </div>
              <div className="field field--check">
                <label className="check">
                  <input
                    type="checkbox"
                    checked={trackEmpties}
                    onChange={(e) => setTrackEmpties(e.target.checked)}
                  />
                  <span>Track empty crates</span>
                </label>
                <span className="field__hint">
                  For returnable bottles that carry a deposit.
                </span>
              </div>
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
            <button type="submit" className="btn btn--primary" disabled={submitting}>
              {submitting ? 'Saving…' : isEdit ? 'Save changes' : 'Add product'}
            </button>
          </div>
        </form>
      </div>
    </div>
  );
}
