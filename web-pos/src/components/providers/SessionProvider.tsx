'use client';

import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useRef,
  useState,
  type ReactNode,
} from 'react';
import type { Session, SupabaseClient } from '@supabase/supabase-js';

import { getSupabaseBrowserClient } from '@/lib/supabase/client';
import { loadOperator, type Operator } from '@/lib/operator';

type AuthStatus = 'loading' | 'signed-out' | 'signed-in';

interface SessionContextValue {
  supabase: SupabaseClient;
  status: AuthStatus;
  session: Session | null;
  operator: Operator | null;
  operatorLoading: boolean;
  signOut: () => Promise<void>;
  reloadOperator: () => Promise<void>;
}

const SessionContext = createContext<SessionContextValue | null>(null);

// Central session/Operator context. The signed-in Supabase session is the
// Operator for the tab (ADR 0011); when it resolves we load the full Operator
// (business, role, permissions, currency, palette) once and re-expose it.
export function SessionProvider({ children }: { children: ReactNode }) {
  const supabase = useMemo(() => getSupabaseBrowserClient(), []);
  const [status, setStatus] = useState<AuthStatus>('loading');
  const [session, setSession] = useState<Session | null>(null);
  const [operator, setOperator] = useState<Operator | null>(null);
  const [operatorLoading, setOperatorLoading] = useState(false);

  // Guards against a stale operator load resolving after a newer session change.
  const loadTokenRef = useRef(0);

  const refreshOperator = useCallback(
    async (activeSession: Session | null) => {
      const token = ++loadTokenRef.current;
      if (!activeSession?.user) {
        setOperator(null);
        setOperatorLoading(false);
        return;
      }
      setOperatorLoading(true);
      try {
        const next = await loadOperator(supabase, activeSession.user);
        if (loadTokenRef.current === token) setOperator(next);
      } catch {
        if (loadTokenRef.current === token) setOperator(null);
      } finally {
        if (loadTokenRef.current === token) setOperatorLoading(false);
      }
    },
    [supabase],
  );

  useEffect(() => {
    let mounted = true;

    supabase.auth.getSession().then(({ data }) => {
      if (!mounted) return;
      const s = data.session ?? null;
      setSession(s);
      setStatus(s ? 'signed-in' : 'signed-out');
      void refreshOperator(s);
    });

    const { data: sub } = supabase.auth.onAuthStateChange((_event, s) => {
      if (!mounted) return;
      setSession(s);
      setStatus(s ? 'signed-in' : 'signed-out');
      void refreshOperator(s);
    });

    return () => {
      mounted = false;
      sub.subscription.unsubscribe();
    };
  }, [supabase, refreshOperator]);

  const signOut = useCallback(async () => {
    await supabase.auth.signOut();
  }, [supabase]);

  const reloadOperator = useCallback(
    () => refreshOperator(session),
    [refreshOperator, session],
  );

  const value = useMemo<SessionContextValue>(
    () => ({
      supabase,
      status,
      session,
      operator,
      operatorLoading,
      signOut,
      reloadOperator,
    }),
    [supabase, status, session, operator, operatorLoading, signOut, reloadOperator],
  );

  return (
    <SessionContext.Provider value={value}>{children}</SessionContext.Provider>
  );
}

export function useSession(): SessionContextValue {
  const ctx = useContext(SessionContext);
  if (!ctx) {
    throw new Error('useSession must be used within a SessionProvider');
  }
  return ctx;
}
