// Live catalogue read for the POS grid (AC: "live product grid shows categories,
// per-tier prices, and reflects the current stock"). All three reads are
// RLS-scoped to the Operator's business; Slice 1 fetches over PostgREST on load
// and on manual refresh — Realtime hardening is Slice 5 (#49), by decision.

import type { SupabaseClient } from '@supabase/supabase-js';

import type {
  CategoryRow,
  InventoryRow,
  ManufacturerRow,
  ProductRow,
  ProductWithStock,
} from './types';

export interface Catalogue {
  categories: { id: string; name: string }[];
  products: ProductWithStock[];
}

// Load categories, products, and on-hand stock, merging stock onto each product.
// On-hand is summed across all of the business's stores (a single number per
// product); per-store scoping is a later slice.
export async function loadCatalogue(
  supabase: SupabaseClient,
): Promise<Catalogue> {
  const [categoriesRes, productsRes, inventoryRes, manufacturersRes] =
    await Promise.all([
      supabase
        .from('categories')
        .select('id, business_id, name, is_deleted')
        .eq('is_deleted', false)
        .order('name', { ascending: true })
        .returns<CategoryRow[]>(),
      supabase
        .from('products')
        .select(
          'id, business_id, category_id, name, unit, size, retailer_price_kobo, wholesaler_price_kobo, buying_price_kobo, is_available, is_deleted, low_stock_threshold, image_path, track_empties, manufacturer_id',
        )
        .eq('is_deleted', false)
        .order('name', { ascending: true })
        .returns<ProductRow[]>(),
      supabase
        .from('inventory')
        .select('id, business_id, product_id, store_id, quantity')
        .returns<InventoryRow[]>(),
      // Manufacturers carry the per-crate deposit rate (Slice 4). Small table;
      // one read attaches each product's deposit rate for the empties surface.
      supabase
        .from('manufacturers')
        .select('id, business_id, deposit_amount_kobo')
        .returns<ManufacturerRow[]>(),
    ]);

  const onHandByProduct = new Map<string, number>();
  for (const row of inventoryRes.data ?? []) {
    onHandByProduct.set(
      row.product_id,
      (onHandByProduct.get(row.product_id) ?? 0) + (row.quantity ?? 0),
    );
  }

  const depositByManufacturer = new Map<string, number>();
  for (const m of manufacturersRes.data ?? []) {
    depositByManufacturer.set(m.id, m.deposit_amount_kobo ?? 0);
  }

  const products: ProductWithStock[] = (productsRes.data ?? []).map((p) => ({
    ...p,
    onHand: onHandByProduct.get(p.id) ?? 0,
    depositRateKobo: p.manufacturer_id
      ? (depositByManufacturer.get(p.manufacturer_id) ?? 0)
      : 0,
  }));

  const categories = (categoriesRes.data ?? []).map((c) => ({
    id: c.id,
    name: c.name ?? 'Uncategorised',
  }));

  return { categories, products };
}
