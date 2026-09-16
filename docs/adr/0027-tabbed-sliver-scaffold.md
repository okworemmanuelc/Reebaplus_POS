# ADR 0027 — The tabbed-sliver scaffold

**Status:** Accepted
**Date:** 2026-09-16
**Issue:** #243 (slice of PRD #239)
**Supersedes nothing. Amends nothing. Related: ADR 0025 (two-curve responsive scale).**

Written *after* the pattern was proven on Inventory, as PRD #239 asked, rather
than before it.

---

## Context

Five screens — Inventory, Orders, Customer Detail, Supplier Detail and Driver
Profile — are the same shape: header cards that scroll away, a tab bar pinned
beneath them, and a tabbed body. Each hand-rolled that shape, and each
hand-rolled it the same wrong way:

```dart
NestedScrollView(
  headerSliverBuilder: ... ,          // summary cards + pinned tab bar
  body: TabBarView(children: [
    Column(children: [
      FilterBand(),                   // fixed height
      Expanded(child: ListView(...)), // whatever is left
    ]),
  ]),
)
```

A `NestedScrollView` charges its body for the **scroll extent of the headers
above it**. The body box is laid out at `viewportHeight - precedingScrollExtent`,
so the taller the scroll-away header, the shorter the body — at rest, regardless
of how much screen there actually is.

Measured on Inventory before the fix (Products tab, populated catalogue, real
device insets and the bottom nav bar MainLayout puts under every screen):

| viewport | tab body | filter band | list height | complete rows | overflow |
|---|---|---|---|---|---|
| 320x568 portrait | 297.3dp | 113.8dp | 105.3dp | 1 | none |
| 800x360 landscape | 95.6dp | 92.6dp | **0.0dp** | **0** | 67px |
| 915x412 landscape | 147.6dp | 92.6dp | **0.0dp** | **0** | 15px |
| 412x915 portrait | 626.9dp | 103.8dp | 427.9dp | 5 | none |

Two things matter in that table.

**The filter band alone is taller than the body it sits in.** At 800x360 there is
*negative* space. Compression cannot close a negative gap, and a single
`AppDropdown` already spends 73dp of it once its stacked label is counted.

**The red band is the harmless symptom.** It only fires when the tab's content is
a fixed-height widget. With products in the catalogue the list is handed exactly
zero height, renders nothing, and reports no error at all — a screen that looks
fine and is simply blank where the stock should be. That is the mode a staff
member actually hits, and the mode an overflow-only test passes.

---

## Decision

`lib/shared/widgets/tabbed_sliver_scaffold.dart` owns the shape.

```dart
TabbedSliverScaffold(
  controller: tabController,
  headerSlivers: [ SliverToBoxAdapter(child: summaryCards) ],
  tabBar: tabBar,
  tabViews: [
    TabSliverView(storageKey: 'inventory-products', slivers: [...]),
  ],
)
```

Three things are decided here, and each is decided **once**, inside the widget:

1. **Every tab is its own `CustomScrollView`.** Its filter band is a sliver above
   its list, not a fixed box above an `Expanded`. Once nothing inside a tab
   depends on a supplied height, the body's short box stops mattering: it is a
   viewport, its content scrolls, and a short screen costs the user a scroll
   instead of costing them the content.

2. **The scaffold pairs `SliverOverlapAbsorber` with `SliverOverlapInjector`.**
   Without the pairing a tab's scroll view starts at the top of the body box and
   paints its first rows *underneath* the pinned tab bar. This pairing existed
   nowhere in the codebase before this change, which is exactly why it belongs
   in one widget rather than at five call sites.

3. **The pinned tab bar goes through `PinnedTabBarDelegate`** (ADR-less, issue
   #240), which forces the child's rendered height and floors the extent at
   `kMinInteractiveDimension`.

`TabSliverView.storageKey` gives each tab a `PageStorageKey`, so a tab keeps its
scroll offset across tab switches.

### Fix unconditionally

No orientation branch. No short-viewport predicate. The 320x568 portrait case
overflows and sits *above* the existing short-viewport threshold, so a gated fix
would miss it; and a structure that cannot overflow at 800x360 cannot overflow
anywhere. One code path, one layout to maintain.

---

## Consequences

After the fix, same screen, same measurements:

| viewport | tab body | complete rows at rest | complete rows after one scroll | overflow |
|---|---|---|---|---|
| 320x568 portrait | 420.0dp | 1 | 4 | none |
| 800x360 landscape | 212.0dp | 0 | 2 | none |
| 915x412 landscape | 264.0dp | 0 | 3 | none |
| 412x915 portrait | 767.0dp | 5 | 7 | none |

The tab body roughly doubles at every viewport, because the absorber stops the
pinned tab bar taking layout extent out of the body. Nothing overflows anywhere.
The list is never zero-height again.

### The honest limit, recorded on purpose

**On the two landscape phones, no product row is on screen at rest.** PRD #239's
prose asks for "at least one complete row … visible and tappable without
scrolling", and at 800x360 that is arithmetically unreachable: the app bar, the
summary cards, the tab bar and the filter band together exceed the whole 360dp
viewport before a single row is laid out. Reaching it would mean hiding a control
or shrinking a tap target, and the PRD forbids both.

What this ADR guarantees instead is the PRD's own Solution wording: the screen is
**one scrollable surface**, so the row exists at full height and one scroll
reaches it. Before the fix there was nothing to scroll to — the list was exactly
0.0dp tall.

This tension between PRD #239's prose bullet and its own arithmetic is filed back
on #239 rather than resolved here. If a shop owner does want a row at rest on a
360dp-tall phone, the lever is the 25dp stacked label above each dropdown field —
a floating-label re-flow, which the PRD explicitly parks as a separate piece of
work — not a squeeze.

### Rejected alternatives

**Orientation gating / a short-viewport predicate.** Rejected: the 320x568
portrait phone is above the threshold and still broken, so a gate would have
shipped a fix that misses a real device. It also doubles the layouts to maintain.

**Pinning the filter band instead of the tab bar.** Rejected: it spends the
scarcest thing on the screen — at-rest vertical space — on the control the user
touches least, and it does not change the arithmetic at 800x360 at all.

**Compressing padding.** Arithmetically impossible at the narrowest viewport.
There is negative space there; no amount of tightening closes a negative gap.

**Touching the two-curve responsive scale (ADR 0025).** Rejected: the scale is
correct and is not implicated. This defect is structural, and the ~2,700 scaled
call sites are not in its path.

**Making `FirstRunEmptyState` scrollable.** Rejected, and explicitly so: it is
the only *visible* signal that this defect exists on the two screens that
actually have it. It is placed inside a `SliverFillRemaining(hasScrollBody:
false)` — which sizes it to the larger of the remaining viewport and its own
natural height — and the widget itself is untouched.

### What adopting screens must do

The other four screens migrate onto this scaffold in #244–#247. Adopting means
converting each tab body to slivers, which in turn means a nested tab widget must
**build a sliver, not a box** — `InventoryHistoryTab` now returns a
`SliverMainAxisGroup` for exactly this reason. A box widget dropped into
`TabSliverView.slivers` fails at layout, loudly, which is the right failure.
