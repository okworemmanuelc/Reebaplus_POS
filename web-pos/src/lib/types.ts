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
}

export interface InventoryRow {
  id: string;
  business_id: string;
  product_id: string;
  store_id: string;
  quantity: number;
}

// A product joined with its on-hand quantity (summed across stores, or scoped
// to the active store) — the shape the POS grid renders.
export interface ProductWithStock extends ProductRow {
  onHand: number;
}
