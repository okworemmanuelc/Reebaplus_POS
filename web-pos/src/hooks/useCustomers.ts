'use client';

import { useCallback, useEffect, useState } from 'react';

import { useSession } from '@/components/providers/SessionProvider';
import { loadCustomers } from '@/lib/customers';
import type { CustomerWithBalance } from '@/lib/types';

// Loads the registered-customer list (with derived wallet balances) once and
// exposes a `refresh` to re-pull after a credit sale changes a balance. Live
// Realtime is a later slice; here we refresh on demand like the catalogue.
export function useCustomers(): {
  customers: CustomerWithBalance[];
  loading: boolean;
  error: string | null;
  refresh: () => Promise<void>;
} {
  const { supabase, operator } = useSession();
  const businessId = operator?.businessId ?? null;

  const [customers, setCustomers] = useState<CustomerWithBalance[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const refresh = useCallback(async () => {
    setError(null);
    try {
      setCustomers(await loadCustomers(supabase));
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to load customers.');
    } finally {
      setLoading(false);
    }
  }, [supabase]);

  useEffect(() => {
    setLoading(true);
    void refresh();
  }, [refresh, businessId]);

  return { customers, loading, error, refresh };
}
