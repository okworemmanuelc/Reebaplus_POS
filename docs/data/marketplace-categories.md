# Marketplace category reference (#472)

Migration 0190 creates a public-read, service-written catalogue and a nullable
FK on categories.marketplace_category. The bundled Dart catalogue mirrors
every seed field; a test compares all rows, order, hierarchy and restrictions.
The public catalogue is independent of Lexicon's UI starter suggestions.
Accessories has distinct phone/fashion mappings. Names are not guessed from
approximate or partial matches.

New category names pre-map only on a trimmed, case-insensitive exact match to a
public catalogue child name. Parent names and unknown names remain unmapped.
General maps to Other; Accessories maps to phone/fashion accessories only for
Phone & Gadgets/Boutique respectively. This keeps working when #503 removes
all starter suggestions. Existing custom categories remain unchanged until mapped
in Manage Categories. A rename preserves the mapping. Clearing to Other
writes an explicit null through the ordinary outbox. The till does not filter
on this optional field.

The snapshot RPC already selects to_jsonb(t) for categories, so both full and
incremental snapshots include the new column automatically. The reference
catalogue itself is compiled into the client, not tenant-synced or writable
through the outbox. Its absence from the tenant registry is intentional.

Beer, spirits and wine are age_18. Broad health groups do not establish whether
an individual medicine is prescription-only. Issue #479 must finish the
restricted-goods policy and classification before online ordering launch;
these metadata are not legal clearance.

Schema86 adds only nullable text to SQLite; the cloud FK validates the canonical
reference. Existing local rows remain valid and sellable without a mapping.
No production migration was run.

Validation: all 46 SQL seed rows match the bundled reference, including metadata;
every public child name has a non-vacuous exact-match regression. Full suite on the
original base passed 5233 tests (294 skipped). After integrating main c019ea4f,
108 focused regressions and four visual baselines pass; analyzer is clean.
The schema86 test reopens an actual v85 SQLite database and preserves its
categories. Tenant write tests verify foreign-business IDs cannot be mapped.
Final integration on main9732ed17: Drift86,132focused tests pass, analyzer clean,
and the full suite passes5424 tests (296 skipped, zero failures). The85→86
fixture also preserves a Kg product and its category link. Drift was regenerated.

Web parity follow-up:
[reebaplus-web#138](https://github.com/okworemmanuelc/reebaplus-web/issues/138).
Migration0190 was applied exclusively to reebaplus-dev on2026-10-24. Public
cloud parity passed (1 test, 0 skips), matching all46 rows and metadata.
The rollback-only SQL test at test/integration/sql/marketplace_categories_permissions.sql
confirmed six write denials (anon/authenticated × insert/update/delete), valid
mapping acceptance, unknown-slug FK rejection and explicit null clearing.
Anon/authenticated have SELECT; service_role has write grants. Fixtures rolled
back. The parity test uses explicit ascending ordering for stable pagination.
