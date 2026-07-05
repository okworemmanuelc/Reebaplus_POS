'use client';

import { useCallback, useEffect, useMemo, useState } from 'react';

import { useSession } from '@/components/providers/SessionProvider';
import { useCan } from '@/components/permissions/Can';
import { useCurrency } from '@/hooks/useCurrency';
import { useCustomers } from '@/hooks/useCustomers';
import { PermissionKeys } from '@/lib/permissions';
import { loadCatalogue, type Catalogue } from '@/lib/catalogue';
import type { CheckoutResult } from '@/lib/checkout';
import type { CustomerWithBalance, ProductWithStock } from '@/lib/types';
import { ProductCard } from './ProductCard';
import { CartProvider, useCart } from './CartProvider';
import { Cart } from './Cart';
import { CheckoutDialog } from './CheckoutDialog';
import { CustomerPicker } from './CustomerPicker';
import { Receipt } from './Receipt';

type Phase = 'shop' | 'checkout' | 'receipt';

const ALL = 'all';

// Slice 2 turns the walking-skeleton grid into the full selling loop: grid → cart
// → checkout (cash/transfer) → receipt → "Done, back to POS". The cart lives in a
// CartProvider above the screen so it survives in-screen navigation within the
// session. Realtime auto-refresh is Slice 5; here a manual Refresh (and an
// automatic one after each sale) re-pulls live stock.
export function PosScreen() {
  const { supabase, operator } = useSession();
  const canSell = useCan(PermissionKeys.salesMake);
  const { kobo } = useCurrency();
  const cart = useCart();
  const customers = useCustomers();

  const [catalogue, setCatalogue] = useState<Catalogue | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [category, setCategory] = useState<string>(ALL);
  const [phase, setPhase] = useState<Phase>('shop');
  const [cartOpen, setCartOpen] = useState(false);
  const [pickerOpen, setPickerOpen] = useState(false);
  const [result, setResult] = useState<CheckoutResult | null>(null);

  const businessId = operator?.businessId ?? null;

  const refresh = useCallback(async () => {
    setError(null);
    try {
      setCatalogue(await loadCatalogue(supabase));
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
    let items = catalogue.products;
    if (category !== ALL) {
      items = items.filter((p) => p.category_id === category);
    }
    if (cart.searchQuery.trim()) {
      const q = cart.searchQuery.toLowerCase().trim();
      items = items.filter((p) => p.name.toLowerCase().includes(q));
    }
    return items;
  }, [catalogue, category, cart.searchQuery]);

  const onSelect = useCallback(
    (p: ProductWithStock) => cart.add(p),
    [cart],
  );

  const startCheckout = useCallback(() => {
    setCartOpen(false);
    setPhase('checkout');
  }, []);

  const onCheckoutComplete = useCallback((r: CheckoutResult) => {
    setResult(r);
    setPhase('receipt');
  }, []);

  const onDone = useCallback(() => {
    cart.clear();
    setResult(null);
    setPhase('shop');
    setCartOpen(false);
    // Stock + a customer's wallet balance changed — re-pull both so the grid
    // and the next customer attach reflect the sale.
    void refresh();
    void customers.refresh();
  }, [cart, refresh, customers]);

  const onPickCustomer = useCallback(
    (c: CustomerWithBalance) => {
      cart.attachCustomer(c);
      setPickerOpen(false);
    },
    [cart],
  );

  return (
    <div className="pos-layout">
      <div className="pos">
        <div className="pos__header">
          <h1 className="pos__title">Point of Sale</h1>
          <button
            className="btn btn--outline btn--refresh"
            onClick={() => void refresh()}
            disabled={loading}
          >
            <svg
              width="14"
              height="14"
              viewBox="0 0 24 24"
              fill="none"
              stroke="currentColor"
              strokeWidth="2.5"
              strokeLinecap="round"
              strokeLinejoin="round"
              className={loading ? 'spin' : ''}
              style={{ marginRight: '6px' }}
            >
              <path d="M21 12a9 9 0 0 0-9-9 9.75 9.75 0 0 0-6.74 2.74L3 8" />
              <path d="M3 3v5h5" />
              <path d="M3 12a9 9 0 0 0 9 9 9.75 9.75 0 0 0 6.74-2.74L21 16" />
              <path d="M16 16h5v5" />
            </svg>
            Refresh
          </button>
        </div>

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

      {/* Desktop/tablet: cart beside the grid. Hidden on phone (CSS). */}
      {canSell && (
        <div className="pos-layout__cart">
          <Cart
            onCheckout={startCheckout}
            onOpenCustomerPicker={() => setPickerOpen(true)}
          />
        </div>
      )}

      {/* Phone: a sticky bar summarising the cart; taps open the cart sheet. */}
      {canSell && cart.itemCount > 0 && (
        <button
          type="button"
          className="cart-bar"
          onClick={() => setCartOpen(true)}
        >
          <span className="cart-bar__count">{cart.itemCount}</span>
          <span>View cart</span>
          <span className="cart-bar__total">{kobo(cart.totalKobo)}</span>
        </button>
      )}

      {canSell && cartOpen && (
        <div className="cart-sheet-overlay" onClick={() => setCartOpen(false)}>
          <div className="cart-sheet" onClick={(e) => e.stopPropagation()}>
            <Cart
              onCheckout={startCheckout}
              onClose={() => setCartOpen(false)}
              onOpenCustomerPicker={() => setPickerOpen(true)}
            />
          </div>
        </div>
      )}

      {canSell && pickerOpen && (
        <CustomerPicker
          customers={customers.customers}
          loading={customers.loading}
          error={customers.error}
          onPick={onPickCustomer}
          onClose={() => setPickerOpen(false)}
        />
      )}

      {phase === 'checkout' && (
        <CheckoutDialog
          onCancel={() => setPhase('shop')}
          onComplete={onCheckoutComplete}
        />
      )}

      {phase === 'receipt' && result && (
        <Receipt result={result} onDone={onDone} />
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
