# Brief: Email-first CEO onboarding

## Summary

"Create a new business" (Welcome screen) currently asks for the email **5th of
9 steps** — after business name, type, full store form, and full name — and has
**no check** for an email that's already linked to a business. The conflict only
surfaces at the final `completeOnboarding` commit (after the user has set + confirmed
a PIN), or not at all. This violates the "one email, one business" invariant
(`CONTEXT/architecture.md` Invariant #9) and is a late-stage blocking error on
maximal sunk effort.

Fix: make "Create a new business" **email-first**, reusing the machinery the
"Sign in" path already has. Verify the email up front; redirect an
already-registered email to sign in; send a brand-new verified email straight
into the existing 7-step `CeoSignUpScreen(verifiedEmail:)` flow (which already
skips email + OTP).

**Do not build new screens or a new RPC.** Everything needed already exists; this
is a rewiring + one new boolean flag. Approach was chosen by the user
("Email-first, reuse Path B").

## Background (read these first)

- `lib/features/auth/screens/welcome_screen.dart` — the "Create a new business"
  CTA currently pushes `CeoSignUpScreen()` (the 9-step flow). This is the only
  thing that routes to the email-collecting 9-step path.
- `lib/features/auth/screens/ceo_sign_up_screen.dart` — `verifiedEmail == null`
  runs 9 steps (collects email at step 4 + OTP at step 5); `verifiedEmail != null`
  runs 7 steps (email/OTP skipped). Header comment admits the
  "email already linked to another business" branch is **deferred**.
- `lib/features/auth/screens/email_entry_screen.dart` — the "Sign in" entry.
  Collects email, sends OTP, pushes `OtpVerificationScreen`. Also has a Google
  sign-in path that resolves routes inline via `resolvePostVerifyRoute`.
- `lib/features/auth/screens/otp_verification_screen.dart` — verifies the OTP,
  then routes via `resolvePostVerifyRoute` (`auth_post_verify_route.dart`):
  - `ExistingAccountRoute` → `ExistingAccountScreen` ("this email already has a
    business — continue / use a different email"). **This is the conflict
    notification we want.**
  - `NoAccountFoundRoute` → `NoAccountFoundScreen` (brand-new email).
  - `LoginRoute` / `CreatePinRoute` → local user already exists on this device.
- `lib/features/auth/screens/no_account_found_screen.dart` — its
  "Create a new business" button already pushes
  `CeoSignUpScreen(verifiedEmail: email)`. Confirms the verified-email handoff
  works today.

## Tasks

- [ ] **Add `createBusinessIntent` flag to `EmailEntryScreen`.**
  - New field: `final bool createBusinessIntent;`, default `false`, added to the
    constructor. Add a doc comment explaining it's the "Create a new business"
    entry point (email verified up front to catch already-registered emails).
- [ ] **Pass the flag into the OTP screen.** In `EmailEntryScreen._submit`, where
  it pushes `OtpVerificationScreen(user: localUser, email: email)`, also pass
  `createBusinessIntent: widget.createBusinessIntent`.
- [ ] **Add `createBusinessIntent` flag to `OtpVerificationScreen`.** Same field
  + constructor default `false`.
- [ ] **Route brand-new verified email to CEO sign-up in `OtpVerificationScreen._submit`.**
  In the `switch (route)`, change the `NoAccountFoundRoute()` arm to:
  ```dart
  NoAccountFoundRoute() => widget.createBusinessIntent
      ? CeoSignUpScreen(verifiedEmail: widget.email)
      : NoAccountFoundScreen(email: widget.email),
  ```
  Add the `ceo_sign_up_screen.dart` import. Leave `ExistingAccountRoute`,
  `LoginRoute`, `CreatePinRoute` arms unchanged — they already do the right
  thing (existing account → sign in; existing local user → PIN/login).
- [ ] **Mirror the same redirect in the Google path.** In
  `EmailEntryScreen._signInWithGoogle`, the inline route switch has the same
  `NoAccountFoundRoute() => NoAccountFoundScreen(email: email)` arm — apply the
  identical `createBusinessIntent` conditional there so Google sign-up on the
  create path also lands in `CeoSignUpScreen(verifiedEmail: email)`. Add the
  import to `email_entry_screen.dart`.
- [ ] **Repoint the Welcome CTA.** In `welcome_screen.dart`, change the
  "Create a new business" button from `_push(const CeoSignUpScreen())` to
  `_push(const EmailEntryScreen(createBusinessIntent: true))`. Remove the now-unused
  `ceo_sign_up_screen.dart` import (analyzer will flag it).
- [ ] **(Optional polish) Intent-aware title/subtitle in `EmailEntryScreen`.**
  When `createBusinessIntent` is true, the `AuthFormShell` title/subtitle
  currently read "Sign in" / "Enter your email to continue." Consider
  "Create your business" / "First, confirm your email — we'll check it isn't
  already linked to a business." Keep it minor; not required for correctness.

## Out of scope (do NOT do)

- Do **not** delete or refactor the dead 9-step branches inside
  `ceo_sign_up_screen.dart` (the `verifiedEmail == null` path). After this change
  nothing routes to it, but ripping out the step-4/5 bodies touches step indices,
  back-nav, and the `_displayStep` dot mapping — meaningful regression risk.
  Leave it; flag a separate follow-up if you want.
- Do not add a new RPC, migration, or pre-flight "is email taken" lookup — the
  OTP + `resolvePostVerifyRoute` already establishes identity and detects the
  existing account.

## Verify

- [ ] `flutter analyze` on the 3 touched files is clean (no unused imports).
- [ ] Run on the Android emulator (`flutter run` — **no APK builds**):
  - Welcome → "Create a new business" now lands on the email screen FIRST.
  - **Brand-new email:** email → OTP → goes straight into the business-name
    step (7-step CEO flow), no "No account found" interstitial.
  - **Already-registered email** (use a seeded account's email): email → OTP →
    `ExistingAccountScreen` ("we found an existing account…"), before any
    business details are collected. User can sign in or use a different email.
  - The "Sign in" entry on Welcome is unchanged (still shows
    `NoAccountFoundScreen` for a brand-new email, since `createBusinessIntent`
    is false there).
- [ ] After it works, add a dated `BUILD_LOG.md` entry (house rule).

## Notes / gotchas

- `email_entry_screen.dart` and `otp_verification_screen.dart` already show as
  modified (`git status`) from parallel work — that's not yours. Re-verify their
  current state before editing; don't `git checkout` them.
- `CeoSignUpScreen._bootstrap` calls `db.clearAllData()` and requires an online
  connection — that's expected and unchanged; the `verifiedEmail` path already
  handles it.
- The `verifiedEmail` path keeps the Supabase session alive across
  `clearAllData()` (session lives in the SDK, not Drift), so the final
  `complete_onboarding` commit still works.
