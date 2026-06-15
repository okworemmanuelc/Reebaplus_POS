# Reebaplus POS — Code Standards

This document defines how code is written in this project.
Every rule is stated as a rule, not a preference.
Two developers reading this file must make the same decision independently.
When a rule conflicts with a framework default, this document wins.

---

## General

- Every file, class, and function has exactly one reason to change. If you cannot name the single responsibility of a unit in one sentence, split it.
- Fix root causes. Do not add a conditional to paper over a state problem, a null check to suppress a type error, or a retry to hide a logic bug.
- Do not mix unrelated concerns in one file. A widget file contains widgets. A DAO file contains queries. A repository file contains the decision of where data lives. If a file is doing two of those things, it is wrong.
- Delete code that is no longer reachable. Dead code is not documentation; it is noise that misleads the next reader.
- Do not leave `TODO` comments without an associated issue number. `// TODO(#42): remove after onboarding gate ships` is allowed. `// TODO: fix this later` is not.
- All user-facing strings live in ARB files under `lib/l10n/`. No string literal that appears in the UI may be written directly in a widget. Access strings via `context.l10n.<key>`.

---

## Dart

### Types and nullability

- Enable sound null safety throughout. The analysis_options.yaml enforces this; do not suppress it.
- Declare variables as non-nullable by default. Add `?` only when null is a meaningful, handled state — not because you are unsure whether the value might be null.
- Never use `dynamic`. Use the narrowest concrete type, a sealed class, or a generic. If the type is genuinely unknown at the boundary (e.g. JSON from Supabase), decode it immediately into a typed model before it enters any logic.
- Never use `Object?` as a return type or parameter type to avoid deciding. Name the type.
- Use `final` for every local variable and field that is not reassigned. Use `const` wherever the value is known at compile time.
- Prefer named parameters for any function with more than one parameter. Positional parameters are allowed only for single-argument functions and well-established Flutter patterns (`build(BuildContext context)`).

```dart
// Correct
CartItem({required this.productId, required this.quantity, required this.unitPrice});

// Wrong — caller cannot tell what true means
CartItem(productId, 3, true);
```

### Enums and sealed classes

- Use Dart `enum` for a fixed, closed set of values with no associated data.
- Use `sealed class` (Dart 3+) for a fixed set of variants that each carry different data. This is the correct type for operation results, sync states, payment methods, and permission outcomes.

```dart
// Correct — sealed class for result with data
sealed class SyncResult {}
final class SyncSuccess extends SyncResult { final int rowsApplied; ... }
final class SyncFailure extends SyncResult { final String reason; ... }
final class SyncOffline extends SyncResult {}

// Wrong — stringly typed
String syncResult = 'success';
```

- Never add a `default` branch to a `switch` on a sealed class or enum. The compiler exhaustiveness check is the safety net; a `default` silences it.

### Error handling

- Repositories return `Result<T, AppError>` from `lib/core/result.dart` — never throw across a layer boundary. Callers must handle both arms.
- Only `lib/sync/` and `lib/core/` may catch `Exception` broadly. Feature code catches only the specific exception types it can meaningfully recover from.
- The global error handler in `lib/core/` is the last resort for uncaught errors. It shows the calm fallback screen, preserves cart state, and writes to `crash_logs` via the outbox. Do not replicate this logic elsewhere.
- Never swallow an error silently. Every `catch` block either returns a `Failure` result, logs to the crash handler, or rethrows. An empty `catch` block is a build failure.

```dart
// Correct
try {
  await _repo.saveOrder(order);
} on DriftDatabaseException catch (e) {
  return Result.failure(AppError.localWrite(e));
}

// Wrong — silent swallow
try {
  await _repo.saveOrder(order);
} catch (_) {}
```

### Formatting and style

