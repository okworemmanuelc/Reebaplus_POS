'use client';

import type { ReactNode } from 'react';

import { useSession } from '@/components/providers/SessionProvider';
import { can, type PermissionKey } from '@/lib/permissions';

// hide-don't-block hook: is the current Operator allowed this action? The CEO is
// always all-on (resolved in loadOperator → resolveEffectivePermissions).
export function useCan(key: PermissionKey): boolean {
  const { operator } = useSession();
  return can(operator?.permissions, key);
}

// Renders `children` only when the Operator has `perm`; otherwise renders
// `fallback` (default: nothing). This is the reusable hide-don't-block wrapper
// later slices use to gate buttons/actions in the web UI.
export function Can({
  perm,
  children,
  fallback = null,
}: {
  perm: PermissionKey;
  children: ReactNode;
  fallback?: ReactNode;
}) {
  const allowed = useCan(perm);
  return <>{allowed ? children : fallback}</>;
}
