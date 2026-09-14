# First-Run Rail and Spotlight Overlay Architecture

**Status:** accepted (2026-09-13)

**Parent:** PRD #229 / Issue #233

## Context and Defect

Following the removal of Store creation from the sign-up wizard (#232), a newly registered CEO arrives in the application with zero Stores. While zero Stores does not crash the application (#231), all core actions dead-end: the Point of Sale is empty and cannot sell, Inventory has no store to receive products, and the Add Product form cannot save without a store.

An unguided owner landing in this empty state is presented with walls. While #231 added empty-state surfaces across all reachable screens to direct users to create a store, a proactive, guided first-run flow is needed to lead the owner directly from first landing to their first saved Store.

## Decision

### 1. Two-Stop First-Run Rail

Onboarding after sign-up is structured as a **Rail** with two distinct **Stops**:
1. **Stop 1 (Create a Store):** A blocking tour walking the owner from the Menu button, through the Drawer, to the Stores screen and the New Store form.
2. **Stop 2 (Add a Product):** A non-blocking pointer orienting the owner to add their first product.

The rail ends permanently when both a Store and a Product exist in data. Once the rail ends, the Get-started checklist card on Home takes over remaining milestones (making a sale, inviting the team).

### 2. Blocking Lives in the Sequence, Never the Overlay

The spotlight overlay (`SpotlightOverlay`) is built as a **general presentation capability** with zero knowledge of Stores, Products, or the rail:
- It takes a target position/key, a caption string, and a `blocking` flag.
- It can be reused for future tours (e.g. adding a supplier, taking stock) which will be non-blocking and started on demand.
- **Blocking is a property of the sequence**: Stop 1 configures the overlay with `blocking: true`; Stop 2 and future tours configure it with `blocking: false`. The overlay widget itself remains domain-agnostic and reusable.

### 3. Gesture Handling in Blocking Mode

In blocking mode, the overlay must prevent the owner from interacting with unrelated controls while still allowing menu lists to be scrolled if a target is below the fold:
- **Inside the hole:** Pointer events pass through completely to the spotlighted widget.
- **Outside the hole:** Taps are swallowed, while drags pass through to underlying scrollable views.
- **Implementation mechanism:** A custom gesture recognizer (`BlockingTapSwallowingRecognizer`) tracks pointer events outside the hole. When a pointer release occurs without exceeding touch slop, it eagerly claims `GestureDisposition.accepted`, preventing underlying `InkWell` or button recognizers from firing. If the pointer moves beyond touch slop, the underlying `Scrollable`'s drag recognizer wins the arena, enabling smooth scrolling.
- **In non-blocking mode (`blocking: false`):** All pointer events pass through unimpeded.

### 4. Failure Handling and Resilience

The rail has no close or skip button. To ensure a bug or unexpected layout never traps the owner under a non-interactive dark screen:
1. **Missing Target Teardown:** If a target widget cannot be found or is not mounted within a reasonable timeout, the overlay immediately tears down and returns the owner to the app. It **never** silently advances to the next stop.
2. **Session Abort Flag:** When a tour aborts, a device-local session flag suppresses the overlay for the remainder of the active session. The owner falls back to #231's empty states.
3. **Device Abort Threshold:** After 3 aborts on a given device, the rail is permanently suppressed on that device (recorded in `SharedPreferences` and logged). A bug specific to a device model will not repeatedly flash dark screens on every launch.
4. **Remote Off-Switch:** A high-precedence remote flag can disable the rail app-wide. When enabled, owners land directly in the app with empty states and the Get-started card active.

### 5. Progress Derived Exclusively from Data

Progress through the rail is derived dynamically from data on every launch:
- `!hasStores` → Stop 1 (Create a Store).
- `hasStores && !hasProducts` → Stop 2 (Add a Product).
- `hasStores && hasProducts` → Rail complete (no stops).
- Non-owners never receive any stop.

A saved position inside a stop may remember internal sub-steps, but **cannot mark a stop done**. If the saved position is lost, the current stop simply replays from its beginning. The stop concludes only when the database commits the required row.

### 6. Sub-Step Scroll Step is Conditional

Within Stop 1, the step directing the user to scroll the drawer menu is **strictly conditional on the Stores nav item being off-screen**. On tablets, desktop, or large phones where the item is already within the viewport, the scroll step is skipped automatically.

### 7. The Target Registry Never Notifies Mid-Frame

Targets register from `initState` and unregister from `dispose`, both of which run
while the framework is building or finalising the tree. `registryRevision` is a
`ValueNotifier` that tour widgets listen to, so mutating it there synchronously calls
`markNeedsBuild()` on a listener that is **not** an ancestor of the widget being built —
which Flutter rejects outright (`setState() or markNeedsBuild() called during build`).
Because `MainLayout` warms each tab offstage one per frame and every tab carries a
`MenuButton`, this fires on a brand-new owner's first seconds in the app.

**Invariant:** every revision bump goes through one phase-aware path. Mid-frame, the
bump is deferred to the end of that frame — which also coalesces a burst of
registrations into a single notification.

### 8. A Target Must Be Painted, Not Merely Laid Out

`MainLayout` keeps every visited tab mounted under an `Offstage`, and an offstage
subtree is still laid out: it is attached, has a size, and reports a plausible global
offset. Selecting a target on size alone can therefore hand back the `MenuButton` of a
tab nobody is looking at and cut the hole over empty screen.

**Invariant:** target resolution walks the render tree and rejects any target an
ancestor declines to paint (`RenderObject.paintsChild`). A target with no painted
registration resolves to `null`, which is the missing-target path in §4.1 — the rail
aborts safely rather than pointing at nothing.

### 9. Target Rects Are Re-Resolved Every Painted Frame

A target moves after it registers: the drawer slides in over ~250 ms, a sheet animates
up, a list settles. Resolving once, on the frame the target mounts, freezes everything
derived from that rect — the hole position, and whether the Stores entry counts as
on-screen. For the drawer the first frame is entirely off-screen, so a one-shot read
leaves the owner under a fully dark sheet with a caption and nothing to tap, and the
rail saying "scroll down to find Stores" while Stores sits in plain view.

**Invariant:** while a `SpotlightOverlay` is mounted, the registry re-resolves every
registered rect after each painted frame and bumps `registryRevision` **only when a rect
actually changed**. Bumping unconditionally would rebuild a listener, which schedules
another frame, which ticks again — a frame loop that never idles. Tracking is
refcounted to the mounted overlays, and a post-frame callback does not itself request a
frame, so the chain costs nothing once the app is idle.

## Domain Language Additions

- **Rail:** The guided multi-stop first-run onboarding path that walks a new shop owner through initial setup.
- **Stop:** An individual milestone step in a rail (Stop 1: create a Store, blocking; Stop 2: add a Product, non-blocking).
- **Spotlight Overlay:** A generic UI presentation widget cutting a hole in a dark sheet over a designated target with a guidance caption.
