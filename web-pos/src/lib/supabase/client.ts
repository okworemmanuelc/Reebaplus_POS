'use client';

import { createClient, type SupabaseClient } from '@supabase/supabase-js';

import { supabaseAnonKey, supabaseUrl } from './config';

// The Web POS is online-first (ADR 0007): a single browser Supabase client is
// the whole data layer — RLS-scoped PostgREST reads and (later slices) rpc()
// writes and Realtime channels. The signed-in Supabase session IS the Operator
// for this browser tab (ADR 0011); it is persisted in localStorage and the
// client detects the OAuth session in the return URL after a Google redirect.
//
// One module-level instance is reused across the app (a fresh client per render
// would drop the auth listener and duplicate Realtime sockets).
let browserClient: SupabaseClient | undefined;

export function getSupabaseBrowserClient(): SupabaseClient {
  if (browserClient) return browserClient;
  browserClient = createClient(supabaseUrl, supabaseAnonKey, {
    auth: {
      persistSession: true,
      autoRefreshToken: true,
      detectSessionInUrl: true,
      flowType: 'pkce',
    },
  });
  return browserClient;
}
