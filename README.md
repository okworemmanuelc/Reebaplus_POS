# Reebaplus POS

Reebaplus POS is a multi-business Point of Sale application designed for Nigerian businesses, including Bars, Beer Distributors, Restaurants, Supermarkets, Pharmacies, and Boutiques. The application features an offline-first architecture with cloud synchronization.

## Features

- **Multi-Business & Multi-Store Architecture:** Manage multiple businesses and stores from a single application.
- **Offline-First Synchronization:** Powered by a local SQLite database (Drift) and synchronized with the cloud (Supabase) to ensure the POS always works, even without an internet connection.
- **Data-Driven Roles:** Four standard roles built-in (CEO, Manager, Cashier, Stock Keeper) with completely data-driven permissions.
- **Funds Register:** Track daily balances for Cash Tills, POS machines, and Bank accounts with daily opening and closing reconciliations.
- **Inventory Management:** Track retailer prices, wholesaler prices, buying prices, and daily stock counts. Includes special empty crate tracking for Bar and Beer Distributor business types.
- **Customer & Supplier Wallets:** Built-in customer wallets for tracking credits and debts, as well as full supplier account management.
- **Hardware Integration:** Support for thermal receipt printing and barcode scanning.

## Tech Stack

- **Framework:** Flutter
- **Local Database:** Drift (SQLite)
- **Cloud Database / Auth:** Supabase
- **State Management:** Riverpod
- **Architecture:** Feature-based modular architecture

## Getting Started

### Prerequisites

- Flutter SDK (version ^3.10.7)
- Supabase Project & Configuration

### Installation

1. Clone the repository
2. Run `flutter pub get` to install dependencies
3. Set up your Supabase configuration and keys.
4. Run `flutter run` to start the application.

## Development Guidelines

Please refer to `CLAUDE.md` and `reebaplus_master_plan.md` for strict development guardrails, architectural rules, and project specifications. These documents define the core sync invariants, role access rules, and the master plan for the application's phases.
