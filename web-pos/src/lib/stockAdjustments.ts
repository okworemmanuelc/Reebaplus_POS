// Web POS Slice 7 (#50) — the stock-adjustment approval gate. A stock keeper's
// Add/Remove is a pending request (no inventory change); a manager/CEO applies
// immediately, and approves/rejects a pending request. The server (RPCs
// request_stock_adjustment / approve_stock_adjustment, 0141) decides the path
// from the CALLER's role — the web hiding a button is convenience, not the gate.

import type { SupabaseClient } from '@supabase/supabase-js';

function newId(): string {
  return typeof crypto !== 'undefined' && 'randomUUID' in crypto
    ? crypto.randomUUID()
    : `${Date.now()}-${Math.random().toString(16).slice(2)}`;
}

function friendlyError(message: string): string {
  if (message.includes('insufficient_stock')) {
    return 'That would take stock below zero. Lower the amount removed.';
  }
  if (message.includes('permission_denied')) {
    return 'You do not have permission to do this.';
  }
  if (message.includes('quantity_diff_must_be_nonzero')) {
    return 'Enter a non-zero quantity.';
  }
  if (message.includes('request_not_found')) {
    return 'That request no longer exists. Refresh the queue.';
  }
  if (message.includes('tenant_mismatch') || message.includes('no_business_for_caller')) {
    return 'Your session is not linked to this business. Sign out and back in.';
  }
  return message;
}

export interface RequestAdjustmentResult {
  status: 'pending' | 'approved' | 'rejected';
  applied: boolean;
}

// Raise an adjustment. The server routes it: a manager/CEO applies it now
// (applied=true, status 'approved'); anyone else with stock.adjust gets a
// pending request (applied=false, status 'pending').
export async function requestStockAdjustment(
  supabase: SupabaseClient,
  args: {
    businessId: string;
    storeId: string;
    productId: string;
    quantityDiff: number;
    reason: string;
  },
): Promise<RequestAdjustmentResult> {
  const { data, error } = await supabase.rpc('request_stock_adjustment', {
    p_business_id: args.businessId,
    p_request_id: newId(),
    p_store_id: args.storeId,
    p_product_id: args.productId,
    p_quantity_diff: args.quantityDiff,
    p_reason: args.reason,
  });
  if (error) throw new Error(friendlyError(error.message));
  const payload = data as { status: RequestAdjustmentResult['status']; applied: boolean };
  return { status: payload.status, applied: payload.applied };
}

// Approve (apply the delta) or reject (no change) a pending request.
export async function approveStockAdjustment(
  supabase: SupabaseClient,
  args: { businessId: string; requestId: string; approve: boolean; reason?: string | null },
): Promise<'approved' | 'rejected'> {
  const { data, error } = await supabase.rpc('approve_stock_adjustment', {
    p_business_id: args.businessId,
    p_request_id: args.requestId,
    p_approve: args.approve,
    p_reason: args.reason ?? null,
  });
  if (error) throw new Error(friendlyError(error.message));
  return (data as { status: 'approved' | 'rejected' }).status;
}

export interface PendingAdjustmentRow {
  id: string;
  product_id: string;
  store_id: string;
  quantity_diff: number;
  reason: string;
  summary: string;
  created_at: string;
}

// Load the pending approval queue (RLS-scoped). Product names are resolved by the
// caller from the catalogue it already holds.
export async function loadPendingAdjustments(
  supabase: SupabaseClient,
): Promise<PendingAdjustmentRow[]> {
  const { data, error } = await supabase
    .from('stock_adjustment_requests')
    .select('id, product_id, store_id, quantity_diff, reason, summary, created_at')
    .eq('status', 'pending')
    .order('created_at', { ascending: true })
    .returns<PendingAdjustmentRow[]>();
  if (error) throw new Error(friendlyError(error.message));
  return data ?? [];
}
