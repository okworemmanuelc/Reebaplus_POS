// Shared helpers for the online-write RPC client libs (checkout / inventory /
// stock adjustments). The web has no outbox: each write calls a server-
// authoritative RPC (ADR 0008) with a client-minted idempotency id, and maps the
// RPC's raw error token to an operator-facing message.

// A client-minted UUID for an RPC's idempotency key. Falls back to a
// timestamp+random id where crypto.randomUUID is unavailable.
export function newId(): string {
  return typeof crypto !== 'undefined' && 'randomUUID' in crypto
    ? crypto.randomUUID()
    : `${Date.now()}-${Math.random().toString(16).slice(2)}`;
}

// One rule for friendlyRpcError: if the raw error contains any of the token(s),
// surface the friendly message. Domain rules are evaluated in order.
export type RpcErrorCase = [string | string[], string];

// Map a raw RPC error to an operator-facing message: domain cases first, then the
// tenant-binding case every RPC can raise, else the raw message unchanged.
export function friendlyRpcError(raw: string, cases: RpcErrorCase[] = []): string {
  const message = raw ?? '';
  for (const [tokens, friendly] of cases) {
    const list = Array.isArray(tokens) ? tokens : [tokens];
    if (list.some((t) => message.includes(t))) return friendly;
  }
  if (message.includes('tenant_mismatch') || message.includes('no_business_for_caller')) {
    return 'Your session is not linked to this business. Sign out and back in.';
  }
  return message;
}
