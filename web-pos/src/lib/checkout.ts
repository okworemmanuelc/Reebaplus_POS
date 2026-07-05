// The Web POS's only money-write for Slice 2: the server-authoritative
// `checkout_order` RPC (migration 0135, ADR 0008). The web never writes order
// rows through PostgREST — it hands the cart to the RPC, which does the whole
// checkout atomically server-side (order + items + FIFO draw-down + COGS
// snapshot + stock guard + server order number + revenue-at-checkout) and
// returns the rows for the receipt. Amounts are `*_kobo` bigint end to end.

import type { SupabaseClient } from '@supabase/supabase-js';

import type { ProductWithStock } from './types';

// The retail tier is the primary line price (per-tier switching is a later
// refinement); fall back to wholesaler, then 0.
export function lineUnitPriceKobo(product: ProductWithStock): number {
  return (
    product.retailer_price_kobo ?? product.wholesaler_price_kobo ?? 0
  );
}

export interface CheckoutLineInput {
  productId: string;
  quantity: number;
  unitPriceKobo: number;
  // Carried only for the receipt (the RPC doesn't echo product names).
  name: string;
}

// The four checkout paths the server-authoritative RPC understands:
//   'cash' | 'transfer' — fully-settled sale (walk-in or registered).
//   'wallet'            — Pay-with-Credit: draw the whole sale from the customer's
//                         existing wallet balance (no cash; amountPaidKobo = 0).
//   'credit'            — Register-as-Credit-Sale: the customer owes the balance;
//                         amountPaidKobo is any cash part-paid now (0..net).
export type PaymentMethod = 'cash' | 'transfer' | 'wallet' | 'credit';

export interface CheckoutArgs {
  businessId: string;
  storeId: string;
  paymentMethod: PaymentMethod;
  amountPaidKobo: number;
  discountKobo: number;
  lines: CheckoutLineInput[];
  // A registered customer for the credit/wallet paths (and to post wallet legs
  // on any registered sale). Null/undefined = walk-in.
  customerId?: string | null;
  // Carried only for the receipt (the RPC doesn't echo the customer name).
  customerName?: string | null;
}

// The shape the receipt renders — the server-authoritative order plus the line
// snapshot we sent (for names) and the tendered amount (for change).
export interface CheckoutResult {
  orderNumber: string;
  totalAmountKobo: number;
  discountKobo: number;
  netAmountKobo: number;
  amountPaidKobo: number;
  paymentMethod: PaymentMethod;
  lines: CheckoutLineInput[];
  createdAt: string;
  // Ephemeral, display-only (not stored server-side — the sale settles at net):
  // the amount the operator tendered and the change to hand back.
  tenderedKobo?: number;
  changeKobo?: number;
  // Registered-customer credit (Slice 3): the name for the receipt and the
  // customer's derived balance AFTER the sale, straight from the RPC.
  customerName?: string | null;
  customerBalanceKobo?: number | null;
  // Empty-crate summary for the receipt (Slice 4, #45): the returnable crates in
  // this sale and their total deposit value. Present only when the business
  // tracks crates; 0 crates ⇒ the receipt hides the empties line.
  crateCount?: number;
  crateDepositKobo?: number;
}

interface OrderRow {
  order_number: string;
  total_amount_kobo: number;
  discount_kobo: number;
  net_amount_kobo: number;
  amount_paid_kobo: number;
  created_at: string;
}

// Turn a raw RPC error into an operator-facing message.
function friendlyError(message: string): string {
  if (message.includes('insufficient_stock')) {
    return 'Not enough stock to complete this sale — another till may have just sold the same item. Refresh and try again.';
  }
  if (message.includes('permission_denied')) {
    return 'You do not have permission to ring up a sale.';
  }
  if (message.includes('debt_limit_exceeded')) {
    return 'This sale would push the customer past their debt limit. Take a payment, lower the amount owed, or raise their limit.';
  }
  if (message.includes('customer_wallet_missing')) {
    return 'This customer has no wallet set up yet. Add them again on the mobile app, then retry.';
  }
  if (message.includes('credit_requires_customer')) {
    return 'Attach a registered customer before selling on credit.';
  }
  if (message.includes('amount_paid_below_net')) {
    return 'The amount paid is less than the total. Enter the full amount, or use Pay with Credit / Register as Credit Sale.';
  }
  if (message.includes('tenant_mismatch') || message.includes('no_business_for_caller')) {
    return 'Your session is not linked to this business. Sign out and back in.';
  }
  return message;
}

export async function checkoutOrder(
  supabase: SupabaseClient,
  args: CheckoutArgs,
): Promise<CheckoutResult> {
  const orderId =
    typeof crypto !== 'undefined' && 'randomUUID' in crypto
      ? crypto.randomUUID()
      : `${Date.now()}-${Math.random().toString(16).slice(2)}`;

  const { data, error } = await supabase.rpc('checkout_order', {
    p_business_id: args.businessId,
    p_order_id: orderId,
    p_store_id: args.storeId,
    p_items: args.lines.map((l) => ({
      product_id: l.productId,
      quantity: l.quantity,
      unit_price_kobo: l.unitPriceKobo,
    })),
    p_payment_method: args.paymentMethod,
    p_amount_paid_kobo: args.amountPaidKobo,
    p_discount_kobo: args.discountKobo,
    p_customer_id: args.customerId ?? null,
  });

  if (error) {
    throw new Error(friendlyError(error.message));
  }

  const payload = data as {
    order: OrderRow;
    customer_balance_kobo: number | null;
  };
  const order = payload.order;
  return {
    orderNumber: order.order_number,
    totalAmountKobo: order.total_amount_kobo,
    discountKobo: order.discount_kobo,
    netAmountKobo: order.net_amount_kobo,
    amountPaidKobo: order.amount_paid_kobo,
    paymentMethod: args.paymentMethod,
    lines: args.lines,
    createdAt: order.created_at,
    customerName: args.customerName ?? null,
    customerBalanceKobo: payload.customer_balance_kobo ?? null,
  };
}
