// Permission-read layer for the Web POS (AC: "A permission-read utility exists
// and hides actions the Operator's role lacks"). It mirrors the *decisions* of
// the mobile Gate Registry (ADR 0002) — not its Dart code (ADR 0009): read the
// same role_permissions / user_permission_overrides rows and apply
// hide-don't-block, with the CEO always all-on.
//
// This is deliberately a plain data utility, reused by later slices. The web
// only HIDES actions; every money-write RPC also re-checks the permission
// server-side (defence in depth, PRD Implementation Decisions).

import type {
  RolePermissionRow,
  UserPermissionOverrideRow,
} from './types';

// The permission keys this walking skeleton references. The full catalogue lives
// in the cloud `permissions` table; later slices add their keys here as they
// wire real actions. Keeping named constants (not string literals at call sites)
// keeps the web's permission vocabulary auditable in one place.
export const PermissionKeys = {
  salesMake: 'sales.make',
  productsAdd: 'products.add',
  stockView: 'stock.view',
  stockAdd: 'stock.add',
  stockReceived: 'stock.received',
  reportsView: 'reports.view',
} as const;

export type PermissionKey =
  (typeof PermissionKeys)[keyof typeof PermissionKeys];

// The resolved permission state for the current Operator.
export interface EffectivePermissions {
  isCeo: boolean;
  keys: ReadonlySet<string>;
}

// Pure resolution of effective permissions, mirroring mobile
// resolveEffectivePermissions + currentUserPermissionsProvider:
//   - CEO (role slug 'ceo') is all-on and skips every override layer.
//   - Otherwise start from the role's business grants, then apply the user's
//     overrides (granted true = force-grant, false = force-revoke).
// Store-scope overrides (§10.2.1 middle layer) are a later slice; the skeleton
// resolves Business ± User, which is the common case for a single-store operator.
export function resolveEffectivePermissions(params: {
  roleSlug: string | null | undefined;
  roleGrants: Pick<RolePermissionRow, 'permission_key'>[];
  userOverrides: Pick<
    UserPermissionOverrideRow,
    'permission_key' | 'is_granted'
  >[];
}): EffectivePermissions {
  const { roleSlug, roleGrants, userOverrides } = params;
  const keys = new Set(roleGrants.map((g) => g.permission_key));

  if (roleSlug === 'ceo') {
    return { isCeo: true, keys };
  }

  for (const o of userOverrides) {
    if (o.is_granted) {
      keys.add(o.permission_key);
    } else {
      keys.delete(o.permission_key);
    }
  }
  return { isCeo: false, keys };
}

// hide-don't-block predicate: does the Operator have this permission? The CEO
// always passes.
export function can(
  perms: EffectivePermissions | null | undefined,
  key: PermissionKey,
): boolean {
  if (!perms) return false;
  if (perms.isCeo) return true;
  return perms.keys.has(key);
}
