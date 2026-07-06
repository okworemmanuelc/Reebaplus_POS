# #56 — web-pos money-track crate deposit at checkout (design + resume notes)

**Status:** IN PROGRESS on branch `feat/web-pos-crate-deposit-money-track` (off latest main).
**Decision locked:** order-header amount convention = **(A) goods convention** (see below).
**Next free migration number: `0142`** (0140/0141 already taken by web inventory/stock-adjustment RPCs).

Brings the web `checkout_order` RPC to money-track parity with mobile "Ring 6"
(`OrdersDao.createOrder`), per issue #56 / ADR 0009 (two implementations, one contract).

## The contract (mobile Ring 6 = reference)

`createOrder(crateDepositPaidByManufacturer: {mfrId: depositPaidKobo})`:
- `depositHeld = Σ deposits` (clamped ≥ 0).
- **Deposit only applies to a registered Cash/Transfer sale** (mobile `_depositApplies`,
  `checkout_page.dart`). Credit/wallet sales stay crate-track (deposit 0).
- Wallet legs (the FIXED cross-impl contract to mirror byte-for-byte):
  - debit  `order_payment`  = goods net, signed −.
  - credit `topup_cash`/`topup_transfer` = goods cash, only if > 0.
  - credit `crate_deposit` = `depositHeld`, only if > 0. (Excluded from spendable balance;
    the golden harness already excludes `crate_deposit*` refs — `dart_dao_golden_test.dart`.)
- `payment_transactions.amount` = GRAND cash (goods + deposit).
- Per manufacturer: always write `order_crate_lines` (rate snapshot + `deposit_paid`).
  **deposit_paid == 0** → also `issued` crate_ledger + `customer_crate_balances`++ (crate-track).
  **deposit_paid > 0** → NO ledger/balance (money-track; settled by the held deposit).

## Convention A (goods) — concrete numbers (3× ₦1000 bottle, ₦500 deposit/crate, cash)

Goods gross G=300000, discount 0, net G=300000, depositHeld D=150000, grand=450000.
- order: total 300000, net 300000, discount 0, **amount_paid 300000 (goods)**,
  **crate_deposit_paid_kobo 150000**, status pending.
- payment_transactions: cash, 450000 (grand physical cash).
- wallet_legs: `order_payment` −300000, `topup_cash` +300000, `crate_deposit` +150000.
- customer_balance_after (excl crate_deposit): 0.
- crate_lines: {M1 crates 3, rate 50000, deposit_paid 150000}; crate_ledger []; crate_balances [].

The web RPC already computes goods-only `v_net`, so the carve-out is SIMPLER than mobile's:
no debit subtraction — just add a `crate_deposit` credit leg, set `deposit_paid`, gate
`issued`/balance on `deposit_paid == 0`, add deposit into `payment_transactions`, and guard
`p_amount_paid ≥ v_net + depositHeld`.

## Build plan / remaining steps
1. **DONE:** `golden_scenario.dart` — `FxCheckout.crateDeposits` (Map<mfrKey,int>) + `depositTotalKobo` + fromJson parse of `checkout.crate_deposits`.
2. **TODO fixture:** add money-track scenario(s) to `test/golden/fixtures/crate_sale_scenarios.json`
   — `checkout.amount_paid_kobo` = GOODS cash, `checkout.crate_deposits` = {mfrKey: paid};
   expected as the concrete example above.
3. **TODO Dart runner** (`test/golden/dart_dao_golden_test.dart`): compute `depositHeld` (map mfrKey→id),
   pass `crateDepositPaidByManufacturer`; createOrder args `totalAmountKobo = net + depositHeld`,
   `amountPaidKobo = goodsCash + depositHeld`; OrdersCompanion header `amountPaidKobo = goodsCash`,
   `crateDepositPaidKobo = depositHeld`. Crate-track (empty map) → unchanged.
4. **VALIDATE:** run `flutter test test/golden/dart_dao_golden_test.dart` offline (proves the contract).
5. **TODO migration `0142`**: `DROP` old 8-arg `checkout_order`, `CREATE` 9-arg with
   `p_crate_deposits jsonb DEFAULT '[]'` ([{manufacturer_id, deposit_paid_kobo}]). Deposit carve
   (cash/transfer + registered + crate business only). Web is the only caller → drop-then-create is safe.
6. **TODO RPC runner** (`test/integration/rpcs/checkout_order_golden_test.dart`): pass `p_crate_deposits`
   (grand `p_amount_paid_kobo` = goods + deposits).
7. **TODO web client**: `web-pos/src/lib/rpc.ts` (param), `checkout.ts`, `crate.ts`,
   `components/pos/CheckoutDialog.tsx` (per-manufacturer deposit-collection UI; guard paid ≥ deposit).
8. **TODO deploy**: `supabase db push` (authorized) + push branch → open PR (Closes #56).
   CI Tier-2 RPC golden validates parity **"when secrets present"** — confirm the repo has Supabase
   CI secrets before relying on it.

## Cross-refs
`supabase/migrations/0137_checkout_order_crate.sql` (the RPC to extend, header comment defers this),
mobile Ring 6 `lib/core/database/daos_orders.dart` (~lines 496–910), `checkout_page.dart` `_depositApplies`/`_totalKobo`.
