# Nigeria area reference (#471)

Verified 2026-10-23: 36 states with 768 LGAs plus six FCT area councils = 774.
`lib/core/data/nigerian_states.dart` and `nigerian_lgas.dart` are the canonical
application keys. Migration `0189_nigerian_areas.sql` seeds those exact pairs.

## Sources and reconciliation

- [Constitution, First Schedule, Parts I–II](https://faolex.fao.org/docs/pdf/nig164561.pdf),
  printed pages 215–223 (PDF pages 221–229), includes Fifth Alteration.
- [INEC state-office directory](https://www.inecnigeria.org/about/state-offices/)
  independently gives each state's count (also pinned in the unit test).
- [INEC Ondo directory](https://inecnigeria.org/wp-content/uploads/2024/04/ONDO-STATE.pdf)
  verifies all 18 Ondo areas.
- [Oyo government's LGA list](https://oyostate.gov.ng/lgas-lcdas-in-oyostate/)
  resolves the constitution edition's “Ibadan Central” to Ibadan North East.
- [INEC Ebonyi directory](https://www.inecnigeria.org/wp-content/uploads/2019/02/EBONYI-LGA.pdf)
  confirms Onicha rather than the old list's spurious “Alimo”.
- [INEC Niger directory](https://inecnigeria.org/wp-content/uploads/2024/04/NIGER-STATE.pdf)
  confirms Munya rather than “Moya” (the constitution edition prints “Muya”).

The old list had 761 entries. Changes to reach 774:

| State | Correction |
|---|---|
| Katsina | Add Dutsi and Matazu; correct Musa → Musawa |
| Kebbi | Add Augie |
| Ondo | Remove spurious Akse; add Akure North, Akure South, Ese Odo, Idanre, Ifedore |
| Osun | Add Ejigbo, Ifedayo, Ifelodun |
| Oyo | Remove spurious Imini; add Ibadan North East, North West, South East, South West |

Other clear typos corrected: Fufure → Fufore, Gayuk → Guyuk, Oturkpo → Otukpo,
Yakuur → Yakurr, Alimo → Onicha, Unuimo → Onuimo, Moya → Munya,
Emuoha → Emohua, Nasarawa Egon → Nasarawa Eggon, Kumi → Kurmi,
Wamako → Wamakko. No existing address rows are rewritten.

Keep recognised names and punctuation stable: e.g. Municipal Area Council
(Abuja Municipal), Gbonyin (Aiyekire), Kunchi (Ghari), Egbado North/South
(Yewa North/South), Afikpo North/South (Afikpo/Edda), Ilesa East/West
(Ilesha), and existing hyphen/space variants. These are keys, not an attempt
to silently rename existing addresses to every new gazette spelling. No LCDAs
are added. The source edition itself has spelling variants and an extra Yobe
“Karawa”; the INEC 17-area count excludes that duplicate/erroneous entry.

## Cloud contract

`public.ng_areas(state text, lga text)` has a composite primary key. RLS grants
anonymous and authenticated clients SELECT only. Only the service role writes.
It contains no tenant or person information. It stays cloud-only: no Drift
migration, sync registry, outbox, or app network request. The picker uses the
bundled list fully offline. Later store, delivery and shopper migrations may
validate Nigerian pairs against this reference; foreign areas remain free text.
Whole-state selection uses a null LGA in the picker result, never a fake row.

Tier-1 verifies counts/uniqueness and exact migration seed parity. Tier-2 reads
all cloud rows with pagination and compares the complete set. Deploy the
migration on a test backend before that check. Recheck sequential migration
numbering before merge/production deployment.

### Development verification (2026-10-23)

Owner approved a fresh project: `reebaplus-dev` (`yngwzuinxhxhzdfagcbg`,
eu-west-1). The public schema was empty before deployment. Applied only
migration 0189; no business data copied and no production changes.

- Actual paginated tier-2 comparison: **1 passed, 0 skipped, 0 failed**.
- Database: 774 rows, 37 state/FCT keys, RLS enabled.
- Role catalogue: anon/authenticated SELECT allowed; INSERT/UPDATE/DELETE
  denied; service_role has read/write privileges.
- Six rollback-wrapped SQL probes independently confirmed write denial for
  anon and authenticated (three operations each).

The app still uses its existing live project. Development currently contains
only this reference, not a full app backend. Test credentials are kept in the
private task scratch directory outside the repository. No secrets belong here.
