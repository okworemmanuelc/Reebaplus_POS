# Marketplace category reference (#472)

Migration 0190 creates a public-read, service-written catalogue and a nullable
FK on categories.marketplace_category. The bundled Dart catalogue mirrors
every seed field; a test compares all rows, order, hierarchy and restrictions.
The initial names come from the existing Lexicon starter categories, grouped
under broad public parents. Accessories has distinct phone/fashion mappings.
Custom categories are not guessed from approximate name matches.

New categories created from exact Lexicon suggestions are pre-mapped for their
business industry. Existing custom categories remain unchanged until mapped
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

Schema85 adds only nullable text to SQLite; the cloud FK validates the canonical
reference. Existing local rows remain valid and sellable without a mapping.
No production migration was run.

Validation: all 46 SQL seed rows match the bundled reference, including metadata;
all industry starter suggestions resolve to a valid slug. Full suite on the
original base passed 5233 tests (294 skipped). After integrating main c019ea4f,
108 focused regressions and four visual baselines pass; analyzer is clean.
The schema85 test reopens an actual v84 SQLite database and preserves its
categories. Tenant write tests verify foreign-business IDs cannot be mapped.

Web parity follow-up:
[reebaplus-web#138](https://github.com/okworemmanuelc/reebaplus-web/issues/138).
The public cloud parity integration test remains pending until0190 is applied
to the isolated development backend.
