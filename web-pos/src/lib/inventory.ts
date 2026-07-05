// Web POS Slice 6 (#48) — the inventory money-writes. Like checkout (Slice 2),
// the web never writes catalogue/stock rows through PostgREST: it calls the
// server-authoritative RPCs add_product / update_product / receive_stock
// (migration 0140, ADR 0008), each one atomic transaction that also enforces the
// caller's permission server-side. Amounts are `*_kobo` bigint end to end.

import type { SupabaseClient } from '@supabase/supabase-js';

import type { CategoryRow, ProductRow, SupplierRow } from './types';

// A product unit the catalogue understands (mirrors the cloud products.unit
// CHECK). 'Piece' is the neutral default for a non-returnable item.
export const PRODUCT_UNITS = [
  'Bottle',
  'Can',
  'PET',
  'Sachet',
  'Keg',
  'Crate',
  'Pack',
  'Carton',
  'Piece',
  'Bag',
  'Box',
  'Tin',
  'Other',
] as const;
export type ProductUnit = (typeof PRODUCT_UNITS)[number];

// A supplier payment tender for Receive Stock (mirrors supplier_ledger_entries).
export const RECEIVE_PAYMENT_METHODS = ['cash', 'transfer', 'pos', 'other'] as const;
export type ReceivePaymentMethod = (typeof RECEIVE_PAYMENT_METHODS)[number];

function newId(): string {
  return typeof crypto !== 'undefined' && 'randomUUID' in crypto
    ? crypto.randomUUID()
    : `${Date.now()}-${Math.random().toString(16).slice(2)}`;
}

// Map an RPC error token to an operator-facing message (mirrors checkout.ts).
function friendlyError(message: string): string {
  if (message.includes('permission_denied')) {
    return 'You do not have permission to do this. Ask a manager.';
  }
  if (message.includes('name_required')) {
    return 'Enter a product name.';
  }
  if (message.includes('lines_required') || message.includes('line_quantity_must_be_positive')) {
    return 'Add at least one line with a quantity of one or more.';
  }
  if (message.includes('opening_stock_must_be_non_negative')) {
    return 'Opening stock cannot be negative.';
  }
  if (message.includes('product_not_found')) {
    return 'That product no longer exists. Refresh and try again.';
  }
  if (message.includes('supplier_id_required')) {
    return 'Choose a supplier for this delivery.';
  }
  if (message.includes('store_id_required')) {
    return 'This account has no store set up yet.';
  }
  if (message.includes('tenant_mismatch') || message.includes('no_business_for_caller')) {
    return 'Your session is not linked to this business. Sign out and back in.';
  }
  return message;
}

export interface AddProductArgs {
  businessId: string;
  storeId: string;
  name: string;
  categoryId?: string | null;
  unit: ProductUnit;
  size?: string | null;
  retailerPriceKobo: number;
  wholesalerPriceKobo: number;
  buyingPriceKobo: number;
  openingStock: number;
  trackEmpties?: boolean;
  manufacturerId?: string | null;
  lowStockThreshold?: number;
}

export async function addProduct(
  supabase: SupabaseClient,
  args: AddProductArgs,
): Promise<ProductRow> {
  const { data, error } = await supabase.rpc('add_product', {
    p_business_id: args.businessId,
    p_product_id: newId(),
    p_store_id: args.storeId,
    p_name: args.name.trim(),
    p_category_id: args.categoryId ?? null,
    p_unit: args.unit,
    p_size: args.size ?? null,
    p_retailer_price_kobo: args.retailerPriceKobo,
    p_wholesaler_price_kobo: args.wholesalerPriceKobo,
    p_buying_price_kobo: args.buyingPriceKobo,
    p_opening_stock: args.openingStock,
    p_track_empties: args.trackEmpties ?? false,
    p_manufacturer_id: args.manufacturerId ?? null,
    p_low_stock_threshold: args.lowStockThreshold ?? 5,
  });
  if (error) throw new Error(friendlyError(error.message));
  return (data as { product: ProductRow }).product;
}

