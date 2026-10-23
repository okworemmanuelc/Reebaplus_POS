# Shopper identity is separate from business membership

**Status: proposed — owner sign-off on invariant #9 wording pending.**
Source: #421 (owner decisions through 2026-10-22), groundwork #422.

One email identifies one login with **at most one business membership**. Shopping
does not create a membership. A login without a business membership is a Shopper;
a business member can also shop using the same login. This preserves the existing
create-business and invite-redemption protections against a second membership.
Separate shopper logins would force people to maintain a second email merely to buy.

Shopper sign-in uses email OTP, no PIN, and a persistent Supabase session. Business
PIN unlock remains device-local. An owner cannot order from their own business;
staff may buy from their employer. Linking a Shopper to a shop's Customer is a
deliberate staff decision on the first accepted order, never a phone-number match.
There is at most one linked Customer per Shopper per business.

A Shopper-only sign-out has no tenant database to wipe. Business logout retains
the existing outbox/photo wipe gate. Deleting shopping data removes the Shopper
profile, saved contact details and account-visible history, cancels unanswered
requests and unlinks shop Customers; the shop retains its own records. A login
with a business membership keeps that business and login. Business deletion
remains exclusively the Danger Zone operation.

## Proposed replacement for invariant #9

> **One email is one identity with at most one business membership.** Email OTP
> and Google with the same resolved email identify the same login. A Shopper is
> not a business membership and may create or join their first business with that
> email. A login already linked to a business, including a staff login, cannot
> create or join a second business. Shopping never changes that restriction.

This ADR proposes the wording; it does not change authentication or routing in
#422. The protected Invariants section remains unchanged until owner sign-off.
