// Live customer read for the cart's attach-a-customer flow (Slice 3, #44). Both
// reads are RLS-scoped to the Operator's business. Balances are DERIVED from the
// append-only wallet ledger (invariant #3) — the same rule the mobile app and
// the checkout_order RPC use: balance = SUM(signed_amount_kobo) over rows whose
// reference_type is NOT a crate-deposit leg. We compute it client-side (like the
// catalogue sums on-hand) rather than push a view, so Slice 3 stays read-only.

import type { SupabaseClient } from '@supabase/supabase-js';

import type {
  CustomerRow,
  CustomerWithBalance,
  WalletTransactionRow,
} from './types';

// The crate-deposit family is refundable money held for the customer — never
// their spendable credit nor their debt (mirrors kCrateDepositReferenceTypes /
// _customer_wallet_balance). Excluded from the balance sum.
const CRATE_DEPOSIT_REFS = new Set([
  'crate_deposit',
  'crate_deposit_refunded',
  'crate_deposit_forfeited',
]);

export async function loadCustomers(
  supabase: SupabaseClient,
): Promise<CustomerWithBalance[]> {
  const [customersRes, ledgerRes] = await Promise.all([
    supabase
      .from('customers')
      .select('id, business_id, name, phone, wallet_limit_kobo, is_deleted')
      .eq('is_deleted', false)
      .order('name', { ascending: true })
      .returns<CustomerRow[]>(),
    supabase
      .from('wallet_transactions')
      .select('customer_id, signed_amount_kobo, reference_type')
      .returns<WalletTransactionRow[]>(),
  ]);

  const balanceByCustomer = new Map<string, number>();
  for (const row of ledgerRes.data ?? []) {
    if (CRATE_DEPOSIT_REFS.has(row.reference_type)) continue;
    balanceByCustomer.set(
      row.customer_id,
      (balanceByCustomer.get(row.customer_id) ?? 0) +
        (row.signed_amount_kobo ?? 0),
    );
  }

  return (customersRes.data ?? []).map((c) => ({
    id: c.id,
    name: c.name,
    phone: c.phone,
    balanceKobo: balanceByCustomer.get(c.id) ?? 0,
    debtLimitKobo: c.wallet_limit_kobo ?? 0,
  }));
}
