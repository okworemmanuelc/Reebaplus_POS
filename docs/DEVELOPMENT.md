# Development guide

Everything needed to build, run, test and read the code. For what the app does, see the [README](../README.md) and [FEATURES.md](FEATURES.md).

## Contents

- [Prerequisites](#prerequisites)
- [Install and run](#install-and-run)
- [First run walkthrough](#first-run-walkthrough)
- [Tests](#tests)
- [Hardware features](#hardware-features)
- [Project structure](#project-structure)
- [Engineering rules](#engineering-rules)

## Prerequisites

- **Flutter 3.44.2 stable** (the version CI uses) with Dart SDK `^3.10.7`. Check with `flutter --version`.
- **Android Studio** with an Android SDK, plus an emulator or a physical Android phone. Android is the only supported target.
- **No Supabase project and no `.env` file.** The Supabase address and public key are in [`lib/main.dart`](../lib/main.dart). That key is meant to be public, and every table is protected by Row-Level Security on the server, so a fresh clone connects and runs as it is.

## Install and run

```bash
git clone https://github.com/okworemmanuelc/Reebaplus_POS.git
cd Reebaplus_POS
flutter pub get
flutter run
```

If you change anything under `lib/core/database/` (tables or data access classes), regenerate the Drift code:

```bash
dart run build_runner build --delete-conflicting-outputs
```

## First run walkthrough

There is no sample data or test account. You create your own business through the app, which is also the quickest way to learn it.

1. On the Welcome screen, tap **Create a new business**.
2. Enter a business name and pick a type. **Beverage distributor** covers the most features, including crates. Fill in your first store; the currency is set from the country.
3. Enter your name and a real email address. A 6-digit code is sent to it.
4. Create and confirm a 6-digit PIN. You arrive on Home as the CEO, with the four default roles and your first store set up.
5. Open **Inventory** and add two or three products, then go to **Point of Sale** and make a sale.
6. Turn off the device's network and sell again. The sale completes on the phone and is sent once you reconnect.

To try the staff side, open **Staff Management**, tap **Invite new staff**, generate an invite code, and redeem it on a second device or emulator with a different email.

## Tests

```bash
flutter test      # the full suite; runs offline
flutter analyze   # must report zero errors and zero warnings
```

Most tests need nothing but a clone. A second group checks the checkout money rules against a real Supabase project and **skips itself automatically** unless these three values are set:

```bash
# .envrc (already gitignored, never commit it)
export TEST_SUPABASE_URL=...
export TEST_SUPABASE_ANON_KEY=...
export TEST_SUPABASE_SERVICE_ROLE_KEY=...
```

Fill them in from your own Supabase project, then run `direnv allow` (or `source .envrc`).

### Golden scenarios in CI

The [golden-scenarios workflow](../.github/workflows/golden-scenarios.yml) runs on every push to `main` and every pull request. It feeds the same cash-sale examples through both versions of the checkout logic, the Dart code on the phone and the SQL function on the server, and fails the build if their results differ in any field. The server half only runs when the `TEST_SUPABASE_*` secrets are configured.

## Hardware features

Both need real hardware, and neither blocks the rest of the app.

- **Barcode scanning** uses the camera. An emulator's virtual camera will not read real barcodes reliably, so test on a physical phone.
- **Receipt printing** needs a Bluetooth ESC/POS thermal printer paired with the phone. Without one, the receipt screen still shows and **Share** still works, so you can check a receipt's contents without printing.

## Project structure

```
lib/
├── main.dart          # startup, crash protection, and which screen you land on
├── core/
│   ├── database/      # Drift tables, data access, migrations, the sync outbox; the only SQL in the app
│   ├── services/      # Supabase client and the sync engine (send, receive, retry, conflicts)
│   ├── permissions/   # every "can this user do X" decision is answered here
│   ├── costing/       # first-in, first-out stock costing and cost of goods
│   ├── crates/        # empty-crate ledgers and the empties pool
│   ├── industry/      # wording and feature switches per business type
│   └── theme/ providers/ utils/ widgets/
├── features/          # one folder per area: auth, customers, dashboard, deliveries,
│                      # diagnostics, expenses, inventory, orders, payments, pos,
│                      # profile, receiving, settings, staff, stores, subscription,
│                      # sync, van_sales
└── shared/            # app shell, navigation, and widgets used everywhere

supabase/
├── migrations/        # server database changes, applied in order
└── functions/         # Edge Functions: send-invite-email, send-push,
                       # reconcile-account-deletions
```

For a deeper tour, [CODEBASE_MAP.md](CODEBASE_MAP.md) walks every screen and [LEARNING_ROADMAP.md](LEARNING_ROADMAP.md) suggests a reading order. Decision records in [adr/](adr/) explain why things are built the way they are.

## Engineering rules

Before changing anything, read [CLAUDE.md](../CLAUDE.md), [AGENTS.md](../AGENTS.md) and the files in [CONTEXT/](../CONTEXT/). These rules are not about style. Breaking one produces code that compiles and seems to work while quietly corrupting money or sync.

1. **The phone's database is the source of truth.** Every screen reads from Drift. Nothing waits on the network or reads Supabase to draw a screen.
2. **Every cloud write goes through the outbox.** Write to Drift, then queue a sync entry. Calling Supabase directly is only allowed in a few approved places.
3. **PINs never leave the device.** Not in the database, not in a log, not in a request.
4. **Ledgers are add-only.** Balances are totals of rows. A correction is a new balancing row, never an edit.
5. **Money is whole kobo.** Never a decimal naira amount.
6. **Permissions come from data.** Ask the permission check; never test for a role name in code.
7. **The server decides which business a row belongs to.** Row-Level Security on `business_id` is the authority; the app is never trusted to limit its own queries.
8. **Opening the app never waits on a download.** No full-screen loader may keep a signed-in user out.
9. **`flutter analyze` must be clean** (zero errors, zero warnings) before anything is committed.
