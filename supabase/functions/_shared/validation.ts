// Lightweight email validation, disposable-domain blocklist, and code/token
// generation. The disposable list is intentionally short — keeping the
// obvious offenders out, not pretending to be a comprehensive defense.

const EMAIL_RE =
  /^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(?:\.[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)+$/;

export function isValidEmail(email: string): boolean {
  return (
    typeof email === "string" &&
    email.length > 0 &&
    email.length <= 254 &&
    EMAIL_RE.test(email)
  );
}

const DISPOSABLE_DOMAINS = new Set<string>([
  "mailinator.com",
  "tempmail.com",
  "10minutemail.com",
  "guerrillamail.com",
  "throwaway.email",
  "yopmail.com",
  "trashmail.com",
  "fakeinbox.com",
  "sharklasers.com",
  "maildrop.cc",
  "getnada.com",
  "discard.email",
]);

export function isDisposableEmail(email: string): boolean {
  const at = email.lastIndexOf("@");
  if (at < 0) return false;
  const domain = email.slice(at + 1).toLowerCase();
  return DISPOSABLE_DOMAINS.has(domain);
}

// Crockford-ish alphabet without 0/O/1/I/L — easier to type when sharing
// the code over the phone. Default for generateCode(); callers can pass a
// different alphabet if they need to (PIN-reset codes, device pairing
// codes, etc. — see plan rev 3 implementation pickup §2).
export const DEFAULT_CODE_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";

export function generateCode(
  length = 8,
  alphabet: string = DEFAULT_CODE_ALPHABET,
): string {
  const bytes = new Uint8Array(length);
  crypto.getRandomValues(bytes);
  let out = "";
  for (let i = 0; i < length; i++) {
    out += alphabet[bytes[i] % alphabet.length];
  }
  return out;
}

// generateToken / sha256Hex were used by the rev 2 token-based deep-link
// path (reebaplus://invite?token=...). Rev 3 drops that path entirely
// (no email/SMS to deliver tokens), so both helpers are gone. If the
// share-via-deep-link feature is reintroduced later, restore them from
// git history and re-add the issue-time token-hash insert.

const VALID_GRANULAR_ROLES = new Set<string>([
  "ceo",
  "manager",
  "stock_keeper",
  "cashier",
  "rider",
]);

export function isValidGranularRole(role: string): boolean {
  return typeof role === "string" && VALID_GRANULAR_ROLES.has(role);
}

const UUID_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export function isUuid(s: unknown): s is string {
  return typeof s === "string" && UUID_RE.test(s);
}
