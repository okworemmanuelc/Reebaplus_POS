// catalogue_concession_report_test.dart
//
// PRD #155 US 32 (#200) — "record the concession against the catalogue price, so
// that under-the-counter discounting is visible in margin review."
//
// The column (`order_items.catalogue_price_kobo`, migration 0158), the checkout
// write and the cloud RPC parity (0160) all landed under #176/#183, but nothing
// in the app ever READ the column: `rg cataloguePriceKobo lib` returned the
// schema and the write and nothing else, so the give-away stayed invisible and
// the story was unmet. These tests pin the reader's money math — the pure
// per-line helper the Profit report accumulates once per sold line.
//
// Period-level behaviour (a cancelled order is not a sale, the period filter,
// the van exclusion, per-line store scope) is deliberately NOT retested here:
// the Profit report reaches the concession through the SAME loop and the SAME
// guards that already gate its revenue and COGS, so that is pre-existing shared
// behaviour, not anything this story introduced.
//
// A concession is NOT `orders.discount_kobo` (§13.3): that discount is explicit,
// order-level, and already netted out of Total Sales. A concession is the quiet
// version — the unit price itself was overridden at the till — which is exactly
// why margin review needs its own figure for it.

import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/features/dashboard/reconciliation/report_revenue.dart';

void main() {
  group('lineConcessionKobo — one sold line', () {
    test('no catalogue price means no concession (sold at list)', () {
      // The writer stores the catalogue price ONLY when the till overrode it, so
      // NULL means "went out at list", never "unknown".
      expect(
        lineConcessionKobo(
          cataloguePriceKobo: null,
          unitPriceKobo: 100000,
          quantity: 3,
        ),
        0,
      );
    });

    test('below list: catalogue − charged, times the quantity', () {
      // List ₦1,000, sold at ₦850, three of them → ₦450 given away.
      expect(
        lineConcessionKobo(
          cataloguePriceKobo: 100000,
          unitPriceKobo: 85000,
          quantity: 3,
        ),
        45000,
      );
    });

    test('above list stays SIGNED, so a markup cannot hide a give-away', () {
      // Sold ₦200 ABOVE list. Clamping this to 0 would let one line's markup
      // silently cancel another line's discount in the period total.
      expect(
        lineConcessionKobo(
          cataloguePriceKobo: 100000,
          unitPriceKobo: 120000,
          quantity: 1,
        ),
        -20000,
      );
    });

    test('takes no buying price, so an UNCOSTED line is valued identically', () {
      // The Profit report excludes lines with no recorded buying price from
      // revenue / COGS / margin, and accumulates the concession BEFORE that skip.
      // This helper's signature is what makes that safe: cost is not an input, so
      // a price cut on an uncosted line cannot be valued differently from the
      // same cut on a costed one — and cannot be silently dropped, which would
      // hide exactly the give-away this story exists to surface.
      expect(
        lineConcessionKobo(
          cataloguePriceKobo: 50000,
          unitPriceKobo: 40000,
          quantity: 2,
        ),
        20000,
      );
    });

    test('a zero-quantity line contributes nothing', () {
      expect(
        lineConcessionKobo(
          cataloguePriceKobo: 100000,
          unitPriceKobo: 50000,
          quantity: 0,
        ),
        0,
      );
    });
  });
}
