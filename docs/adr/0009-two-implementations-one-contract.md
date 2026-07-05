# One behavioral contract, two implementations — golden-scenario suite

The same money rules (FIFO COGS draw-down, wallet/crate ledger posting, order
numbering, revenue recognition) are implemented **twice**: once in Dart DAOs for the
offline-first mobile app, once in the Postgres RPCs for the online-first web app
(ADR 0008). We accept the duplication because we cannot remove it: mobile is
offline-first and *must* compute a receipt, a stock decrement, and a COGS snapshot
locally with no server round-trip, so it can never call the live RPC at write time.
"Full parity on web" means the same rules, not one shared write path.

The anti-divergence mechanism is a **shared golden-scenario suite**: a set of
scenario fixtures (input state → expected resulting rows) run in CI against *both*
the Dart path and the SQL RPC. Any drift between the two implementations fails the
build. This is the guarantee that keeps money math identical across clients; correctness
does not rely on humans keeping two code paths in sync by hand.

Rejected: migrating mobile onto the RPCs (breaks the offline selling loop) and a
portable codegen'd math engine (heavy tooling, FIFO/ledger don't express portably).
