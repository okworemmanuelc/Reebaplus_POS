'use client';

import { useCallback, useEffect, useMemo, useState } from 'react';

import { useSession } from '@/components/providers/SessionProvider';
import { useCan } from '@/components/permissions/Can';
import { useCurrency } from '@/hooks/useCurrency';
import { PermissionKeys } from '@/lib/permissions';
import { loadCatalogue, type Catalogue } from '@/lib/catalogue';
import {
  loadInventoryRefs,
  type InventoryRefs,
} from '@/lib/inventory';
import type { ProductWithStock } from '@/lib/types';
import { ProductFormDialog } from './ProductFormDialog';
import { ReceiveStockDialog } from './ReceiveStockDialog';
import { AdjustStockDialog } from './AdjustStockDialog';
import { ApprovalsPanel } from './ApprovalsPanel';

// Web POS Slice 6 (#48) — Inventory management. A live product list with the two
// catalogue money-writes: Add/Edit product (products.add) and Receive Stock
// (stock.received / stock.add). Hide-don't-block: the action buttons appear only
// when the Operator's role allows them; the RPCs re-check server-side. Reads are
// RLS-scoped PostgREST (Realtime auto-refresh is Slice 5, #49).
export function InventoryScreen() {
  const { supabase, operator } = useSession();
  const { kobo } = useCurrency();
  const canAdd = useCan(PermissionKeys.productsAdd);
  const canAdjust = useCan(PermissionKeys.stockAdjust);
  const canReceive =
    useCan(PermissionKeys.stockReceived) ||
    useCan(PermissionKeys.stockAdd) ||
    canAdd;
  // Approvers (CEO / Manager) see the pending-request queue — mirrors the
  // server rule in approve_stock_adjustment (0141).
  const canApprove =
    operator?.role?.slug === 'ceo' || operator?.role?.slug === 'manager';

  const [catalogue, setCatalogue] = useState<Catalogue | null>(null);
  const [refs, setRefs] = useState<InventoryRefs | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [query, setQuery] = useState('');

  // Dialog state: add a product, edit a specific product, receive a delivery,
  // or adjust one product's stock.
  const [formOpen, setFormOpen] = useState(false);
  const [editing, setEditing] = useState<ProductWithStock | null>(null);
  const [receiveOpen, setReceiveOpen] = useState(false);
  const [adjusting, setAdjusting] = useState<ProductWithStock | null>(null);

  const businessId = operator?.businessId ?? null;

  const refresh = useCallback(async () => {
    setError(null);
    try {
      const [cat, ref] = await Promise.all([
        loadCatalogue(supabase),
        loadInventoryRefs(supabase),
      ]);
      setCatalogue(cat);
      setRefs(ref);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to load inventory.');
    } finally {
      setLoading(false);
    }
  }, [supabase]);

  useEffect(() => {
    setLoading(true);
    void refresh();
  }, [refresh, businessId]);

  const filtered = useMemo(() => {
    if (!catalogue) return [];
    const q = query.toLowerCase().trim();
    if (!q) return catalogue.products;
    return catalogue.products.filter((p) => p.name.toLowerCase().includes(q));
  }, [catalogue, query]);

  const openAdd = useCallback(() => {
    setEditing(null);
    setFormOpen(true);
  }, []);

  const openEdit = useCallback((p: ProductWithStock) => {
    setEditing(p);
    setFormOpen(true);
  }, []);

  const onSaved = useCallback(() => {
    setFormOpen(false);
    setReceiveOpen(false);
    setEditing(null);
    setAdjusting(null);
    void refresh();
  }, [refresh]);

  const nameById = useMemo(
    () => new Map((catalogue?.products ?? []).map((p) => [p.id, p.name])),
    [catalogue],
  );

  const categoryName = useCallback(
    (id: string | null) =>
      id ? (catalogue?.categories.find((c) => c.id === id)?.name ?? '—') : '—',
    [catalogue],
  );

  return (
    <div className="inventory">
      <div className="inventory__header">
        <div>
          <h1 className="pos__title">Inventory</h1>
          <p className="muted inventory__subtitle">
            {catalogue ? `${catalogue.products.length} product(s)` : ' '}
          </p>
        </div>
        <div className="inventory__actions">
          <button
            className="btn btn--outline"
            onClick={() => void refresh()}
            disabled={loading}
          >
            Refresh
          </button>
          {canReceive && (
            <button
              className="btn btn--outline"
              onClick={() => setReceiveOpen(true)}
              disabled={!catalogue || catalogue.products.length === 0}
            >
              Receive stock
            </button>
          )}
          {canAdd && (
            <button className="btn btn--primary" onClick={openAdd}>
              + Add product
            </button>
          )}
        </div>
      </div>

      {error && <div className="banner banner--error">{error}</div>}

      {canApprove && (
        <ApprovalsPanel nameById={nameById} onChanged={() => void refresh()} />
      )}

      <div className="inventory__toolbar">
        <input
          className="input"
          type="search"
          placeholder="Search products…"
          value={query}
          onChange={(e) => setQuery(e.target.value)}
        />
      </div>

      {loading && !catalogue ? (
        <div className="empty-state">
          <div className="spinner" style={{ margin: '0 auto 12px' }} />
          Loading inventory…
        </div>
      ) : filtered.length === 0 ? (
        <div className="empty-state">
          {catalogue && catalogue.products.length === 0
            ? canAdd
              ? 'No products yet. Add your first product to get started.'
              : 'No products yet.'
            : 'No products match your search.'}
        </div>
      ) : (
        <div className="inventory__table-wrap">
          <table className="inventory__table">
            <thead>
              <tr>
                <th>Product</th>
                <th>Category</th>
                <th className="num">In stock</th>
                <th className="num">Retail</th>
                <th className="num">Wholesale</th>
                <th className="num">Cost</th>
                {(canAdd || canAdjust) && <th aria-label="Actions" />}
              </tr>
            </thead>
            <tbody>
              {filtered.map((p) => {
                const low =
                  p.low_stock_threshold != null &&
                  p.onHand <= p.low_stock_threshold;
                return (
                  <tr key={p.id}>
                    <td>
                      <div className="inventory__name">{p.name}</div>
                      <div className="inventory__meta">
                        {p.unit ?? 'Piece'}
                        {p.size ? ` · ${p.size}` : ''}
                      </div>
                    </td>
                    <td>{categoryName(p.category_id)}</td>
                    <td className="num">
                      <span
                        className={`inventory__stock${low ? ' inventory__stock--low' : ''}`}
                      >
                        {p.onHand}
                      </span>
                    </td>
                    <td className="num">{kobo(p.retailer_price_kobo)}</td>
                    <td className="num">{kobo(p.wholesaler_price_kobo)}</td>
                    <td className="num">{kobo(p.buying_price_kobo)}</td>
                    {(canAdd || canAdjust) && (
                      <td className="num">
                        <div className="inventory__row-actions">
                          {canAdjust && (
                            <button
                              className="btn btn--outline btn--sm"
                              onClick={() => setAdjusting(p)}
                            >
                              Adjust
                            </button>
                          )}
                          {canAdd && (
                            <button
                              className="btn btn--outline btn--sm"
                              onClick={() => openEdit(p)}
                            >
                              Edit
                            </button>
                          )}
                        </div>
                      </td>
                    )}
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      )}

      {formOpen && refs && (
        <ProductFormDialog
          product={editing}
          categories={refs.categories}
          onSaved={onSaved}
          onCancel={() => {
            setFormOpen(false);
            setEditing(null);
          }}
        />
      )}

      {receiveOpen && refs && catalogue && (
        <ReceiveStockDialog
          products={catalogue.products}
          suppliers={refs.suppliers}
          onSaved={onSaved}
          onCancel={() => setReceiveOpen(false)}
        />
      )}

      {adjusting && (
        <AdjustStockDialog
          product={adjusting}
          onSaved={onSaved}
          onCancel={() => setAdjusting(null)}
        />
      )}
    </div>
  );
}