- Line length limit: **100 characters**. The analysis_options.yaml enforces this.
- Use `dartfmt` (via `dart format`) before every commit. CI rejects unformatted code.
- One class per file. One Drift table definition per file inside `lib/data/local/tables/`.
- Trailing commas on all multi-line argument lists and parameter lists. This keeps `dart format` diffs clean.

---

## Flutter

### Widget rules

- Every UI component is a `StatelessWidget` subclass with a named class. Helper methods that return `Widget` are not allowed — extract a new named widget class instead.

```dart
// Correct
class CartLineItem extends StatelessWidget {
  const CartLineItem({super.key, required this.item});
  final CartItem item;
  @override Widget build(BuildContext context) { ... }
}

// Wrong — anonymous private method
Widget _buildCartLineItem(CartItem item) { ... }
```

- A widget's `build` method contains only layout and composition. It does not compute values, call repositories, or contain business logic. Move any computation to a provider or view model.
- Pass only the data a widget needs. Do not pass a full model to a widget that uses one field. Derive and pass the field.
- Use `const` constructors wherever all fields are compile-time constants. Mark widgets `const` at call sites when possible.
- Never call `setState` — there is no `StatefulWidget` in this codebase. All mutable state lives in Riverpod providers.

### ConsumerWidget and providers

- Widgets that read Riverpod state extend `ConsumerWidget`, not `StatelessWidget`.
- Call `ref.watch` for state the widget must rebuild on. Call `ref.read` inside callbacks (tap handlers, form submissions) where you need the current value once without subscribing.
- Never call `ref.watch` inside a callback or conditional — only at the top level of `build`.

```dart
// Correct
@override
Widget build(BuildContext context, WidgetRef ref) {
  final cart = ref.watch(cartProvider);
  return Text('${cart.itemCount} items');
}

// Wrong — watch inside callback
onTap: () {
  final cart = ref.watch(cartProvider); // runtime error
}
```

- Providers are defined at the top level of their feature's provider file, never inside a class or function.
- Use `AsyncNotifierProvider` for operations that load data. Use `NotifierProvider` for synchronous state machines. Use `Provider` for pure derivations with no side effects.

### Navigation

- Use named routes defined in `lib/core/router.dart`. Do not push routes by constructing widget instances directly.
- Do not pass large objects through route arguments. Pass an ID; the destination screen reads from its provider.

---

## Naming

### Files and folders

- File names: `snake_case.dart` always.
- Folder names: `snake_case` always.
- One class per file; the file name matches the class name in snake_case.

| Class name | File name |
|---|---|
| `CartLineItem` | `cart_line_item.dart` |
| `OrderRepository` | `order_repository.dart` |
| `SyncOutboxDao` | `sync_outbox_dao.dart` |
| `ProductsTable` | `products_table.dart` |

### Classes

- Widgets: `PascalCase`, noun or noun phrase describing what is shown. No `Widget` suffix.
  - Correct: `CartSummaryCard`, `CheckoutPaymentSelector`, `ReceiptShareSheet`
  - Wrong: `CartWidget`, `CheckoutView2`, `MyCard`
- Providers: `camelCase` + `Provider` suffix for the provider, `camelCase` + `Notifier` for the notifier class.
  - Correct: `cartProvider`, `CartNotifier`, `syncProgressProvider`
  - Wrong: `CartProviderClass`, `cart_provider`
- Repositories: `PascalCase` + `Repository` suffix.
  - Correct: `OrderRepository`, `CustomerRepository`
  - Wrong: `OrderRepo`, `Orders`
- DAOs: `PascalCase` + `Dao` suffix.
  - Correct: `SyncOutboxDao`, `ProductsDao`
- Drift table classes: `PascalCase` + `Table` suffix.
  - Correct: `ProductsTable`, `WalletLedgerTable`
- Drift companion / data classes are auto-generated; do not rename them.
- Edge Function modules (Deno/TypeScript): `kebab-case` file names matching the function name in Supabase.

### Variables and functions

