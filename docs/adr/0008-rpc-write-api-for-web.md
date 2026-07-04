# Server-authoritative Postgres RPCs are the web write API

Every money-write the web POS performs — checkout, receive/adjust stock, wallet and
crate ledger posting, order-number minting, revenue recognition — executes inside a
`SECURITY DEFINER` Postgres RPC, transactionally, behind RLS. The web client never
writes business rows directly through PostgREST; it calls the RPC and the server
does the math. This is because that logic today lives entirely in the mobile app's
Dart DAOs, which a browser cannot run, and because two clients writing the same
shared database must not each carry their own copy of, say, FIFO draw-down.

RPCs (not Edge Functions) were chosen so the whole operation is one atomic SQL
transaction with the strongest concurrency guarantees — the web checkout must
decrement live stock and draw down FIFO batches under a row lock and reject at
commit if stock is insufficient, which the offline LWW model never had to solve
server-side.

The shared contract between mobile and web is therefore the **database schema + the
RPC surface** — never client code.
