'use client';

import type { ProductWithStock } from '@/lib/types';
import { useCurrency } from '@/hooks/useCurrency';

// One product tile in the POS grid: image space, name, size/unit, the two price tiers
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

  // Get a beautiful themed beverage emoji based on product keywords
  const getPlaceholderEmoji = (name: string): string => {
    const lower = name.toLowerCase();
    if (
      lower.includes('beer') ||
      lower.includes('heineken') ||
      lower.includes('guinness') ||
      lower.includes('stout') ||
      lower.includes('lager') ||
      lower.includes('brew')
    ) {
      return '🍺';
    }
    if (
      lower.includes('soda') ||
      lower.includes('cola') ||
      lower.includes('coke') ||
      lower.includes('fanta') ||
      lower.includes('sprite') ||
      lower.includes('pepsi') ||
      lower.includes('soft drink')
    ) {
      return '🥤';
    }
    if (
      lower.includes('wine') ||
      lower.includes('champagne') ||
      lower.includes('rose') ||
      lower.includes('red') ||
      lower.includes('white wine')
    ) {
      return '🍷';
    }
    if (
      lower.includes('water') ||
      lower.includes('h2o') ||
      lower.includes('eva') ||
      lower.includes('mineral')
    ) {
      return '💧';
    }
    if (
      lower.includes('juice') ||
      lower.includes('orange') ||
      lower.includes('fruit') ||
      lower.includes('pineapple') ||
      lower.includes('cocktail')
    ) {
      return '🍹';
    }
    if (
      lower.includes('milk') ||
      lower.includes('shake') ||
      lower.includes('yoghurt') ||
      lower.includes('dairy')
    ) {
      return '🥛';
    }
    if (
      lower.includes('spirit') ||
      lower.includes('vodka') ||
      lower.includes('gin') ||
      lower.includes('whiskey') ||
      lower.includes('tequila') ||
      lower.includes('alcohol') ||
      lower.includes('liquor') ||
      lower.includes('liqueur') ||
      lower.includes('rum')
    ) {
      return '🍾';
    }
    return '🍹'; // default beverage fallback
  };

  const isExternalUrl = (path: string | null): boolean => {
    if (!path) return false;
    return path.startsWith('http://') || path.startsWith('https://');
  };

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
      {/* Product Image Space */}
      <div className="product-card__image-container">
        {isExternalUrl(product.image_path) ? (
          // eslint-disable-next-line @next/next/no-img-element
          <img
            src={product.image_path!}
            className="product-card__image"
            alt={product.name}
            loading="lazy"
          />
        ) : (
          <div className="product-card__placeholder">
            <span className="product-card__placeholder-icon">
              {getPlaceholderEmoji(product.name)}
            </span>
          </div>
        )}
      </div>

      <div className="product-card__content">
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