- Variables and function names: `camelCase`.
- Boolean variables and getters: prefix with `is`, `has`, `can`, or `should`.
  - Correct: `isOffline`, `hasUnsyncedChanges`, `canApplyDiscount`
  - Wrong: `offline`, `unsynced`, `discountAllowed`
- Private class members: prefix with `_`.
- Constants: `camelCase` (Dart convention for `const` values, not `SCREAMING_SNAKE_CASE`).
  - Correct: `const maxDiscountPercent = 30;`
  - Wrong: `const MAX_DISCOUNT_PERCENT = 30;`

### ARB / l10n keys

- Keys: `camelCase`, structured as `<screen><Action>` or `<domain><Label>`.
  - Correct: `cartProceedToCheckout`, `checkoutConfirmPayment`, `posSearchProducts`
  - Wrong: `button1`, `proceed`, `confirm_payment`
- Plurals and parameterised strings use the ICU message format in the ARB file.

---

## Riverpod (State Management)

- Every provider is defined in the provider file for its feature: `lib/features/<feature>/<feature>_providers.dart`.
- Providers never import other features' provider files directly. Cross-feature data flows through `lib/data/repositories/`.
- A provider that calls a repository must handle the `Result` type from the repository and expose a typed async state — never expose raw `Future` or raw exceptions to the widget tree.
- Business logic belongs in `Notifier` classes, not in widgets and not in repositories. The repository fetches and persists; the notifier decides what to do with the data.
- The `cartProvider` is the single source of truth for the active cart. No widget holds cart state locally. No other provider duplicates cart state.
- `syncProgressProvider` watches the `sync_progress` Drift table. Any screen showing sync progress reads from this provider — it does not poll directly.
- Do not use `StateProvider` for anything beyond a simple toggle or ephemeral UI selection. Anything with business rules goes in a `Notifier`.

---

## Styling (UI Tokens)

All visual values — colours, spacing, radii, typography — are resolved through the theme system defined in `lib/core/theme/app_theme.dart`. The full token reference lives in `ui-context.md`. No raw hex value, raw pixel size, or raw palette constant (`amberPrimary`, `alBg`, etc.) may appear in widget code.

### Colours

- Colours are accessed through three paths — use the correct one for the type of value:
  - `Theme.of(context).colorScheme.*` for background, surface, primary, secondary, error, and text roles.
  - `Theme.of(context).scaffoldBackgroundColor`, `.dividerColor`, `.cardColor` for layout-level colours.
  - `Theme.of(context).extension<AppSemanticColors>()!.success` / `.warning` / `.info` / `.glow` / `.successButton` for semantic state colours.
- Do not write hex literals or `Color(0xFF...)` values in widget files.
  - Correct: `color: Theme.of(context).colorScheme.error`
  - Wrong: `color: const Color(0xFFFF3B30)`
- Do not reference raw palette constants by name (`amberPrimary`, `dangerRed`, `successGreen`). Use the access paths above.

### Spacing

- All spacing scales from a 375 px baseline via `context.getRSize(basePixels)`. There are no static spacing constants.
- Do not write raw pixel values in `EdgeInsets`, `SizedBox`, or `Gap`.
  - Correct: `padding: EdgeInsets.all(context.getRSize(16))`
  - Wrong: `padding: const EdgeInsets.all(16)`
- Common base values: 4, 6, 8, 10, 12, 14, 16, 20, 28, 40, 56. See `ui-context.md` for the full usage table.

### Border radius

- Radius values are constants defined in `lib/core/theme/app_theme.dart` as `AppRadius.*`. Reference them by name — never write a raw `BorderRadius.circular(n)`.
  - Correct: `borderRadius: BorderRadius.circular(AppRadius.md)`
  - Wrong: `borderRadius: BorderRadius.circular(14)`
