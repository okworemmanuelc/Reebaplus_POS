// Empty-crate (returnable-case) helpers for the Web POS (Slice 4, #45). Mirrors
// the mobile crate model: crate features are visible only for crate-eligible
// businesses that opt into empty tracking, and a sale of deposit-bearing product
// carries returnable empties valued at a per-manufacturer deposit rate.
//
// The web posts the crate LEDGER server-side (checkout_order RPC, migration
// 0137) for a registered customer at a crate-eligible business; this module is
// the read/display side — the hide-don't-block surface and the empties summary
// the cart + receipt show.

import type { Operator } from './operator';
import type { ProductWithStock } from './types';

// Whether [type] is a business that uses empty-crate features — Bar or Beer/
// Beverage distributor only. Byte-for-byte the mobile isCrateBusiness(type)
// (lib/core/data/business_types.dart): case-insensitive + trimmed, so tenants
// onboarded by older builds with non-canonical casings still match.
export function isCrateBusiness(type: string | null | undefined): boolean {
  const t = type?.trim().toLowerCase();
  return t === 'bar' || t === 'beer distributor' || t === 'beverage distributor';
}

// Whether the business shows crate surfaces at all: crate-eligible type AND the
// empty-crate tracking opt-in. This is the single gate for the web crate UI —
// when false, no empties context is shown anywhere (mirrors the mobile hide).
export function businessTracksCrates(
  type: string | null | undefined,
  tracksEmptyCrates: boolean,
): boolean {
  return isCrateBusiness(type) && tracksEmptyCrates;
}

// Whether THIS operator's business shows crate surfaces — the crate gate read off
// the session operator, bundled so the checkout components (Cart, CheckoutDialog)
// don't each repeat the same `business?.type` / `?? false` unpacking.
export function operatorTracksCrates(operator: Operator | null): boolean {
  return businessTracksCrates(
    operator?.business?.type,
    operator?.business?.tracksEmptyCrates ?? false,
  );
}

// Whether a product carries a returnable crate deposit — a bottle with empties
// tracking on and a manufacturer (whose deposit rate applies). Same basis as the
// mobile sale-time crate dispatch (unit == 'bottle' && trackEmpties && a
// manufacturer).
export function crateEligible(product: ProductWithStock): boolean {
  return (
    product.unit?.toLowerCase() === 'bottle' &&
    product.track_empties === true &&
    product.manufacturer_id != null
  );
}

export interface CrateSummary {
  // Total deposit-bearing crates (empties) in the sale.
  crates: number;
  // Their total deposit value (sum of qty × the manufacturer's deposit rate).
  depositValueKobo: number;
}

// The empties summary for a set of cart/receipt lines, counting only
// crate-eligible bottles. Returns zero crates when the business doesn't track
// crates, so callers can gate the surface on `crates > 0`.
export function crateSummary(
  lines: { product: ProductWithStock; quantity: number }[],
  businessCrateEligible: boolean,
): CrateSummary {
  if (!businessCrateEligible) return { crates: 0, depositValueKobo: 0 };
  let crates = 0;
  let depositValueKobo = 0;
  for (const l of lines) {
    if (!crateEligible(l.product)) continue;
    crates += l.quantity;
    depositValueKobo += l.quantity * (l.product.depositRateKobo ?? 0);
  }
  return { crates, depositValueKobo };
}
