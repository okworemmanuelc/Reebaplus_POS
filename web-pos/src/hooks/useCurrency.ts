'use client';

import { useCallback } from 'react';

import { useSession } from '@/components/providers/SessionProvider';
import { DEFAULT_CURRENCY, formatCurrency, formatKobo } from '@/lib/currency';

// Currency helpers bound to the Operator's business currency (default_currency).
// Every money display goes through these so nothing hard-codes ₦ (AC).
export function useCurrency() {
  const { operator } = useSession();
  const code = operator?.currencyCode ?? DEFAULT_CURRENCY;

  const money = useCallback((amount: number) => formatCurrency(amount, code), [
    code,
  ]);
  const kobo = useCallback((amount: number | null | undefined) =>
    formatKobo(amount, code), [code]);

  return { code, money, kobo };
}
