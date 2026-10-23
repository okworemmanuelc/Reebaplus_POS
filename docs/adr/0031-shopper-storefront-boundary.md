# The Shopper surface is online-first behind a public storefront contract

**Status: accepted — owner approved the Shopper boundary in chat on 2026-10-23.**
Source: #421 (latest owner decisions 2026-10-22), groundwork #422.

The Shopper surface reads and writes through a small, server-validated set of
`SECURITY DEFINER` storefront RPCs. It does not use tenant Drift tables or the
shop outbox. A local key-value cart survives browsing, restart and sign-in;
placement revalidates it in the cloud. The alternative, replicating other shops'
catalogues into Drift, would expose private tenant data and add offline sync to
a surface that needs current availability. Like the Web POS (ADR 0007), this is
an explicit exception, not a change to the till's offline-first contract.

## Approved invariant scope

- **#1:** the business till uses Drift; the Shopper surface requires connectivity
  and renders only public storefront RPC results or the device-local cart.
- **#4:** business writes retain Drift + outbox; Shopper commands use storefront
  RPCs directly, with identity taken from `auth.uid()` and validation server-side.
- **#8:** core/shared storefront services own that cloud access; feature widgets
  consume their contract. Existing one-way dependencies remain in force.
- **#5:** extend the existing public-projection exception: storefront RPCs may
  expose explicitly public listing fields across businesses. Base tenant rows,
  buying prices, cost batches and other customers remain inaccessible.

The approved exceptions are recorded in architecture.md. They authorize no
implementation beyond #422; screens and routing are later slices. Approval does
not waive live security verification or resolve the deletion-tombstone question.

## Eligibility and public listings

A Listing is the Product plus online fields, not a separate listing record.
The cloud must apply the same eligibility rules to feed, search, direct store
pages and Sponsored results:

- Product is not deleted, Show online is on, and it is available for sale.
- Store is online, is a physical store rather than a van, and delivers to the
  Shopper's area. An otherwise eligible out-of-area store may be browsed through
  its direct link but cannot receive an order for that address.
- Business is not deleted, Inactive or trial-ended; product/store is not blocked
  by an admin. Prescription-only categories are excluded. Alcohol needs an 18+
  mark and confirmation before adding/placing an order.
- One card per business per product in the cross-shop feed/search, chosen from
  its nearest delivering store with the best stock label. Cart identity remains
  `(store, product)`. Unmapped categories appear under Other.
- Out-of-stock products are absent from the feed; store pages and search show
  them greyed and not orderable. Stock is a server-computed label, never a raw
  stock field: In stock / Low stock / Only 1–3 left / Out of stock. Placement
  caps quantity against real stock without disclosing it in the refusal.
- After 72 hours without store-device sync, cards are demoted and marked
  "Stock may be out of date"; after 7 days they are hidden (current PRD value).
- Organic ranking uses delivery-area proximity, stock label, photo and recency.
  Sponsored slots remain capped, labelled, eligible and fairly rotated; their
  cap comes from `platform_settings` (#461's newer requirement).

Public responses contain listing content, unit, photos, category, store-currency
price, stock label, crate-deposit note and business name + LGA. Linked Shoppers
receive that business's Customer tier price; others receive Retailer. No raw
tenant table access is granted to signed-out or membership-less logins.

## Ordering and release boundary

One cart can contain several stores, with per-store subtotals rather than a
cross-currency grand total. Placement creates an independent Online Order per
store; failures keep only that store's lines in the cart. An Online Order is a
request: it reserves no stock and moves no revenue, money or crates. Shop writes
remain Drift + outbox; accepted requests become Sales only at normal Checkout.
See ADR 0030 for identity and the deliberate Customer link.

No business login: Browse first; Sell on Reebaplus opens the existing Welcome.
Business login: existing PIN/till path, including offline. Browse offline shows
the connect message with Sell still reachable. Land behind a switch until Browse
→ Place order → shop Online tab works. Screen slices require owner designs.

## Security completion gate

See [the #422 audit](../security/0422-shopper-isolation.md). A profile pointer is
currently the RLS authority, not merely a cached membership. Test direct tenant
access, attempts to forge that pointer, and definer RPC execution separately.
The existing deletion-tombstone read contract requires an explicit owner decision;
do not silently break remote wipe in order to claim zero access.
