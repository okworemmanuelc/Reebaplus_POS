'use client';

import type { ProductWithStock } from '@/lib/types';
import { useCurrency } from '@/hooks/useCurrency';

// One product tile in the POS grid: name, size/unit, the two price tiers
// (Retailer primary, Wholesaler secondary), and a live stock indicator. Out of
// stock (live count) renders unavailable and non-interactive (user story #8).
export function ProductCard({
  product,
  canSell,
  onSelect,
}: {
  product: ProductWithStock;
  canSell: boolean;
  onSelect: (product: ProductWithStock) => void;
}) {
  const { kobo } = useCurrency();

  const outOfStock = product.onHand <= 0;
  const low =
    !outOfStock &&
    product.low_stock_threshold != null &&
    product.onHand <= product.low_stock_threshold;

  const stockClass = outOfStock
    ? 'stock-dot stock-dot--out'
    : low
      ? 'stock-dot stock-dot--low'
      : 'stock-dot';

  const meta = [product.size, product.unit].filter(Boolean).join(' · ');

  return (
    <button
      type="button"
      className="product-card"
      disabled={outOfStock || !canSell}
      onClick={() => onSelect(product)}
      title={
        !canSell
          ? 'You do not have permission to sell'
          : outOfStock
            ? 'Out of stock'
            : `Add ${product.name}`
      }
    >
      <div>
        <div className="product-card__name">{product.name}</div>
        {meta && <div className="product-card__meta">{meta}</div>}
      </div>

      <div className="product-card__prices">
        <div className="product-card__price">
          {kobo(product.retailer_price_kobo)}
        </div>
        {product.wholesaler_price_kobo != null &&
          product.wholesaler_price_kobo !== product.retailer_price_kobo && (
            <div className="product-card__wholesale">
              Wholesale {kobo(product.wholesaler_price_kobo)}
            </div>
          )}
      </div>

      <div
        className={`product-card__stock${
          outOfStock ? ' product-card__badge-out' : ''
        }`}
      >
        <span className={stockClass} aria-hidden />
        {outOfStock ? 'Out of stock' : `${product.onHand} in stock`}
      </div>
    </button>
  );
}
