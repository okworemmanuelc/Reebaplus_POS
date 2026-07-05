'use client';

import {
  createContext,
  useContext,
  useEffect,
  useState,
  type ReactNode,
} from 'react';

import { useSession } from './SessionProvider';
import {
  DEFAULT_PALETTE,
  PALETTES,
  tokensToCssVars,
  type PaletteName,
  type ThemeMode,
} from '@/lib/theme/palettes';

export type UserThemeMode = 'light' | 'dark' | 'system';

interface ThemeContextType {
  themeMode: UserThemeMode;
  resolvedTheme: ThemeMode;
  setThemeMode: (mode: UserThemeMode) => void;
}

const ThemeContext = createContext<ThemeContextType | null>(null);

// Applies the active business palette live at the document root, supporting a
// stateful manual theme override (Light / Dark / System) stored in localStorage.
export function ThemeProvider({ children }: { children: ReactNode }) {
  const { operator } = useSession();
  const palette: PaletteName = operator?.paletteName ?? DEFAULT_PALETTE;

  const [themeMode, setThemeModeState] = useState<UserThemeMode>('system');
  const [resolvedTheme, setResolvedTheme] = useState<ThemeMode>('light');

  // Load the initial stored theme preference on mount to avoid server-render mismatch
  useEffect(() => {
    const stored = localStorage.getItem('theme-mode') as UserThemeMode;
    if (stored === 'light' || stored === 'dark' || stored === 'system') {
      setThemeModeState(stored);
    }
  }, []);

  const setThemeMode = (mode: UserThemeMode) => {
    setThemeModeState(mode);
    try {
      localStorage.setItem('theme-mode', mode);
    } catch {
      // Ignore localStorage issues in private browsing
    }
  };

  useEffect(() => {
    const root = document.documentElement;

    const apply = (mode: ThemeMode) => {
      setResolvedTheme(mode);
      const tokens = PALETTES[palette][mode];
      const vars = tokensToCssVars(tokens);
      for (const [k, v] of Object.entries(vars)) {
        root.style.setProperty(k, v);
      }
      root.dataset.palette = palette;
      root.dataset.theme = mode;
      root.style.colorScheme = mode;
    };

    const mql = window.matchMedia('(prefers-color-scheme: dark)');

    const determineAndApply = () => {
      if (themeMode === 'system') {
        apply(mql.matches ? 'dark' : 'light');
      } else {
        apply(themeMode);
      }
    };

    determineAndApply();

    const onChange = () => {
      if (themeMode === 'system') {
        apply(mql.matches ? 'dark' : 'light');
      }
    };

    mql.addEventListener('change', onChange);
    return () => mql.removeEventListener('change', onChange);
  }, [palette, themeMode]);

  return (
    <ThemeContext.Provider value={{ themeMode, resolvedTheme, setThemeMode }}>
      {children}
    </ThemeContext.Provider>
  );
}

export function useTheme(): ThemeContextType {
  const ctx = useContext(ThemeContext);
  if (!ctx) {
    throw new Error('useTheme must be used within a ThemeProvider');
  }
  return ctx;
}