- Scale: `AppRadius.hairline` 2px / `inputAuth` 10px / `sm` 12px / `md` 14px / `lg` 16px / `xl` 20px / `xxl` 28px. See `ui-context.md` for the full usage mapping.

### Typography

- Use `Theme.of(context).textTheme.<style>` for all text styles. Do not construct `TextStyle` with raw `fontSize` or `fontWeight` outside of `app_theme.dart`.
  - Correct: `style: Theme.of(context).textTheme.titleMedium`
  - Wrong: `style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)`
- Font sizes scale at runtime via `context.getRFontSize(base)`. The theme applies this automatically — do not call `getRFontSize` manually in widget code.

### Inline styles

- No inline `style:` overrides on `Text`, `Container`, or `DecoratedBox` widgets outside of the theme. If a style recurs more than once, it becomes a token or a named widget.

---

## Edge Functions (Supabase / Deno)

Edge Functions are the only code that runs server-side. They handle: applying sync batches transactionally, generating invite codes, and the atomic Danger Zone deletion. These rules apply to every Edge Function.

- **Validate before processing.** The first thing every function does is parse and validate the incoming request body. A malformed or oversized payload is rejected before any database operation runs.
- **Enforce the 200 KB hard cap.** Reject any push-batch body exceeding 200 KB with HTTP 413. Log the rejected size and `business_id` to `sync_audit_rejected`. Do not process the payload at all.
- **Authenticate before mutating.** Verify the JWT and extract `business_id` from claims before touching any row. Reject with HTTP 401 if the token is absent or invalid; reject with HTTP 403 if the `business_id` does not match the rows being mutated.
- **All-or-nothing transactions.** A sync batch is applied inside a single Postgres transaction. If any row in the batch fails, the entire batch rolls back and the function returns an error. The client retries the whole batch.
- **Consistent response shape.** Every function returns JSON with the same envelope:
  - Success: `{ "ok": true, "data": <payload> }`
  - Failure: `{ "ok": false, "error": { "code": "<machine_code>", "message": "<human message>" } }`
- **No business logic in Edge Functions beyond what is listed above.** Discount calculations, wallet balance derivations, and permission checks run on the client from local Drift data. The Edge Function persists; it does not compute.
- **TypeScript strict mode is required** in all Edge Function files. No `any` types. Validate all `unknown` inputs with a type guard or schema parser before use.

---

## Data and Storage

These rules implement the storage model defined in `architecture.md`. They are not preferences.

- Business data belongs in Drift (SQLite). If a piece of state needs to survive an app restart and is not a secret, it goes in Drift.
- Secrets and session pointers belong in `flutter_secure_storage`. The PIN hash, the JWT refresh token, the active business ID, the active store ID, and the last-active staff pointer live here and nowhere else.
- Sync engine internal state (`sync_outbox`, `sync_meta`, `sync_progress`, `sync_debug`) belongs in Drift but is **never added to the outbox**. These tables are device-local only.
- Operator audit records (`sync_audit_rejected`) belong in Supabase Postgres only. They are never mirrored to Drift and never added to the client outbox.
- Wallet and supplier ledger rows are **append-only**. No code may issue an `UPDATE` or `DELETE` on a ledger row. Corrections are new compensating rows. The balance is always derived by summing the ledger, never stored as a single field.
- No Supabase client call may appear in `lib/features/` or `lib/data/repositories/`. All network calls go through `lib/data/remote/`. All SQL goes through `lib/data/local/`.
- IDs for all business-data rows are **UUIDv7**, generated on the client at write time in `lib/core/`. Do not use auto-increment integers or UUIDv4 for rows that pass through the outbox.

---

## Import Order

Dart imports are ordered in the following groups, separated by a blank line. The `dart format` tool and the analysis_options.yaml linter enforce this order.

1. `dart:` SDK imports
2. `package:flutter/` imports
3. Other `package:` imports (alphabetical within this group)
4. Relative project imports, from deepest to shallowest layer

