# Web app lives in this repo (monorepo), beside the migrations

The Next.js web app is a new top-level directory in this repository (`web-pos/`),
alongside `supabase/migrations/` and the Flutter `lib/`. The deciding factor is that
the shared mobile↔web contract is the DB schema + RPCs (ADR 0008), and those
migrations already live here. Keeping the web client in the same repo means a
contract change (a new RPC) and its web caller land in **one atomic PR**, with no
cross-repo version coordination. The web app deploys to Vercel with its project root
set to the `web-pos/` subdirectory.

Note the pre-existing `web/` directory is Flutter's own web build output — the new
app is `web-pos/` to avoid the collision. Workspace tooling (pnpm/turbo) was not set
up now; it can be introduced if more JS packages (shared types, an admin console)
later join.
