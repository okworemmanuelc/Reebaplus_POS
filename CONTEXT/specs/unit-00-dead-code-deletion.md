# Unit 00: Deletion of All Dead and Duplicate Codes

## Goal

Remove all unused imports, unreachable code, unreferenced files, and duplicate logic across the `lib` directory to improve maintainability and performance. Ensure the project compiles cleanly without any dead code warnings from the Dart analyzer.

## Design

This unit does not introduce new visual components or change the UI design. It enforces the architectural boundaries defined in `architecture.md` (e.g., ensuring `lib/features/`, `lib/data/`, and `lib/sync/` boundaries remain strictly separated) by eliminating repetitive logic and consolidating any duplicated access patterns or UI components.

## Implementation

### 1. `dart analyze` & Unused Code Removal
Run `dart analyze` to systematically identify and remove:
- Unused imports across all Dart files.
- Unused local variables, unreferenced private functions, and uninstantiated classes.
- Unused parameters and unreachable code blocks.

### 2. Duplicate Code Refactoring
Identify and consolidate duplicated logic, paying special attention to:
- **Repositories (`lib/data/repositories/`):** Ensure data access and `sync_outbox` enqueuing patterns are not duplicated.
- **UI Components (`lib/features/`):** Extract identical widgets (e.g., common buttons, dialogs, or list items) into shared UI components, respecting the guidelines in `ui-context.md`.
- **Core Primitives (`lib/core/`):** Move any duplicated crash-handling, ID generation, or currency formatting logic into the `lib/core/` layer.

### 3. Unused Dependencies Cleanup
Review `pubspec.yaml` and `pubspec.lock` against actual project usage. Remove any Dart/Flutter packages that were added during experimentation but are no longer referenced in the codebase.

## Dependencies

- None (No new packages required).

## Verify when done

- [ ] `dart analyze` reports zero warnings regarding unused imports, dead code, or unreferenced variables
- [ ] No duplicate repository or sync logic exists across features
- [ ] `flutter build apk` (or `ios`) passes without errors
- [ ] App launches and core flows (Auth, POS cart, offline sync) function correctly with no regressions
- [ ] `pubspec.yaml` contains only actively utilized dependencies
