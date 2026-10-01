# Reebaplus POS

[![Platform: Android](https://img.shields.io/badge/platform-Android-3DDC84?logo=android&logoColor=white)](#current-status)
[![Flutter 3.44.2](https://img.shields.io/badge/Flutter-3.44.2-02569B?logo=flutter&logoColor=white)](https://docs.flutter.dev/release/archive)
[![Golden scenarios](https://github.com/okworemmanuelc/Reebaplus_POS/actions/workflows/golden-scenarios.yml/badge.svg)](https://github.com/okworemmanuelc/Reebaplus_POS/actions/workflows/golden-scenarios.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

An offline-first Android point-of-sale app for Nigerian distributors and shops that share one till across several staff. Built for beverage distributors, pharmacies, and frozen foods and grocery businesses, where empty crates, customer credit, and supplier debt matter as much as the sales themselves.

**In daily use by 16 businesses across 22 stores, with over ₦86 million in transactions recorded.**

## Contents

- [Why it exists](#why-it-exists)
- [What it does](#what-it-does)
- [Current status](#current-status)
- [Quick start](#quick-start)
- [Tech stack](#tech-stack)
- [Documentation](#documentation)
- [Contributing](#contributing)
- [License and contact](#license-and-contact)

## Why it exists

Most POS software assumes the internet stays up and that a shop only needs to track what was sold. Neither is true for a Nigerian distributor.

- **It keeps selling when the network drops.** Every sale is saved on the phone first and sent to the cloud, and to every other device in the business, once a connection returns. Opening the app never waits on the network.
- **It tracks the money that isn't sales.** Empty crates a customer still owes, empties owed to suppliers, crate deposits, customer credit and debt limits, and supplier invoices are all proper records, not notes.
- **It knows who is at the till.** Each staff member unlocks with their own 6-digit PIN, and the device locks itself after a period of inactivity.
- **The owner sets the rules.** Who can give discounts, see totals, or approve stock changes is a switch in Settings, not an app update.

Correctness is built in rather than left to habit. Money is stored in whole kobo so rounding cannot lose any. Ledgers are never edited, only added to, so two devices can never disagree about a balance. Profit uses first-in, first-out stock costing, so it reflects what the stock actually cost.

## What it does

| Area | Highlights |
|---|---|
| **Selling** | Product grid with retail and wholesale prices, barcode scanning, per-line discounts capped by role, saved carts, cash, transfer or credit checkout, Bluetooth receipt printing |
| **Stock** | Receive stock against supplier invoices, low-stock and expiry alerts, daily stock counts, approved adjustments, transfers between stores |
| **Money owed** | Customer credit with debt limits, supplier ledgers, empty-crate tracking per customer, supplier, store and manufacturer |
| **Oversight** | Role-based reports (daily reconciliation, supplier accounts, crate deposits, profit), expense approvals and budgets, activity logs, four default roles with per-staff permissions |
| **Reliability** | Fully offline, live sync between devices, resumes after the app is closed, unsynced work can never be silently wiped, crashes never blank the till mid-sale |

The full feature list is in [docs/FEATURES.md](docs/FEATURES.md).

## Current status

In production on Android as `com.reebaplus.pos`, version 1.0.8+8.

**Worth knowing upfront:**

- **Android only.** The iOS, web and desktop folders are Flutter defaults and are not supported targets. Tablets get a wider layout.
- **Three business types can be chosen at sign-up:** Beverage distributor, Pharmacy, and Frozen Foods and Grocery. Others exist in code but are not yet selectable.
- **One email, one business.** There is no switching between businesses.
- **Logging out clears the phone's local data**, which downloads again on next sign-in. Unsynced work blocks this rather than being lost.
- **Van sales is built but switched off** until it has been tested on the road.

Every known limit is listed in [docs/FEATURES.md](docs/FEATURES.md#known-limits). A separate online-first web client lives in its own repository; this repository is the mobile app.

## Quick start

You need Flutter 3.44.2 (stable) and an Android emulator or phone. No Supabase project or `.env` file is needed: the app ships with its public connection details, and every table is protected on the server.

```bash
git clone https://github.com/okworemmanuelc/Reebaplus_POS.git
cd Reebaplus_POS
flutter pub get
flutter run
```

On first launch, tap **Create a new business**, choose **Beverage distributor** (it exercises the most features), and sign up with an email address you can open, since a one-time code is sent to it. Add a few products in **Inventory**, then ring up a sale in **Point of Sale**. Turn off the network and sell again to see the offline path.

Running tests, regenerating database code, hardware setup and project structure are covered in [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md).

## Tech stack

| Layer | Used |
|---|---|
| App | Flutter and Dart (SDK `^3.10.7`), Riverpod for state |
| On-device database | Drift over SQLite, 66 tables |
| Cloud | Supabase: Postgres with Row-Level Security, Auth, Realtime, Storage, SQL functions, 3 Edge Functions |
| Sign-in | Email one-time code or Google, plus a device-only PIN and optional fingerprint |
| Hardware | `mobile_scanner` for barcodes, `print_bluetooth_thermal` and `esc_pos_utils_plus` for receipts |
| Push | Firebase Cloud Messaging with `flutter_local_notifications` |

## Documentation

| Document | What's in it |
|---|---|
| [docs/FEATURES.md](docs/FEATURES.md) | Every feature, area by area, and every known limit |
| [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) | Setup, tests, hardware, project structure, and the rules the code must follow |
| [docs/CODEBASE_MAP.md](docs/CODEBASE_MAP.md) | A walk through every screen |
| [docs/LEARNING_ROADMAP.md](docs/LEARNING_ROADMAP.md) | A suggested order for reading the code |
| [docs/adr/](docs/adr/) | Decision records explaining why things are built the way they are |

## Contributing

**Issues are welcome; pull requests are not being accepted right now.** To report a bug or suggest something, open an issue on [the tracker](https://github.com/okworemmanuelc/Reebaplus_POS/issues) saying what you did, what you expected, and what happened.

Anyone reading or changing the code, including with an AI agent, should start with [CLAUDE.md](CLAUDE.md), [AGENTS.md](AGENTS.md) and the [CONTEXT/](CONTEXT/) folder, then read the [engineering rules](docs/DEVELOPMENT.md#engineering-rules). Breaking one of those rules produces code that compiles and seems to work while corrupting money or sync.

## License and contact

Licensed under the [MIT License](LICENSE).

- **Bugs and feature requests:** [GitHub Issues](https://github.com/okworemmanuelc/Reebaplus_POS/issues)
- **Business enquiries, screenshots, or a live walkthrough:** okworchimezie@gmail.com
