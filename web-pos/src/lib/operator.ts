// Loads the Operator context for the signed-in Supabase session (ADR 0011: the
// per-user session IS the Operator). Business scope is resolved server-side from
// profiles.business_id (the RLS anchor, current_user_business_ids()); the role
// comes from the active user_businesses membership. Every read below is
// RLS-scoped, so the Operator only ever sees their own business's rows (AC:
// "shows only the caller's business data ... with no custom JWT claims").

import type { SupabaseClient, User } from '@supabase/supabase-js';

import {
  resolveEffectivePermissions,
  type EffectivePermissions,
} from './permissions';
import { DEFAULT_CURRENCY, normalizeCurrencyCode } from './currency';
import { parsePaletteName, type PaletteName } from './theme/palettes';
import type {
  BusinessRow,
  ProfileRow,
  RolePermissionRow,
  RoleRow,
  SettingRow,
  StoreRow,
  UserBusinessRow,
  UserPermissionOverrideRow,
  UserRow,
} from './types';

const BUSINESS_DESIGN_SYSTEM_KEY = 'business_design_system';
const DEFAULT_CURRENCY_KEY = 'default_currency';

export interface Operator {
  authUserId: string;
  authEmail: string | null;
  userId: string | null;
  businessId: string | null;
  displayName: string;
  business: {
    id: string;
    name: string;
    tracksEmptyCrates: boolean;
  } | null;
  role: { id: string; slug: string | null; name: string | null } | null;
  permissions: EffectivePermissions;
  currencyCode: string;
  paletteName: PaletteName;
  stores: { id: string; name: string }[];
}

const NO_PERMISSIONS: EffectivePermissions = {
  isCeo: false,
  keys: new Set<string>(),
};

// Resolve everything about the current Operator with RLS-scoped reads. Returns a
// best-effort Operator even when some links are missing (e.g. a session not yet
// bound to a users row) so the shell can still render and surface the state.
export async function loadOperator(
  supabase: SupabaseClient,
  authUser: User,
): Promise<Operator> {
  const authUserId = authUser.id;

  const { data: profile } = await supabase
    .from('profiles')
    .select('id, business_id, name')
    .eq('id', authUserId)
    .maybeSingle<ProfileRow>();

  const businessId = profile?.business_id ?? null;

  const { data: userRow } = await supabase
    .from('users')
    .select('id, business_id, auth_user_id, name, email')
    .eq('auth_user_id', authUserId)
    .maybeSingle<UserRow>();

  const userId = userRow?.id ?? null;

  // Role via the active membership for the bound business.
  let role: Operator['role'] = null;
  let permissions: EffectivePermissions = NO_PERMISSIONS;

  if (userId) {
    const { data: memberships } = await supabase
      .from('user_businesses')
      .select('id, business_id, user_id, role_id, status')
      .eq('user_id', userId)
      .returns<UserBusinessRow[]>();

    const membership =
      memberships?.find(
        (m) => m.business_id === businessId && m.status === 'active',
      ) ??
      memberships?.find((m) => m.status === 'active') ??
      memberships?.[0] ??
      null;

    if (membership?.role_id) {
      const { data: roleRow } = await supabase
        .from('roles')
        .select('id, business_id, name, slug, is_deleted')
        .eq('id', membership.role_id)
        .maybeSingle<RoleRow>();

      if (roleRow) {
        role = { id: roleRow.id, slug: roleRow.slug, name: roleRow.name };

        const [{ data: grants }, { data: overrides }] = await Promise.all([
          supabase
            .from('role_permissions')
            .select('id, business_id, role_id, permission_key')
            .eq('role_id', roleRow.id)
            .returns<RolePermissionRow[]>(),
          supabase
            .from('user_permission_overrides')
            .select('id, business_id, user_id, permission_key, is_granted')
            .eq('user_id', userId)
            .returns<UserPermissionOverrideRow[]>(),
        ]);

        permissions = resolveEffectivePermissions({
          roleSlug: roleRow.slug,
          roleGrants: grants ?? [],
          userOverrides: overrides ?? [],
        });
      }
    }
  }

  // Business + settings + stores.
  const [businessRes, settingsRes, storesRes] = await Promise.all([
    businessId
      ? supabase
          .from('businesses')
          .select('id, name, type, tracks_empty_crates')
          .eq('id', businessId)
          .maybeSingle<BusinessRow>()
      : Promise.resolve({ data: null }),
    supabase
      .from('settings')
      .select('business_id, key, value')
      .in('key', [BUSINESS_DESIGN_SYSTEM_KEY, DEFAULT_CURRENCY_KEY])
      .returns<SettingRow[]>(),
    supabase
      .from('stores')
      .select('id, business_id, name, is_deleted')
      .eq('is_deleted', false)
      .returns<StoreRow[]>(),
  ]);

  const businessRow = businessRes.data as BusinessRow | null;
  const settings = settingsRes.data ?? [];
  const stores = storesRes.data ?? [];

  const designValue =
    settings.find((s) => s.key === BUSINESS_DESIGN_SYSTEM_KEY)?.value ?? null;
  const currencyValue =
    settings.find((s) => s.key === DEFAULT_CURRENCY_KEY)?.value ?? null;

  return {
    authUserId,
    authEmail: authUser.email ?? null,
    userId,
    businessId,
    displayName:
      userRow?.name ?? profile?.name ?? authUser.email ?? 'Operator',
    business: businessRow
      ? {
          id: businessRow.id,
          name: businessRow.name ?? 'Your business',
          tracksEmptyCrates: businessRow.tracks_empty_crates ?? false,
        }
      : null,
    role,
    permissions,
    currencyCode: currencyValue
      ? normalizeCurrencyCode(currencyValue)
      : DEFAULT_CURRENCY,
    paletteName: parsePaletteName(designValue),
    stores: stores.map((s) => ({ id: s.id, name: s.name ?? 'Store' })),
  };
}
