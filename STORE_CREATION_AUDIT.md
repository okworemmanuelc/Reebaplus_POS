# Store creation — end-to-end audit

**Date:** 2026-09-08
**Scope:** every path that creates or edits a `stores` row, from CEO onboarding
through Settings → Stores, plus the cloud RPC and the sync round-trip.
**Trigger:** users report they find it difficult to create a store during onboarding.

---

## 1. Where stores come from

There are **four** surfaces that write a `stores` row, and they do **not** agree
with each other.

| # | Surface | File | Writes via | Address fields collected |
|---|---------|------|-----------|--------------------------|
| 1 | CEO onboarding, step 3 "Your first store" | [ceo_sign_up_screen.dart:889](lib/features/auth/screens/ceo_sign_up_screen.dart#L889) | `complete_onboarding` RPC + local mirror | Street, **Country, State/Region, LGA/District** |
| 2 | Stores screen → "New Store" sheet | [stores_screen.dart:67](lib/features/stores/screens/stores_screen.dart#L67) | **raw `db.into(db.stores).insert`** + `enqueueUpsert` | Street, Country, State/Region, LGA (optional) |
| 3 | Stores screen → "Edit Store" sheet | [stores_screen.dart:331](lib/features/stores/screens/stores_screen.dart#L331) | raw `db.update(db.stores)` + `enqueueUpsert` | same as #2, parsed back out of the fused string |
| 4 | Settings → Stores (also registers vans) | [stores_settings_screen.dart:135](lib/core/settings/stores_settings_screen.dart#L135) | `StoresDao.createStore` / `updateStore` | **one free-text "location" box** |

`stores` itself is tiny — [app_database.dart:172](lib/core/database/app_database.dart#L172):

```
id, business_id, name, location (nullable TEXT), kind ('store' | 'van'),
is_deleted, created_at, last_updated_at
```

There is **no** street / state / country / phone column. Everything the four
surfaces collect is fused into the single `location` string, comma-separated.

---

## 2. The onboarding path, step by step

1. **Entry.** `CeoSignUpScreen._bootstrap()`
   ([ceo_sign_up_screen.dart:215](lib/features/auth/screens/ceo_sign_up_screen.dart#L215))
   requires network (`_ensureOnline`), **wipes the local database**
   (`db.clearAllData()`), starts a fresh `OnboardingDraft`, and pre-fills the
   phone box with `+234`.
2. **Collect-first / commit-once.** Steps 1–8 write only into
   [`OnboardingDraft`](lib/features/auth/onboarding/onboarding_draft.dart) — an
   in-memory Riverpod object. `businessId`, `storeId` and `userId` are minted
   client-side at draft creation so a retry is idempotent. Nothing reaches
   Supabase until Confirm PIN.
3. **Step 3 validation** — `_submitStoreDetails()`
   ([:317](lib/features/auth/screens/ceo_sign_up_screen.dart#L317)) requires, in
   order: store name ≥ 2 chars → phone ≥ 8 digits → street address → **State /
   Region** → **Local Government / District**. All five are hard-required.
4. **Fuse.** `OnboardingDraft.locationCombined`
   ([:63](lib/features/auth/onboarding/onboarding_draft.dart#L63)) joins
   `street, lga, state, country`.
5. **Commit** — `AuthService.completeOnboarding()`
   ([auth_service.dart:1729](lib/shared/services/auth_service.dart#L1729)) calls
   the `complete_onboarding` RPC, then mirrors `businesses` + `stores` + `users`
   into Drift in one transaction, then blocks on up to 3 pulls until the CEO's
   role binding lands locally.
6. **Cloud** — `public.complete_onboarding`
   ([0123_business_tracks_empty_crates.sql](supabase/migrations/0123_business_tracks_empty_crates.sql))
   upserts `businesses`, `profiles`, `stores`, `settings`, `users`, seeds the 5
   default roles + permissions, and binds the CEO to the business and to the
   store. All of it `ON CONFLICT DO UPDATE`, so a retry converges.

---

## 3. Why it is hard to create a store — 7 verified defects

### D1 — Typing in the Country box silently erases the phone number
[ceo_sign_up_screen.dart:952-961](lib/features/auth/screens/ceo_sign_up_screen.dart#L952-L961)

```dart
onChanged: (v) => setState(() {
  _countryValue = v;
  ...
  final dialCode = kCountryDialCodes[v] ?? '';
  _storePhoneCtrl.text = dialCode;   // ← unconditional overwrite
}),
```

`AutocompleteField.onChanged` fires on **every keystroke**, not just on picking a
suggestion. So the moment the user touches the Country field after entering the
phone number, the phone box is overwritten — and while the typed country is a
partial string (`"Nig"`), `kCountryDialCodes` misses and the box is set to the
**empty string**. The user then taps Continue and gets *"Enter a valid phone
number (at least 8 digits)"* pointing at a field they already filled in.

The staff sign-up screen guards the same line with `if (dialCode.isNotEmpty)`
([staff_sign_up_screen.dart:1170](lib/features/auth/screens/staff_sign_up_screen.dart#L1170))
— onboarding does not. This is the single most likely cause of the reports.

### D2 — "District (optional)" is required
For any country other than Nigeria the LGA field is labelled **"District
(optional)"** ([:1006](lib/features/auth/screens/ceo_sign_up_screen.dart#L1006))
but `_submitStoreDetails` still rejects an empty value with *"Enter the Local
Government / District."* ([:345](lib/features/auth/screens/ceo_sign_up_screen.dart#L345)).
A Ghanaian or Kenyan user is blocked by a field the UI told them to skip. Same
bug in staff sign-up ([staff_sign_up_screen.dart:521](lib/features/auth/screens/staff_sign_up_screen.dart#L521)).

### D3 — Editing Country wipes State and LGA with no warning
Every keystroke in Country resets `_stateValue`, `_lgaValue` and both plain-text
controllers. Because `isNigeria` is an exact match on the *full* string
(`_countryValue.trim().toLowerCase() == 'nigeria'`), typing "Nigeria" one letter
at a time swaps the State and LGA widgets between Autocomplete and plain
TextField repeatedly, destroying their contents each time. Fill the form
bottom-up and you lose everything below Country.

### D4 — The LGA the user is forced to enter is thrown away on the first sync
The client fuses **four** parts (`street, lga, state, country`) but the RPC
payload only carries three
([auth_service.dart:1759-1764](lib/shared/services/auth_service.dart#L1759-L1764)):

```dart
'p_location': {'name': …, 'street': …, 'city': draft.cityState, 'country': …},
```

and the cloud rebuilds the string from `street, city, country`
([0123 §3](supabase/migrations/0123_business_tracks_empty_crates.sql)). So:

* local Drift row → `"14 Market Road, Eti-Osa, Lagos, Nigeria"`
* cloud row → `"14 Market Road, Lagos, Nigeria"`

`stores` is a synced table with a plain PK-keyed upsert restore
([sync_registry.dart:544](lib/core/database/sync_registry.dart#L544)), so the
**next pull overwrites the local row and the LGA disappears**. Users are being
made to fill a mandatory field whose value is discarded minutes later.

### D5 — Free text is accepted as a "dropdown" value
`AutocompleteField` ([auth_form_kit.dart:154](lib/features/auth/widgets/auth_form_kit.dart#L154))
is a suggestion list, not a constrained picker — `onChanged` is wired straight to
the TextField. Validation only checks non-empty. `"lagos"`, `"Lag"`, and
`"Lagoss"` all pass. The dropdowns buy no data quality; they only cost taps.
A partial country also silently downgrades the currency to the NGN default
(`currencyForCountry` returns `kDefaultCurrency` on a miss).

### D6 — The keyboard covers the form
`CeoSignUpScreen` sets `resizeToAvoidBottomInset: false`
([:742](lib/features/auth/screens/ceo_sign_up_screen.dart#L742)) and the step is
six fields deep. `AuthFormShell` centres content and only adds bottom padding,
so when the keyboard opens nothing scrolls into view automatically. The Country
autocomplete's 220px suggestion overlay opens *below* the field — i.e. behind
the keyboard — on the bottom half of the form.

### D7 — The field is called "Store phone" but is saved as the business phone
`_submitStoreDetails` writes `d.businessPhone = formattedPhone`
([:351](lib/features/auth/screens/ceo_sign_up_screen.dart#L351)). `stores` has no
phone column; the value lands on `businesses.phone`. Not a blocker, but the
label is wrong.

---

## 4. Secondary findings (not blocking, worth knowing)

* **Post-onboarding "New Store" sheet bypasses the DAO.** [stores_screen.dart:288-300](lib/features/stores/screens/stores_screen.dart#L288-L300)
  does a raw `db.into(db.stores).insert` instead of `StoresDao.createStore`,
  so it skips the business-scoping invariant, never sets `kind`, and writes no
  activity-log entry. Two of the four store-creation surfaces therefore behave
  differently. (Not fixed in this pass — flagged for a follow-up.)
* **Permission chain is healthy.** `stores.manage` is seeded both locally
  (Drift v38, [app_database.dart:4385](lib/core/database/app_database.dart#L4385))
  and in the cloud ([0095](supabase/migrations/0095_add_stores_manage_permission.sql)),
  and `seed_default_roles_for_business` grants the CEO **every** key
  ([0161](supabase/migrations/0161_van_sales_prefactor.sql)). Permissions are not
  the cause of the onboarding difficulty.
* **The write boundary in the New/Edit Store sheets fails silently.** If
  `stores.manage` is missing, the Save button `return`s with no message
  ([:275](lib/features/stores/screens/stores_screen.dart#L275),
  [:557](lib/features/stores/screens/stores_screen.dart#L557)) — nothing happens
  and the sheet stays open. Every other write site in the app calls
  `showGateDenied`.
* **No widget test covers the onboarding store step.** `test/auth/` has tests for
  role binding, PIN scoping and the staff sign-up screen, but nothing exercises
  step 3 of the CEO wizard.
* **Onboarding is online-only and destructive on entry.** `_bootstrap` calls
  `db.clearAllData()` before anything is collected, so backing out of the wizard
  leaves the device with an empty local database.

---

## 5. Change requested: collect Country + Address only

**Decision:** drop the State/Region and LGA/District pickers from onboarding.
The address becomes `street, country`.

This removes D2, D3 and D5 outright, and D4 becomes impossible because client
and cloud now build the identical two-part string (the RPC's `city` key is sent
as null, and `concat_ws` skips nulls — **no cloud migration is needed**).

Applied to:

1. **`OnboardingDraft`** — `lgaDistrict` and `cityState` removed;
   `locationCombined` → `street, country`.
2. **CEO onboarding step 3** — Store name, Store phone, Street address, Country.
   Plus a fix for D1: changing country now **re-prefixes** the existing local
   number instead of wiping it.
3. **Staff sign-up address step** — Street address + Country (same two dropdowns
   removed; same required-but-labelled-optional bug gone).
4. **New Store / Edit Store sheets** — Street address + Country. The Edit sheet's
   parser had to change too: with a 2-part location the old code put the
   **country into the State box**. It now reads segment 0 as street and the last
   segment as country, so legacy 3-part and 4-part rows still open correctly
   (the dropped middle segments are simply not re-collected).

**Backward compatibility.** Existing rows keep their 3- and 4-part strings until
someone edits them; nothing reads the middle segments. `receiptStoreAddress`
([store_address.dart](lib/core/utils/store_address.dart)) drops the trailing
country segment and is unchanged — a 2-part `"14 Market Road, Nigeria"` correctly
renders as `"14 Market Road"` on receipts, which its existing test already covers.

`kNigerianStates` / `kNigerianLgas` are left in the repo but are now unreferenced
by any screen.