export interface UpdateProductArgs {
  businessId: string;
  productId: string;
  name?: string;
  categoryId?: string | null;
  unit?: ProductUnit;
  size?: string | null;
  retailerPriceKobo?: number;
  wholesalerPriceKobo?: number;
  buyingPriceKobo?: number;
  trackEmpties?: boolean;
  manufacturerId?: string | null;
  lowStockThreshold?: number;
}

export async function updateProduct(
  supabase: SupabaseClient,
  args: UpdateProductArgs,
): Promise<ProductRow> {
  const { data, error } = await supabase.rpc('update_product', {
    p_business_id: args.businessId,
    p_product_id: args.productId,
    p_name: args.name ?? null,
    p_category_id: args.categoryId ?? null,
    p_unit: args.unit ?? null,
    p_size: args.size ?? null,
    p_retailer_price_kobo: args.retailerPriceKobo ?? null,
    p_wholesaler_price_kobo: args.wholesalerPriceKobo ?? null,
    p_buying_price_kobo: args.buyingPriceKobo ?? null,
    p_track_empties: args.trackEmpties ?? null,
    p_manufacturer_id: args.manufacturerId ?? null,
    p_low_stock_threshold: args.lowStockThreshold ?? null,
  });
  if (error) throw new Error(friendlyError(error.message));
  return (data as { product: ProductRow }).product;
}

export interface ReceiveStockLine {
  productId: string;
  quantity: number;
  buyingPriceKobo: number;
  // Optional edited sell prices persisted alongside the delivery.
  retailerPriceKobo?: number | null;
  wholesalerPriceKobo?: number | null;
}

export interface ReceiveStockArgs {
  businessId: string;
  supplierId: string;
  storeId: string;
  receivedAt?: string; // ISO; defaults server-side to now
  lines: ReceiveStockLine[];
  amountPaidKobo: number;
  paymentMethod: ReceivePaymentMethod;
  note?: string | null;
}

export interface ReceiveStockResult {
  invoiceTotalKobo: number;
  amountPaidKobo: number;
  units: number;
}

export async function receiveStock(
  supabase: SupabaseClient,
  args: ReceiveStockArgs,
): Promise<ReceiveStockResult> {
  const { data, error } = await supabase.rpc('receive_stock', {
    p_business_id: args.businessId,
    p_receipt_id: newId(),
    p_supplier_id: args.supplierId,
    p_store_id: args.storeId,
    p_lines: args.lines.map((l) => ({
      product_id: l.productId,
      quantity: l.quantity,
      buying_price_kobo: l.buyingPriceKobo,
      retailer_price_kobo: l.retailerPriceKobo ?? null,
      wholesaler_price_kobo: l.wholesalerPriceKobo ?? null,
    })),
    p_received_at: args.receivedAt ?? null,
    p_amount_paid_kobo: args.amountPaidKobo,
    p_payment_method: args.paymentMethod,
    p_note: args.note ?? null,
  });
  if (error) throw new Error(friendlyError(error.message));
  const payload = data as {
    invoice_total_kobo: number;
    amount_paid_kobo: number;
    units: number;
  };
  return {
    invoiceTotalKobo: payload.invoice_total_kobo,
    amountPaidKobo: payload.amount_paid_kobo,
    units: payload.units,
  };
}

export interface InventoryRefs {
  categories: CategoryRow[];
  suppliers: SupplierRow[];
}

// Reference data for the add/edit + receive forms (categories for the picker,
// suppliers for a delivery). RLS-scoped to the Operator's business.
export async function loadInventoryRefs(
  supabase: SupabaseClient,
): Promise<InventoryRefs> {
  const [categoriesRes, suppliersRes] = await Promise.all([
    supabase
      .from('categories')
      .select('id, business_id, name, is_deleted')
      .eq('is_deleted', false)
      .order('name', { ascending: true })
      .returns<CategoryRow[]>(),
    supabase
      .from('suppliers')
      .select('id, business_id, name, is_deleted')
      .eq('is_deleted', false)
      .order('name', { ascending: true })
      .returns<SupplierRow[]>(),
  ]);
  return {
    categories: categoriesRes.data ?? [],
    suppliers: suppliersRes.data ?? [],
  };
}
