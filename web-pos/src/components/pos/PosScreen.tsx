'use client';

import { useCallback, useEffect, useMemo, useState } from 'react';

import { useSession } from '@/components/providers/SessionProvider';
import { useCan } from '@/components/permissions/Can';
import { PermissionKeys } from '@/lib/permissions';
import { loadCatalogue, type Catalogue } from '@/lib/catalogue';
import type { ProductWithStock } from '@/lib/types';
import { ProductCard } from './ProductCard';

const ALL = 'all';

// The POS product grid — Slice 1's one live, end-to-end screen. It reads the
// RLS-scoped catalogue (categories + per-tier prices + on-hand stock) over
// PostgREST and renders it in the responsive grid. Realtime auto-refresh is
// Slice 5; here a manual Refresh re-pulls. Tapping a product is gated on
// sales.make (the cart itself lands in Slice 2 / #43).
export function PosScreen() {
  const { supabase, operator } = useSession();
  const canSell = useCan(PermissionKeys.salesMake);

  const [catalogue, setCatalogue] = useState<Catalogue | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [category, setCategory] = useState<string>(ALL);
  const [selected, setSelected] = useState<ProductWithStock | null>(null);

  const businessId = operator?.businessId ?? null;

  const refresh = useCallback(async () => {
    setError(null);
    try {
      const next = await loadCatalogue(supabase);
      setCatalogue(next);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to load products.');
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
    if (category === ALL) return catalogue.products;
    return catalogue.products.filter((p) => p.category_id === category);
  }, [catalogue, category]);

  const onSelect = useCallback((p: ProductWithStock) => {
    // Cart wiring is Slice 2 (#43). For the skeleton, acknowledge the tap.
    setSelected(p);
  }, []);

  return (
    <div className="pos">
      <div className="pos__header">
        <h1 className="pos__title">Point of Sale</h1>
        <button
          className="btn btn--outline"
          onClick={() => void refresh()}
          disabled={loading}
        >
          {loading ? 'Loading…' : 'Refresh'}
        </button>
      </div>

      {selected && (
        <div className="banner banner--info" role="status">
          Selected <strong>{selected.name}</strong> — the cart & checkout arrive
          in the next slice.
        </div>
      )}

      {error && <div className="banner banner--error">{error}</div>}

      {catalogue && catalogue.categories.length > 0 && (
        <div className="category-bar" role="tablist" aria-label="Categories">
          <CategoryChip
            label="All"
            active={category === ALL}
            onClick={() => setCategory(ALL)}
          />
          {catalogue.categories.map((c) => (
            <CategoryChip
              key={c.id}
              label={c.name}
              active={category === c.id}
              onClick={() => setCategory(c.id)}
            />
          ))}
        </div>
      )}

      {loading && !catalogue ? (
        <div className="empty-state">
          <div className="spinner" style={{ margin: '0 auto 12px' }} />
          Loading your catalogue…
        </div>
      ) : filtered.length === 0 ? (
        <div className="empty-state">
          {catalogue && catalogue.products.length === 0
            ? 'No products yet. Add products on the mobile app or (soon) here on web.'
            : 'No products in this category.'}
        </div>
      ) : (
        <div className="product-grid">
          {filtered.map((p) => (
            <ProductCard
              key={p.id}
              product={p}
              canSell={canSell}
              onSelect={onSelect}
            />
          ))}
        </div>
      )}
    </div>
  );
}

function CategoryChip({
  label,
  active,
  onClick,
}: {
  label: string;
  active: boolean;
  onClick: () => void;
}) {
  return (
    <button
      type="button"
      role="tab"
      aria-selected={active}
      className={`chip${active ? ' chip--active' : ''}`}
      onClick={onClick}
    >
      {label}
    </button>
  );
}
