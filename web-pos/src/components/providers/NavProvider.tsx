'use client';

import {
  createContext,
  useContext,
  useMemo,
  useState,
  type ReactNode,
} from 'react';

// The in-app "view" the shell shows. The Web POS is a single signed-in surface
// (ADR 0011) rather than a multi-route site, so navigation is a client-side view
// switch held above the shell — the sidebar sets it, the content area renders it.
// Slice 6 (#48) adds 'inventory'; later slices add their own.
export type AppView = 'pos' | 'inventory' | 'reports';

interface NavContextValue {
  view: AppView;
  setView: (view: AppView) => void;
}

const NavContext = createContext<NavContextValue | null>(null);

export function NavProvider({ children }: { children: ReactNode }) {
  const [view, setView] = useState<AppView>('pos');
  const value = useMemo<NavContextValue>(() => ({ view, setView }), [view]);
  return <NavContext.Provider value={value}>{children}</NavContext.Provider>;
}

export function useNav(): NavContextValue {
  const ctx = useContext(NavContext);
  if (!ctx) throw new Error('useNav must be used within a NavProvider');
  return ctx;
}
