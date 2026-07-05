// Currency formatting for the Web POS — a faithful port of the mobile app's
// number_format.dart + currencies.dart, so a money amount renders identically on
// web and mobile. The business currency comes from the synced `default_currency`
// setting; nothing hard-codes ₦ (AC: "Currency is formatted from the business
// currency setting, never hard-coded").

export const DEFAULT_CURRENCY = 'NGN';

// ISO-4217 code → display symbol. Keep in lockstep with the mobile
// kCurrencySymbols map (lib/core/data/currencies.dart).
export const CURRENCY_SYMBOLS: Record<string, string> = {
  NGN: '₦',
  XOF: 'CFA',
  XAF: 'FCFA',
  CAD: 'CA$',
  CNY: '¥',
  EGP: 'E£',
  EUR: '€',
  GHS: 'GH₵',
  INR: '₹',
  KES: 'KSh',
  LRD: 'L$',
  MAD: 'DH',
  RWF: 'FRw',
  SLL: 'Le',
  ZAR: 'R',
  TZS: 'TSh',
  UGX: 'USh',
  AED: 'AED',
  GBP: '£',
  USD: '$',
  ZMW: 'ZK',
  ZWL: 'Z$',
};

const THREE_LETTERS = /[A-Za-z]{3}/g;
const TRAILING_LETTER = /[A-Za-z]$/;

// Normalise a stored currency value to a bare ISO-4217 code where possible.
// Tolerant of legacy label-style values ("NGN (₦)" → "NGN", "Naira (NGN)" →
// "NGN"), matching the mobile normalizeCurrencyCode.
export function normalizeCurrencyCode(code: string | null | undefined): string {
  if (!code || !code.trim()) return DEFAULT_CURRENCY;
  const raw = code.trim().toUpperCase();
  if (raw in CURRENCY_SYMBOLS) return raw;
  const matches = raw.match(THREE_LETTERS);
  if (matches) {
    for (const m of matches) {
      if (m in CURRENCY_SYMBOLS) return m;
    }
  }
  return raw;
}

// Display symbol for a stored currency value — the glyph only (e.g. '₦', '$',
// 'GH₵'), never the code or a "CODE (symbol)" label.
export function currencySymbolForCode(code: string | null | undefined): string {
  const norm = normalizeCurrencyCode(code);
  return CURRENCY_SYMBOLS[norm] ?? norm;
}

// Format a whole-currency amount (NOT kobo) with the given currency's symbol.
// A space follows letter-ending symbols ('KES' → 'KSh 5,000') but not glyphs
// ('NGN' → '₦5,000'). Mirrors mobile formatCurrency.
export function formatCurrency(
  amount: number,
  code: string | null | undefined = DEFAULT_CURRENCY,
): string {
  const isNegative = amount < 0;
  const rounded = Math.round(Math.abs(amount));
  const formatted = rounded.toLocaleString('en-US');
  const sym = currencySymbolForCode(code);
  const sep = TRAILING_LETTER.test(sym) ? ' ' : '';
  return isNegative ? `-${sym}${sep}${formatted}` : `${sym}${sep}${formatted}`;
}

// Convenience: format a `*_kobo` bigint amount. Amounts are stored in kobo
// (1/100 of the major unit) across the schema; the mobile app divides by 100 at
// the display boundary. A null amount renders as an em dash.
export function formatKobo(
  kobo: number | null | undefined,
  code: string | null | undefined = DEFAULT_CURRENCY,
): string {
  if (kobo === null || kobo === undefined) return '—';
  return formatCurrency(kobo / 100, code);
}

// Parse a major-unit (e.g. naira) text input to kobo. Empty / non-positive ⇒ 0.
export function toKobo(naira: string): number {
  const n = parseFloat(naira);
  return Number.isFinite(n) && n > 0 ? Math.round(n * 100) : 0;
}

// Render a kobo amount as an editable major-unit string (empty when 0/absent).
// Inverse of toKobo for form inputs.
export function fromKobo(kobo: number | null | undefined): string {
  return kobo && kobo > 0 ? (kobo / 100).toString() : '';
}
