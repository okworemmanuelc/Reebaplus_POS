// Row shapes for the cloud tables the Web POS reads directly over RLS-scoped
// PostgREST. Only the columns Slice 1 (walking skeleton) uses are typed; later
// slices widen these. Amounts are `*_kobo` bigints, returned by PostgREST as
// JS numbers (safe below 2^53 — Naira kobo amounts stay well under that).
//
// Mirrors the cloud schema (snake_case) verified against the live project, not
// the Flutter Drift models.

export interface ProfileRow {
  id: string; // = auth.uid()
  business_id: string | null;
  name: string | null;
}

export interface UserRow {
  id: string;
  business_id: string | null;
  auth_user_id: string | null;
  name: string | null;
  email: string | null;
}

export interface UserBusinessRow {
  id: string;
  business_id: string;
  user_id: string;
  role_id: string | null;
  status: string | null; // 'active' | 'suspended'
}

export interface RoleRow {
  id: string;
  business_id: string;
  name: string | null;
  slug: string | null; // 'ceo' | 'manager' | 'cashier' | 'stock_keeper'
  is_deleted: boolean | null;
}

export interface RolePermissionRow {
  id: string;
  business_id: string;
  role_id: string;
  permission_key: string;
}

export interface UserPermissionOverrideRow {
  id: string;
  business_id: string;
  user_id: string;
  permission_key: string;
  is_granted: boolean;
}

export interface BusinessRow {
  id: string;
  name: string | null;
  type: string | null;
  tracks_empty_crates: boolean | null;
}

export interface SettingRow {
  business_id: string;
  key: string;
  value: string | null;
}

export interface StoreRow {
  id: string;
  business_id: string;
  name: string | null;
  is_deleted: boolean | null;
}

export interface CategoryRow {
  id: string;
  business_id: string;
  name: string | null;
  is_deleted: boolean | null;
}

export interface ProductRow {
  id: string;
  business_id: string;
  category_id: string | null;
  name: string;
  unit: string | null;
  size: string | null;
  retailer_price_kobo: number | null;
  wholesaler_price_kobo: number | null;
  buying_price_kobo: number | null;
  is_available: boolean | null;
  is_deleted: boolean | null;
  low_stock_threshold: number | null;
  image_path: string | null;
  // Empty-crate tracking (Slice 4, #45). A product is crate-eligible when it's a
  // returnable bottle (unit 'bottle') with track_empties on AND a manufacturer
  // (whose per-crate deposit rate applies) — see crateEligible() in crate.ts.
  track_empties: boolean | null;
  manufacturer_id: string | null;
}

// A manufacturer with its per-crate deposit rate (deposit_amount_kobo). The
// deposit value of empties is per-manufacturer, shared across its products.
export interface ManufacturerRow {
  id: string;
  business_id: string;
  deposit_amount_kobo: number | null;
}

export interface InventoryRow {
  id: string;
  business_id: string;
  product_id: string;
  store_id: string;
  quantity: number;
}

// A product joined with its on-hand quantity (summed across stores, or scoped
// to the active store) — the shape the POS grid renders. [depositRateKobo] is
// the product's manufacturer's per-crate deposit (0 when not crate-eligible).
export interface ProductWithStock extends ProductRow {
  onHand: number;
  depositRateKobo: number;
}

// A registered customer (Slice 3, #44). `wallet_limit_kobo` is the debt limit —
// 0 means no credit is allowed at all (mirrors the mobile rule).
export interface CustomerRow {
  id: string;
  business_id: string;
  name: string;
  phone: string | null;
  wallet_limit_kobo: number | null;
  is_deleted: boolean | null;
}

// One append-only wallet ledger row. The customer's spendable balance is
// SUM(signed_amount_kobo) over rows whose reference_type is NOT a crate deposit.
export interface WalletTransactionRow {
  customer_id: string;
  signed_amount_kobo: number;
  reference_type: string;
}

// A customer joined with their derived spendable wallet balance (kobo). Positive
// = credit we hold; negative = they owe us.
export interface CustomerWithBalance {
  id: string;
  name: string;
  phone: string | null;
  balanceKobo: number;
  debtLimitKobo: number;
}
