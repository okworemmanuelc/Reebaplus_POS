// The five named business palettes, ported verbatim from the mobile app's
// AppTheme / colors.dart so the web brand matches mobile exactly (AC: reproduce
// blue / amber / purple / green / b&w, light + dark). The active palette is the
// synced `business_design_system` value — the DesignSystem enum *name* the CEO
// set — so these keys must equal the Flutter enum names.

export type PaletteName = 'blue' | 'amber' | 'purple' | 'green' | 'bw';
export type ThemeMode = 'light' | 'dark';

export const PALETTE_NAMES: PaletteName[] = [
  'blue',
  'amber',
  'purple',
  'green',
  'bw',
];

export const DEFAULT_PALETTE: PaletteName = 'blue';

// The token set every theme surface reads. Each maps 1:1 to a CSS custom
// property `--<token>` applied at the document root.
export interface ThemeTokens {
  bg: string;
  surface: string;
  surface2: string;
  border: string;
  text: string;
  subtext: string;
  primary: string;
  primaryHover: string;
  onPrimary: string;
  secondary: string;
  danger: string;
  success: string;
  warning: string;
  info: string;
}

type PaletteSet = Record<ThemeMode, ThemeTokens>;

// Shared status colours per design system (from AppTheme's _*Semantics + the
// per-palette danger/success brand colours).
const blue: PaletteSet = {
  light: {
    bg: '#F8FAFC',
    surface: '#FFFFFF',
    surface2: '#F1F5F9',
    border: '#E2E8F0',
    text: '#0F172A',
    subtext: '#64748B',
    primary: '#2563EB',
    primaryHover: '#1D4ED8',
    onPrimary: '#FFFFFF',
    secondary: '#60A5FA',
    danger: '#EF4444',
    success: '#10B981',
    warning: '#FFB020',
    info: '#3B82F6',
  },
  dark: {
    bg: '#090D14',
    surface: '#111827',
    surface2: '#1C2438',
    border: 'rgba(255,255,255,0.12)',
    text: '#F8FAFC',
    subtext: '#A0AEC0',
    primary: '#3B82F6',
    primaryHover: '#2563EB',
    onPrimary: '#FFFFFF',
    secondary: '#60A5FA',
    danger: '#EF4444',
    success: '#10B981',
    warning: '#FFB020',
    info: '#3B82F6',
  },
};

const amber: PaletteSet = {
  light: {
    bg: '#F4F6FA',
    surface: '#FFFFFF',
    surface2: '#EDF0F5',
    border: 'rgba(0,0,0,0.07)',
    text: '#0E1420',
    subtext: '#4B5563',
    primary: '#D97706', // contrastAmber — light-theme high-contrast amber
    primaryHover: '#B45309',
    onPrimary: '#000000',
    secondary: '#FF7A00',
    danger: '#FF3B30',
    success: '#30D158',
    warning: '#FFB020',
    info: '#3B82F6',
  },
  dark: {
    bg: '#080C12',
    surface: '#0E1420',
    surface2: '#141B28',
    border: 'rgba(255,255,255,0.06)',
    text: '#E8EEF6',
    subtext: '#6B7A90',
    primary: '#F5A623', // amberPrimary
    primaryHover: '#D97706',
    onPrimary: '#000000',
    secondary: '#FF7A00',
    danger: '#FF3B30',
    success: '#30D158',
    warning: '#FFB020',
    info: '#3B82F6',
  },
};

