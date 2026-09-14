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

Stop 1 is bracketed by two **cards** — panels that ask the owner for a decision
rather than for a tap on the app behind them. It opens with a welcome card and
closes with a hand-off card. See §10.

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

The off-screen test is **vertical only**. The drawer slides in sideways over
~250 ms, so a horizontal bounds test answers "off-screen" for the length of the
animation and the caption flicks from "scroll down to find Stores" to "tap
Stores" once the slide lands. "Below the fold" is a question about the scroll
axis and nothing else.

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

### 10. The Rail Opens and Closes Stop One With a Card

A dark sheet with a hole in it is an instruction, not an introduction. An owner
who has been given no reason to tap the menu is being ordered about by an app
they signed up to five seconds ago, and the first thing the rail does is take
their screen away.

Stop 1 therefore opens with a **welcome card**: who they are, what a store is
for, and two choices — *Set up my store*, or *I'll look around first*. It closes
with a **hand-off card** the moment the store saves: what they just made, what
comes next, and a way into stop 2. PRD #229 story 28 asks for guidance that ends
by pointing somewhere rather than by stopping; before the hand-off card existed
the rail simply vanished, and stop 2's pointer only ever appeared for an owner
who found their own way to Inventory.

**Invariant:** the cards are configuration of the same overlay, never a second
presentation widget. The overlay takes an optional interactive panel and renders
it centred with no hole cut; it still knows nothing about stores, products or
rails.

### 11. A Step May Have Nothing to Point At

The scroll step cuts **no hole**. It used to cut one over the whole drawer menu
list, which on a phone is most of the screen — and pointer events inside the
hole pass through completely, so every other destination in the drawer was live
during the one stop whose entire job is to keep the owner out of a screen that
cannot work yet. The owner could tap Point of Sale from inside the blocking
sheet.

**Invariant:** a hole is cut only over something the caption is asking the owner
to tap. A step that has something to say and nothing to point at renders its
caption centred, and drags still pass through to the scrollable underneath, so
the owner can scroll exactly as before.

### 12. Drawer State Comes From the Drawer, Not From a Scaffold

MainLayout's Scaffold declares no `drawer:`. Every screen builds its own through
`SharedScaffold`, and a handful build one directly. So `onDrawerChanged` on
MainLayout never fires and `mainScaffoldKey.currentState.isDrawerOpen` reports a
drawer it does not own as permanently closed — which made `nav.isDrawerOpen`
hard-false on every phone. Stop 1 could never leave its first step: the caption
read "Tap the menu to get started" with the drawer wide open over the button the
hole was cut around, and every tap swallowed.

Flutter's `DrawerController` does not build its child while the drawer is
dismissed, so *an `AppDrawer` is mounted* and *a drawer is open or animating*
are the same statement — and unlike `onDrawerChanged`, it is true wherever the
drawer was declared. On desktop the drawer is a permanent sidebar, permanently
open, which is also what this reports.

**Invariant:** `drawerOpenNotifier` is written by a refcount of mounted
`AppDrawer`s and by nothing else; `openDrawer`/`closeDrawer` no longer write it.
Both edges go through the §7 phase-aware path, because the rail's overlay
listens from a sibling `Stack` entry. A static seam
(`test/tour/drawer_presence_ban_test.dart`) holds both halves: every `drawer:`
in `lib/` is an `AppDrawer`, and `AppDrawer` reports through `frameSafe`.

### 13. Declining Is Not Aborting

The rail has two ways to end early and they mean different things.

*I'll look around first*, on the welcome card, is an owner who read the offer and
said no. It ends the rail for the session and touches nothing else. Because
progress is derived from the data, the rail offers again on the next cold start —
the decline defers rather than discards, and #231's empty states and the
Get-started card hold in the meantime.

*Having trouble? Skip setup* is the owner reporting a failure the code could not
detect. It counts towards the device abort threshold in §4.3.

**Invariant:** the device abort count is incremented only by a failure — a
missing target, or an owner who told us they were stuck. It is never incremented
by a healthy decline, so three "not right now"s can never retire the only
guidance an owner will get. This is the letter of #233's rule that the flag is
set by an abort and never by a user action, with the stall escape admitted as
evidence of a failure rather than as a preference.

### 14. The Rail Notices When It Has Trapped Someone

§4.1's missing-target teardown catches a target that is gone. It cannot catch a
step that is simply *wrong*: the target resolves, the hole is cut somewhere
useless, and the sheet goes on swallowing every tap. That is not hypothetical —
it is precisely the failure §12 describes, and nothing in the rail noticed it.

**Invariant:** while a blocking step is on screen, two signals are watched — the
step sitting unchanged for ~20 seconds, and three taps the sheet swallowed. Either
offers the owner a way out, which aborts the rail properly (§13). Both reset
whenever the step changes, because a step change is progress. The taps counted
are taps only: a press that travels beyond touch slop is a drag on its way to a
scrollable underneath, and scrolling a list is not a cry for help.

## Domain Language Additions

- **Rail:** The guided multi-stop first-run onboarding path that walks a new shop owner through initial setup.
- **Stop:** An individual milestone step in a rail (Stop 1: create a Store, blocking; Stop 2: add a Product, non-blocking).
- **Spotlight Overlay:** A generic UI presentation widget cutting a hole in a dark sheet over a designated target with a guidance caption.
- **Card:** A panel on the rail's sheet that asks the owner for a decision rather than for a tap on the app behind it (the welcome and hand-off panels).
