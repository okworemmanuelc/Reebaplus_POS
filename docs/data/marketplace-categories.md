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

Schema84 adds only nullable text to SQLite; the cloud FK validates the canonical
reference. Existing local rows remain valid and sellable without a mapping.
No production migration was run.