const purple: PaletteSet = {
  light: {
    bg: '#F7F8FA',
    surface: '#FFFFFF',
    surface2: '#EDF0F4',
    border: 'rgba(0,0,0,0.07)',
    text: '#111827',
    subtext: '#6B7280',
    primary: '#7C3AED', // purplePrimaryDark — light-theme primary
    primaryHover: '#6D28D9',
    onPrimary: '#FFFFFF',
    secondary: '#6D28D9',
    danger: '#FF3B30',
    success: '#34D399',
    warning: '#FBBF24',
    info: '#8B5CF6',
  },
  dark: {
    bg: '#0B0D10',
    surface: '#15171B',
    surface2: '#1E2127',
    border: 'rgba(255,255,255,0.08)',
    text: '#F3F4F6',
    subtext: '#9CA3AF',
    primary: '#8B5CF6', // purplePrimary
    primaryHover: '#7C3AED',
    onPrimary: '#FFFFFF',
    secondary: '#6D28D9',
    danger: '#FF3B30',
    success: '#34D399',
    warning: '#FBBF24',
    info: '#8B5CF6',
  },
};

const green: PaletteSet = {
  light: {
    bg: '#F7F8FA',
    surface: '#FFFFFF',
    surface2: '#EDF0F4',
    border: 'rgba(0,0,0,0.07)',
    text: '#111827',
    subtext: '#6B7280',
    primary: '#15803D', // greenContrast — light-theme deep forest primary
    primaryHover: '#166534',
    onPrimary: '#FFFFFF',
    secondary: '#166534',
    danger: '#FF3B30',
    success: '#22C55E',
    warning: '#FFB020',
    info: '#3B82F6',
  },
  dark: {
    bg: '#0B0D10',
    surface: '#15171B',
    surface2: '#1E2127',
    border: 'rgba(255,255,255,0.08)',
    text: '#F3F4F6',
    subtext: '#9CA3AF',
    primary: '#22C55E', // greenPrimary
    primaryHover: '#15803D',
    onPrimary: '#FFFFFF',
    secondary: '#166534',
    danger: '#FF3B30',
    success: '#22C55E',
    warning: '#FFB020',
    info: '#3B82F6',
  },
};

const bw: PaletteSet = {
  light: {
    bg: '#F4F4F5',
    surface: '#FFFFFF',
    surface2: '#E7E7E9',
    border: 'rgba(0,0,0,0.08)',
    text: '#09090B',
    subtext: '#52525B',
    primary: '#111111', // bwPrimaryLight — near-black
    primaryHover: '#3F3F46',
    onPrimary: '#FFFFFF',
    secondary: '#3F3F46',
    danger: '#FF3B30',
    success: '#22C55E',
    warning: '#FFB020',
    info: '#3B82F6',
  },
  dark: {
    bg: '#000000',
    surface: '#121212',
    surface2: '#1E1E1E',
    border: 'rgba(255,255,255,0.12)',
    text: '#FAFAFA',
    subtext: '#A1A1AA',
    primary: '#FAFAFA', // bwPrimaryDark — near-white
    primaryHover: '#BDBDBD',
    onPrimary: '#000000',
    secondary: '#BDBDBD',
    danger: '#FF3B30',
    success: '#22C55E',
    warning: '#FFB020',
    info: '#3B82F6',
  },
};

export const PALETTES: Record<PaletteName, PaletteSet> = {
  blue,
  amber,
  purple,
  green,
  bw,
};

// Coerce an arbitrary stored `business_design_system` value to a known palette,
// falling back to the blue default (matches the mobile _parseDesignSystem +
// blue default when the key is unset/invalid).
export function parsePaletteName(value: string | null | undefined): PaletteName {
  if (value && (PALETTE_NAMES as string[]).includes(value)) {
    return value as PaletteName;
  }
  return DEFAULT_PALETTE;
}

// The CSS custom properties for a palette+mode, as a plain object ready to apply
// to an element's style (`el.style.setProperty('--bg', ...)`).
export function tokensToCssVars(tokens: ThemeTokens): Record<string, string> {
  const vars: Record<string, string> = {};
  for (const [key, value] of Object.entries(tokens)) {
    // camelCase token → kebab CSS var (`primaryHover` → `--primary-hover`).
    const cssKey = key.replace(/[A-Z]/g, (m) => `-${m.toLowerCase()}`);
    vars[`--${cssKey}`] = value;
  }
  return vars;
}
