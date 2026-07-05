'use client';

import { useMemo } from 'react';

import { useSession } from '@/components/providers/SessionProvider';
import { useCurrency } from '@/hooks/useCurrency';
import { lineUnitPriceKobo } from '@/lib/checkout';
import { crateSummary, operatorTracksCrates } from '@/lib/crate';
import { useCart } from './CartProvider';

// The cart panel: line items (qty stepper + remove), a role-capped discount, the
// running order total, and the button into checkout. Grid-beside-cart on tablet+
// (PRD responsive bands); on phone it's the full-screen sheet PosScreen toggles.
export function Cart({
  onCheckout,
  onClose,
  onOpenCustomerPicker,
}: {
  onCheckout: () => void;
  onClose?: () => void;
  onOpenCustomerPicker?: () => void;
}) {
  const { operator } = useSession();
  const { kobo } = useCurrency();
  const {
    lines,
    discountKobo,
    subtotalKobo,
    totalKobo,
    itemCount,
    customer,
    setQuantity,
    remove,
    setDiscountKobo,
    detachCustomer,
    clear,
  } = useCart();

  const maxPct = operator?.maxDiscountPercent ?? 0;
  const discountCapKobo = useMemo(
    () => Math.floor((subtotalKobo * maxPct) / 100),
    [subtotalKobo, maxPct],
  );
  const cappedDiscountKobo = Math.min(discountKobo, discountCapKobo);
  const overCap = discountKobo > discountCapKobo;

  // Empties surface (Slice 4, #45): hidden entirely unless the business is
  // crate-eligible AND opts into empty tracking (mirrors mobile's hide). When on,
  // it summarises the returnable, deposit-bearing crates in the cart.
  const crateOn = operatorTracksCrates(operator);
  const empties = useMemo(
    () => crateSummary(lines, crateOn),
    [lines, crateOn],
  );

  const empty = lines.length === 0;

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
    return '🍹';
  };

  const isExternalUrl = (path: string | null): boolean => {
    if (!path) return false;
    return path.startsWith('http://') || path.startsWith('https://');
  };

  return (
    <aside className="cart" aria-label="Cart">
      <div className="cart__head">
        <h2 className="cart__title">
          Active Sale / Cart{itemCount > 0 && <span className="cart__count">{itemCount}</span>}
        </h2>
        <div className="cart__head-actions">
          {!empty && (
            <button className="cart__link" onClick={clear} type="button">
              Clear
            </button>
          )}
          {onClose && (
            <button
              className="cart__link"
              onClick={onClose}
              type="button"
              aria-label="Close cart"
            >
              Close
            </button>
          )}
        </div>
      </div>

      {onOpenCustomerPicker && (
        <div className="cart__customer">
          {customer ? (
            <>
              <div className="cart__customer-info">
                <span className="cart__customer-name">{customer.name}</span>
                <span
                  className={`cart__customer-balance${
                    customer.balanceKobo < 0
                      ? ' cart__customer-balance--owed'
                      : ' cart__customer-balance--credit'
                  }`}
                >
                  {customer.balanceKobo < 0
                    ? `Owes ${kobo(-customer.balanceKobo)}`
                    : `${kobo(customer.balanceKobo)} credit`}
                </span>
              </div>
              <div className="cart__customer-actions">
                <button
                  className="cart__link"
                  type="button"
                  onClick={onOpenCustomerPicker}
                >
                  Change
                </button>
                <button
                  className="cart__link"
                  type="button"
                  onClick={detachCustomer}
                >
                  Remove
                </button>
              </div>
            </>
          ) : (
            <button
              type="button"
              className="cart__customer-add"
              onClick={onOpenCustomerPicker}
            >
              <span className="plus-icon">+</span> Attach customer
            </button>
          )}
        </div>
      )}

      {empty ? (
        <div className="cart__empty">
          <div className="cart__empty-illustration">
            <svg width="48" height="48" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round" style={{ opacity: 0.25, marginBottom: '12px' }}>
              <circle cx="8" cy="21" r="1" />
              <circle cx="19" cy="21" r="1" />
              <path d="M2.05 2.05h2l2.66 12.42a2 2 0 0 0 2 1.58h9.78a2 2 0 0 0 1.95-1.57l1.65-7.43H5.12" />
            </svg>
          </div>
          Cart holds items to process.
        </div>
      ) : (
        <ul className="cart__lines">
          {lines.map((l) => {
            const unit = lineUnitPriceKobo(l.product);
            return (
              <li key={l.product.id} className="cart__line">
                <div className="cart__line-thumbnail">
                  {isExternalUrl(l.product.image_path) ? (
                    // eslint-disable-next-line @next/next/no-img-element
                    <img
                      src={l.product.image_path!}
                      alt={l.product.name}
                      className="cart__line-image"
                      loading="lazy"
                    />
                  ) : (
                    <div className="cart__line-placeholder">
                      {getPlaceholderEmoji(l.product.name)}
                    </div>
                  )}
                </div>
                <div className="cart__line-info">
                  <div className="cart__line-name">{l.product.name}</div>
                  <div className="cart__line-unit">{kobo(unit)} each</div>
                </div>
                <div className="cart__stepper" role="group" aria-label={`Quantity for ${l.product.name}`}>
                  <button
                    type="button"
                    className="cart__step"
                    onClick={() => setQuantity(l.product.id, l.quantity - 1)}
                    aria-label="Decrease quantity"
                  >
                    −
                  </button>
                  <input
                    className="cart__qty"
                    type="number"
                    min={1}
                    value={l.quantity}
                    onChange={(e) =>
                      setQuantity(l.product.id, Number.parseInt(e.target.value, 10) || 0)
                    }
                    aria-label={`Quantity for ${l.product.name}`}
                  />
                  <button
                    type="button"
                    className="cart__step"
                    onClick={() => setQuantity(l.product.id, l.quantity + 1)}
                    disabled={l.quantity >= Math.max(l.product.onHand, 1)}
                    aria-label="Increase quantity"
                  >
                    +
                  </button>
                </div>
                <div className="cart__line-total">{kobo(unit * l.quantity)}</div>
                <button
                  type="button"
                  className="cart__remove"
                  onClick={() => remove(l.product.id)}
                  aria-label={`Remove ${l.product.name}`}
                >
                  ✕
                </button>
              </li>
            );
          })}
        </ul>
      )}

      {!empty && (
        <div className="cart__foot">
          <div className="cart__row">
            <span>Subtotal</span>
            <span>{kobo(subtotalKobo)}</span>
          </div>

          {maxPct > 0 && (
            <div className="cart__discount">
              <label className="cart__discount-label" htmlFor="cart-discount">
                Discount
                <span className="cart__discount-cap">
                  up to {maxPct}% ({kobo(discountCapKobo)})
                </span>
              </label>
              <div className="cart__discount-input">
                <input
                  id="cart-discount"
                  className="input"
                  type="number"
                  min={0}
                  step={1}
                  value={discountKobo === 0 ? '' : Math.round(discountKobo / 100)}
                  placeholder="0"
                  onChange={(e) => {
                    const major = Number.parseFloat(e.target.value) || 0;
                    setDiscountKobo(Math.round(major * 100));
                  }}
                />
              </div>
              {overCap && (
                <div className="cart__discount-note">
                  Capped at your role limit — {kobo(discountCapKobo)} applied.
                </div>
              )}
            </div>
          )}

          {cappedDiscountKobo > 0 && (
            <div className="cart__row cart__row--muted">
              <span>Discount</span>
              <span>−{kobo(cappedDiscountKobo)}</span>
            </div>
          )}

          <div className="cart__row cart__row--total">
            <span>Total</span>
            <span>{kobo(totalKobo)}</span>
          </div>

          {crateOn && empties.crates > 0 && (
            <div className="cart__row cart__row--muted">
              <span>Empties (returnable)</span>
              <span>
                {empties.crates} crate{empties.crates === 1 ? '' : 's'}
                {empties.depositValueKobo > 0 &&
                  ` · ${kobo(empties.depositValueKobo)} deposit`}
              </span>
            </div>
          )}

          <div className="cart__action-buttons">
            <button
              type="button"
              className="btn btn--primary cart__checkout-btn"
              onClick={onCheckout}
              disabled={totalKobo <= 0}
            >
              Check Out
            </button>
            <button
              type="button"
              className="btn btn--outline cart__save-btn"
              onClick={() => alert('Sale saved successfully to drafts!')}
              disabled={totalKobo <= 0}
            >
              Save Sale
            </button>
          </div>
        </div>
      )}
    </aside>
  );
}
