// Web POS Slice 8 (#51) — read-only reports & dashboards. No write RPCs: these
// are RLS-scoped aggregation reads the UI computes over. The money rules mirror
// mobile EXACTLY (ADR 0009 decisions, not its Dart):
//   * A sale is any order NOT reversed — status in {pending, completed}
//     (orderCountsAsSale); revenue is recognized at checkout, never at Confirm.
//   * The profit report EXCLUDES Uncosted units (a line with no product or
//     buying_price_kobo <= 0) from BOTH revenue and COGS, and reports their count
//     separately — so Revenue − COGS always equals Gross Profit.

import type { SupabaseClient } from '@supabase/supabase-js';

// The order statuses that count as a recognized sale (mirrors mobile
// orderRevenueStatuses — pending|completed, never cancelled/refunded).
export const SALE_STATUSES = ['pending', 'completed'] as const;

export interface SalesReport {
  // All recognized-sale revenue in the window (net), incl. uncosted lines.
  revenueKobo: number;
  orderCount: number;
  // Profit view — costed lines only (uncosted excluded from both sides).
  costedRevenueKobo: number;
  cogsKobo: number;
  grossProfitKobo: number;
  uncostedUnits: number;
  byDay: { date: string; revenueKobo: number }[];
  topProducts: {
    productId: string;
    name: string;
    qty: number;
    revenueKobo: number;
    profitKobo: number;
  }[];
}

interface OrderRow {
  net_amount_kobo: number | null;
  created_at: string;
}

interface ItemRow {
  product_id: string | null;
  quantity: number;
  unit_price_kobo: number;
  buying_price_kobo: number;
  products: { name: string } | { name: string }[] | null;
}

function productName(p: ItemRow['products']): string {
  if (!p) return 'Unknown';
  return Array.isArray(p) ? (p[0]?.name ?? 'Unknown') : p.name;
}

// Load the sales/revenue + profit numbers for a window, optionally scoped to a
// store. Uses a PostgREST inner-join filter so item rows are already restricted
// to counted orders in the window (one round trip), matching the orders read.
export async function loadSalesReport(
  supabase: SupabaseClient,
  args: { fromIso: string; storeId?: string | null },
): Promise<SalesReport> {
  let ordersQuery = supabase
    .from('orders')
    .select('net_amount_kobo, created_at')
    .in('status', SALE_STATUSES as unknown as string[])
    .gte('created_at', args.fromIso);
  if (args.storeId) ordersQuery = ordersQuery.eq('store_id', args.storeId);

  let itemsQuery = supabase
    .from('order_items')
    .select(
      'product_id, quantity, unit_price_kobo, buying_price_kobo, orders!inner(status, created_at, store_id), products(name)',
    )
    .in('orders.status', SALE_STATUSES as unknown as string[])
    .gte('orders.created_at', args.fromIso);
  if (args.storeId) itemsQuery = itemsQuery.eq('orders.store_id', args.storeId);

  const [ordersRes, itemsRes] = await Promise.all([
    ordersQuery.returns<OrderRow[]>(),
    itemsQuery.returns<ItemRow[]>(),
  ]);
  if (ordersRes.error) throw new Error(ordersRes.error.message);
  if (itemsRes.error) throw new Error(itemsRes.error.message);

  const orders = ordersRes.data ?? [];
  const items = itemsRes.data ?? [];

  let revenueKobo = 0;
  const byDayMap = new Map<string, number>();
  for (const o of orders) {
    const net = o.net_amount_kobo ?? 0;
    revenueKobo += net;
    const day = o.created_at.slice(0, 10);
    byDayMap.set(day, (byDayMap.get(day) ?? 0) + net);
  }

  let costedRevenueKobo = 0;
  let cogsKobo = 0;
  let uncostedUnits = 0;
  const byProduct = new Map<
    string,
    { name: string; qty: number; revenueKobo: number; cogsKobo: number }
  >();
  for (const i of items) {
    // Uncosted line (no product, or no recorded buying price) — excluded from
    // the profit math on both sides, counted separately (mirrors mobile).
    if (!i.product_id || i.buying_price_kobo <= 0) {
      uncostedUnits += i.quantity;
      continue;
    }
    const lineRevenue = i.quantity * i.unit_price_kobo;
    const lineCogs = i.quantity * i.buying_price_kobo;
    costedRevenueKobo += lineRevenue;
    cogsKobo += lineCogs;
    const acc = byProduct.get(i.product_id) ?? {
      name: productName(i.products),
      qty: 0,
      revenueKobo: 0,
      cogsKobo: 0,
    };
    acc.qty += i.quantity;
    acc.revenueKobo += lineRevenue;
    acc.cogsKobo += lineCogs;
    byProduct.set(i.product_id, acc);
  }

  const byDay = [...byDayMap.entries()]
    .map(([date, kobo]) => ({ date, revenueKobo: kobo }))
    .sort((a, b) => a.date.localeCompare(b.date));

  const topProducts = [...byProduct.entries()]
    .map(([productId, a]) => ({
      productId,
      name: a.name,
      qty: a.qty,
      revenueKobo: a.revenueKobo,
      profitKobo: a.revenueKobo - a.cogsKobo,
    }))
    .sort((a, b) => b.profitKobo - a.profitKobo)
    .slice(0, 8);

  return {
    revenueKobo,
    orderCount: orders.length,
    costedRevenueKobo,
    cogsKobo,
    grossProfitKobo: costedRevenueKobo - cogsKobo,
    uncostedUnits,
    byDay,
    topProducts,
  };
}

export interface ActivityLogRow {
  id: string;
  action: string;
  description: string;
  created_at: string;
}

export async function loadActivityLogs(
  supabase: SupabaseClient,
  args: { storeId?: string | null; limit?: number } = {},
): Promise<ActivityLogRow[]> {
  let q = supabase
    .from('activity_logs')
    .select('id, action, description, created_at')
    .order('created_at', { ascending: false })
    .limit(args.limit ?? 50);
  if (args.storeId) q = q.eq('store_id', args.storeId);
  const { data, error } = await q.returns<ActivityLogRow[]>();
  if (error) throw new Error(error.message);
  return data ?? [];
}
