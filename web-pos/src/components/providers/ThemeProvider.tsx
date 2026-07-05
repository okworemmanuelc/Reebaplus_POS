'use client';

import { useEffect } from 'react';

import { useSession } from './SessionProvider';
import {
  DEFAULT_PALETTE,
  PALETTES,
  tokensToCssVars,
  type PaletteName,
  type ThemeMode,
} from '@/lib/theme/palettes';

// Applies the active business palette live at the document root (AC: "The
// palette set by the CEO (business_design_system) is applied app-wide ...
// reactively"). The colour axis is the synced, CEO-authoritative
// business_design_system value (via the Operator); light/dark follows the
// browser/device preference (ADR-noted split). Because we set CSS custom
// properties, a palette change re-paints the whole app with no reload.
export function ThemeProvider() {
  const { operator } = useSession();
  const palette: PaletteName = operator?.paletteName ?? DEFAULT_PALETTE;

  useEffect(() => {
    const root = document.documentElement;

    const apply = (mode: ThemeMode) => {
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
    apply(mql.matches ? 'dark' : 'light');

    const onChange = (e: MediaQueryListEvent) =>
      apply(e.matches ? 'dark' : 'light');
    mql.addEventListener('change', onChange);
    return () => mql.removeEventListener('change', onChange);
  }, [palette]);

  return null;
}
