'use client';

import {
  createContext,
  useCallback,
  useContext,
  useMemo,
  useState,
  type ReactNode,
} from 'react';

import type { CustomerWithBalance, ProductWithStock } from '@/lib/types';
import { lineUnitPriceKobo } from '@/lib/checkout';

// A Cart is a pre-checkout draft (CONTEXT.md "Cart"): mutable, no revenue, no
// status. It becomes an Order at Checkout. This provider holds it in React state
// above the POS screen so it persists across in-screen navigation within the
// session (user story #13) and is cleared by "Done — back to POS".

export interface CartLine {
  product: ProductWithStock;
  quantity: number;
}

interface CartContextValue {
  lines: CartLine[];
  discountKobo: number;
  itemCount: number;
  subtotalKobo: number;
  // Discount clamped to the role cap (see cappedDiscountKobo); totalKobo uses it.
  totalKobo: number;
  // The registered customer attached to the sale (Slice 3), or null for a
  // walk-in. Drives the credit/wallet checkout paths and the debt-limit guard.
  customer: CustomerWithBalance | null;
  add: (product: ProductWithStock) => void;
  setQuantity: (productId: string, quantity: number) => void;
  remove: (productId: string) => void;
  setDiscountKobo: (kobo: number) => void;
  attachCustomer: (customer: CustomerWithBalance) => void;
  detachCustomer: () => void;
  clear: () => void;
}

const CartContext = createContext<CartContextValue | null>(null);

export function CartProvider({ children }: { children: ReactNode }) {
  const [lines, setLines] = useState<CartLine[]>([]);
  const [discountKobo, setDiscountRaw] = useState(0);
  const [customer, setCustomer] = useState<CustomerWithBalance | null>(null);

  const add = useCallback((product: ProductWithStock) => {
    setLines((prev) => {
      const existing = prev.find((l) => l.product.id === product.id);
      if (existing) {
        // Don't exceed the live on-hand count.
        const next = Math.min(existing.quantity + 1, Math.max(product.onHand, 1));
        return prev.map((l) =>
          l.product.id === product.id ? { ...l, quantity: next } : l,
        );
      }
      return [...prev, { product, quantity: 1 }];
    });
  }, []);

  const setQuantity = useCallback((productId: string, quantity: number) => {
    setLines((prev) => {
      if (quantity <= 0) return prev.filter((l) => l.product.id !== productId);
      return prev.map((l) =>
        l.product.id === productId
          ? { ...l, quantity: Math.min(quantity, Math.max(l.product.onHand, 1)) }
          : l,
      );
    });
  }, []);

  const remove = useCallback((productId: string) => {
    setLines((prev) => prev.filter((l) => l.product.id !== productId));
  }, []);

  const setDiscountKobo = useCallback((kobo: number) => {
    setDiscountRaw(Math.max(0, Math.round(kobo)));
  }, []);

  const attachCustomer = useCallback((c: CustomerWithBalance) => {
    setCustomer(c);
  }, []);

  const detachCustomer = useCallback(() => {
    setCustomer(null);
  }, []);

  const clear = useCallback(() => {
    setLines([]);
    setDiscountRaw(0);
    setCustomer(null);
  }, []);

  const subtotalKobo = useMemo(
    () =>
      lines.reduce(
        (sum, l) => sum + lineUnitPriceKobo(l.product) * l.quantity,
        0,
      ),
    [lines],
  );

  const itemCount = useMemo(
    () => lines.reduce((n, l) => n + l.quantity, 0),
    [lines],
  );

  const cappedDiscount = Math.min(discountKobo, subtotalKobo);
  const value = useMemo<CartContextValue>(
    () => ({
      lines,
      discountKobo,
      itemCount,
      subtotalKobo,
      totalKobo: Math.max(0, subtotalKobo - cappedDiscount),
      customer,
      add,
      setQuantity,
      remove,
      setDiscountKobo,
      attachCustomer,
      detachCustomer,
      clear,
    }),
    [
      lines,
      discountKobo,
      itemCount,
      subtotalKobo,
      cappedDiscount,
      customer,
      add,
      setQuantity,
      remove,
      setDiscountKobo,
      attachCustomer,
      detachCustomer,
      clear,
    ],
  );

  return <CartContext.Provider value={value}>{children}</CartContext.Provider>;
}

export function useCart(): CartContextValue {
  const ctx = useContext(CartContext);
  if (!ctx) throw new Error('useCart must be used within a CartProvider');
  return ctx;
}