```dart
import 'dart:async';
import 'dart:isolate';

import 'package:flutter/material.dart';

import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/result.dart';
import '../../data/repositories/order_repository.dart';
import 'cart_providers.dart';
```

### Module boundary rules

- `lib/features/<feature>/` may import from: `lib/data/repositories/`, `lib/permissions/`, `lib/auth/`, `lib/core/`, and its own sibling files.
- `lib/features/<feature>/` must not import from: another feature's folder, `lib/data/local/`, `lib/data/remote/`, or `lib/sync/`.
- `lib/data/repositories/` may import from: `lib/data/local/`, `lib/data/remote/`, `lib/core/`.
- `lib/data/repositories/` must not import from: `lib/features/`, `lib/sync/`, any widget.
- `lib/sync/` may import from: `lib/data/local/`, `lib/core/`, `lib/data/remote/` (for the Edge Function caller only).
- `lib/sync/` must not import from: `lib/features/`, any widget, any Riverpod provider.
- `lib/core/` must not import from any other `lib/` folder. It is the bottom of the dependency graph.

A circular import between any two modules is a build error, not a warning.

---

## File Organisation

```
lib/
├── core/                      # Cross-cutting primitives — no feature logic
│   ├── theme/                 # app_theme.dart (AppRadius constants, text theme, ThemeData)
│   ├── router.dart            # Named route definitions
│   ├── result.dart            # Result<T, E> and AppError sealed classes
│   └── id.dart                # UUIDv7 generator
│
├── l10n/                      # ARB files and generated l10n output
│   ├── app_en.arb
│   └── (generated)
│
├── data/
│   ├── local/                 # Drift schema only — tables, DAOs, migrations
│   │   ├── tables/            # One file per Drift table
│   │   ├── daos/              # One file per DAO
│   │   └── app_database.dart  # Drift database class
│   ├── remote/                # Supabase client wrapper and Edge Function callers
│   └── repositories/          # One file per aggregate root
│
├── auth/                      # Session lifecycle, PIN, "Who's working?" picker
├── permissions/               # can(action) resolver, reads from Drift
├── sync/                      # Sync isolate entry point and all sync subsystems
│
└── features/
    ├── pos/                   # Point of sale grid and price tier selector
    ├── cart/                  # Cart, line items, discount application
    ├── checkout/              # Payment method selection and confirmation
    ├── inventory/             # Product list, stock counts, daily count
    ├── customers/             # Customer profiles, wallet ledger view
    ├── orders/                # Pending / completed / cancelled tabs
    ├── expenses/              # Expense entry, approval flow
    ├── suppliers/             # Supplier accounts and ledger
    ├── staff/                 # Staff management, invite flow
    ├── reports/               # Daily reconciliation, profit, approvals queue
    └── settings/              # Role permissions, store settings, danger zone

supabase/
└── functions/                 # One folder per Edge Function (kebab-case)
    ├── apply-sync-batch/
    ├── generate-invite-code/
    └── delete-business/
```

- One Dart file per class. Do not put two classes in one file unless one is a private implementation detail used only by the other.
- Test files mirror the source tree under `test/` with a `_test.dart` suffix.
- Generated files (`*.g.dart`, `*.freezed.dart`) are never edited by hand. Regenerate with `dart run build_runner build`.

---

## Permissions Gating

- A widget that renders a gated action must call `ref.watch(permissionsProvider).can(<action>)` and omit the widget entirely if the result is false. Do not render a disabled version — omit it entirely (hide-don't-block).
- Permission checks are the only acceptable use of an `if` branch in a `build` method that affects which child widgets are returned.
- No feature may hard-code a role name to gate behaviour. `if (role == 'Cashier')` is a standards violation. The correct form is `if (!permissions.can(Action.applyDiscount))`.
- The `can(action)` call reads from Drift via `lib/permissions/`. It is synchronous because permissions are already local. It must not trigger a network call.
